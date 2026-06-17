defmodule Tau.Factory.BudgetEscalationHaltTest do
  @moduledoc """
  Gating test for issue #618 — LIVE-liveness-7 (E-BUDGET global-halt circuit).

  ## Invariant under test (LIVE-liveness-7)

  "E-BUDGET escalation fires globally when the token, cost, time, or iteration
  budget is exhausted. Falsified by: the coordinator continuing factory steps
  after budget exhaustion."

  ## What is broken (as of issue #618)

  Three broken links in the budget-exhaustion-to-global-halt circuit:

  1. `Scheduler.check_budget/1` correctly returns `{:defer, {:budget, dim}}`
     when the budget is exhausted (scheduler.ex:170-177).

  2. `Unit.planned/3` receives `{:defer, {:budget, dim}}` but matches it with
     the generic `{:defer, reason}` pattern and calls
     `escalate(data, :E_SCHEDULER_DEFER)` — a hardcoded unit-scope atom.
     It NEVER calls `Escalation.classify/1` and NEVER inspects the
     `{:budget, dim}` shape's `:global` scope (unit.ex:213-216).

  3. `Unit.escalate/2` → `terminal/4` unconditionally sends
     `{:unit_terminal, unit_id, :escalated, provenance}` to `report_to`
     (coordinator). No clause emits `{:escalate, {:"E-BUDGET", :global}}`
     (unit.ex:672-675, 766-787).

  4. `Coordinator.running/3` handles `{:unit_terminal, ..., :escalated, ...}`
     with `halt_pending: false` by clearing `in_flight` and issuing
     `{:next_event, :internal, :loop}` — the factory CONTINUES after a
     budget-driven `:escalated` terminal (coordinator.ex:212-223).

  ## Conformant behaviour (the invariant's demand)

  When `Scheduler.admit` returns `{:defer, {:budget, dim}}` for a unit, the
  coordinator MUST reach `:halted`. The classification `{:budget, dim}` →
  `{:"E-BUDGET", :global}` (via `Escalation.classify/1`) means the scope is
  `:global`; the coordinator's `:halting` path is the only correct outcome.

  ## Test strategy

  Drive a real `Tau.Factory.Coordinator` with:
  - A real `Tau.Factory.Scheduler` configured with a `Budget.Owner` where the
    token budget starts at 0 (immediately exhausted).
  - A `drive_fun` that starts a real `Tau.Factory.Unit` FSM which calls
    `Scheduler.admit/3` in its `:planned` state — hitting the budget ceiling.
  - A `select_fun` that returns one work item and then `nil`.

  The conformant circuit fires as:
    Unit.planned → Scheduler.admit → {:defer, {:budget, :tokens}}
    → Escalation.classify({:budget, :tokens}) = {:"E-BUDGET", :global}
    → send(coordinator, {:escalate, {:"E-BUDGET", :global}})
    → Coordinator transitions to :halting → :halted

  Currently the broken circuit fires as:
    Unit.planned → Scheduler.admit → {:defer, {:budget, :tokens}}
    → escalate(data, :E_SCHEDULER_DEFER)
    → send(coordinator, {:unit_terminal, ..., :escalated, ...})
    → Coordinator stays :running and loops

  The test asserts the coordinator reaches :halted within a bounded timeout.
  Currently it FAILS because the coordinator stays :running and never halts.

  ## Linkage

  - Invariant: LIVE-liveness-7
  - D-320 — Budget ceiling is a hard pre-admission gate; exhaustion raises E-BUDGET.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :"live-liveness-7"

  @coordinator Tau.Factory.Coordinator
  @scheduler Tau.Factory.Scheduler
  @budget_owner Tau.Factory.Budget.Owner
  @unit_supervisor Tau.Factory.UnitSupervisor
  @ledger_writer Tau.Factory.Ledger.Writer

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # ---------------------------------------------------------------------------
  # LIVE-liveness-7 — budget exhaustion triggers global halt, not loop-continue
  # ---------------------------------------------------------------------------

  @tag :"live-liveness-7"
  @tag :d_320
  test "LIVE-liveness-7: coordinator halts (reaches :halted) when budget is exhausted at admission" do
    test_pid = self()
    coord_name = unique(:coord_budget_halt)
    sched_name = unique(:sched_budget_halt)
    owner_name = unique(:owner_budget_halt)
    sup_name = unique(:sup_budget_halt)

    # Start an isolated Ledger.Writer backed by a tmp DB (required by Budget.Owner).
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique(:writer_budget_halt)

    start_supervised!(
      {@ledger_writer, db_path: db_path, name: writer_name},
      id: writer_name
    )

    # Budget.Owner with tokens=0 — immediately exhausted.
    # Scheduler.admit will return {:defer, {:budget, :tokens}} for any unit.
    start_supervised!(
      {@budget_owner, ledger: writer_name, totals: %{tokens: 0}, name: owner_name},
      id: owner_name
    )

    # Scheduler configured with the exhausted Budget.Owner.
    start_supervised!(
      {@scheduler, name: sched_name, w_cap: 10, budget: {owner_name, [:tokens]}},
      id: sched_name
    )

    # UnitSupervisor to host the real Unit FSM.
    start_supervised!(
      {@unit_supervisor, name: sup_name},
      id: sup_name
    )

    # select_fun: returns one work item, then nil.
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    work_item = "unit-budget-halt-#{System.unique_integer([:positive])}"
    unit_id = work_item

    select_fun = fn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      if n == 0, do: work_item, else: nil
    end

    # drive_fun: starts a real Unit FSM using the scheduler with exhausted budget.
    # The Unit will call Scheduler.admit in its :planned state. With tokens=0
    # the scheduler returns {:defer, {:budget, :tokens}} immediately.
    drive_fun = fn _work ->
      coord_pid = Process.whereis(coord_name)

      _unit_pid =
        @unit_supervisor.start_unit(sup_name,
          unit_id: unit_id,
          declared_scope: empty_scope(),
          hash: "hash-#{unit_id}",
          scheduler: sched_name,
          report_to: coord_pid,
          worker_fun: fn _role ->
            # Should never be called because admission is denied at :planned.
            # If called, park forever to make test failure more observable.
            worker_pid = spawn(fn -> Process.sleep(:infinity) end)
            {:ok, worker_pid}
          end,
          gate_fun: fn _coord -> :pass end,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      :ok
    end

    # on_halted spy: notifies the test when the coordinator reaches :halted.
    on_halted_pid =
      spawn_link(fn ->
        receive do
          :coordinator_halted -> send(test_pid, :coordinator_halted)
        end
      end)

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: select_fun,
        drive_fun: drive_fun,
        scheduler: sched_name,
        on_halted: on_halted_pid
      },
      id: coord_name
    )

    # The conformant behaviour: when the Unit FSM's :planned state calls
    # Scheduler.admit and receives {:defer, {:budget, :tokens}}, it must
    # classify the reason as {:"E-BUDGET", :global} and send
    # {:escalate, {:"E-BUDGET", :global}} to the coordinator. The coordinator
    # then transitions to :halting and eventually :halted.
    #
    # The current broken behaviour: planned/3 calls escalate(data, :E_SCHEDULER_DEFER),
    # which sends {:unit_terminal, ..., :escalated, ...} to the coordinator.
    # The coordinator receives this and calls :loop, staying :running.
    #
    # This assertion FAILS on current code because the coordinator never halts.
    assert_receive :coordinator_halted,
                   3_000,
                   "LIVE-liveness-7: coordinator must reach :halted when budget is " <>
                     "exhausted at admission. " <>
                     "Current code: Unit.planned/3 calls escalate(data, :E_SCHEDULER_DEFER) " <>
                     "(hardcoded atom) instead of classifying {:budget, dim} via " <>
                     "Escalation.classify/1 → {:\"E-BUDGET\", :global}. " <>
                     "The coordinator receives {:unit_terminal, ..., :escalated, ...} " <>
                     "and loops instead of halting. " <>
                     "Fix: Unit.planned/3 must inspect the {:budget, dim} shape and emit " <>
                     "{:escalate, {:\"E-BUDGET\", :global}} to report_to."

    # Secondary: confirm the coordinator is actually in :halted state.
    {final_state, _} = :sys.get_state(coord_name)

    assert final_state == :halted,
           "LIVE-liveness-7: coordinator must be in :halted state after E-BUDGET escalation; " <>
             "got state=#{inspect(final_state)}"
  end
end
