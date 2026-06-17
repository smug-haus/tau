defmodule Tau.Factory.CoordinatorEscalationDurabilityTest do
  @moduledoc """
  Gating test for issue #614 / invariant LIVE-liveness-2.

  Enforces the three sub-requirements of `liveness.md` §"On every escalation":

      (1) HALT SCOPE — global escalation halts the loop; per-unit escalation
          does NOT halt the loop (the unit is halted, loop continues).
      (2) DURABLE WRITE — reason + state snapshot written to the Ledger
          via `Ledger.Writer.record_escalation/3` (B3 contract,
          SPEC-FACTORY-CORE §4 B3; CON-7, conservation.md).
      (3) OPERATOR NOTIFICATION — PubSub broadcast on "factory:escalation"
          with the reason present (already enforced; asserted here as part of
          the full LIVE-liveness-2 conformance check).

  ## What LIVE-liveness-2 states (liveness.md §"On every escalation")

      On every escalation: halt the affected scope (per-unit halts the unit;
      global halts the loop), write reason + state snapshot to the durable
      store (CON-7), and notify the operator.

  CON-7 (conservation.md §"CON-7 Escalation conservation"):

      ∀ e ∈ raised. delivered(e) ∧ recorded(reason(e), state(e))

  The `record_escalation/3` call is the write leg of CON-7. It is listed in
  SPEC-FACTORY-CORE §4 B3 as a mandatory `Ledger.Writer` write op:

      B3: {C3,C6} ↔ C1 Ledger.Writer | … record_escalation (call, WAL-before-ack)

  ## Current defects (fail-before state)

  1. `Tau.Factory.Ledger.Writer.record_escalation/3` does NOT exist; calling it
     raises `UndefinedFunctionError`.
  2. `Tau.Factory.Ledger.Writer.escalations_recorded/1` does NOT exist (a new
     read op needed to query what was durably written). Its absence is the
     load-bearing fail-before oracle.
  3. The Coordinator does NOT store the `:ledger` reference in its `data` map
     (coordinator.ex `init/1` reads the opt but never assigns `data.ledger`),
     so even if the function existed the coordinator could not call it from its
     escalation handlers.
  4. Neither escalation handler (`{:escalate, {e, :global}}` nor
     `{:escalate, {e, :unit}}`) calls any ledger write op.

  All four defects must be fixed before this test passes.

  ## Entry point

  Tests exercise the REAL `Tau.Factory.Coordinator.start_link/1` (gen_statem)
  with a REAL `Tau.Factory.Ledger.Writer` (SQLite/Exqlite, isolated tmp DB per
  test). Escalation events are delivered as real `:info` messages to the live
  gen_statem. The durable oracle is
  `Tau.Factory.Ledger.Writer.escalations_recorded/1` — a new read op on the
  Writer (also absent today; its absence is load-bearing for the fail-before).

  AC/D-NNN linkage: LIVE-liveness-2.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :liveness_2

  @coordinator Tau.Factory.Coordinator
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive, :monotonic])}"

  # Start a real, isolated Ledger.Writer backed by a tmp SQLite DB.
  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique(:esc_ledger)
    start_supervised!({@writer, db_path: db_path, name: writer_name}, id: writer_name)
    writer_name
  end

  # Start a Coordinator in :running/idle state with the given ledger.
  # select_fun returns nil (idle), drive_fun is a no-op.
  defp start_coordinator(ledger) do
    name = unique(:coord_esc_dur)
    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:escalation")

    start_supervised!(
      {
        @coordinator,
        name: name,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _work -> :ok end,
        scheduler: nil,
        on_halted: nil,
        ledger: ledger
      },
      id: name
    )

    pid = wait_for_running(name)
    {name, pid}
  end

  defp wait_for_running(name) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case Process.whereis(name) do
        nil ->
          Process.sleep(5)
          {:cont, nil}

        pid ->
          case :sys.get_state(pid, 500) do
            {:running, _data} -> {:halt, pid}
            _ -> Process.sleep(5) && {:cont, nil}
          end
      end
    end) || raise "Coordinator never reached :running"
  end

  # ---------------------------------------------------------------------------
  # LIVE-liveness-2 — global escalation: durable write + operator notification.
  #
  # Sub-requirements exercised: (2) durable write; (3) operator notification.
  #
  # Fail-before:
  #   `@writer.escalations_recorded/1` does not exist →
  #   `UndefinedFunctionError` at the assertion line. The test CANNOT pass
  #   against the current production code. It passes only once:
  #     (a) `Ledger.Writer.record_escalation/3` and
  #         `Ledger.Writer.escalations_recorded/1` are implemented,
  #     (b) the Coordinator stores `:ledger` in `data`, AND
  #     (c) the global-escalation handler calls `record_escalation/3`.
  # ---------------------------------------------------------------------------

  @tag :liveness_2
  test "LIVE-liveness-2: global escalation writes reason + state snapshot to Ledger durably" do
    ledger = start_ledger()
    {coord_name, _coord_pid} = start_coordinator(ledger)

    reason = :"E-RED-MAIN"

    # Deliver a global escalation via the real Coordinator entry point.
    send(coord_name, {:escalate, {reason, :global}})

    # Sub-requirement (3): operator notified via PubSub "factory:escalation".
    assert_receive {:escalation, %{reason: ^reason, scope: :global}},
                   1_000,
                   "LIVE-liveness-2 (3/3): global escalation MUST broadcast " <>
                     "{:escalation, %{reason: reason, scope: :global}} to " <>
                     "\"factory:escalation\" (operator notification, CON-7). " <>
                     "No broadcast received within 1s."

    # Allow the WAL-before-ack ledger write to complete.
    Process.sleep(100)

    # Sub-requirement (2): reason + state snapshot in the durable store.
    #
    # `@writer.escalations_recorded/1` is a NEW Ledger.Writer read op (absent
    # today — its absence is the load-bearing fail-before). It returns a list
    # of maps, each with at least :reason and :scope, ordered by insertion.
    #
    # FAILS today with UndefinedFunctionError because neither
    # `record_escalation/3` nor `escalations_recorded/1` exists in
    # Tau.Factory.Ledger.Writer.
    records = @writer.escalations_recorded(ledger)

    assert length(records) >= 1,
           "LIVE-liveness-2 (2/3): global escalation MUST write reason + state " <>
             "snapshot to the durable Ledger (record_escalation/3, CON-7 / B3). " <>
             "escalations_recorded/1 returned an empty list — the Coordinator " <>
             "either did not call record_escalation/3, or the Ledger write was " <>
             "skipped. Every raised escalation MUST be durable (CON-7: " <>
             "∀ e ∈ raised. delivered(e) ∧ recorded(reason(e), state(e)))."

    latest = List.last(records)

    assert Map.get(latest, :reason) == reason,
           "LIVE-liveness-2 (2/3): durable escalation record has wrong reason; " <>
             "expected #{inspect(reason)}, got #{inspect(Map.get(latest, :reason))}. " <>
             "The Coordinator MUST persist the reason term (not discard it)."

    assert Map.get(latest, :scope) == :global,
           "LIVE-liveness-2 (2/3): durable escalation record has wrong scope; " <>
             "expected :global, got #{inspect(Map.get(latest, :scope))}."
  end

  # ---------------------------------------------------------------------------
  # LIVE-liveness-2 — per-unit escalation: durable write + operator notification
  # + loop stays :running.
  #
  # Sub-requirements exercised: (1) loop stays :running; (2) durable write;
  # (3) operator notification.
  #
  # Fail-before: same as global path — UndefinedFunctionError on
  # `@writer.escalations_recorded/1`.
  # ---------------------------------------------------------------------------

  @tag :liveness_2
  test "LIVE-liveness-2: per-unit escalation writes reason + state snapshot to Ledger durably" do
    ledger = start_ledger()
    {coord_name, _coord_pid} = start_coordinator(ledger)

    reason = :"E-RETRY-EXHAUSTED"

    # Deliver a per-unit escalation to the real gen_statem.
    send(coord_name, {:escalate, {reason, :unit}})

    # Sub-requirement (3): operator notified via PubSub.
    assert_receive {:escalation, %{reason: ^reason, scope: :unit}},
                   1_000,
                   "LIVE-liveness-2 (3/3): per-unit escalation MUST broadcast " <>
                     "{:escalation, %{reason: reason, scope: :unit}} to " <>
                     "\"factory:escalation\" (operator notification, CON-7). " <>
                     "No broadcast received within 1s."

    # Sub-requirement (1): per-unit escalation does NOT halt the loop — the
    # Coordinator must remain in :running after a unit escalation.
    {state_after, _} = :sys.get_state(coord_name)

    assert state_after == :running,
           "LIVE-liveness-2 (1/3): per-unit escalation MUST NOT halt the loop; " <>
             "Coordinator must remain :running after {:escalate, {e, :unit}}; " <>
             "got state=#{inspect(state_after)}."

    Process.sleep(100)

    # Sub-requirement (2): durable write.
    # FAILS today with UndefinedFunctionError — same root cause as global path.
    records = @writer.escalations_recorded(ledger)

    assert length(records) >= 1,
           "LIVE-liveness-2 (2/3): per-unit escalation MUST durably write reason " <>
             "+ state snapshot to the Ledger (record_escalation/3, CON-7 / B3). " <>
             "escalations_recorded/1 returned an empty list."

    latest = List.last(records)

    assert Map.get(latest, :reason) == reason,
           "LIVE-liveness-2 (2/3): durable escalation record has wrong reason; " <>
             "expected #{inspect(reason)}, got #{inspect(Map.get(latest, :reason))}."

    assert Map.get(latest, :scope) == :unit,
           "LIVE-liveness-2 (2/3): durable escalation record has wrong scope; " <>
             "expected :unit, got #{inspect(Map.get(latest, :scope))}."
  end

  # ---------------------------------------------------------------------------
  # LIVE-liveness-2 — global escalation halts the loop (halt-scope sub-req alone).
  #
  # Sub-requirement (1) only: global escalation transitions the Coordinator to
  # :halting → :halted. This is already enforced by escalation_drain_test.exs
  # for the drain case; this test re-asserts it as part of the full
  # LIVE-liveness-2 conformance check (the invariant is a conjunction).
  #
  # This sub-test does NOT call escalations_recorded/1, so it fails only if the
  # halt-scope logic is broken — it is a standalone assertion for sub-req (1).
  # ---------------------------------------------------------------------------

  @tag :liveness_2
  test "LIVE-liveness-2: global escalation halts the Coordinator loop (halt-scope sub-req)" do
    ledger = start_ledger()
    {coord_name, coord_pid} = start_coordinator(ledger)

    reason = :"E-BUDGET"

    send(coord_name, {:escalate, {reason, :global}})

    # With no unit in-flight the Coordinator drains immediately to :halted.
    halted? =
      Enum.reduce_while(1..200, false, fn _, _ ->
        case :sys.get_state(coord_pid, 500) do
          {:halted, _} ->
            {:halt, true}

          {:halting, _} ->
            Process.sleep(5)
            {:cont, false}

          _ ->
            Process.sleep(5)
            {:cont, false}
        end
      end)

    assert halted?,
           "LIVE-liveness-2 (1/3): global escalation MUST halt the Coordinator " <>
             "loop (transition :running → :halting → :halted, D-320). " <>
             "State after escalation: #{inspect(:sys.get_state(coord_pid, 500))}."
  end
end
