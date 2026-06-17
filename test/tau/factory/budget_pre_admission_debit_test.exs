defmodule Tau.Factory.BudgetPreAdmissionDebitTest do
  @moduledoc """
  Gating test for issue #660 (FR-7.1) — AC-FR-7.1 / D-320.

  ## Invariant under test

  FR-7.1 has three conjuncts. This file targets **conjunct 2**:

    > "every billable action MUST be debited pre-admission (INV-21, CON-3)"

  `Tau.Factory.Scheduler.admit/3` is the sole admission authority (D-380).
  When it returns `:admit`, the budget spend for the admitted unit_id MUST
  be recorded in the Ledger (via `Budget.Owner.debit/4` →
  `Ledger.Writer.debit_budget/4`) **before the reply is sent** (D-320 /
  D-315 WAL-before-ack).

  ## Evidence of the current gap (issue #660)

  `Scheduler.admit/3` calls `check_budget/1` which calls
  `Budget.Owner.budget_precheck/2` (a read-only ETS probe). It NEVER calls
  `Budget.Owner.debit/4`. A grep of `lib/` for `Budget.Owner.debit` /
  `Owner.debit` / `debit_budget` returns EMPTY outside tests.

  ## What the test asserts (conformant post-fix behaviour)

  1. Call `Scheduler.admit/3` with a budget-configured Scheduler (`:budget`
     option set to a live Budget.Owner with non-zero headroom).
  2. Assert that `Ledger.Writer.budget_debited/1` returns a map with a
     non-zero spend for at least one configured dimension.
  3. Assert that a DEFERRED admission (budget = 0) does NOT write a debit.

  ## Why this FAILS today (fail-before validity)

  `Scheduler.admit/3` only reads ETS (`budget_precheck`) and never writes to
  the Ledger (`debit/4`). After a successful `:admit` the Ledger spend stays 0
  — the assertion `Map.get(debited, :tokens, 0) > 0` fails.

  ## Boundary entry point

  `Tau.Factory.Scheduler.admit/3` — the real admission entry point (D-380).
  NOT a hand-built struct; the full Scheduler GenServer is started via
  `start_supervised!/2` with a real `Budget.Owner` and `Ledger.Writer`.

  AC linkage: AC-FR-7.1 / D-320.
  """

  use ExUnit.Case, async: true

  @moduletag :ac_fr_7_1
  @moduletag :d_320
  @moduletag :capture_log

  @writer Tau.Factory.Ledger.Writer
  @owner Tau.Factory.Budget.Owner
  @scheduler Tau.Factory.Scheduler

  # A minimal conflict-check scope that clears all five clauses against an
  # empty in-flight set.
  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # Start an isolated Ledger.Writer + Budget.Owner + Scheduler triple.
  # Returns {writer_name, owner_name, scheduler_name}.
  defp start_admission_triple(totals) do
    db_path = Briefly.create!(extname: ".db")
    uid = System.unique_integer([:positive])
    writer_name = :"test_pa_writer_#{uid}"
    owner_name = :"test_pa_owner_#{uid}"
    scheduler_name = :"test_pa_scheduler_#{uid}"

    start_supervised!(
      {@writer, db_path: db_path, name: writer_name},
      id: :"pa_writer_#{uid}"
    )

    start_supervised!(
      {@owner, ledger: writer_name, totals: totals, name: owner_name},
      id: :"pa_owner_#{uid}"
    )

    start_supervised!(
      {
        @scheduler,
        name: scheduler_name, w_cap: 8, budget: {owner_name, Map.keys(totals)}
      },
      id: :"pa_scheduler_#{uid}"
    )

    {writer_name, owner_name, scheduler_name}
  end

  # ---------------------------------------------------------------------------
  # FR-7.1 / D-320 — admission MUST debit the Ledger pre-admission
  # ---------------------------------------------------------------------------

  describe "AC-FR-7.1 / D-320 — Scheduler.admit/3 records a Ledger debit on successful admission" do
    @tag :ac_fr_7_1
    @tag :d_320
    test "AC-FR-7.1 / D-320: Ledger records a budget debit after a successful admit" do
      # FR-7.1 conjunct 2: every billable action MUST be debited pre-admission.
      # The Scheduler is the sole admission authority (D-380). After it returns
      # :admit, the Ledger MUST contain at least one budget_debit row for the
      # admitted unit_id — proving debit was recorded as part of the admission
      # path (before the reply was sent, per D-315 WAL-before-ack).
      totals = %{tokens: 1_000}
      {writer_name, _owner_name, scheduler_name} = start_admission_triple(totals)

      unit_id = "unit-fr7.1-debit-test"

      # Exercise the real admission entry point (D-380 single authority).
      result = @scheduler.admit(scheduler_name, unit_id, empty_scope())

      # Precondition: admission must succeed.
      assert result == :admit,
             "Expected :admit but got #{inspect(result)}; check test setup (totals=#{inspect(totals)})"

      # D-320 / FR-7.1 conjunct 2: the Ledger MUST record a debit for at least
      # one configured dimension (`:tokens`) after the successful admit.
      # Currently FAILS: Scheduler.admit/3 only calls budget_precheck/2 (read-only)
      # and never calls Budget.Owner.debit/4 — so budget_debited returns %{}.
      debited = @writer.budget_debited(writer_name)

      assert Map.get(debited, :tokens, 0) > 0,
             "FR-7.1 / D-320 VIOLATED: Ledger shows 0 debited tokens after " <>
               "Scheduler.admit/3 returned :admit for unit #{inspect(unit_id)}. " <>
               "Scheduler.admit/3 must call Budget.Owner.debit/4 on the :admit path " <>
               "(budget_debited returned: #{inspect(debited)})."
    end

    @tag :ac_fr_7_1
    @tag :d_320
    test "AC-FR-7.1 / D-320: no Ledger debit is recorded for a deferred (budget-exhausted) admission" do
      # Corollary of D-320: a DEFERRED admission must NOT write a Ledger debit.
      # D-343 says F is not mutated on defer; the Ledger must not be written
      # either — the unit was not admitted, so no spend occurred.
      totals = %{tokens: 0}
      {writer_name, _owner_name, scheduler_name} = start_admission_triple(totals)

      unit_id = "unit-fr7.1-deferred"
      result = @scheduler.admit(scheduler_name, unit_id, empty_scope())

      # With tokens: 0, precheck must return {:exhausted, :tokens}.
      assert {:defer, {:budget, :tokens}} = result,
             "Expected {:defer, {:budget, :tokens}} but got #{inspect(result)}"

      # No Ledger debit must exist for a deferred admission.
      debited = @writer.budget_debited(writer_name)

      assert Map.get(debited, :tokens, 0) == 0,
             "FR-7.1 / D-343: Ledger debit was recorded for a DEFERRED admission " <>
               "of unit #{inspect(unit_id)}. A defer must not write to the Ledger " <>
               "(budget_debited returned: #{inspect(debited)})."
    end

    @tag :ac_fr_7_1
    @tag :d_320
    test "AC-FR-7.1 / D-320: cumulative Ledger spend grows with each successive admitted unit" do
      # Each successive :admit must produce an additional Ledger debit entry,
      # so budget_debited reflects the running total.
      totals = %{tokens: 10_000}
      {writer_name, _owner_name, scheduler_name} = start_admission_triple(totals)

      # Admit two distinct units sequentially.
      :admit = @scheduler.admit(scheduler_name, "unit-seq-1", empty_scope())
      :admit = @scheduler.admit(scheduler_name, "unit-seq-2", empty_scope())

      debited = @writer.budget_debited(writer_name)

      # Two admissions → Ledger spend must reflect at least two debit rows.
      # If debit/4 is never called, the total stays 0 and this fails.
      assert Map.get(debited, :tokens, 0) > 0,
             "FR-7.1 / D-320: after two successful admits, Ledger shows 0 spent tokens. " <>
               "Scheduler.admit/3 must call Budget.Owner.debit/4 on every :admit path " <>
               "(budget_debited returned: #{inspect(debited)})."
    end
  end
end
