defmodule Tau.Session.CodingAgentStreamingTest do
  @moduledoc """
  SPEC-CODING-AGENT §4 B1 / D-037: when a session is started with a
  `:coding_agent` configured, user messages route to the
  `:coding_agent_streaming` FSM state. The dispatcher's normalized
  `Tau.CodingAgent.Event` stream folds into `data.messages` as
  `%Tau.Message.Assistant{}` / `%Tau.Message.ToolResult{}` so the
  existing TUI render path (`Session.Events.MessageEnd`) and
  persistence apply unchanged.

  Drives the FSM through the `Tau.CodingAgents.Replay` adapter so the
  test never spawns a real `claude` subprocess and the assertions are
  deterministic.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Session.Events, as: SE
  alias Tau.CodingAgent.Event, as: CAE

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-ca-stream-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  # The Replay fixture: a basic happy-path run that lets us assert
  # text content, telemetry, and FSM transition without needing git.
  defp happy_fixture do
    [
      %CAE.Start{agent: :replay, version: "test"},
      %CAE.AssistantText{text: "Hello", turn: 0},
      %CAE.AssistantText{text: ", world", turn: 0},
      %CAE.Cost{tokens: %{}, usd: 0.0, duration_ms: 1},
      %CAE.Done{exit_status: 0, final_message: nil}
    ]
  end

  defp tool_fixture do
    [
      %CAE.Start{agent: :replay, version: "test"},
      %CAE.AssistantText{text: "Looking at it.", turn: 0},
      %CAE.ToolUse{id: "t1", name: "Read", input: %{"path" => "README.md"}},
      %CAE.ToolResult{tool_use_id: "t1", content: "file body", is_error: false},
      %CAE.AssistantText{text: "Done.", turn: 1},
      %CAE.Done{exit_status: 0, final_message: nil}
    ]
  end

  defp start_with_fixture(fixture) do
    sid = "ca-stream-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    # Workspace.Cwd backend so the test doesn't need a git repo; the
    # Replay fixture's `replay_fixture` slot is threaded via
    # provider_ctx → ctx.
    {:ok, ^sid} =
      start_session_for_test(
        session_id: sid,
        coding_agent: Tau.CodingAgents.Replay,
        coding_agent_workspace_backend: Tau.CodingAgent.Workspace.Cwd,
        coding_agent_ctx: %{replay_fixture: fixture}
      )

    sid
  end

  describe "happy path — AssistantText events normalize to %Assistant{}" do
    test "MessageEnd carries a non-empty content block with the concatenated text" do
      sid = start_with_fixture(happy_fixture())

      Tau.send(sid, "say hello")

      assert_receive %SE.MessageStart{}, 2_000
      assert_receive %SE.MessageEnd{message: msg}, 2_000

      assert %Tau.Message.Assistant{} = msg
      assert is_list(msg.content) and msg.content != []

      text =
        msg.content
        |> Enum.filter(&match?(%{type: :text}, &1))
        |> Enum.map_join("", & &1.text)

      assert text =~ "Hello"
      assert text =~ "world"
      assert msg.stop_reason == :end_turn
    end

    test "FSM returns to :awaiting_user after Done" do
      sid = start_with_fixture(happy_fixture())
      Tau.send(sid, "say hello")

      assert_receive %SE.MessageEnd{}, 2_000
      Process.sleep(50)

      {:ok, snap} = Tau.snapshot(sid)
      assert snap.state == :awaiting_user
    end

    test "[:tau, :session, :coding_agent_streaming, :start] telemetry fires" do
      parent = self()
      handler_id = "tau-ca-stream-start-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :session, :coding_agent_streaming, :start],
        fn _e, _m, meta, _ -> send(parent, {:tel_start, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      sid = start_with_fixture(happy_fixture())
      Tau.send(sid, "go")

      assert_receive {:tel_start, %{agent: Tau.CodingAgents.Replay}}, 2_000
    end

    test "[:tau, :session, :coding_agent_streaming, :stop] telemetry fires on Done" do
      parent = self()
      handler_id = "tau-ca-stream-stop-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :session, :coding_agent_streaming, :stop],
        fn _e, _m, meta, _ -> send(parent, {:tel_stop, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      sid = start_with_fixture(happy_fixture())
      Tau.send(sid, "go")

      assert_receive {:tel_stop,
                      %{agent: Tau.CodingAgents.Replay, exit_status: 0, stop_reason: :end_turn}},
                     2_000
    end
  end

  describe "ToolUse / ToolResult round-trip" do
    test "ToolUse appends a :tool_call content block; ToolResult becomes a ToolResult message" do
      sid = start_with_fixture(tool_fixture())

      Tau.send(sid, "do it")

      # First assistant message ends when the ToolUse is followed by a
      # ToolResult — the FSM flushes the pending message so the user
      # sees the tool result framed correctly. Then a final
      # MessageEnd carries the post-tool AssistantText.
      assert_receive %SE.MessageStart{}, 2_000
      assert_receive %SE.MessageEnd{message: pre_tool_msg}, 2_000

      assert Enum.any?(pre_tool_msg.content, &match?(%{type: :tool_call, name: "Read"}, &1))

      assert_receive %SE.ToolEnd{tool_call_id: "t1", result: tool_result}, 2_000
      assert %Tau.Message.ToolResult{tool_name: "Read", content: "file body"} = tool_result

      assert_receive %SE.MessageStart{}, 2_000
      assert_receive %SE.MessageEnd{message: post_tool_msg}, 2_000
      assert post_tool_msg.stop_reason == :end_turn

      assert Enum.any?(post_tool_msg.content, fn
               %{type: :text, text: t} -> String.contains?(t, "Done.")
               _ -> false
             end)

      Process.sleep(50)
      {:ok, snap} = Tau.snapshot(sid)
      assert snap.state == :awaiting_user
    end
  end

  describe "regression — no coding_agent leaves provider path byte-identical" do
    test "without :coding_agent the FSM still routes through :provider_streaming" do
      sid = "ca-stream-noflag-#{System.unique_integer([:positive])}"

      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          provider: Tau.Providers.Replay,
          model: "replay"
        )

      Tau.send(sid, "hello")
      Process.sleep(150)

      {:ok, snap} = Tau.snapshot(sid)
      # Either it streamed and returned to awaiting_user, or it's
      # still mid-stream — neither is `:coding_agent_streaming`. The
      # negative assertion is the regression guard.
      refute snap.state == :coding_agent_streaming
    end
  end

  describe "non-recoverable Error event surfaces a visible assistant message" do
    test "Error{recoverable: false} → assistant with stop_reason: :error and non-empty content" do
      fixture = [
        %CAE.Start{agent: :replay},
        %CAE.Error{reason: :auth_failed, recoverable: false},
        # Adapter's dispatcher will follow with a synthetic Done.
        %CAE.Done{exit_status: -1}
      ]

      sid = start_with_fixture(fixture)
      Tau.send(sid, "anything")

      assert_receive %SE.MessageEnd{message: msg}, 2_000
      assert msg.stop_reason == :error
      assert is_binary(msg.error_message) and msg.error_message != ""

      assert msg.content != [],
             "D-009 must hold on the coding-agent path: error content MUST be non-empty"
    end
  end
end
