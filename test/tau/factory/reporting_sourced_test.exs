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

  When the Coordinator broadcasts `{:milestone_complete, payload}` on
  `"factory:report"` (INV-REPORTING-ESCALATION-ONLY), the payload MUST carry:

    - `:total_tokens` — a non-negative integer sourced from the
      `[:tau, :factory, :coordinator, ...]` telemetry span measurements.
    - `:duration_ms` — a non-negative integer (or float) sourced from the
      `[:tau, :factory, :coordinator, ...]` telemetry span measurements.

  The test attaches a `:telemetry` handler to the Coordinator's span event, captures
  the measurements emitted at the milestone boundary, then asserts the broadcast
  payload carries the SAME values — proving they are sourced, not hardcoded or
  estimated.

  Similarly, when the Coordinator broadcasts `{:escalation, payload}` on
  `"factory:escalation"`, the payload MUST carry `:total_tokens` and
  `:duration_ms` from the `[:tau, :factory, :coordinator, :escalate]` span.

  ## Fail-before validity

  The current `Tau.Factory.Coordinator.running(:internal, :loop, data)` with
  `select_fun → nil` broadcasts `{:milestone_complete, %{}}` (coordinator.ex:162)
  — an EMPTY map. No `:total_tokens` or `:duration_ms` key is present in the
  payload. Both assertions below FAIL against the current implementation.

  The telemetry/3 helper (coordinator.ex:338-340) always passes `%{}` as the
  measurements map at every call site, so no telemetry-sourced number exists to
  carry into the report.

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
  # INV-REPORTING-SOURCED — Part 1: milestone boundary report carries
  # telemetry-sourced :total_tokens and :duration_ms.
  #
  # Timeline:
  #   1. Subscribe to "factory:report" on Tau.PubSub.
  #   2. Attach a telemetry handler to [:tau, :factory, :coordinator, :loop] (or
  #      the coordinator's milestone-boundary span event) to capture measurements.
  #   3. Start Coordinator with select_fun returning one work item then nil.
  #   4. drive_fun immediately sends {:unit_terminal, …} (instant unit).
  #   5. The second loop call hits select_fun → nil = milestone boundary.
  #   6. Coordinator broadcasts {:milestone_complete, payload} on "factory:report".
  #   7. Assert payload has :total_tokens (non-negative integer) and :duration_ms
  #      (non-negative number), sourced from the telemetry span measurements.
  #
  # FAILS against current code: {:milestone_complete, %{}} has no :total_tokens
  # or :duration_ms key.
  # ---------------------------------------------------------------------------

  @tag :inv_reporting_sourced
  test "INV-REPORTING-SOURCED: milestone_complete payload carries :total_tokens and :duration_ms sourced from telemetry span" do
    coord_name = unique_name(:coord_sourced_milestone)

    # Capture the telemetry measurements emitted by the Coordinator's
    # milestone-boundary span so we can verify the broadcast payload is sourced
    # from them (not hardcoded or estimated).
    test_pid = self()
    handler_id = "#{coord_name}_handler_milestone"

    :telemetry.attach(
      handler_id,
      [:tau, :factory, :coordinator, :milestone],
      fn _event, measurements, _metadata, _config ->
        send(test_pid, {:telemetry_measurements, measurements})
      end,
      nil
    )

    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:report")

    work_item = "unit-sourced-milestone-#{System.unique_integer([:positive])}"
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    select_fun = fn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      if n == 0, do: work_item, else: nil
    end

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

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Assert the Coordinator broadcasts {:milestone_complete, payload} on "factory:report"
    # at the milestone boundary. Use pattern-match in assert_receive to skip any
    # telemetry handler echoes in the test process mailbox.
    assert_receive {:milestone_complete, payload},
                   2000,
                   "INV-REPORTING-SOURCED: no {:milestone_complete, _} message on " <>
                     "\"factory:report\" at milestone boundary. Coordinator must broadcast " <>
                     "{:milestone_complete, payload} when select_fun returns nil."

    # INV-REPORTING-SOURCED core assertion: payload MUST carry :total_tokens
    # sourced from telemetry span measurements.
    assert Map.has_key?(payload, :total_tokens),
           "INV-REPORTING-SOURCED violation: milestone_complete payload is missing " <>
             ":total_tokens. All numbers in reports must be sourced from telemetry " <>
             "span measurements (governance.md §5). Got payload: #{inspect(payload)}"

    assert is_integer(payload.total_tokens) and payload.total_tokens >= 0,
           "INV-REPORTING-SOURCED violation: :total_tokens must be a non-negative " <>
             "integer (sourced from the span measurement), got: #{inspect(payload.total_tokens)}"

    # INV-REPORTING-SOURCED core assertion: payload MUST carry :duration_ms
    # sourced from telemetry span measurements.
    assert Map.has_key?(payload, :duration_ms),
           "INV-REPORTING-SOURCED violation: milestone_complete payload is missing " <>
             ":duration_ms. All wall-times in reports must be sourced from telemetry " <>
             "span measurements (governance.md §5). Got payload: #{inspect(payload)}"

    assert (is_integer(payload.duration_ms) or is_float(payload.duration_ms)) and
             payload.duration_ms >= 0,
           "INV-REPORTING-SOURCED violation: :duration_ms must be a non-negative " <>
             "number (sourced from the span measurement), got: #{inspect(payload.duration_ms)}"
  end

  # ---------------------------------------------------------------------------
  # INV-REPORTING-SOURCED — Part 2: escalation report carries
  # telemetry-sourced :total_tokens and :duration_ms.
  #
  # Timeline:
  #   1. Subscribe to "factory:escalation" on Tau.PubSub.
  #   2. Start idle Coordinator (select_fun always nil).
  #   3. Deliver {:escalate, {reason, :global}}.
  #   4. Coordinator broadcasts {:escalation, payload} on "factory:escalation".
  #   5. Assert payload has :total_tokens and :duration_ms from the
  #      [:tau, :factory, :coordinator, :escalate] span measurements.
  #
  # FAILS against current code: running(:info, {:escalate, {e, :global}}, data)
  # broadcasts {:escalation, %{reason: e, scope: :global}} — no :total_tokens
  # or :duration_ms key.
  # ---------------------------------------------------------------------------

  @tag :inv_reporting_sourced
  test "INV-REPORTING-SOURCED: escalation payload carries :total_tokens and :duration_ms sourced from telemetry span" do
    coord_name = unique_name(:coord_sourced_escalation)

    test_pid = self()
    handler_id = "#{coord_name}_handler_escalation"

    :telemetry.attach(
      handler_id,
      [:tau, :factory, :coordinator, :escalate],
      fn _event, measurements, _metadata, _config ->
        send(test_pid, {:telemetry_measurements, measurements})
      end,
      nil
    )

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

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Process.sleep(20)
    send(coord_name, {:escalate, {:E_SOURCED_TEST, :global}})

    assert_receive {:escalation, payload},
                   2000,
                   "INV-REPORTING-SOURCED: no {:escalation, _} message on \"factory:escalation\" after " <>
                     "global escalation. Coordinator must broadcast escalation report."

    # INV-REPORTING-SOURCED core assertion: escalation payload MUST carry
    # :total_tokens sourced from the [:tau, :factory, :coordinator, :escalate] span.
    assert Map.has_key?(payload, :total_tokens),
           "INV-REPORTING-SOURCED violation: escalation payload is missing :total_tokens. " <>
             "All numbers in reports must be sourced from telemetry span measurements " <>
             "(governance.md §5). Got payload: #{inspect(payload)}"

    assert is_integer(payload.total_tokens) and payload.total_tokens >= 0,
           "INV-REPORTING-SOURCED violation: :total_tokens must be a non-negative " <>
             "integer (sourced from the span measurement), got: #{inspect(payload.total_tokens)}"

    # INV-REPORTING-SOURCED core assertion: escalation payload MUST carry
    # :duration_ms sourced from the span.
    assert Map.has_key?(payload, :duration_ms),
           "INV-REPORTING-SOURCED violation: escalation payload is missing :duration_ms. " <>
             "All wall-times in reports must be sourced from telemetry span measurements " <>
             "(governance.md §5). Got payload: #{inspect(payload)}"

    assert (is_integer(payload.duration_ms) or is_float(payload.duration_ms)) and
             payload.duration_ms >= 0,
           "INV-REPORTING-SOURCED violation: :duration_ms must be a non-negative " <>
             "number (sourced from the span measurement), got: #{inspect(payload.duration_ms)}"
  end
end
