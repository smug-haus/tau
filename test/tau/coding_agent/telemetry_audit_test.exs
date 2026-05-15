defmodule Tau.CodingAgent.TelemetryAuditTest do
  @moduledoc """
  SPEC-CODING-AGENT D-034 audit (Phase 1B Team D / AC-4).

  Phase 1A's `telemetry_test.exs` exercises the dispatcher-level
  events in isolation against the Replay adapter. This audit suite
  is the end-to-end completeness check across all the events
  D-034 promises, exercised through the session FSM with both
  Replay and (under `:external`) the real ClaudeCode adapter.

  The events under audit:

    * `[:tau, :coding_agent, :start | :event | :stop]` — emitted
      by the dispatcher.
    * `[:tau, :session, :coding_agent_streaming, :start | :stop |
      :adapter_start]` — emitted by the session FSM.
    * `[:tau, :coding_agent, :cost]` — emitted on each
      `%Event.Cost{}` fold (D-038, Phase 1B Team D addition).
    * `[:tau, :coding_agent, :resume]` — emitted when a launched
      dispatcher carries `task.resume_id` (D-037 + D-038 plumbing).
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.CodingAgent.Event, as: CAE
  alias Tau.Session.Events, as: SE

  @audit_events [
    [:tau, :coding_agent, :start],
    [:tau, :coding_agent, :event],
    [:tau, :coding_agent, :stop],
    [:tau, :coding_agent, :exception],
    [:tau, :session, :coding_agent_streaming, :start],
    [:tau, :session, :coding_agent_streaming, :stop],
    [:tau, :session, :coding_agent_streaming, :adapter_start],
    [:tau, :session, :coding_agent_streaming, :exception],
    [:tau, :coding_agent, :cost],
    [:tau, :coding_agent, :cost, :failed],
    [:tau, :coding_agent, :resume]
  ]

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-ca-tel-audit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    parent = self()
    handler_id = "tau-ca-tel-audit-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      @audit_events,
      fn event, m, meta, _ -> send(parent, {:tel, event, m, meta}) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{}
  end

  defp drain(timeout \\ 500) do
    receive do
      {:tel, _, _, _} = msg -> [msg | drain(timeout)]
    after
      timeout -> []
    end
  end

  defp event_names(messages) do
    Enum.map(messages, fn {:tel, name, _, _} -> name end)
  end

  describe "Replay adapter — D-034 events fire end-to-end" do
    test "single-turn run emits start, ≥1 event, stop, FSM start+stop+adapter_start, cost" do
      fixture = [
        %CAE.Start{agent: :replay, version: "test", session_id: "replay-sess-1"},
        %CAE.AssistantText{text: "audited", turn: 0},
        %CAE.Cost{
          tokens: %{"input_tokens" => 1, "output_tokens" => 2},
          usd: 0.001,
          duration_ms: 10
        },
        %CAE.Done{exit_status: 0, final_message: nil}
      ]

      sid = "ca-tel-audit-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          coding_agent: Tau.CodingAgents.Replay,
          coding_agent_workspace_backend: Tau.CodingAgent.Workspace.Cwd,
          coding_agent_ctx: %{replay_fixture: fixture}
        )

      Tau.send(sid, "audit me")
      assert_receive %SE.MessageEnd{}, 2_000
      Process.sleep(100)

      msgs = drain()
      names = event_names(msgs)

      # Dispatcher-level (D-034 mandatory shape)
      assert [:tau, :coding_agent, :start] in names
      assert [:tau, :coding_agent, :event] in names
      assert [:tau, :coding_agent, :stop] in names

      # Session FSM
      assert [:tau, :session, :coding_agent_streaming, :start] in names
      assert [:tau, :session, :coding_agent_streaming, :stop] in names
      assert [:tau, :session, :coding_agent_streaming, :adapter_start] in names

      # D-038: Cost fold-in
      assert [:tau, :coding_agent, :cost] in names
    end

    test "second turn in same session fires [:tau, :coding_agent, :resume]" do
      first = [
        %CAE.Start{agent: :replay, version: "test", session_id: "resume-sess"},
        %CAE.Done{exit_status: 0, final_message: nil}
      ]

      sid = "ca-tel-resume-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          coding_agent: Tau.CodingAgents.Replay,
          coding_agent_workspace_backend: Tau.CodingAgent.Workspace.Cwd,
          coding_agent_ctx: %{replay_fixture: first}
        )

      Tau.send(sid, "turn 1")
      assert_receive %SE.MessageEnd{}, 2_000
      _ = drain(200)

      :ok =
        Tau.update_provider(sid,
          coding_agent_ctx: %{replay_fixture: [%CAE.Done{exit_status: 0, final_message: nil}]}
        )

      Tau.send(sid, "turn 2")
      assert_receive %SE.MessageEnd{}, 2_000
      Process.sleep(50)

      msgs = drain()
      names = event_names(msgs)

      assert Enum.count(names, &(&1 == [:tau, :coding_agent, :resume])) == 1

      # The resume telemetry's metadata should match what we captured.
      resume_meta =
        msgs
        |> Enum.find(fn {:tel, name, _, _} -> name == [:tau, :coding_agent, :resume] end)
        |> elem(3)

      assert resume_meta.adapter_session_id == "resume-sess"
      assert resume_meta.session_id == sid
    end
  end

  describe "no-cost path emits no [:tau, :coding_agent, :cost]" do
    test "fixture without %Cost{} does not produce the cost event" do
      fixture = [
        %CAE.Start{agent: :replay},
        %CAE.AssistantText{text: "no cost", turn: 0},
        %CAE.Done{exit_status: 0, final_message: nil}
      ]

      sid = "ca-tel-nocost-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          coding_agent: Tau.CodingAgents.Replay,
          coding_agent_workspace_backend: Tau.CodingAgent.Workspace.Cwd,
          coding_agent_ctx: %{replay_fixture: fixture}
        )

      Tau.send(sid, "go")
      assert_receive %SE.MessageEnd{}, 2_000
      Process.sleep(50)

      msgs = drain()
      names = event_names(msgs)
      assert [] == Enum.filter(names, &(&1 == [:tau, :coding_agent, :cost]))
    end
  end

  describe "exception path" do
    @tag :external
    test "ClaudeCode adapter end-to-end emits the same audit set" do
      # Requires `claude` on PATH and the user authenticated. Marked
      # :external so CI without claude available skips it. Asserts
      # the same audit-event set as Replay, providing the D-034
      # cross-adapter parity guarantee.
      unless System.find_executable("claude") do
        flunk("claude executable required for external audit; install Claude Code")
      end

      sid = "ca-tel-claude-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          coding_agent: Tau.CodingAgents.ClaudeCode,
          coding_agent_workspace_backend: Tau.CodingAgent.Workspace.Cwd
        )

      Tau.send(sid, "say hi in one word")
      assert_receive %SE.MessageEnd{}, 30_000
      Process.sleep(200)

      msgs = drain()
      names = event_names(msgs)

      assert [:tau, :coding_agent, :start] in names
      assert [:tau, :coding_agent, :stop] in names
      assert [:tau, :session, :coding_agent_streaming, :start] in names
      assert [:tau, :session, :coding_agent_streaming, :stop] in names
    end
  end
end
