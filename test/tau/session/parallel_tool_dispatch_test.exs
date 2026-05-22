defmodule Tau.Session.ParallelToolDispatchTest do
  @moduledoc """
  Regression coverage for #33: parallel tool dispatch via
  `Task.Supervisor.async_stream_nolink/4`.

  Verifies that when a tool task crashes mid-flight (the worker process
  exits without `{:ok, _}`), the dispatcher synthesises a synthetic
  `is_error: true` `ToolResult` keyed to the original `tool_call_id`,
  preserving the FSM's tool_call → tool_result correspondence. Without
  this, the next provider turn would see a tool_call with no matching
  tool_result and the loop would wedge.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  defmodule CrashingTool do
    @moduledoc false
    @behaviour Tau.Tool

    @impl true
    def name, do: "crash_tool_for_33"

    @impl true
    def description, do: "Test tool that exits its worker process."

    @impl true
    def parameters,
      do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def execute(_args, _ctx) do
      # Exit the async_stream worker without rescue. async_stream_nolink
      # surfaces this as `{:exit, :crash_for_33}` to the dispatcher.
      Process.exit(self(), :crash_for_33)
    end

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def streams_updates?, do: false
  end

  defmodule ProviderWithToolCall do
    @moduledoc false
    @behaviour Tau.Provider

    # First call: emit a tool_call. Second call (after the synthetic
    # tool_result): emit a clean text response so the FSM can return
    # to :awaiting_user without hanging.
    @impl true
    def stream(messages, _opts, _ctx) do
      has_tool_result? =
        Enum.any?(messages, &match?(%Tau.Message.ToolResult{}, &1))

      events =
        if has_tool_result? do
          [
            %Event.Start{request_id: "r2", model: "p33"},
            %Event.TextStart{block_id: "t1"},
            %Event.TextDelta{block_id: "t1", text: "ok-after-crash"},
            %Event.TextEnd{block_id: "t1"},
            %Event.Done{stop_reason: :stop, usage: %{}}
          ]
        else
          [
            %Event.Start{request_id: "r1", model: "p33"},
            %Event.ToolCallStart{tool_call_id: "call-33", name: "crash_tool_for_33"},
            %Event.ToolCallEnd{tool_call_id: "call-33", params: %{}},
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
        parallel_tools: true
      }

    @impl true
    def default_model, do: "p33"
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-tool-dispatch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    # Make the FSM register CrashingTool at session boot.
    prior_builtins = Application.get_env(:tau, :builtin_tools, [])
    Application.put_env(:tau, :builtin_tools, [CrashingTool | prior_builtins])

    on_exit(fn ->
      Application.put_env(:tau, :builtin_tools, prior_builtins)
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  test "tool worker exit surfaces as synthetic is_error tool_result" do
    sid = "tool-crash-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: ProviderWithToolCall,
        model: "p33",
        session_id: sid,
        # SPEC-PERMISSION-PROMPTS: bypass permissions — this test exercises
        # tool worker crash isolation, not the permission system.
        metadata: %{permissions_mode: :bypass}
      )

    Tau.send(sid, "please use the crashing tool")

    # The dispatcher should synthesise a ToolResult keyed to "call-33".
    assert_receive %SE.ToolEnd{
                     tool_call_id: "call-33",
                     result: %Tau.Message.ToolResult{is_error: true, content: content}
                   },
                   5_000

    assert content =~ "Tool task crashed"
    assert content =~ "crash_for_33"

    # Second turn (after the synthetic result is fed back) finalises cleanly.
    assert_receive %SE.MessageEnd{message: %{content: [%{text: "ok-after-crash"}]}}, 5_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user

    # JSONL records the synthetic tool_result with is_error: true.
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    rows =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    tool_result =
      Enum.find(rows, fn r ->
        r["kind"] == "tool_result" and r["data"]["tool_call_id"] == "call-33"
      end)

    assert tool_result
    assert tool_result["data"]["is_error"] == true
  end
end
