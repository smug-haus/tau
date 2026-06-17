defmodule Tau.Factory.NFRBudgetPrecisionTest do
  @moduledoc """
  Gating test for issue #671 — NFR-BUDGET-PRECISION.

  ## Invariant under test

  **NFR-BUDGET-PRECISION** (docs/arch/02-requirements/nfrs.md):

    > "Spend never exceeds budget by more than one in-flight action's cost
    > (admission is checked pre-action; INV-21)."

  Operationally (docs/arch/04-software-architecture/governance.md §2):

    > "Admission is checked *pre-action* and debits a reservation, so spend
    > exceeds budget by ≤ one in-flight action's cost — the action already
    > admitted when the ceiling was crossed."

  ## The gap this test pins (#671 audit finding)

  `Tau.Factory.Supervisor.init_full_subtree/1` (the `enabled: true` production
  assembly path) hardcodes the BudgetOwner child spec as:

      {BudgetOwner, ledger: writer_name, totals: %{}, name: budget_owner_name}

  No `:budget_totals` (or equivalent) option is threaded from the supervisor's
  incoming opts to the BudgetOwner.  Consequently:

  1. There is **no way to configure a non-zero budget ceiling** through the
     production entry point.  Every `totals: %{}` starts with zero headroom for
     all dimensions — every admission through the enabled path is immediately
     deferred on `:tokens` because the ETS table has no `:tokens` row.

  2. The NFR cannot be exercised on the enabled path: a valid (bounded) ceiling
     that admits units up to the limit and denies past it is impossible to
     express through `Tau.Factory.Supervisor` with `enabled: true`.

  3. The test currently fails at the first admission: with `totals: %{}`,
     `budget_precheck/2` returns `{:exhausted, :tokens}` (dimension absent from
     ETS), so `Scheduler.admit/3` returns `{:defer, {:budget, :tokens}}` even
     for the first unit.  The assertion `assert first_result == :admit` fails.

  ## Conformant behaviour (post-fix)

  The production supervisor MUST accept a `budget_totals:` keyword option and
  thread it to the BudgetOwner child spec, replacing the hardcoded `totals: %{}`.
  Default: `%{}` (unchanged behaviour when the caller omits the opt).

  With `budget_totals: %{tokens: N}`:

  - The first N calls to `Scheduler.admit/3` MUST return `:admit` (headroom
    remains after each debit).
  - The (N+1)th call MUST return `{:defer, {:budget, :tokens}}` (ceiling
    exhausted; D-320 hard gate fires).
  - Spend recorded in the Ledger after N admits equals N (cost = 1 per
    admitted unit via `Budget.Owner.debit_admission/3`).  Remaining = 0.

  ## Why this FAILS today (fail-before validity)

  With `totals: %{}` hardcoded, `budget_precheck(owner, :tokens)` returns
  `{:exhausted, :tokens}` on the very first `admit/3` call.  The assertion

      assert first_result == :admit

  fails immediately — the first admission is deferred, not admitted.

  The test exercises the real production entry point
  (`Tau.Factory.Supervisor` with `enabled: true`) and drives admissions
  through the derived `Tau.Factory.Scheduler` child — no hand-built struct
  bypasses the real wiring.

  ## AC/D-NNN linkage

  - NFR-BUDGET-PRECISION (issue #671)
  - D-320 — Budget ceiling is a hard pre-admission gate
  """

  use ExUnit.Case, async: false

  @moduletag :nfr_budget_precision
  @moduletag :d_320
  @moduletag :capture_log

  @supervisor Tau.Factory.Supervisor
  @scheduler Tau.Factory.Scheduler
  @issue_selector Tau.Factory.IssueSelector
  @unit_driver Tau.Factory.UnitDriver

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Minimal throwaway git repo (required by MergeAuthority).
  defp setup_git_repo do
    repo_dir = Briefly.create!(type: :directory)
    git = fn args -> System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true) end
    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])
    File.write!(Path.join(repo_dir, "README"), "initial\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial commit"])
    repo_dir
  end

  # Replicate the name-derivation logic from Supervisor.derive_name/3.
  defp derive_child_name(sup_name, child_mod) do
    suffix =
      inspect(child_mod)
      |> String.split(".")
      |> List.last()
      |> Macro.underscore()

    :"#{sup_name}_#{suffix}"
  end

  # Minimal declared_scope that clears all ConflictCheck clauses against an
  # empty in-flight set (no conflict; below w_cap=5; only budget gates).
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
  # NFR-BUDGET-PRECISION — production supervisor must accept and thread budget_totals
  # ---------------------------------------------------------------------------

  describe "NFR-BUDGET-PRECISION — Supervisor threads budget_totals to BudgetOwner on enabled path" do
    @tag :nfr_budget_precision
    @tag :d_320
    test "NFR-BUDGET-PRECISION: admissions up to the ceiling succeed; the next one is deferred" do
      # This test exercises the NFR-BUDGET-PRECISION invariant through the
      # real production entry point — Tau.Factory.Supervisor with enabled: true.
      #
      # The conformant fix: init_full_subtree/1 reads a :budget_totals opt and
      # threads it to the BudgetOwner child spec so a real ceiling can be set.
      #
      # Current broken behaviour: totals: %{} is hardcoded; budget_precheck for
      # :tokens always returns {:exhausted, :tokens} because the ETS table has
      # no :tokens row; the first admission is deferred rather than admitted.

      ceiling = 3
      repo_dir = setup_git_repo()
      db_path = Briefly.create!(extname: ".db")
      sup_name = :"factory_sup_nfr_bp_#{System.unique_integer([:positive])}"

      # No-issues gh_fun keeps the Coordinator idle (drives no uncontrolled work).
      no_issues_gh_fun = fn _milestone -> {:ok, []} end

      _sup_pid =
        start_supervised!(
          {
            @supervisor,
            # NFR-BUDGET-PRECISION: configure a real ceiling via the production
            # entry point.  The conformant fix threads this to BudgetOwner.
            enabled: true,
            db_path: db_path,
            name: sup_name,
            repo_dir: repo_dir,
            milestone: "nfr-bp-test-milestone",
            gh_fun: no_issues_gh_fun,
            select_fun: &@issue_selector.select/1,
            drive_fun: &@unit_driver.drive/2,
            budget_totals: %{tokens: ceiling}
          },
          id: sup_name
        )

      scheduler_name = derive_child_name(sup_name, @scheduler)

      assert is_pid(Process.whereis(scheduler_name)),
             "NFR-BUDGET-PRECISION: Scheduler #{inspect(scheduler_name)} not registered; " <>
               "full supervisor did not start Scheduler child."

      # Admit `ceiling` units — each should be granted (:admit).
      # With the conformant fix, BudgetOwner has totals: %{tokens: 3} so there
      # is headroom for 3 admissions.
      admitted_results =
        Enum.map(1..ceiling, fn i ->
          @scheduler.admit(scheduler_name, "nfr-bp-unit-#{i}", empty_scope())
        end)

      first_result = List.first(admitted_results)

      assert first_result == :admit,
             "NFR-BUDGET-PRECISION VIOLATED: first admission returned " <>
               "#{inspect(first_result)} instead of :admit. " <>
               "init_full_subtree/1 must accept :budget_totals and thread it to " <>
               "BudgetOwner (currently hardcodes totals: %{} — supervisor.ex ~line 263). " <>
               "With totals: %{}, ETS has no :tokens row so budget_precheck/2 " <>
               "returns {:exhausted, :tokens} on every call regardless of the " <>
               "configured ceiling."

      assert Enum.all?(admitted_results, &(&1 == :admit)),
             "NFR-BUDGET-PRECISION: not all #{ceiling} admissions below the ceiling succeeded; " <>
               "results=#{inspect(admitted_results)}"

      # The (ceiling+1)th admission MUST be denied by budget exhaustion.
      # D-320: budget_precheck denies at the ceiling before the unit is billable.
      over_ceiling_result =
        @scheduler.admit(scheduler_name, "nfr-bp-unit-over", empty_scope())

      assert over_ceiling_result == {:defer, {:budget, :tokens}},
             "NFR-BUDGET-PRECISION VIOLATED: Scheduler.admit/3 returned " <>
               "#{inspect(over_ceiling_result)} for the (ceiling+1)th admission, " <>
               "expected {:defer, {:budget, :tokens}}. " <>
               "D-320: admission MUST be denied once the budget ceiling is exhausted."
    end
  end
end
