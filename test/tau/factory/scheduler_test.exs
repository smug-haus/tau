defmodule Tau.Factory.SchedulerTest do
  @moduledoc """
  Gating tests for PR #440 (P4b2-Scheduler) — D-312 / D-343.

  Verifies:
    - D-312: conflict-gated admission is sound (admit only when ConflictCheck
      clears, budget headroom holds, and |F| < W_cap; defer otherwise with the
      right reason; the in-flight set F is only mutated on :admit or release).
    - D-343: admission is monotone — a {:defer, _} never mutates F; the only
      writes to F are an :admit (adds one entry) and release (removes one entry);
      no admit→withdraw→re-admit cycle is possible.

  Written BEFORE production code exists (oracle-separation phase, factory-loop §4b).
  Tests fail at runtime (UndefinedFunctionError on Tau.Factory.Scheduler) until
  the implementer creates `lib/tau/factory/scheduler.ex`.

  ## Pinned API contract (implementer must conform exactly)

  ### Tau.Factory.Scheduler (GenServer; wholly absent before this PR)

    - `start_link(opts) :: GenServer.on_start()`
        Required options:
          `:name`    — atom; registered name for the GenServer.
          `:w_cap`   — positive integer; maximum concurrent admitted units (|F| < W_cap).
        Optional options:
          `:budget`  — `{budget_owner_name :: atom(), dimensions :: [atom()]}`;
                       if present, `admit/3` calls `Budget.Owner.budget_precheck/2`
                       for each listed dimension and defers with `{:defer, {:budget, dim}}`
                       if any dimension is exhausted.
                       If absent (or `:budget` not in opts), the budget gate is skipped.

    - `admit(server, unit_id, declared_scope) :: :admit | {:defer, reason}`
        `call`. Checks three admission conditions in this order:
          1. Conflict: `ConflictCheck.clear?(declared_scope, F)` — if `{:conflict, clause}`,
             returns `{:defer, {:conflict, clause}}`.
          2. Capacity: `map_size(F) < W_cap` — if at or over cap, returns
             `{:defer, :at_capacity}`.
          3. Budget (if configured): `Budget.Owner.budget_precheck(owner, dim)` for
             each gated dimension — if any returns `{:exhausted, dim}`, returns
             `{:defer, {:budget, dim}}`.
        On `:admit`: adds `{unit_id => declared_scope}` to F BEFORE the reply.

    - `release(server, unit_id) :: :ok`
        `call`. Removes `unit_id` from F. No-op if unit_id is not in F.

    - `in_flight(server) :: %{unit_id => declared_scope}`
        `call`. Returns the current F map (a snapshot at the time of the call).

  Precedence of defer reasons (first failing condition wins):
    conflict → at_capacity → budget

  AC linkage: D-312 / D-343.
  """

  use ExUnit.Case, async: true

  @moduletag :d_312
  @moduletag :d_343
  @moduletag :capture_log

  # Runtime module references — the file compiles even while Scheduler is absent.
  # Using @mod attributes avoids alias-time resolution and compile-time crashes
  # (Credo strict forbids apply/2,3 — use @mod.fun(args) form instead).
  @scheduler Tau.Factory.Scheduler
  @writer Tau.Factory.Ledger.Writer
  @owner Tau.Factory.Budget.Owner

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build a minimal non-conflicting scope (empty MapSets — clears all five
  # ConflictCheck clauses against any other empty-MapSet scope).
  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # Build a scope that overlaps `other_scope` on the :files clause.
  defp scope_with_file(filename) do
    %{
      deps: [],
      files: MapSet.new([filename]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # Start an isolated Ledger.Writer + Budget.Owner pair backed by a tmp DB.
  # Returns {writer_name, owner_name}.
  defp start_isolated_budget(totals) do
    db_path = Briefly.create!(extname: ".db")
    uid = System.unique_integer([:positive])
    writer_name = :"test_sched_writer_#{uid}"
    owner_name = :"test_sched_owner_#{uid}"

    start_supervised!(
      {@writer, db_path: db_path, name: writer_name},
      id: :"sched_writer_#{uid}"
    )

    start_supervised!(
      {@owner, ledger: writer_name, totals: totals, name: owner_name},
      id: :"sched_owner_#{uid}"
    )

    {writer_name, owner_name}
  end

  # Start a Scheduler with no budget gate.
  defp start_scheduler(w_cap) do
    uid = System.unique_integer([:positive])
    name = :"test_scheduler_#{uid}"

    start_supervised!(
      {@scheduler, name: name, w_cap: w_cap},
      id: :"scheduler_#{uid}"
    )

    name
  end

  # Start a Scheduler with a budget gate.
  defp start_scheduler_with_budget(w_cap, owner_name, dimensions) do
    uid = System.unique_integer([:positive])
    name = :"test_scheduler_budgeted_#{uid}"

    start_supervised!(
      {@scheduler, name: name, w_cap: w_cap, budget: {owner_name, dimensions}},
      id: :"scheduler_budgeted_#{uid}"
    )

    name
  end

  # ---------------------------------------------------------------------------
  # D-312 — sound admission: :admit when all conditions clear
  # ---------------------------------------------------------------------------

  describe "D-312 — sound admission" do
    @tag :d_312
    test "D-312: a unit with clear scope, budget headroom, and |F| < W_cap is admitted; in_flight gains that unit" do
      sched = start_scheduler(3)
      scope = empty_scope()

      result = @scheduler.admit(sched, "unit-alpha", scope)
      assert result == :admit

      f = @scheduler.in_flight(sched)
      assert map_size(f) == 1
      assert Map.has_key?(f, "unit-alpha")
      assert Map.fetch!(f, "unit-alpha") == scope
    end

    @tag :d_312
    test "D-312: defer on conflict — overlapping file scope; F is unchanged (still just unit A)" do
      sched = start_scheduler(5)
      scope_a = scope_with_file("lib/foo.ex")
      scope_b = scope_with_file("lib/foo.ex")

      # Admit unit A — must succeed.
      assert :admit = @scheduler.admit(sched, "unit-a", scope_a)

      # Admit unit B with the same file — must conflict.
      result = @scheduler.admit(sched, "unit-b", scope_b)
      assert {:defer, {:conflict, :disjoint_files}} = result

      # F must still contain only unit A — the defer did not add unit B.
      f = @scheduler.in_flight(sched)
      assert map_size(f) == 1
      assert Map.has_key?(f, "unit-a")
      refute Map.has_key?(f, "unit-b")
    end

    @tag :d_312
    test "D-312: defer on budget exhausted; F is unchanged after the defer" do
      totals = %{tokens: 10}
      {writer_name, owner_name} = start_isolated_budget(totals)
      sched = start_scheduler_with_budget(5, owner_name, [:tokens])

      # Drain the budget via the Owner debit path.
      :ok = @owner.debit(writer_name, "pre-unit", :tokens, 10)
      assert {:exhausted, :tokens} = @owner.budget_precheck(owner_name, :tokens)

      # Now attempt to admit a unit with a clear (non-conflicting) scope.
      result = @scheduler.admit(sched, "unit-budget-denied", empty_scope())
      assert {:defer, {:budget, :tokens}} = result

      # F must still be empty — the defer did not add the unit.
      f = @scheduler.in_flight(sched)
      assert map_size(f) == 0
    end

    @tag :d_312
    test "D-312: defer at capacity — second non-conflicting unit deferred when |F| == W_cap; F unchanged" do
      sched = start_scheduler(1)

      # Admit first unit — must succeed (|F| = 0 < W_cap = 1).
      assert :admit = @scheduler.admit(sched, "unit-cap-1", empty_scope())

      # A second non-conflicting, no-budget unit — must be deferred because |F| = 1 = W_cap.
      result = @scheduler.admit(sched, "unit-cap-2", empty_scope())
      assert {:defer, :at_capacity} = result

      # F must still contain only the first unit.
      f = @scheduler.in_flight(sched)
      assert map_size(f) == 1
      assert Map.has_key?(f, "unit-cap-1")
      refute Map.has_key?(f, "unit-cap-2")
    end
  end

  # ---------------------------------------------------------------------------
  # D-343 — monotone / release: F only ever grows via :admit, shrinks via release
  # ---------------------------------------------------------------------------

  describe "D-343 — monotone admission and release" do
    @tag :d_343
    test "D-343: release shrinks F; the previously-deferred unit can then be admitted cleanly" do
      sched = start_scheduler(1)
      scope_a = empty_scope()
      scope_b = empty_scope()

      # Admit unit A (fills capacity).
      assert :admit = @scheduler.admit(sched, "unit-mono-a", scope_a)

      # Unit B deferred (at capacity).
      assert {:defer, :at_capacity} = @scheduler.admit(sched, "unit-mono-b", scope_b)

      # F contains only unit A.
      f_before = @scheduler.in_flight(sched)
      assert map_size(f_before) == 1
      assert Map.has_key?(f_before, "unit-mono-a")

      # Release unit A.
      :ok = @scheduler.release(sched, "unit-mono-a")

      # F is now empty.
      f_after_release = @scheduler.in_flight(sched)
      assert map_size(f_after_release) == 0

      # Now admit unit B — fresh decision; must succeed.
      assert :admit = @scheduler.admit(sched, "unit-mono-b", scope_b)

      # F contains only unit B.
      f_final = @scheduler.in_flight(sched)
      assert map_size(f_final) == 1
      assert Map.has_key?(f_final, "unit-mono-b")
    end

    @tag :d_343
    test "D-343: a sequence of defers never mutates F — F changes only on :admit and release" do
      sched = start_scheduler(1)

      # Pre-condition: F is empty.
      assert map_size(@scheduler.in_flight(sched)) == 0

      # Attempt to admit a unit with conflicting scope against nothing (will succeed —
      # but we want to produce defers next).
      scope_first = scope_with_file("lib/shared.ex")
      assert :admit = @scheduler.admit(sched, "unit-first", scope_first)

      f_after_admit = @scheduler.in_flight(sched)
      assert map_size(f_after_admit) == 1

      # Three separate defers in succession — conflict, at_capacity, conflict.
      # None of these should mutate F.
      scope_conflict = scope_with_file("lib/shared.ex")
      assert {:defer, _} = @scheduler.admit(sched, "unit-defer-1", scope_conflict)
      assert map_size(@scheduler.in_flight(sched)) == 1

      # at_capacity for a non-conflicting unit
      assert {:defer, _} = @scheduler.admit(sched, "unit-defer-2", empty_scope())
      assert map_size(@scheduler.in_flight(sched)) == 1

      # conflict again
      assert {:defer, _} = @scheduler.admit(sched, "unit-defer-3", scope_conflict)
      assert map_size(@scheduler.in_flight(sched)) == 1

      # F still contains only the first unit — no defer added or removed anything.
      f_final = @scheduler.in_flight(sched)
      assert Map.keys(f_final) == ["unit-first"]

      # Release restores empty F (normal shrink path).
      :ok = @scheduler.release(sched, "unit-first")
      assert map_size(@scheduler.in_flight(sched)) == 0
    end
  end
end
