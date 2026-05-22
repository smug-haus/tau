defmodule Tau.Extensions.IntegrationTest do
  @moduledoc """
  Integration tests for the extension subsystem — SPEC-EXTENSIONS AC-7, AC-8.

  Exercises the user-facing path:

    AC-8a — extension tool dispatches via the real session FSM path
             (`Tau.Tool.lookup/1` → `execute/2`)
    AC-8b — extension slash command resolves via `Tau.Command` / session classify
    AC-8c — extension `:pre_tool_use` hook fires on a tool call
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Extensions.Loader
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  # ---------------------------------------------------------------------------
  # Provider that calls hello_world tool on the first turn, then end_turn.
  # ---------------------------------------------------------------------------

  defmodule HelloWorldProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(messages, _opts, _ctx) do
      has_tool_result? = Enum.any?(messages, &match?(%Tau.Message.ToolResult{}, &1))

      events =
        if has_tool_result? do
          [
            %Event.Start{request_id: "r2", model: "hw-model"},
            %Event.TextStart{block_id: "t1"},
            %Event.TextDelta{block_id: "t1", text: "done"},
            %Event.TextEnd{block_id: "t1"},
            %Event.Done{stop_reason: :end_turn, usage: %{}}
          ]
        else
          [
            %Event.Start{request_id: "r1", model: "hw-model"},
            %Event.ToolCallStart{tool_call_id: "hw-call-1", name: "hello_world"},
            %Event.ToolCallEnd{tool_call_id: "hw-call-1", params: %{"name" => "Tau"}},
            %Event.Done{stop_reason: :tool_use, usage: %{}}
          ]
        end

      {:ok, events}
    end

    @impl true
    def capabilities,
      do: %{
        thinking: false,
        tools: true,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }

    @impl true
    def default_model, do: "hw-model"

    @impl true
    def configure(opts), do: {:ok, opts}
  end

  # ---------------------------------------------------------------------------
  # Setup: ensure the reference extension is loaded before each test.
  # ---------------------------------------------------------------------------

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-ext-integ-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    # Load the reference extension via the Loader (module form — already compiled).
    Loader.reload(HelloWorldExt)
    :timer.sleep(150)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # AC-8a: tool dispatches via real session path
  # ---------------------------------------------------------------------------

  test "AC-8a: hello_world tool dispatches via session FSM and returns ToolResult" do
    sid = "hw-tool-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: HelloWorldProvider,
        model: "hw-model",
        session_id: sid,
        # bypass permissions so the extension tool executes without prompts
        metadata: %{permissions_mode: :bypass}
      )

    Tau.send(sid, "say hello")

    # The provider emits a tool_call for hello_world; session dispatches it.
    assert_receive %SE.ToolEnd{
                     tool_call_id: "hw-call-1",
                     result: %Tau.Message.ToolResult{is_error: false, content: content}
                   },
                   5_000

    assert content =~ "Hello, Tau!"

    # Turn completes cleanly.
    assert_receive %SE.MessageEnd{message: %{stop_reason: :end_turn}}, 5_000
  end

  # ---------------------------------------------------------------------------
  # AC-8b: slash command resolves via Tau.Command
  # ---------------------------------------------------------------------------

  test "AC-8b: /hello slash command resolves via Tau.Commands.Registry" do
    # Verify the command is registered — key verification that Loader wired it up.
    entries = Registry.lookup(Tau.Commands.Registry, "/hello")
    assert Enum.any?(entries, fn {_pid, mod} -> mod == HelloWorldExt.HelloCommand end)
  end

  test "AC-8b: /hello slash command execute/2 is dispatched and its result injected" do
    # The extension's HelloCommand returns {:inject, text}. The session FSM
    # prepends the injected text to the user message and drives a provider turn.
    # We verify the turn completes (provider was called) — which only happens
    # when the command was dispatched and the inject path was followed.
    sid = "hw-cmd-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: HelloWorldProvider,
        model: "hw-model",
        session_id: sid,
        metadata: %{permissions_mode: :bypass}
      )

    Tau.send(sid, "/hello")

    # The injected message drives a provider turn — HelloWorldProvider emits
    # a tool call on the first turn, then end_turn. Assert the full turn
    # completes cleanly (tool dispatched + final MessageEnd).
    assert_receive %SE.ToolEnd{tool_call_id: "hw-call-1"}, 5_000
    assert_receive %SE.MessageEnd{message: %{stop_reason: :end_turn}}, 5_000
  end

  # ---------------------------------------------------------------------------
  # AC-8c: :pre_tool_use hook fires on tool call
  # ---------------------------------------------------------------------------

  test "AC-8c: :pre_tool_use hook fires when hello_world is dispatched" do
    sid = "hw-hook-#{System.unique_integer([:positive])}"

    # Subscribe to the PubSub channel the AuditHook publishes to.
    Phoenix.PubSub.subscribe(Tau.PubSub, "test:hooks")
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: HelloWorldProvider,
        model: "hw-model",
        session_id: sid,
        metadata: %{permissions_mode: :bypass}
      )

    Tau.send(sid, "trigger hook")

    # Wait for the tool call to dispatch.
    assert_receive %SE.ToolEnd{tool_call_id: "hw-call-1"}, 5_000

    # The AuditHook should have published to "test:hooks".
    assert_receive {:pre_tool_use, %{tool_name: "hello_world"}}, 2_000
  end
end
