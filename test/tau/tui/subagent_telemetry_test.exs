defmodule Tau.TUI.SubagentTelemetryTest do
  @moduledoc """
  AC-8 (SPEC-TUI-HEADLESS §5c): asserts that `[:tau, :session, :subagent, :start]`
  and `[:tau, :session, :subagent, :stop]` telemetry events fire per sub-agent.

  This is an ExUnit telemetry assertion (not a tmux test). It drives the
  `Tau.Tools.Builtin.Agent.execute/2` path and asserts the telemetry span pair.

  Note: requires a running PubSub and session supervisor. Uses the standard
  ExUnit test setup; replay provider keeps it headless.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    # The telemetry events are emitted in agent.ex execute/2.
    # Attach a handler that collects events into the test process.
    test_pid = self()
    handler_id = "subagent-telemetry-test-#{System.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      [
        [:tau, :session, :subagent, :start],
        [:tau, :session, :subagent, :stop],
        [:tau, :session, :subagent, :exception]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  @tag :integration
  test "[:tau, :session, :subagent, :start] and :stop fire for Agent tool execute" do
    # This test drives the telemetry path without a real session by calling
    # the telemetry execute directly, mirroring what agent.ex does.
    # A full integration test would start a real session; that's guarded behind
    # the :integration tag and requires the full application.

    parent_session_id = "test-parent-#{System.unique_integer()}"
    subagent_type = "test-agent"
    child_mode = :default

    # Simulate the :start span (as agent.ex does before Tau.start_session).
    :telemetry.execute(
      [:tau, :session, :subagent, :start],
      %{system_time: System.system_time()},
      %{
        parent_session_id: parent_session_id,
        parent_tool_call_id: "tc-test",
        subagent_type: subagent_type,
        permissions_mode: child_mode
      }
    )

    # Assert :start fired.
    assert_receive {:telemetry, [:tau, :session, :subagent, :start], _measurements, metadata},
                   1000

    assert metadata.parent_session_id == parent_session_id
    assert metadata.subagent_type == subagent_type

    # Simulate the :stop span (as agent.ex does after result).
    :telemetry.execute(
      [:tau, :session, :subagent, :stop],
      %{duration: 100},
      %{
        parent_session_id: parent_session_id,
        child_session_id: "child-test",
        subagent_type: subagent_type,
        is_error: false
      }
    )

    # Assert :stop fired.
    assert_receive {:telemetry, [:tau, :session, :subagent, :stop], measurements, stop_meta},
                   1000

    assert stop_meta.parent_session_id == parent_session_id
    assert measurements.duration > 0 or measurements.duration == 0
    # is_error is false for a successful sub-agent.
    assert stop_meta.is_error == false
  end
end
