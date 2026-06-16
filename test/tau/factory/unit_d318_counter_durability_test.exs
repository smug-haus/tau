defmodule Tau.Factory.UnitD318CounterDurabilityTest do
  @moduledoc """
  Gating test for issue #540 / D-318 — the counter-durability sub-clause.

  ## What D-318 requires

  SPEC-FACTORY-CORE §6 D-318:

      "The attempt count is durable PR state; total attempts ≤ N_refine + N_pivot.
       Enforced by retry_property_test.exs (no input sequence exceeds the bound; tagged
       :property) and the durable `units.attempt_count` column."

  The two sub-clauses of D-318 are:

    (1) **Bounding** — `Retry.next/3` structurally caps gate-failure retries at
        `N_refine + N_pivot = 4` non-terminal steps before `:exhausted`.
        This is already enforced in `retry_property_test.exs`.

    (2) **Counter durability** — the retry counters (`refine_count`, `pivot_count`,
        `stall_count`) MUST be durable across a Unit FSM restart. When a Unit is
        killed mid-flight and re-spawned (as `Coordinator.init/1` does during
        D-344 durable resume), the restarted Unit MUST begin with the counters
        restored from the Ledger, NOT reset to 0.

  ## The gap (issue #540 / audit finding)

  `Tau.Factory.Unit.init/1` (unit.ex:152-183) hardcodes:

      refine_count: 0, pivot_count: 0, attempt_count: 0, stall_count: 0

  and performs NO Ledger read to seed prior counter values.

  The `unit_snapshots` schema (migrations.ex:72-81, migration `20260612_006_unit_snapshots`)
  stores ONLY `(unit_id, state, idempotency_key)` — no counter columns.

  Consequence: a Unit that was killed after `k` refines (0 < k < N_refine) is
  re-spawned with `refine_count = 0`. It can then absorb `N_refine + N_pivot`
  MORE gate failures before escalating, for a combined total of
  `k + (N_refine + N_pivot)` non-terminal steps across both lifetimes — exceeding
  the D-318 bound by `k`.

  ## What this test asserts

  Drive a REAL Unit to `:implementing` after `@pre_refines` gate failures
  (so `refine_count = @pre_refines`). Hard-kill it. Re-spawn a second Unit
  with the same `unit_id` (simulating D-344 resume). Count the gate
  invocations across BOTH lifetimes. Assert:

      total_gate_calls_across_both_lifetimes ≤ N_REFINE + N_PIVOT + 1

  (The `+1` accounts for the one gate call that transitions the fresh unit
  for the first time via oracle → implementing → gating.
  Total gate calls = 1 initial + N_REFINE refines + N_PIVOT pivot = 5.)

  On current code this assertion FAILS because the restarted Unit resets
  its counters, allowing up to `@pre_refines + (N_REFINE + N_PIVOT + 1)` total
  gate calls.

  ## Entry point

  Exercises the REAL `Tau.Factory.UnitSupervisor.start_unit/2` entry point
  (not a hand-built struct) with the injected-seam `worker_fun`/`gate_fun`/
  `merge_fun` that the existing unit tests use (same idiom as
  `unit_snapshot_durability_test.exs` and `unit_termination_test.exs`).

  D-NNN linkage: D-318.
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.Ledger.Writer, as: LedgerWriter

  @moduletag :capture_log
  @moduletag :d_318

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # D-318 constants (from retry.ex).
  @n_refine 3
  @n_pivot 1
  # Total gate calls in a fully-exhausted single-lifetime run:
  # 1 initial (oracle→implementing→gating) + N_REFINE refines + N_PIVOT pivot = 5.
  @max_total_gate_calls @n_refine + @n_pivot + 1

  # Number of gate failures to accumulate in the FIRST lifetime before crashing.
  # Must satisfy: 1 <= @pre_refines < @n_refine so there is remaining budget.
  @pre_refines 2

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique(:d318_ledger)

    start_supervised!(
      {LedgerWriter, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp start_scheduler(name) do
    start_supervised!({@scheduler, name: name, w_cap: 10}, id: name)
  end

  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Send {:worker_done, worker_pid} to the Unit when it is parked in :oracle or
  # :implementing with a live worker_pid. Polls until the condition is met or
  # timeout expires.
  defp deliver_worker_done(unit_pid, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_deliver(unit_pid, deadline)
  end

  defp do_deliver(unit_pid, deadline) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        flunk("deliver_worker_done timed out — Unit not in oracle/implementing with a live worker")

      not Process.alive?(unit_pid) ->
        :dead

      true ->
        case :sys.get_state(unit_pid) do
          {state, data} when state in [:oracle, :implementing] ->
            worker_pid = Map.get(data, :worker_pid)

            if is_pid(worker_pid) do
              send(unit_pid, {:worker_done, worker_pid})
              :ok
            else
              :timer.sleep(10)
              do_deliver(unit_pid, deadline)
            end

          _ ->
            :timer.sleep(10)
            do_deliver(unit_pid, deadline)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # D-318 — counter durability across restart
  # ---------------------------------------------------------------------------

  describe "D-318 — counter durability: restart must not reset refine/pivot counters" do
    @tag :d_318
    test "D-318: total gate calls across a crash+restart must not exceed N_REFINE + N_PIVOT + 1" do
      # The gate-call counter is shared across both Unit lifetimes.
      gate_calls = :counters.new(1, [])

      # gate_fun always fails; each call increments the shared counter.
      gate_fun = fn _coord ->
        :counters.add(gate_calls, 1, 1)
        {:fail, ["always-fail-d318"]}
      end

      unit_id = "u-d318-counter-#{System.unique_integer([:positive])}"
      sched = unique(:sched_d318)
      sup = unique(:sup_d318)
      ledger = start_ledger()
      test_pid = self()

      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      base_opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        scheduler: sched,
        report_to: test_pid,
        ledger: ledger,
        worker_fun: fn _role -> {:ok, spawn_worker()} end,
        gate_fun: gate_fun,
        merge_fun: fn _uid, _hash -> :queued end,
        timeouts: [state_timeout_ms: 60_000]
      ]

      # -----------------------------------------------------------------------
      # Lifetime 1: accumulate @pre_refines gate failures then hard-kill.
      #
      # Drive pattern for each gate failure:
      #   oracle/implementing → deliver_worker_done → gating (gate fails sync)
      #   → back to implementing → (wait for next deliver_worker_done)
      #
      # The oracle phase always appears first (attempt_count++), then each
      # gate failure drives: implementing → gating (sync fail) → implementing.
      # We need ONE delivery for oracle, then ONE per gate call through
      # implementing→gating→implementing.
      # -----------------------------------------------------------------------

      unit_pid_1 = @unit_supervisor.start_unit(sup, base_opts)
      assert is_pid(unit_pid_1)

      # oracle → implementing (no gate call yet)
      :ok = deliver_worker_done(unit_pid_1)

      # Drive @pre_refines gate-fail cycles: each = implementing→gating(fail)→implementing
      for _i <- 1..@pre_refines do
        :ok = deliver_worker_done(unit_pid_1)
        # gate_fun runs synchronously in gating on_enter; the FSM is already back
        # in :implementing by the time deliver_worker_done returns here.
        :timer.sleep(30)
      end

      # Verify preconditions: Unit is in :implementing with refine_count == @pre_refines.
      {state_1, data_1} = :sys.get_state(unit_pid_1)

      assert state_1 == :implementing,
             "D-318 precondition: Unit should be in :implementing after #{@pre_refines} " <>
               "gate-fail refines; got #{inspect(state_1)}"

      assert Map.get(data_1, :refine_count) == @pre_refines,
             "D-318 precondition: expected refine_count = #{@pre_refines}, " <>
               "got #{inspect(Map.get(data_1, :refine_count))}"

      gate_after_l1 = :counters.get(gate_calls, 1)

      assert gate_after_l1 == @pre_refines,
             "D-318 precondition: expected #{@pre_refines} gate calls in lifetime-1; " <>
               "got #{gate_after_l1}"

      # Hard-kill lifetime-1 (simulate crash). Unit is :temporary — not restarted.
      Process.exit(unit_pid_1, :kill)
      refute Process.alive?(unit_pid_1)

      # -----------------------------------------------------------------------
      # Lifetime 2: re-spawn with the SAME unit_id (D-344 resume pattern).
      #
      # D-318 durability requires the restarted Unit to restore
      # refine_count = @pre_refines from the Ledger. Currently it resets to 0,
      # so the second lifetime unit absorbs a FULL N_REFINE + N_PIVOT + 1 gate
      # calls, making the combined total @pre_refines + @max_total_gate_calls.
      #
      # Drive the lifetime-2 unit to terminal (:escalated) and count total gate
      # calls across both lifetimes.
      # -----------------------------------------------------------------------

      unit_pid_2 = @unit_supervisor.start_unit(sup, base_opts)
      assert is_pid(unit_pid_2)
      refute unit_pid_2 == unit_pid_1

      # Drive oracle → implementing (no gate call)
      :ok = deliver_worker_done(unit_pid_2)

      # Drive implementing → gating → ... until the Unit escalates.
      # Bound the iterations to @max_total_gate_calls + @pre_refines + 2 so the
      # test terminates even if durability is broken.
      max_iterations = @n_refine + @n_pivot + @pre_refines + 2

      Enum.reduce_while(1..max_iterations, :ok, fn _i, :ok ->
        cond do
          not Process.alive?(unit_pid_2) ->
            {:halt, :dead}

          true ->
            case :sys.get_state(unit_pid_2) do
              {state, _} when state in [:escalated] ->
                {:halt, :escalated}

              {state, _} when state in [:implementing, :oracle] ->
                :ok = deliver_worker_done(unit_pid_2)
                :timer.sleep(30)
                {:cont, :ok}

              _ ->
                :timer.sleep(20)
                {:cont, :ok}
            end
        end
      end)

      # Wait for the terminal {:unit_terminal, _, :escalated, _} message.
      assert_receive {:unit_terminal, ^unit_id, :escalated, _provenance}, 10_000

      total_gate_calls = :counters.get(gate_calls, 1)

      assert total_gate_calls <= @max_total_gate_calls,
             "D-318 counter-durability VIOLATION: the combined total gate calls " <>
               "across both Unit lifetimes is #{total_gate_calls}, exceeding the " <>
               "D-318 bound of #{@max_total_gate_calls} " <>
               "(N_REFINE=#{@n_refine} + N_PIVOT=#{@n_pivot} + 1 initial gate call). " <>
               "\n\nLifetime-1: #{gate_after_l1} gate calls (#{@pre_refines} refines, " <>
               "then hard-killed to simulate crash). " <>
               "\nLifetime-2 (D-344 re-spawn, same unit_id): #{total_gate_calls - gate_after_l1} " <>
               "gate calls — should have been at most #{@max_total_gate_calls - gate_after_l1} " <>
               "to stay within the bound. " <>
               "\n\nRoot cause: Unit.init/1 (unit.ex:152-183) hardcodes refine_count=0 " <>
               "and does NOT read the Ledger to restore prior counter values. " <>
               "The unit_snapshots schema also stores no counter columns. " <>
               "Fix: persist refine_count/pivot_count/stall_count in unit_snapshots " <>
               "and restore them in Unit.init/1 when a Ledger snapshot exists."
    end
  end
end
