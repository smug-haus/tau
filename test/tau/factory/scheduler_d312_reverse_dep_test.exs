defmodule Tau.Factory.SchedulerD312ReverseDependencyTest do
  @moduledoc """
  Gating test for issue #574 (D-312 reverse-dependency) exercised at the
  Scheduler admission boundary — the governing entry point for D-312.

  ## Invariant under test (SPEC-FACTORY-CORE §6, D-312)

  D-312 — Conflict-gated admission is sound: the Scheduler MUST admit
  concurrent work only if ConflictCheck clears on all five declared sets (HR-4).
  The `no_dependency` clause is **bidirectional**: the Scheduler must defer a
  candidate unit when ANY in-flight unit lists the candidate in its own `deps`
  list, not only when the candidate itself declares a dep on an in-flight unit.

  The audit finding in #574 identified that `check_no_dependency/2` only
  checked the **forward** direction (`candidate.deps ∩ in_flight_ids`).
  The reverse direction — any in-flight unit declaring the candidate as its
  dependency — was a blind spot.

  The fix extends `ConflictCheck.clear?/3` with `check_reverse_dependency/2`
  and updates `Scheduler.evaluate_admission/3` to call `clear?/3` passing the
  candidate's own `unit_id` so the reverse scan can run.

  This test exercises the fix at the **Scheduler boundary** (`Scheduler.admit/3`
  and `Scheduler.admit/4`), which is the real user-facing entry point for
  D-312 admission (SPEC-FACTORY-CORE §4 B1). The lower-level
  `ConflictCheck.clear?/3` is already covered by
  `conflict_check_reverse_dep_test.exs`; this file closes the gap at the
  governing boundary.

  ## Fail-before analysis

  At the merge-base (`main` before this PR), `Scheduler.evaluate_admission/3`
  called `ConflictCheck.clear?(declared_scope, f)` (two-argument form).
  `clear?/2` delegates to `clear?(nil, declared_scope, f)`, which skips the
  reverse-dependency scan (`nil` candidate_id → `check_reverse_dependency/2`
  returns `:ok` immediately). Against that code:

    - unit_a is admitted with `deps: ["unit_b"]` → succeeds (F = {unit_a}).
    - unit_b is submitted with `deps: []`, disjoint files → `clear?/2` sees
      `unit_b.deps = []` (no forward dep) and returns `:clear`.
    - Scheduler admits unit_b → both are in F despite unit_a listing unit_b
      as a dependency.
    - The test's `assert result == {:defer, {:conflict, :no_dependency}}`
      fails (result is `:admit`).

  Against the fixed code (`clear?/3` via `Scheduler.evaluate_admission/3`),
  `check_reverse_dependency("unit_b", F)` finds `"unit_b" in scope_a.deps`
  and returns `{:conflict, :no_dependency}`, so the Scheduler defers and the
  test passes.

  ## AC linkage

    - D-312 — all tests tagged `:d_312`
  """

  use ExUnit.Case, async: true

  @moduletag :d_312
  @moduletag :capture_log

  alias Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp start_scheduler(w_cap \\ 5) do
    name = unique_name(:sched_d312_rev)
    start_supervised!({Scheduler, name: name, w_cap: w_cap}, id: unique_name(:sup_d312_rev))
    name
  end

  defp scope(deps, files) do
    %{
      deps: deps,
      files: MapSet.new(files),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # ---------------------------------------------------------------------------
  # D-312 — reverse-dependency direction via Scheduler.admit (issue #574)
  # ---------------------------------------------------------------------------

  describe "D-312 reverse-dep — Scheduler.admit defers when in-flight unit has candidate in its deps" do
    @tag :d_312
    test "D-312 reverse-dep: Scheduler.admit/3 defers candidate when in-flight unit lists it in deps (issue #574)" do
      sched = start_scheduler()

      # unit_a is admitted with unit_b in its deps (unit_a depends on unit_b).
      scope_a = scope(["unit_b"], ["lib/tau/factory/coordinator.ex"])
      assert :admit = Scheduler.admit(sched, "unit_a", scope_a)

      # unit_b is submitted with no deps and disjoint files.
      # D-312 requires deferral: unit_a (in-flight) declares unit_b as a dep.
      # Pre-fix: Scheduler called clear?/2 which is unidirectional → admits unit_b.
      # Post-fix: Scheduler calls clear?/3 which scans reverse deps → defers.
      scope_b = scope([], ["lib/tau/factory/unit.ex"])
      result = Scheduler.admit(sched, "unit_b", scope_b)

      assert result == {:defer, {:conflict, :no_dependency}},
             "D-312 reverse-dep: Scheduler.admit must defer unit_b because in-flight " <>
               "unit_a lists unit_b in its deps. The no_dependency clause must be " <>
               "bidirectional. Got: #{inspect(result)}"

      # F must contain only unit_a — unit_b must not have been admitted.
      f = Scheduler.in_flight(sched)

      assert map_size(f) == 1,
             "D-312 reverse-dep: F must contain only unit_a after unit_b is deferred. " <>
               "Got map_size=#{map_size(f)}, F=#{inspect(f)}"

      assert Map.has_key?(f, "unit_a"),
             "D-312 reverse-dep: unit_a must remain in F. Got F=#{inspect(f)}"

      refute Map.has_key?(f, "unit_b"),
             "D-312 reverse-dep: unit_b must NOT be in F after deferral. Got F=#{inspect(f)}"
    end

    @tag :d_312
    test "D-312 reverse-dep: Scheduler.admit/4 (policy form) also defers on reverse dep (issue #574)" do
      sched = start_scheduler()

      policy = %Tau.Factory.Policy{
        model_per_role: %{test_author: "claude-3-5-haiku-20241022"},
        retry_bound_n: 3
      }

      # unit_a admitted with policy pin; its deps include unit_b.
      scope_a = scope(["unit_c"], ["lib/tau/factory/scheduler.ex"])
      assert :admit = Scheduler.admit(sched, "unit_a", scope_a, policy)

      # unit_c (the dep) tries to be admitted via admit/4.
      # Both the forward and reverse paths must block admission.
      scope_c = scope([], ["lib/tau/factory/retry.ex"])
      result = Scheduler.admit(sched, "unit_c", scope_c, policy)

      assert result == {:defer, {:conflict, :no_dependency}},
             "D-312 reverse-dep (admit/4): Scheduler.admit/4 must also defer unit_c " <>
               "because in-flight unit_a has unit_c in its deps. Got: #{inspect(result)}"
    end

    @tag :d_312
    test "D-312 reverse-dep symmetry: bidirectional blocking — forward dep also defers (issue #574)" do
      # Verify BOTH directions block through the Scheduler:
      # forward: candidate.deps contains in-flight unit
      # reverse: in-flight unit.deps contains candidate
      #
      # This confirms the Scheduler's no_dependency clause is fully symmetric
      # as D-312 requires ("The predicate is symmetric" — SPEC §6 D-312).
      sched_fwd = start_scheduler()
      sched_rev = start_scheduler()

      scope_with_dep_b = scope(["unit_b"], ["lib/tau/factory/unit.ex"])
      scope_empty = scope([], ["lib/tau/factory/coordinator.ex"])

      # --- Forward direction ---
      # unit_b is in F; unit_a declares a dep on unit_b → unit_a must be deferred.
      assert :admit = Scheduler.admit(sched_fwd, "unit_b", scope_empty)
      fwd_result = Scheduler.admit(sched_fwd, "unit_a", scope_with_dep_b)

      assert fwd_result == {:defer, {:conflict, :no_dependency}},
             "D-312 forward dep: unit_a (dep on unit_b) must be deferred when unit_b " <>
               "is in F. Got: #{inspect(fwd_result)}"

      # --- Reverse direction ---
      # unit_a is in F with dep on unit_b; unit_b tries to be admitted → must be deferred.
      assert :admit = Scheduler.admit(sched_rev, "unit_a", scope_with_dep_b)
      rev_result = Scheduler.admit(sched_rev, "unit_b", scope_empty)

      assert rev_result == {:defer, {:conflict, :no_dependency}},
             "D-312 reverse dep: unit_b must be deferred when in-flight unit_a lists " <>
               "unit_b in its deps. Got: #{inspect(rev_result)}"
    end
  end
end
