defmodule Tau.Factory.ConflictCheckReverseDependencyTest do
  @moduledoc """
  Gating test for issue #574 (D-312 reverse-dependency gap).

  The `no_dependency` clause of `ConflictCheck.clear?/2` is bidirectional:
  admission MUST be blocked when ANY in-flight unit declares the candidate as
  its dependency, not only when the candidate declares a dep on an in-flight
  unit (SPEC-FACTORY-CORE §4 B2, D-312).

  Current behaviour (confirmed bug): `check_no_dependency/2` only checks
  `declared_scope.deps ∩ in_flight_ids`; it does NOT scan in-flight scopes for
  reverse mentions of the candidate. The concrete failing path:

    - `unit_a` is in-flight with `deps: ["unit_b"]`.
    - `unit_b` is admitted as candidate with `deps: []`.
    - `check_no_dependency` sees `unit_b.deps = []` — no member of
      in_flight_ids found — returns `:ok`.
    - Both units are now in-flight despite `unit_a` listing `unit_b` as a
      dependency, violating D-312's "no dependency" admission clause.

  The fix MUST make the check symmetric: `clear?(candidate_scope, in_flight)`
  returns `{:conflict, :no_dependency}` when any in-flight unit's `deps` list
  contains the candidate's `unit_id`.

  ## Pinned interface

    `Tau.Factory.ConflictCheck.clear?(declared_scope, in_flight) :: :clear | {:conflict, clause}`

  where `in_flight :: %{unit_id => declared_scope}` and the candidate's own
  `unit_id` is NOT a key in `in_flight` (the Scheduler self-excludes it before
  calling — D-380). The reverse-dep check therefore requires passing the
  candidate's `unit_id` so the check can scan in-flight scopes for mentions of
  it; see the SPEC gap note below.

  ## SPEC gap note

  SPEC-FACTORY-CORE §4 B2 documents `clear?(declared_scope, in_flight)` with a
  two-argument signature. A bidirectional dependency check requires knowing the
  candidate's own `unit_id` (to scan in-flight `deps` lists for reverse
  mentions). Two conformant resolutions exist:

    1. Extend the signature to `clear?(unit_id, declared_scope, in_flight)` —
       the Scheduler already has the candidate's id at call-site, and the SPEC
       note at §4 B2 ("unit-id-agnostic") targets `ConflictCheck` not carrying
       *in-flight* unit-ids, which this does not violate.
    2. Keep the two-argument signature but require `declared_scope` to carry the
       candidate's own id (e.g. a `:self_id` key the Scheduler injects before
       calling). The Scheduler self-exclusion step (D-380) already has this id.

  Either resolution is acceptable. The test is written against the extended
  three-argument form (`clear?/3`) as the simpler change: the Scheduler passes
  the candidate's `unit_id` explicitly. If the implementer chooses resolution 2,
  the test must be updated to match.

  AC linkage: D-312.
  """

  use ExUnit.Case, async: true

  @moduletag :d_312

  @cc_mod Tau.Factory.ConflictCheck

  # ---------------------------------------------------------------------------
  # D-312 — reverse-dependency direction (issue #574)
  # ---------------------------------------------------------------------------

  @tag :d_312
  test "D-312 reverse-dep: {:conflict, :no_dependency} when in-flight unit has candidate in its deps (issue #574)" do
    # unit_a is in-flight and declares unit_b as a dependency.
    # unit_b is the candidate being admitted; its own deps list is empty.
    # The conflict check MUST detect the reverse edge and return
    # {:conflict, :no_dependency}, not :clear.

    unit_b_id = "unit_b"

    scope_unit_a_inflight = %{
      deps: [unit_b_id],
      files: MapSet.new(["lib/tau/factory/coordinator.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    scope_unit_b_candidate = %{
      deps: [],
      files: MapSet.new(["lib/tau/factory/unit.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    in_flight = %{"unit_a" => scope_unit_a_inflight}

    # The three-argument form: clear?(candidate_id, declared_scope, in_flight).
    # The candidate's id is required so the check can scan in-flight deps lists
    # for reverse mentions.
    result = @cc_mod.clear?(unit_b_id, scope_unit_b_candidate, in_flight)

    assert result == {:conflict, :no_dependency},
           "Expected {:conflict, :no_dependency} because in-flight unit_a declares " <>
             "unit_b as a dependency, but got: #{inspect(result)}"
  end
end
