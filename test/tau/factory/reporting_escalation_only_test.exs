defmodule Tau.Factory.ReportingEscalationOnlyTest do
  @moduledoc """
  Gating test for issue #556 — INV-REPORTING-ESCALATION-ONLY.

  Enforces **INV-REPORTING-ESCALATION-ONLY** (D-S1 escalation-only autonomy):
  the Coordinator MUST emit operator-facing reports via PubSub ONLY at:

    1. **Milestone boundary** — when `select_fun → nil` (work exhausted),
       the Coordinator MUST broadcast `{:milestone_complete, measurements}`
       on the `"factory:report"` PubSub topic, where `measurements` is a map
       containing at least `:duration_ms` (integer >= 0) and `:total_tokens`
       (integer >= 0).

    2. **Global escalation events** — when a global escalation fires,
       the Coordinator MUST broadcast `{:escalation, payload}` on
       `"factory:escalation"` where `payload` carries `:reason` (the raised
       atom) and `:scope: :global`.

    3. **Per-unit escalation events** — when a per-unit escalation fires,
       the Coordinator MUST broadcast `{:escalation, payload}` on
       `"factory:escalation"` where `payload` carries `:reason` (the raised
       atom) and `:scope: :unit`.

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

  These tests gate on SPECIFIC message content. A broadcast of `{:wrong_atom}`
  or any arbitrary tuple would pass `assert_receive` but FAIL the pattern-match
  and structural assertions below. An implementation that:

    - Does NOT broadcast on the topic -> `assert_receive` times out (2 s).
    - Broadcasts `{:milestone_complete, %{}}` (missing `:duration_ms`) ->
      `Map.has_key?(measurements, :duration_ms)` assertion fails (test 1).
    - Broadcasts `{:escalation, %{scope: :global}}` (missing `:reason`) ->
      `Map.get(payload, :reason) == reason` assertion fails (tests 2 and 3).

  The previous version of this test used `assert is_tuple(msg) or is_atom(msg)`
  which was vacuous -- almost any Elixir message satisfies it. These tests have
  been repaired to assert the MINIMUM REQUIRED payload per the invariant.

  ## What constitutes the operator-facing report

  SPEC-FACTORY-CORE §4 C117 defines the PubSub topics. The invariant requires
  (a) the correct topic is used, AND (b) the message carries the minimum payload
  identifying the event: milestone -> `duration_ms` + `total_tokens`;
  escalation -> `reason` + `scope`.

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
  # INV-REPORTING-ESCALATION-ONLY / D-336 -- Part 1: milestone boundary report.
  #
  # Timeline:
  #   1. Subscribe to `"factory:report"` on Tau.PubSub.
  #   2. Start Coordinator with select_fun that returns one work item then nil.
  #   3. drive_fun immediately sends {:unit_terminal, ...} back (instant unit).
  #   4. The second loop iteration has select_fun -> nil = milestone exhausted.
  #   5. Assert {:milestone_complete, %{duration_ms: ms, total_tokens: t}} is
  #      received on "factory:report" with ms >= 0 and t >= 0.
  #
  # FAILS against an implementation that does NOT broadcast, or broadcasts
  # a wrong shape (e.g. {:milestone_complete, %{}} without duration_ms).
  # ---------------------------------------------------------------------------

  @tag :inv_reporting_escalation_only
  @tag :d_336
  test "INV-REPORTING-ESCALATION-ONLY: Coordinator broadcasts {:milestone_complete, %{duration_ms, total_tokens}} on \"factory:report\" at milestone boundary (select_fun -> nil)" do
    coord_name = unique_name(:coord_report)
    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:report")

    work_item = "unit-milestone-#{System.unique_integer([:positive])}"

    # select_fun: returns one work item (first call), then nil (milestone drained).
    # Build counter inside test body -- never store pids/refs in module attributes.
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
    # select_fun again -> nil. At this point the milestone boundary is reached and
    # INV-REPORTING-ESCALATION-ONLY requires a broadcast on "factory:report".
    # The message MUST carry duration_ms and total_tokens (INV-REPORTING-SOURCED).
    assert_receive {:milestone_complete, measurements},
                   2000,
                   "INV-REPORTING-ESCALATION-ONLY violation: no {:milestone_complete, _} " <>
                     "received on \"factory:report\" after milestone boundary " <>
                     "(select_fun -> nil). The Coordinator must broadcast " <>
                     "{:milestone_complete, %{duration_ms: _, total_tokens: _}} " <>
                     "when the milestone is drained."

    assert is_map(measurements),
           "Milestone broadcast payload must be a map, got: #{inspect(measurements)}"

    assert Map.has_key?(measurements, :duration_ms),
           "Milestone broadcast payload must contain :duration_ms, got: #{inspect(measurements)}"

    assert Map.has_key?(measurements, :total_tokens),
           "Milestone broadcast payload must contain :total_tokens, got: #{inspect(measurements)}"

    assert measurements.duration_ms >= 0,
           "Milestone :duration_ms must be >= 0 (sourced from monotonic clock), " <>
             "got: #{inspect(measurements.duration_ms)}"

    assert measurements.total_tokens >= 0,
           "Milestone :total_tokens must be >= 0, got: #{inspect(measurements.total_tokens)}"
  end

  # ---------------------------------------------------------------------------
  # INV-REPORTING-ESCALATION-ONLY / D-336 -- Part 2: global escalation report.
  #
  # Timeline:
  #   1. Subscribe to `"factory:escalation"` on Tau.PubSub.
  #   2. Start Coordinator with select_fun that idles (always nil).
  #   3. Deliver a global escalation {:escalate, {reason, :global}}.
  #   4. Assert {:escalation, %{reason: ^reason, scope: :global}} is received.
  #
  # D-336: every raised escalation is delivered to the operator and recorded;
  # none is raised-and-swallowed. The reason atom MUST be present so the
  # operator can identify WHICH escalation fired.
  #
  # FAILS against an implementation that does not broadcast, or broadcasts
  # {:escalation, %{scope: :global}} without the reason field.
  # ---------------------------------------------------------------------------

  @tag :inv_reporting_escalation_only
  @tag :d_336
  test "INV-REPORTING-ESCALATION-ONLY / D-336: Coordinator broadcasts {:escalation, %{reason: ^reason, scope: :global}} on \"factory:escalation\" when a global escalation fires" do
    coord_name = unique_name(:coord_esc_report)
    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:escalation")

    # Idle coordinator: select_fun always returns nil so no unit is in flight.
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

    reason = :E_TEST_ESCALATION_GLOBAL

    # Deliver a global escalation directly to the Coordinator's mailbox.
    send(coord_name, {:escalate, {reason, :global}})

    # Assert the SPECIFIC message shape -- reason atom and scope must both be present.
    assert_receive {:escalation, payload},
                   2000,
                   "INV-REPORTING-ESCALATION-ONLY / D-336 violation: no {:escalation, _} " <>
                     "received on \"factory:escalation\" after a global escalation event. " <>
                     "D-336 requires every escalation to be delivered to the operator; " <>
                     "the Coordinator must broadcast {:escalation, %{reason: _, scope: :global}}."

    assert is_map(payload),
           "Escalation broadcast payload must be a map, got: #{inspect(payload)}"

    assert Map.get(payload, :reason) == reason,
           "Escalation payload must carry :reason == #{inspect(reason)}, " <>
             "got: #{inspect(Map.get(payload, :reason))}"

    assert Map.get(payload, :scope) == :global,
           "Escalation payload must carry :scope == :global, " <>
             "got: #{inspect(Map.get(payload, :scope))}"
  end

  # ---------------------------------------------------------------------------
  # INV-REPORTING-ESCALATION-ONLY / D-336 -- Part 3: per-unit escalation report.
  #
  # Per-unit escalations keep the loop running (D-320) but are ALSO escalation
  # events per D-336 and must be delivered to the operator on
  # "factory:escalation". The reason atom MUST be present.
  #
  # FAILS against an implementation that does not broadcast, or broadcasts
  # {:escalation, %{scope: :unit}} without the reason field.
  # ---------------------------------------------------------------------------

  @tag :inv_reporting_escalation_only
  @tag :d_336
  test "INV-REPORTING-ESCALATION-ONLY / D-336: Coordinator broadcasts {:escalation, %{reason: ^reason, scope: :unit}} on \"factory:escalation\" when a per-unit escalation fires" do
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

    reason = :E_TEST_UNIT_ESCALATION_UNIT

    # Deliver a per-unit escalation.
    send(coord_name, {:escalate, {reason, :unit}})

    # Assert the SPECIFIC message shape -- reason atom and scope: :unit must be present.
    assert_receive {:escalation, payload},
                   2000,
                   "INV-REPORTING-ESCALATION-ONLY / D-336 violation: no {:escalation, _} " <>
                     "received on \"factory:escalation\" after a per-unit escalation event. " <>
                     "D-336 requires every escalation to be delivered to the operator; " <>
                     "the Coordinator must broadcast {:escalation, %{reason: _, scope: :unit}}."

    assert is_map(payload),
           "Escalation broadcast payload must be a map, got: #{inspect(payload)}"

    assert Map.get(payload, :reason) == reason,
           "Escalation payload must carry :reason == #{inspect(reason)}, " <>
             "got: #{inspect(Map.get(payload, :reason))}"

    assert Map.get(payload, :scope) == :unit,
           "Escalation payload must carry :scope == :unit, " <>
             "got: #{inspect(Map.get(payload, :scope))}"
  end
end
