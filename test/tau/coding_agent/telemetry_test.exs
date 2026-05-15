defmodule Tau.CodingAgent.TelemetryTest do
  @moduledoc """
  Asserts the `[:tau, :coding_agent, *]` event names and metadata
  shape documented in SPEC-CODING-AGENT.md §4 B5 (D-034).

  Phase 1A: Replay only. The same handler will be reused against
  the ClaudeCode adapter in Phase 1B.
  """

  use ExUnit.Case, async: false

  alias Tau.CodingAgent.Dispatcher
  alias Tau.CodingAgent.Event

  setup do
    test_pid = self()
    handler_id = "tau-coding-agent-telem-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:tau, :coding_agent, :start],
        [:tau, :coding_agent, :event],
        [:tau, :coding_agent, :stop],
        [:tau, :coding_agent, :exception]
      ],
      fn event, measurements, metadata, _config ->
        Kernel.send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "happy path emits :start then per-event :event then :stop with documented metadata" do
    task = %{prompt: "p", workspace: System.tmp_dir!()}

    args = [
      adapter: Tau.CodingAgents.Replay,
      task: task,
      ctx: %{session_id: "sess-xyz"},
      subscriber: self()
    ]

    {:ok, pid} = Dispatcher.start_link(args)
    {:ok, _events} = Dispatcher.await(pid)

    assert_receive {:telemetry, [:tau, :coding_agent, :start], _m,
                    %{adapter: Tau.CodingAgents.Replay, session_id: "sess-xyz"}},
                   1_000

    # At least one :event hit before stop.
    assert_receive {:telemetry, [:tau, :coding_agent, :event], _m,
                    %{adapter: Tau.CodingAgents.Replay, event: Event.Start}},
                   1_000

    assert_receive {:telemetry, [:tau, :coding_agent, :stop], measurements,
                    %{adapter: Tau.CodingAgents.Replay, exit_status: 0}},
                   1_000

    assert is_integer(measurements.duration)
    assert measurements.events_count >= 4
  end

  test "cancel emits :stop with exit_status: -2 and reason: :cancelled" do
    events = [
      %Event.Start{agent: :replay},
      %Event.AssistantText{text: "x"},
      %Event.Done{exit_status: 0}
    ]

    args = [
      adapter: Tau.CodingAgents.Replay,
      task: %{prompt: "p", workspace: System.tmp_dir!(), replay_fixture: events},
      ctx: %{replay_delay_ms: 50},
      subscriber: self()
    ]

    {:ok, pid} = Dispatcher.start_link(args)

    # Make sure the run is in-flight before cancelling.
    assert_receive {:telemetry, [:tau, :coding_agent, :event], _m, _meta}, 1_000
    Dispatcher.cancel(pid)

    assert_receive {:telemetry, [:tau, :coding_agent, :stop], _m,
                    %{exit_status: -2, reason: :cancelled}},
                   1_000
  end
end
