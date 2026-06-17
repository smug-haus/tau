defmodule Tau.Factory.ReportingEscalationOnlyTest do
  @moduledoc """
  Gating test for issue #556 — INV-REPORTING-ESCALATION-ONLY.

  Enforces **INV-REPORTING-ESCALATION-ONLY** (D-S1 escalation-only autonomy):
  the Coordinator MUST emit operator-facing reports via PubSub ONLY at:

    1. **Milestone boundary** — when `select_fun → nil` (work exhausted),
       the Coordinator MUST broadcast a `:milestone_complete` (or equivalent)
       message on the `"factory:report"` PubSub topic.

    2. **Escalation events** — when a global or per-unit escalation fires,
       the Coordinator MUST broadcast an `:escalation` (or equivalent) message
       on the `"factory:escalation"` PubSub topic.

  Source: SPEC-FACTORY-CORE.md §4 Q7 [C117]:
    > The **observation plane is PubSub** (`"factory:report"`, `"factory:pr:<id>"`,
    > `"factory:escalation"`) — decoupled fan-out to observers, never the control
    > path.

  And factory-loop.md §Reporting cadence:
    > reports to the user only at **milestone boundaries** and on **escalation**.

  And SPEC-FACTORY-CORE.md §6 **D-336 — Escalation conservation:**
    > every raised escalation is delivered to the operator and recorded with
    > reason + state snapshot; none is raised-and-swallowed.

  ## Fail-before validity

  The current `Tau.Factory.Coordinator` (coordinator.ex):
    - `running(:internal, :loop, data)` with `select_fun → nil` only sets
      `in_flight: nil` and keeps state — NO `Phoenix.PubSub.broadcast/3` on
      `"factory:report"`. (lines 156-166)
    - Escalation handlers call only `telemetry/3` and stay/transition state —
      NO `Phoenix.PubSub.broadcast/3` on `"factory:escalation"`. (lines 230-240)

  Both assertions below FAIL against the current implementation and pass only
  once the Coordinator broadcasts on the required PubSub topics at the required
  lifecycle points.

  ## What constitutes the operator-facing report

  The SPEC names the PubSub topic but does not prescribe a payload shape for
  the observation plane (C117 says "decoupled fan-out to observers"). The
  minimal conformant signal is any broadcast message on the correct topic at
  the correct lifecycle point. The test subscribes and asserts receipt of ANY
  message on the required topic — it does NOT prescribe payload shape, allowing
  the implementer freedom in struct design.

  AC/D-NNN linkage: INV-REPORTING-ESCALATION-ONLY, D-336.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :inv_reporting_escalation_only
  @moduletag :d_336

  @coordinator Tau.Factory.Coordinator

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # ---------------------------------------------------------------------------
  # INV-REPORTING-ESCALATION-ONLY / D-336 — Part 1: milestone boundary report.
  #
  # Timeline:
  #   1. Subscribe to `"factory:report"` on Tau.PubSub.
  #   2. Start Coordinator with select_fun that returns one work item then nil.
  #   3. drive_fun immediately sends {:unit_terminal, …} back (instant unit).
  #   4. The second loop iteration has select_fun → nil = milestone exhausted.
  #   5. Assert a message is received on `"factory:report"` (milestone boundary).
  #
  # FAILS against current code: running(:internal, :loop, data) with nil return
  # only sets in_flight: nil — no PubSub broadcast is emitted.
  # ---------------------------------------------------------------------------

  @tag :inv_reporting_escalation_only
  @tag :d_336
  test "INV-REPORTING-ESCALATION-ONLY: Coordinator broadcasts on \"factory:report\" at milestone boundary (select_fun → nil)" do
    coord_name = unique_name(:coord_report)
    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:report")

    work_item = "unit-milestone-#{System.unique_integer([:positive])}"

    # select_fun: returns one work item (first call), then nil (milestone drained).
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    select_fun = fn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      if n == 0, do: work_item, else: nil
    end

    # drive_fun: immediately signals unit terminal so loop can re-enter idle path.
    drive_fun = fn _work ->
      coord_pid = Process.whereis(coord_name)
      if is_pid(coord_pid), do: send(coord_pid, {:unit_terminal, work_item, :merged})
      :ok
    end

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: select_fun,
        drive_fun: drive_fun,
        scheduler: nil
      },
      id: coord_name
    )

    # The Coordinator drives the one work item, receives its terminal, then calls
    # select_fun again → nil. At this point the milestone boundary is reached and
    # INV-REPORTING-ESCALATION-ONLY requires a broadcast on "factory:report".
    assert_receive msg,
                   2000,
                   "INV-REPORTING-ESCALATION-ONLY violation: no message received on " <>
                     "\"factory:report\" after milestone boundary (select_fun → nil). " <>
                     "The Coordinator must broadcast an operator-facing report when the " <>
                     "milestone is drained."

    assert is_tuple(msg) or is_atom(msg),
           "Received a non-message value on \"factory:report\": #{inspect(msg)}"
  end

  # ---------------------------------------------------------------------------
  # INV-REPORTING-ESCALATION-ONLY / D-336 — Part 2: escalation report.
  #
  # Timeline:
  #   1. Subscribe to `"factory:escalation"` on Tau.PubSub.
  #   2. Start Coordinator with select_fun that idles (always nil).
  #   3. Deliver a global escalation {:escalate, {reason, :global}}.
  #   4. Assert a message is received on `"factory:escalation"`.
  #
  # D-336: every raised escalation is delivered to the operator and recorded;
  # none is raised-and-swallowed.
  #
  # FAILS against current code: running(:info, {:escalate, {_e, :global}}, data)
  # calls only telemetry/3 — no PubSub broadcast on "factory:escalation".
  # ---------------------------------------------------------------------------

  @tag :inv_reporting_escalation_only
  @tag :d_336
  test "INV-REPORTING-ESCALATION-ONLY / D-336: Coordinator broadcasts on \"factory:escalation\" when a global escalation fires" do
    coord_name = unique_name(:coord_esc_report)
    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:escalation")

    # Idle coordinator: select_fun always returns nil so no unit is in flight
    # when we deliver the escalation (simpler path; drain is not the concern here).
    select_fun = fn -> nil end
    drive_fun = fn _work -> :ok end

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: select_fun,
        drive_fun: drive_fun,
        scheduler: nil
      },
      id: coord_name
    )

    # Give the Coordinator a moment to reach the idle path.
    Process.sleep(20)

    # Deliver a global escalation directly to the Coordinator's mailbox (the
    # same mechanism used by escalation_drain_test.exs and kill_switch_test.exs).
    send(coord_name, {:escalate, {:E_TEST_ESCALATION, :global}})

    assert_receive msg,
                   2000,
                   "INV-REPORTING-ESCALATION-ONLY / D-336 violation: no message received " <>
                     "on \"factory:escalation\" after a global escalation event. " <>
                     "D-336 requires every escalation to be delivered to the operator; " <>
                     "the Coordinator must broadcast on \"factory:escalation\"."

    assert is_tuple(msg) or is_atom(msg),
           "Received a non-message value on \"factory:escalation\": #{inspect(msg)}"
  end

  # ---------------------------------------------------------------------------
  # INV-REPORTING-ESCALATION-ONLY / D-336 — Part 3: per-unit escalation report.
  #
  # Per-unit escalations keep the loop running (D-320) but are ALSO escalation
  # events per D-336 and must be delivered to the operator on
  # "factory:escalation".
  #
  # FAILS against current code: running(:info, {:escalate, {_e, :unit}}, data)
  # calls only telemetry/3 — no PubSub broadcast on "factory:escalation".
  # ---------------------------------------------------------------------------

  @tag :inv_reporting_escalation_only
  @tag :d_336
  test "INV-REPORTING-ESCALATION-ONLY / D-336: Coordinator broadcasts on \"factory:escalation\" when a per-unit escalation fires" do
    coord_name = unique_name(:coord_unit_esc_report)
    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:escalation")

    select_fun = fn -> nil end
    drive_fun = fn _work -> :ok end

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: select_fun,
        drive_fun: drive_fun,
        scheduler: nil
      },
      id: coord_name
    )

    Process.sleep(20)

    # Deliver a per-unit escalation.
    send(coord_name, {:escalate, {:E_TEST_UNIT_ESCALATION, :unit}})

    assert_receive msg,
                   2000,
                   "INV-REPORTING-ESCALATION-ONLY / D-336 violation: no message received " <>
                     "on \"factory:escalation\" after a per-unit escalation event. " <>
                     "D-336 requires every escalation to be delivered to the operator; " <>
                     "the Coordinator must broadcast on \"factory:escalation\"."

    assert is_tuple(msg) or is_atom(msg),
           "Received a non-message value on \"factory:escalation\": #{inspect(msg)}"
  end
end
