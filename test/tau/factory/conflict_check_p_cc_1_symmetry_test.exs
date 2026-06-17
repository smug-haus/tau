defmodule Tau.Factory.ConflictCheckPCC1SymmetryTest do
  @moduledoc """
  Gating test for issue #622 — P-CC-1 symmetry violation on the `no_dependency`
  clause of `Tau.Factory.ConflictCheck.clear?/2`.

  P-CC-1 states: `pairwise_clear?(a, b) ⟺ pairwise_clear?(b, a)` for all
  scopes. Admission order must not change the conflict verdict (SPEC-FACTORY-CORE
  §4 B2, `factory-loop.md` §Parallel execution — no dependency clause).

  The `clear?/2` entry point is the documented user-facing public API (the
  Scheduler calls it for each in-flight member). The existing property suite
  (conflict_check_property_test.exs, lines 155-176) never catches this violation
  because `scope_gen/0` always generates `deps: []`, making the symmetry check
  vacuous for the dependency clause.

  ## Violation path

    - scope_a: `deps: ["id_b"]`, all other fields disjoint from scope_b.
    - scope_b: `deps: []`, all other fields disjoint from scope_a.

    `clear?(scope_a, %{"id_b" => scope_b})` sees scope_a.deps ∩ {id_b} ≠ ∅ →
    returns `{:conflict, :no_dependency}`.

    `clear?(scope_b, %{"id_a" => scope_a})` sees scope_b.deps = [] →
    returns `:clear`.

    The two results differ, so P-CC-1 is falsified.

  ## Expected conformant behaviour

  After a conformant fix, both directions MUST agree. The correct result for the
  pair is `{:conflict, :no_dependency}` in both directions: if `a` lists `b` as
  a dep, neither may be admitted while the other is in-flight, regardless of
  which one is the candidate.

  AC linkage: P-CC-1.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :p_cc_1

  @cc_mod Tau.Factory.ConflictCheck

  # ---------------------------------------------------------------------------
  # P-CC-1 — Symmetry: no_dependency clause with non-empty deps (issue #622)
  # ---------------------------------------------------------------------------

  @tag :p_cc_1
  test "P-CC-1 symmetry: clear?/2 agrees in both directions when one scope has non-empty deps (issue #622)" do
    # scope_a explicitly depends on id_b.
    # All structural fields (files, codepoints, specs, resources) are kept
    # disjoint between the two scopes so that clauses 2-5 do not fire —
    # the only relevant clause is no_dependency (clause 1).
    id_a = "unit_a"
    id_b = "unit_b"

    scope_a = %{
      deps: [id_b],
      files: MapSet.new(["a_lib/tau/factory/coordinator.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    scope_b = %{
      deps: [],
      files: MapSet.new(["b_lib/tau/factory/unit.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    # Forward direction: scope_a is the candidate, scope_b is in-flight.
    # scope_a.deps contains id_b (which IS an in-flight id) → conflict.
    result_a_sees_b = @cc_mod.clear?(scope_a, %{id_b => scope_b})

    # Reverse direction: scope_b is the candidate, scope_a is in-flight.
    # scope_b.deps = [] (no forward dep on id_a) BUT scope_a.deps = [id_b]
    # means scope_a is waiting for scope_b.  Under P-CC-1 the verdict must
    # agree with the forward direction.
    result_b_sees_a = @cc_mod.clear?(scope_b, %{id_a => scope_a})

    conflict_a_sees_b = match?({:conflict, _}, result_a_sees_b)
    conflict_b_sees_a = match?({:conflict, _}, result_b_sees_a)

    assert conflict_a_sees_b == conflict_b_sees_a,
           "P-CC-1 violated: clear?(scope_a, {id_b => scope_b}) = #{inspect(result_a_sees_b)} " <>
             "but clear?(scope_b, {id_a => scope_a}) = #{inspect(result_b_sees_a)}. " <>
             "Admission order must not change the conflict verdict."

    # Additionally assert the full conformant behaviour: both must return
    # {:conflict, :no_dependency} — not just "both the same".  If scope_a
    # depends on id_b, neither may be admitted while the other is in-flight.
    assert result_a_sees_b == {:conflict, :no_dependency},
           "Expected {:conflict, :no_dependency} for forward direction, got #{inspect(result_a_sees_b)}"

    assert result_b_sees_a == {:conflict, :no_dependency},
           "Expected {:conflict, :no_dependency} for reverse direction (P-CC-1 requires same verdict), " <>
             "got #{inspect(result_b_sees_a)}"
  end

  @tag :p_cc_1
  @tag :property
  property "P-CC-1 symmetry property: conflict(a, {b}) iff conflict(b, {a}) for scopes with non-empty deps (issue #622)" do
    unit_id_gen =
      StreamData.string(:alphanumeric, min_length: 4, max_length: 12)

    file_path_gen =
      StreamData.map(
        StreamData.string(:alphanumeric, min_length: 3, max_length: 20),
        &("lib/tau/" <> &1 <> ".ex")
      )

    spec_atom_gen =
      StreamData.member_of([
        :spec_factory_core,
        :spec_factory_gate,
        :spec_factory_merge,
        :spec_factory_fleet
      ])

    resource_gen =
      StreamData.member_of([:mix_burrito, :hex_cache, :zig_cache])

    # This property mirrors the existing P-CC-1 property in conflict_check_property_test.exs
    # but generates scopes with NON-EMPTY deps — the gap that makes the existing
    # suite vacuous for the dependency clause.
    check all(
            id_a <- unit_id_gen,
            id_b <- unit_id_gen,
            files_a_list <- StreamData.list_of(file_path_gen, min_length: 1, max_length: 3),
            files_b_list <- StreamData.list_of(file_path_gen, min_length: 1, max_length: 3),
            specs_a <- StreamData.list_of(spec_atom_gen, max_length: 1),
            resources_b <- StreamData.list_of(resource_gen, max_length: 1),
            id_a != id_b
          ) do
      # scope_a depends on id_b — non-empty deps, targeting the exact gap.
      # Files are prefix-tagged to ensure clauses 2-5 remain disjoint so only
      # the no_dependency clause (clause 1) is relevant.
      scope_a = %{
        deps: [id_b],
        files: MapSet.new(Enum.map(files_a_list, &("a_" <> &1))),
        codepoints: MapSet.new(),
        specs: MapSet.new(specs_a),
        resources: MapSet.new()
      }

      scope_b = %{
        deps: [],
        files: MapSet.new(Enum.map(files_b_list, &("b_" <> &1))),
        codepoints: MapSet.new(),
        specs: MapSet.new(),
        resources: MapSet.new(resources_b)
      }

      result_a = @cc_mod.clear?(scope_a, %{id_b => scope_b})
      result_b = @cc_mod.clear?(scope_b, %{id_a => scope_a})

      conflict_a = match?({:conflict, _}, result_a)
      conflict_b = match?({:conflict, _}, result_b)

      assert conflict_a == conflict_b,
             "P-CC-1 violated for (#{id_a}, #{id_b}): " <>
               "clear?(a, {b}) = #{inspect(result_a)} " <>
               "but clear?(b, {a}) = #{inspect(result_b)}"
    end
  end
end
