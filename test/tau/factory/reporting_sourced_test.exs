defmodule Tau.Factory.ReportingSourcedTest do
  @moduledoc """
  Gating test for issue #557 — INV-REPORTING-SOURCED.

  Enforces **INV-REPORTING-SOURCED**:
  All numbers (token counts, wall times) in Coordinator-emitted reports MUST be
  sourced from telemetry measurements (`total_tokens` from span, `duration_ms`
  from span), never estimated or rounded. Falsified if a report contains a token
  count or wall time not traceable to a telemetry span measurement.

  Source: docs/arch/04-software-architecture/governance.md §5:
    > Numbers cited from their source, never estimated (substance-over-ceremony,
    > research INV-F9). Token counts come from the telemetry measurement
    > (`total_tokens`), wall-times from `duration_ms` — both *measured*, sourced
    > from the span that recorded them (§5), not rounded or guessed.
    > The reporter has no path to emit an unsourced number — measurements flow
    > from telemetry, which is the only number source.

  ## What this test asserts

  ### Part 1 — Milestone boundary (token accumulation)

  When the Coordinator broadcasts `{:milestone_complete, payload}` on
  `"factory:report"` after processing a unit, the payload MUST carry
  `:total_tokens` equal to the sum of `total_tokens` emitted by
  `[:tau, :factory, :unit, :merged]` telemetry spans during the run — NOT
  a hardcoded `0`. The `drive_fun` fires `[:tau, :factory, :unit, :merged]`
  with `%{total_tokens: 99}` before sending `{:unit_terminal, …}`. The
  milestone payload's `:total_tokens` MUST equal 99.

  The current implementation hardcodes `total_tokens: 0` (coordinator.ex:165).
  This test FAILS against current code because `payload.total_tokens == 0`,
  not `99`.

  ### Part 2 — Escalation (token accumulation)

  When the Coordinator broadcasts `{:escalation, payload}` on
  `"factory:escalation"` after processing a unit + global escalation, the
  payload MUST carry `:total_tokens` equal to the accumulated value from unit
  telemetry spans — NOT a hardcoded `0`.

  The current implementation hardcodes `total_tokens: 0` (coordinator.ex:250).
  This test FAILS against current code because `payload.total_tokens == 0`.

  ### Part 3 — Duration sourcing (no rounding / estimation)

  The `duration_ms` in both milestone and escalation payloads MUST be sourced
  from the monotonic-clock span (non-negative, strictly positive when the
  coordinator has been running for any observable time). A hardcoded `0` or
  a rounded-to-nearest-second value would falsify this.

  ## Fail-before validity (issue #557)

  Current coordinator.ex lines 165, 250, 268: `total_tokens: 0` — hardcoded.
  No mechanism accumulates unit-telemetry token counts. Every assertion on
  `total_tokens == injected_value` fails (got 0, expected 99 or 42).

  AC/D-NNN linkage: INV-REPORTING-SOURCED (#557).
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :inv_reporting_sourced

  @coordinator Tau.Factory.Coordinator

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # ---------------------------------------------------------------------------
  # INV-REPORTING-SOURCED — Part 1: milestone_complete payload carries
  # :total_tokens sourced from unit telemetry spans (NOT hardcoded 0).
  #
  # The drive_fun fires [:tau, :factory, :unit, :merged] with total_tokens: 99
  # before sending {:unit_terminal, …}. The Coordinator MUST subscribe to that
  # event and accumulate the value; the milestone broadcast's :total_tokens
  # MUST equal 99.
  #
  # FAILS against current code: total_tokens: 0 is hardcoded (coordinator.ex:165).
  # ---------------------------------------------------------------------------

  @tag :inv_reporting_sourced
  test "INV-REPORTING-SOURCED: milestone_complete :total_tokens reflects unit telemetry accumulation, not hardcoded 0" do
    coord_name = unique_name(:coord_sourced_milestone)

    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:report")

    work_item = "unit-sourced-milestone-#{System.unique_integer([:positive])}"
    injected_tokens = 99
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    select_fun = fn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      if n == 0, do: work_item, else: nil
    end

    drive_fun = fn work ->
      # Emit the unit-level telemetry event that the Coordinator MUST subscribe
      # to and accumulate. This mirrors the real path where a Unit FSM emits
      # [:tau, :factory, :unit, :merged] with measured token counts.
      :telemetry.execute(
        [:tau, :factory, :unit, :merged],
        %{total_tokens: injected_tokens},
        %{unit_id: work}
      )

      coord_pid = Process.whereis(coord_name)
      if is_pid(coord_pid), do: send(coord_pid, {:unit_terminal, work, :merged})
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

    assert_receive {:milestone_complete, payload},
                   2000,
                   "INV-REPORTING-SOURCED: no {:milestone_complete, _} on " <>
                     "\"factory:report\" at milestone boundary"

    # INV-REPORTING-SOURCED core assertion: total_tokens MUST equal the
    # value emitted by the unit telemetry span — NOT the hardcoded 0.
    assert Map.has_key?(payload, :total_tokens),
           "INV-REPORTING-SOURCED violation: milestone_complete payload missing " <>
             ":total_tokens. Got: #{inspect(payload)}"

    assert payload.total_tokens == injected_tokens,
           "INV-REPORTING-SOURCED violation: milestone_complete :total_tokens is " <>
             "#{inspect(payload.total_tokens)}, expected #{injected_tokens} (the value " <>
             "emitted by [:tau, :factory, :unit, :merged] telemetry). The Coordinator " <>
             "must accumulate token counts from unit telemetry spans, not hardcode 0. " <>
             "(governance.md §5, coordinator.ex:165)"
  end

  # ---------------------------------------------------------------------------
  # INV-REPORTING-SOURCED — Part 2: escalation payload carries
  # :total_tokens sourced from unit telemetry spans (NOT hardcoded 0).
  #
  # The drive_fun fires [:tau, :factory, :unit, :merged] with total_tokens: 42
  # before unit_terminal, then a global escalation fires. The escalation broadcast
  # MUST carry total_tokens: 42 accumulated from the unit span.
  #
  # FAILS against current code: total_tokens: 0 is hardcoded (coordinator.ex:250).
  # ---------------------------------------------------------------------------

  @tag :inv_reporting_sourced
  test "INV-REPORTING-SOURCED: escalation :total_tokens reflects unit telemetry accumulation, not hardcoded 0" do
    coord_name = unique_name(:coord_sourced_escalation)

    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:escalation")

    work_item = "unit-sourced-escalation-#{System.unique_integer([:positive])}"
    injected_tokens = 42
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    select_fun = fn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      if n == 0, do: work_item, else: nil
    end

    drive_fun = fn work ->
      # Emit unit telemetry with known token count before terminal.
      :telemetry.execute(
        [:tau, :factory, :unit, :merged],
        %{total_tokens: injected_tokens},
        %{unit_id: work}
      )

      coord_pid = Process.whereis(coord_name)

      if is_pid(coord_pid) do
        send(coord_pid, {:unit_terminal, work, :merged})
        # Trigger global escalation after unit completes.
        Process.sleep(20)
        send(coord_pid, {:escalate, {:E_SOURCED_TEST, :global}})
      end

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

    assert_receive {:escalation, payload},
                   2000,
                   "INV-REPORTING-SOURCED: no {:escalation, _} on " <>
                     "\"factory:escalation\" after global escalation"

    # INV-REPORTING-SOURCED core assertion: total_tokens MUST equal the
    # accumulated value from unit telemetry spans — NOT the hardcoded 0.
    assert Map.has_key?(payload, :total_tokens),
           "INV-REPORTING-SOURCED violation: escalation payload missing " <>
             ":total_tokens. Got: #{inspect(payload)}"

    assert payload.total_tokens == injected_tokens,
           "INV-REPORTING-SOURCED violation: escalation :total_tokens is " <>
             "#{inspect(payload.total_tokens)}, expected #{injected_tokens} (the value " <>
             "emitted by [:tau, :factory, :unit, :merged] telemetry). The Coordinator " <>
             "must accumulate token counts from unit telemetry spans, not hardcode 0. " <>
             "(governance.md §5, coordinator.ex:250)"
  end

  # ---------------------------------------------------------------------------
  # INV-REPORTING-SOURCED — Part 3: duration_ms is sourced from the monotonic
  # clock span (strictly positive — NOT hardcoded or rounded).
  #
  # The coordinator records start_mono_ms at init and computes duration_ms at
  # each report boundary. With a brief sleep before the milestone, duration_ms
  # MUST be > 0 — a hardcoded 0 would falsify this.
  #
  # Current code sources duration_ms from the monotonic clock correctly.
  # This test confirms that property is preserved and guards against regression.
  # It PASSES against current code; Parts 1 and 2 are the fail-before tests.
  # ---------------------------------------------------------------------------

  @tag :inv_reporting_sourced
  test "INV-REPORTING-SOURCED: milestone_complete :duration_ms is sourced from monotonic clock (strictly positive after sleep)" do
    coord_name = unique_name(:coord_sourced_duration)

    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:report")

    work_item = "unit-sourced-duration-#{System.unique_integer([:positive])}"
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    select_fun = fn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      if n == 0, do: work_item, else: nil
    end

    drive_fun = fn work ->
      # Inject a brief delay so the coordinator has been running for a
      # measurable wall time. duration_ms must be > 0.
      Process.sleep(10)

      coord_pid = Process.whereis(coord_name)
      if is_pid(coord_pid), do: send(coord_pid, {:unit_terminal, work, :merged})
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

    assert_receive {:milestone_complete, payload},
                   2000,
                   "INV-REPORTING-SOURCED: no {:milestone_complete, _} on " <>
                     "\"factory:report\" at milestone boundary"

    assert Map.has_key?(payload, :duration_ms),
           "INV-REPORTING-SOURCED violation: milestone_complete payload missing " <>
             ":duration_ms. Got: #{inspect(payload)}"

    assert (is_integer(payload.duration_ms) or is_float(payload.duration_ms)) and
             payload.duration_ms > 0,
           "INV-REPORTING-SOURCED violation: :duration_ms is #{inspect(payload.duration_ms)}, " <>
             "expected a strictly positive number sourced from the monotonic clock span. " <>
             "(governance.md §5, coordinator.ex:164)"
  end
end
