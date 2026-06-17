defmodule Tau.Factory.SchedulerFR22ScopeCeilingTest do
  @moduledoc """
  Gating test for issue #649 (FR-2.2 gateability ceiling) exercised at the
  Scheduler admission boundary.

  ## Invariant under test (docs/arch/02-requirements/R-list.md, FR-2.2)

  FR-2.2 — A work unit is one coherent shippable increment bounded by two
  guards:

    (1) declared-frozen scope (FR-1.3) — already enforced by IssueSelector
        + Scheduler (see issue body #649 evidence §guard 1).

    (2) **gateability ceiling** — the unit must be reviewable in a single pass.
        *Falsify:* a unit too large to gate in one pass.
        *Authority:* the Scheduler.

  Guard (2) has NO executable enforcement anywhere in the production tree at the
  merge-base of this PR. An exhaustive grep over lib/ for gateab*/ceiling/
  single-pass/diff-size/line-count/too-large/reviewable/coherent/scope-creep/
  max_lines yields only unrelated constructs (#649 audit finding). In particular:

    - check_capacity/2 (scheduler.ex:168-174) bounds the number of CONCURRENT
      in-flight units, NOT the size of any single unit.
    - No :scope_ceiling option is read from start_link/1 opts.
    - No {:defer, :scope_too_large} code path exists.

  This test pins the interface the implementation MUST satisfy:

    - Scheduler.start_link/1 accepts :scope_ceiling — a positive integer
      bounding the maximum number of declared files in any admitted unit's scope.
    - Scheduler.admit/3 (and admit/4) MUST return {:defer, :scope_too_large}
      when MapSet.size(declared_scope.files) > scope_ceiling.
    - On {:defer, :scope_too_large}, F MUST NOT be mutated (D-343 monotone
      admission).
    - A unit whose file count is AT OR BELOW the ceiling MUST still be admitted.

  ## Fail-before analysis

  At the merge-base, Scheduler.init/1 ignores the :scope_ceiling opt
  (not present in Keyword.get calls) and evaluate_admission/4 has no size check.
  Against that code:

    - Scheduler.admit(sched, "unit-big", scope_with_11_files) returns :admit
      (not {:defer, :scope_too_large}).
    - The test's assert result == {:defer, :scope_too_large} FAILS.

  Against the fixed code, evaluate_admission/4 checks
  MapSet.size(declared_scope.files) <= scope_ceiling and returns
  {:defer, :scope_too_large} when the ceiling is exceeded.

  ## AC linkage

  All tests tagged :fr_2_2.
  """

  use ExUnit.Case, async: true

  @moduletag :fr_2_2
  @moduletag :capture_log

  alias Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp start_scheduler_with_ceiling(scope_ceiling, w_cap \\ 10) do
    name = unique_name(:sched_fr22)

    start_supervised!(
      {Scheduler, name: name, w_cap: w_cap, scope_ceiling: scope_ceiling},
      id: unique_name(:sup_fr22)
    )

    name
  end

  # Build a scope with exactly n distinct files and no other conflict signals.
  defp scope_with_n_files(n) do
    files = for i <- 1..n, do: "lib/tau/factory/module_#{i}.ex"

    %{
      deps: [],
      files: MapSet.new(files),
      gating_paths: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # Build a minimal empty scope (no conflict signals).
  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      gating_paths: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # ---------------------------------------------------------------------------
  # FR-2.2 gateability ceiling tests
  # ---------------------------------------------------------------------------

  @tag :fr_2_2
  test "FR-2.2: a unit whose file count exceeds the scope_ceiling is deferred as :scope_too_large" do
    # Ceiling of 10 — a scope with 11 files must be deferred.
    sched = start_scheduler_with_ceiling(10)
    scope = scope_with_n_files(11)

    result = Scheduler.admit(sched, "unit-big", scope)

    assert result == {:defer, :scope_too_large}
  end

  @tag :fr_2_2
  test "FR-2.2: D-343 — defer :scope_too_large does NOT mutate F" do
    # Ceiling of 5 — ensure F stays empty after the over-ceiling admit attempt.
    sched = start_scheduler_with_ceiling(5)
    scope = scope_with_n_files(6)

    assert {:defer, :scope_too_large} = Scheduler.admit(sched, "unit-too-big", scope)

    # F must remain empty: the defer must not have inserted the unit.
    f = Scheduler.in_flight(sched)
    assert f == %{}
    refute Map.has_key?(f, "unit-too-big")
  end

  @tag :fr_2_2
  test "FR-2.2: a unit whose file count equals the scope_ceiling IS admitted (at-ceiling is allowed)" do
    # Ceiling of 7 — a scope with exactly 7 files is at the ceiling, not over it.
    # The ceiling is a strict upper bound: > ceiling defers, == ceiling admits.
    sched = start_scheduler_with_ceiling(7)
    scope = scope_with_n_files(7)

    result = Scheduler.admit(sched, "unit-at-ceiling", scope)

    assert result == :admit
    f = Scheduler.in_flight(sched)
    assert Map.has_key?(f, "unit-at-ceiling")
  end

  @tag :fr_2_2
  test "FR-2.2: units well below the ceiling continue to be admitted normally" do
    # Baseline regression: existing admission behaviour is not broken.
    sched = start_scheduler_with_ceiling(20)
    scope = empty_scope()

    assert :admit = Scheduler.admit(sched, "unit-small", scope)
    f = Scheduler.in_flight(sched)
    assert Map.has_key?(f, "unit-small")
  end

  @tag :fr_2_2
  test "FR-2.2: scope_ceiling check defers with :scope_too_large, not :at_capacity" do
    # Even when the scheduler is under-capacity, a large scope is still deferred.
    # The defer reason must be :scope_too_large, not :at_capacity.
    sched = start_scheduler_with_ceiling(3, 10)
    scope = scope_with_n_files(4)

    result = Scheduler.admit(sched, "unit-oversized", scope)

    # Must be the scope ceiling reason, not a capacity reason.
    assert result == {:defer, :scope_too_large}
  end

  @tag :fr_2_2
  test "FR-2.2: admit/4 (with policy nil) also enforces the scope_ceiling" do
    # The ceiling must apply to both admit/3 and admit/4 (pinned-policy form).
    sched = start_scheduler_with_ceiling(2)
    scope = scope_with_n_files(3)

    result = Scheduler.admit(sched, "unit-big-with-policy", scope, nil)

    assert result == {:defer, :scope_too_large}
  end
end
