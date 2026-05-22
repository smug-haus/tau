defmodule Tau.TUI.SubagentTelemetryTest do
  @moduledoc """
  AC-8 (SPEC-TUI-HEADLESS §5c, D-159): asserts that `[:tau, :session, :subagent, :start]`
  and `[:tau, :session, :subagent, :stop]` telemetry events fire per sub-agent dispatch.

  This test drives the **real production path**: it starts a parent session that causes the
  `Tau.Tools.Builtin.Agent` tool to execute (via `MultiFixtureProvider`), attaches a
  telemetry handler, and asserts the span pair fires **from `agent.ex`** — not from a
  hand-crafted `telemetry.execute` call.

  The test MUST fail if the `:telemetry.execute/3` calls in `agent.ex` are removed, because
  no production code would fire those events. This distinguishes it from the prior tautological
  test (refine-2 critic finding) which would have passed even with no telemetry in agent.ex.

  Uses `async: false` because it attaches a process-wide telemetry handler.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE
  alias Tau.Test.MultiFixtureProvider

  # Fixtures identical to those in agent_test.exs — parent triggers Agent tool,
  # child responds with :end_turn, parent receives ToolResult and completes.
  defp agent_tool_call_fixture(call_id, description) do
    [
      %Event.Start{request_id: "telm-parent-r1", model: "multi-fixture"},
      %Event.ToolCallStart{tool_call_id: call_id, name: "Agent"},
      %Event.ToolCallEnd{
        tool_call_id: call_id,
        params: %{"description" => description}
      },
      %Event.Done{stop_reason: :tool_use, usage: %{}}
    ]
  end

  defp parent_end_turn_fixture do
    [
      %Event.Start{request_id: "telm-parent-r2", model: "multi-fixture"},
      %Event.TextStart{block_id: "b0"},
      %Event.TextDelta{block_id: "b0", text: "telm-parent done"},
      %Event.TextEnd{block_id: "b0"},
      %Event.Done{stop_reason: :end_turn, usage: %{}}
    ]
  end

  defp child_text_fixture(text) do
    [
      %Event.Start{request_id: "telm-child-r1", model: "multi-fixture"},
      %Event.TextStart{block_id: "b0"},
      %Event.TextDelta{block_id: "b0", text: text},
      %Event.TextEnd{block_id: "b0"},
      %Event.Done{stop_reason: :end_turn, usage: %{}}
    ]
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "tau-subagent-telm-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

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

    on_exit(fn ->
      :telemetry.detach(handler_id)
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{tmp: tmp}
  end

  @tag :integration
  test "[:tau, :session, :subagent, :start] and :stop fire from Agent.execute/2 (AC-8 / D-159)",
       %{tmp: tmp} do
    # This test exercises the REAL production path: Tau.Tools.Builtin.Agent.execute/2
    # is the canonical source of the telemetry span pair (D-159). It MUST fail if the
    # :telemetry.execute/3 calls in agent.ex are removed.

    parent_sid = Tau.Session.generate_id()
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{parent_sid}")

    call_id = "telm-agent-call-1"
    child_text = "child result from telemetry test"

    provider_ctx = %{
      parent_session_id: parent_sid,
      parent_first_fixture: agent_tool_call_fixture(call_id, "run a sub-task"),
      parent_second_fixture: parent_end_turn_fixture(),
      child_fixture: child_text_fixture(child_text)
    }

    {:ok, ^parent_sid} =
      start_session_for_test(
        provider: MultiFixtureProvider,
        session_id: parent_sid,
        cwd: tmp,
        # bypass permissions so Agent tool runs without permission gate
        metadata: %{permissions_mode: :bypass},
        provider_ctx: provider_ctx
      )

    Tau.send(parent_sid, "please run the sub-agent")

    # Wait for parent to complete its second turn — confirms the full Agent.execute/2
    # path ran (parent got ToolResult → issued second provider call → :end_turn).
    assert_receive %SE.MessageEnd{message: %{stop_reason: :end_turn}}, 15_000

    # D-159: [:tau, :session, :subagent, :start] MUST have fired from agent.ex before
    # the child was spawned. The metadata carries the parent_session_id.
    assert_receive {:telemetry, [:tau, :session, :subagent, :start], _measurements, start_meta},
                   1_000

    assert start_meta.parent_session_id == parent_sid,
           "subagent :start metadata MUST carry the parent session id; got: #{inspect(start_meta)}"

    # D-159: [:tau, :session, :subagent, :stop] MUST have fired from agent.ex after
    # the child completed. The metadata must have is_error: false for a clean result.
    assert_receive {:telemetry, [:tau, :session, :subagent, :stop], stop_measurements, stop_meta},
                   1_000

    assert stop_meta.parent_session_id == parent_sid,
           "subagent :stop metadata MUST carry the parent session id; got: #{inspect(stop_meta)}"

    assert stop_meta.is_error == false,
           "subagent :stop metadata MUST have is_error: false for a clean child result"

    assert is_integer(stop_measurements.duration) and stop_measurements.duration >= 0,
           "subagent :stop measurements MUST include a non-negative duration; got: #{inspect(stop_measurements)}"
  end
end
