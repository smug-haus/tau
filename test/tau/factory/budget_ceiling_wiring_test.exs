defmodule Tau.Factory.BudgetCeilingWiringTest do
  @moduledoc """
  Gating test for issue #579 — D-320 budget ceiling wiring in the production
  enabled path.

  ## Invariant under test

  **D-320** (SPEC-FACTORY-CORE §4): Scheduler and Budget.Owner MUST reject
  admission when the pre-admission check shows the budget would be exceeded;
  spend MUST NOT exceed budget by more than 1 action.

  ## The defect this test pins

  `Tau.Factory.Supervisor.init_full_subtree/1` (the `enabled: true` production
  assembly path) starts the Scheduler with NO `:budget` option
  (`supervisor.ex:265`):

      {Scheduler, name: scheduler_name, w_cap: 5}

  `Scheduler.init/1` defaults `budget: nil` when `:budget` is absent
  (`scheduler.ex:106`).  `check_budget(nil)` unconditionally returns `:ok`
  (`scheduler.ex:171`).  The ceiling is therefore NEVER evaluated on the
  enabled production path — every `admit/3` call succeeds regardless of spend.

  ## What the test asserts (conformant behaviour, post-fix)

  1. The full supervisor (`enabled: true`) assembles a Budget.Owner and
     a Scheduler that are **wired together**: the Scheduler's budget option
     references the Budget.Owner.
  2. Because the default `totals: %{}` registers no dimension rows, any
     dimension is immediately at-ceiling (ETS lookup returns nothing →
     `{:exhausted, dim}` — `budget/owner.ex:73-76`, B4/D-320).
  3. `Scheduler.admit/3` returns `{:defer, {:budget, :tokens}}` — not `:admit`
     — even when the in-flight set F is empty and capacity is available.

  ## Why this FAILS today (fail-before validity, oracle-separation §4b)

  With the current code `check_budget(nil) = :ok` → `admit` returns `:admit`.
  The assertion `assert {:defer, {:budget, :tokens}} = ...` fails.

  ## Boundary entry point

  `Tau.Factory.Scheduler.admit/3` called via `Tau.Factory.Supervisor`
  (`enabled: true`) — the real production assembly, not a hand-built struct.
  The Supervisor starts the Scheduler; the test drives admission through it.
  """

  use ExUnit.Case, async: false

  @moduletag :d_320
  @moduletag :capture_log

  @supervisor Tau.Factory.Supervisor
  @scheduler Tau.Factory.Scheduler
  @issue_selector Tau.Factory.IssueSelector
  @unit_driver Tau.Factory.UnitDriver

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Throwaway git repo required by MergeAuthority (same pattern as
  # factory_supervision_test.exs).
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

  # Derive the per-supervisor child name using the same logic as
  # Tau.Factory.Supervisor.derive_name/3 (private function, replicated here).
  defp derive_child_name(sup_name, child_mod) do
    suffix =
      inspect(child_mod)
      |> String.split(".")
      |> List.last()
      |> Macro.underscore()

    :"#{sup_name}_#{suffix}"
  end

  # ---------------------------------------------------------------------------
  # D-320 — budget ceiling wiring in the enabled production path
  # ---------------------------------------------------------------------------

  describe "D-320 — Scheduler is wired to Budget.Owner in the enabled production path" do
    @tag :d_320
    test "D-320: Scheduler.admit returns {:defer, {:budget, dim}} when budget is at-ceiling in the full enabled-path assembly" do
      # Start the full factory subtree via the REAL production entry point.
      repo_dir = setup_git_repo()
      db_path = Briefly.create!(extname: ".db")
      sup_name = :"factory_sup_d320_#{System.unique_integer([:positive])}"

      # A no-issues gh_fun so the Coordinator idles and drives no uncontrolled
      # work (mirrors factory_supervision_test.exs pattern).
      no_issues_gh_fun = fn _milestone -> {:ok, []} end

      _sup_pid =
        start_supervised!(
          {
            @supervisor,
            enabled: true,
            db_path: db_path,
            name: sup_name,
            repo_dir: repo_dir,
            milestone: "d320-test-milestone",
            gh_fun: no_issues_gh_fun,
            select_fun: &@issue_selector.select/1,
            drive_fun: &@unit_driver.drive/2
          },
          id: sup_name
        )

      # Derive the scheduler child name (matches Supervisor.derive_name/3).
      scheduler_name = derive_child_name(sup_name, Tau.Factory.Scheduler)

      # Confirm the Scheduler is registered and live.
      assert is_pid(Process.whereis(scheduler_name)),
             "D-320: The enabled full-subtree assembly MUST start a Scheduler " <>
               "registered as #{inspect(scheduler_name)}. " <>
               "Process.whereis returned nil — the Scheduler is absent."

      # Attempt admission for a fresh unit with a minimal declared scope (no
      # conflict risk; well under w_cap=5; F is empty).  The budget dimension
      # :tokens is at-ceiling because the default totals: %{} seeds no ETS rows,
      # so budget_precheck for any dimension returns {:exhausted, dim}.
      #
      # D-320 requires: Scheduler MUST return {:defer, {:budget, :tokens}}.
      # Current broken behaviour: check_budget(nil) = :ok → returns :admit.
      # Build a minimal but valid declared_scope (all required ConflictCheck keys;
      # empty sets ensure no conflict on any clause — the only deferral should
      # be the budget ceiling, per D-320).
      empty_scope = %{
        deps: [],
        files: MapSet.new(),
        codepoints: MapSet.new(),
        specs: MapSet.new(),
        resources: MapSet.new()
      }

      result = @scheduler.admit(scheduler_name, "unit-d320-test", empty_scope)

      assert result == {:defer, {:budget, :tokens}},
             "D-320 VIOLATED: Scheduler.admit/3 returned #{inspect(result)} instead of " <>
               "{:defer, {:budget, :tokens}}. " <>
               "The enabled production assembly (Tau.Factory.Supervisor, init_full_subtree/1) " <>
               "starts Scheduler WITHOUT a :budget option (supervisor.ex:265). " <>
               "Scheduler.init/1 defaults budget: nil (scheduler.ex:106). " <>
               "check_budget(nil) unconditionally returns :ok (scheduler.ex:171). " <>
               "Budget ceiling enforcement is DEAD on the enabled path. " <>
               "Fix: thread :budget => {budget_owner_name, [:tokens, ...]} " <>
               "into the Scheduler child spec in init_full_subtree/1."
    end
  end
end
