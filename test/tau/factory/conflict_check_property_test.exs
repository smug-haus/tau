defmodule Tau.Factory.ConflictCheckPropertyTest do
  @moduledoc """
  StreamData property suite for `Tau.Factory.ConflictCheck` (SPEC-FACTORY-CORE
  §4 B2, D-312, D-343).

  Pinned interface:

    `clear?(declared_scope, in_flight) :: :clear | {:conflict, clause}`

  where:

    declared_scope :: %{
      deps:       [unit_id],
      files:      MapSet.t(String.t()),
      codepoints: MapSet.t({String.t(), atom()}),
      specs:      MapSet.t(atom()),
      resources:  MapSet.t(atom())
    }

    in_flight :: %{unit_id() => declared_scope}

    clause :: :no_dependency | :disjoint_files | :disjoint_codepoints |
              :no_shared_spec | :resource_isolatable

  Properties (P-CC-1..5):

  * P-CC-1 — Symmetry: conflict(a, {b}) ⟺ conflict(b, {a}).
  * P-CC-2 — Non-trivial self-conflict: a scope that overlaps itself is
    reported as a conflict when placed in in_flight.
  * P-CC-3 — Monotonicity (D-343): if clear?(d, F) is a conflict, then
    clear?(d, F ∪ {g}) is still a conflict for any g.
  * P-CC-4 — Disjoint positive: disjoint scopes yield :clear.
  * P-CC-5 — Each clause violation yields the correct {:conflict, clause} atom.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  @cc_mod Tau.Factory.ConflictCheck

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp unit_id_gen do
    StreamData.string(:alphanumeric, min_length: 4, max_length: 12)
  end

  defp file_path_gen do
    StreamData.map(
      StreamData.string(:alphanumeric, min_length: 3, max_length: 20),
      &("lib/tau/" <> &1 <> ".ex")
    )
  end

  defp codepoint_gen do
    StreamData.tuple({
      StreamData.string(:alphanumeric, min_length: 3, max_length: 20),
      StreamData.atom(:alphanumeric)
    })
  end

  defp spec_atom_gen do
    StreamData.member_of([
      :spec_factory_core,
      :spec_factory_gate,
      :spec_factory_merge,
      :spec_factory_fleet,
      :spec_user_turn,
      :spec_circuit_breaker
    ])
  end

  defp resource_gen do
    StreamData.member_of([:mix_burrito, :hex_cache, :zig_cache, :pg_db, :redis_lock])
  end

  defp scope_gen do
    StreamData.bind(
      StreamData.tuple({
        StreamData.list_of(file_path_gen(), max_length: 4),
        StreamData.list_of(codepoint_gen(), max_length: 3),
        StreamData.list_of(spec_atom_gen(), max_length: 2),
        StreamData.list_of(resource_gen(), max_length: 2)
      }),
      fn {files, codepoints, specs, resources} ->
        StreamData.constant(%{
          deps: [],
          files: MapSet.new(files),
          codepoints: MapSet.new(codepoints),
          specs: MapSet.new(specs),
          resources: MapSet.new(resources)
        })
      end
    )
  end

  # A scope whose files set is guaranteed non-empty (needed for overlap tests).
  defp non_empty_file_scope_gen do
    StreamData.bind(
      StreamData.tuple({
        StreamData.list_of(file_path_gen(), min_length: 1, max_length: 4),
        StreamData.list_of(codepoint_gen(), max_length: 2)
      }),
      fn {files, codepoints} ->
        StreamData.constant(%{
          deps: [],
          files: MapSet.new(files),
          codepoints: MapSet.new(codepoints),
          specs: MapSet.new(),
          resources: MapSet.new()
        })
      end
    )
  end

  # A disjoint pair of scopes — all clause inputs are pairwise disjoint.
  defp disjoint_pair_gen do
    StreamData.bind(
      StreamData.tuple({
        StreamData.list_of(file_path_gen(), min_length: 1, max_length: 4),
        StreamData.list_of(file_path_gen(), min_length: 1, max_length: 4)
      }),
      fn {files_a, files_b} ->
        # Prefix-guarantee disjointness without rejection.
        tagged_a = Enum.map(files_a, &("a_" <> &1))
        tagged_b = Enum.map(files_b, &("b_" <> &1))

        scope_a = %{
          deps: [],
          files: MapSet.new(tagged_a),
          codepoints: MapSet.new(),
          specs: MapSet.new(),
          resources: MapSet.new()
        }

        scope_b = %{
          deps: [],
          files: MapSet.new(tagged_b),
          codepoints: MapSet.new(),
          specs: MapSet.new(),
          resources: MapSet.new()
        }

        StreamData.constant({scope_a, scope_b})
      end
    )
  end

  # ---------------------------------------------------------------------------
  # P-CC-1 — Symmetry (AC-3 / D-312)
  # ---------------------------------------------------------------------------

  @tag :ac_3
  @tag :d_312
  property "P-CC-1 symmetry: conflict(a, {b}) iff conflict(b, {a}) (AC-3 / D-312)" do
    check all(
            id_a <- unit_id_gen(),
            id_b <- unit_id_gen(),
            scope_a <- scope_gen(),
            scope_b <- scope_gen(),
            # ensure the ids differ to avoid trivial self-tests
            id_a != id_b
          ) do
      result_a_sees_b = @cc_mod.clear?(scope_a, %{id_b => scope_b})
      result_b_sees_a = @cc_mod.clear?(scope_b, %{id_a => scope_a})

      conflict_a_sees_b = match?({:conflict, _}, result_a_sees_b)
      conflict_b_sees_a = match?({:conflict, _}, result_b_sees_a)

      assert conflict_a_sees_b == conflict_b_sees_a,
             "Symmetry violated: clear?(a,{b})=#{inspect(result_a_sees_b)} " <>
               "but clear?(b,{a})=#{inspect(result_b_sees_a)}"
    end
  end

  # ---------------------------------------------------------------------------
  # P-CC-2 — Non-trivial self-conflict (AC-3 / D-312)
  # ---------------------------------------------------------------------------

  @tag :ac_3
  @tag :d_312
  property "P-CC-2 self-conflict: a non-empty-file scope conflicts when placed in-flight (AC-3 / D-312)" do
    check all(
            id <- unit_id_gen(),
            scope <- non_empty_file_scope_gen()
          ) do
      result = @cc_mod.clear?(scope, %{id => scope})

      assert match?({:conflict, _}, result),
             "Expected conflict for self-overlap, got #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # P-CC-3 — Monotonicity in F (AC-3 / D-312 / D-343)
  # ---------------------------------------------------------------------------

  @tag :ac_3
  @tag :d_312
  @tag :d_343
  property "P-CC-3 monotonicity: conflict(d, F) implies conflict(d, F ∪ {g}) for any g (AC-3 / D-312 / D-343)" do
    check all(
            id_b <- unit_id_gen(),
            id_g <- unit_id_gen(),
            scope_d <- scope_gen(),
            scope_b <- scope_gen(),
            scope_g <- scope_gen(),
            id_b != id_g
          ) do
      base_in_flight = %{id_b => scope_b}
      result_base = @cc_mod.clear?(scope_d, base_in_flight)

      if match?({:conflict, _}, result_base) do
        extended = Map.put(base_in_flight, id_g, scope_g)
        result_extended = @cc_mod.clear?(scope_d, extended)

        assert match?({:conflict, _}, result_extended),
               "Monotonicity violated: adding to in_flight turned conflict into :clear. " <>
                 "Base result: #{inspect(result_base)}, extended result: #{inspect(result_extended)}"
      else
        # :clear — no constraint to check; skip.
        assert result_base == :clear
      end
    end
  end

  # ---------------------------------------------------------------------------
  # P-CC-4 — Disjoint scopes yield :clear (AC-3 / D-312)
  # ---------------------------------------------------------------------------

  @tag :ac_3
  @tag :d_312
  property "P-CC-4 positive: disjoint scopes yield :clear (AC-3 / D-312)" do
    check all(
            id_b <- unit_id_gen(),
            {scope_a, scope_b} <- disjoint_pair_gen()
          ) do
      result = @cc_mod.clear?(scope_a, %{id_b => scope_b})

      assert result == :clear,
             "Expected :clear for disjoint scopes, got #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # P-CC-5 — Each clause violation yields the correct {:conflict, clause} atom (AC-3 / D-312)
  # ---------------------------------------------------------------------------

  @tag :ac_3
  @tag :d_312
  test "P-CC-5 disjoint_files clause: shared file yields {:conflict, :disjoint_files} (AC-3 / D-312)" do
    shared_file = "lib/tau/factory/scheduler.ex"

    scope_a = %{
      deps: [],
      files: MapSet.new([shared_file, "lib/tau/factory/coordinator.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    scope_b = %{
      deps: [],
      files: MapSet.new([shared_file, "lib/tau/factory/unit.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    result = @cc_mod.clear?(scope_a, %{"unit_b" => scope_b})
    assert result == {:conflict, :disjoint_files}
  end

  @tag :ac_3
  @tag :d_312
  test "P-CC-5 no_shared_spec clause: shared SPEC atom yields {:conflict, :no_shared_spec} (AC-3 / D-312)" do
    shared_spec = :spec_factory_core

    scope_a = %{
      deps: [],
      files: MapSet.new(["lib/tau/factory/coordinator.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new([shared_spec]),
      resources: MapSet.new()
    }

    scope_b = %{
      deps: [],
      files: MapSet.new(["lib/tau/factory/unit.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new([shared_spec]),
      resources: MapSet.new()
    }

    result = @cc_mod.clear?(scope_a, %{"unit_b" => scope_b})
    assert result == {:conflict, :no_shared_spec}
  end

  @tag :ac_3
  @tag :d_312
  test "P-CC-5 no_dependency clause: dep on in-flight unit yields {:conflict, :no_dependency} (AC-3 / D-312)" do
    blocked_on_id = "unit_b"

    scope_a = %{
      deps: [blocked_on_id],
      files: MapSet.new(["lib/tau/factory/coordinator.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    scope_b = %{
      deps: [],
      files: MapSet.new(["lib/tau/factory/unit.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    result = @cc_mod.clear?(scope_a, %{blocked_on_id => scope_b})
    assert result == {:conflict, :no_dependency}
  end

  @tag :ac_3
  @tag :d_312
  test "P-CC-5 resource_isolatable clause: shared resource yields {:conflict, :resource_isolatable} (AC-3 / D-312)" do
    shared_resource = :mix_burrito

    scope_a = %{
      deps: [],
      files: MapSet.new(["lib/tau/factory/coordinator.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new([shared_resource])
    }

    scope_b = %{
      deps: [],
      files: MapSet.new(["lib/tau/factory/unit.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new([shared_resource])
    }

    result = @cc_mod.clear?(scope_a, %{"unit_b" => scope_b})
    assert result == {:conflict, :resource_isolatable}
  end

  @tag :ac_3
  @tag :d_312
  test "P-CC-5 disjoint_codepoints clause: shared codepoint (disjoint files/specs/resources/deps) yields {:conflict, :disjoint_codepoints} (AC-3 / D-312)" do
    shared_codepoint = {"lib/tau/factory/scheduler.ex", :admit_unit}

    # Files are prefix-tagged to guarantee disjointness — clause 2 must pass
    # so clause 3 fires first.
    scope_a = %{
      deps: [],
      files: MapSet.new(["a_lib/tau/factory/coordinator.ex"]),
      codepoints: MapSet.new([shared_codepoint]),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    scope_b = %{
      deps: [],
      files: MapSet.new(["b_lib/tau/factory/unit.ex"]),
      codepoints: MapSet.new([shared_codepoint]),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    result = @cc_mod.clear?(scope_a, %{"unit_b" => scope_b})
    assert result == {:conflict, :disjoint_codepoints}
  end

  @tag :ac_3
  @tag :d_312
  @tag :d_343
  test "P-CC-5 no_dependency monotonicity: conflict persists when in_flight grows (AC-3 / D-312 / D-343)" do
    blocked_on_id = "unit_b"

    scope_a = %{
      deps: [blocked_on_id],
      files: MapSet.new(["lib/tau/factory/coordinator.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    scope_b = %{
      deps: [],
      files: MapSet.new(["lib/tau/factory/unit.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    scope_extra = %{
      deps: [],
      files: MapSet.new(["lib/tau/factory/ledger.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    base = %{blocked_on_id => scope_b}
    assert @cc_mod.clear?(scope_a, base) == {:conflict, :no_dependency}

    extended = Map.put(base, "unit_extra", scope_extra)

    assert @cc_mod.clear?(scope_a, extended) == {:conflict, :no_dependency},
           "Monotonicity violated: adding a disjoint unit to in_flight cleared a :no_dependency conflict"
  end

  @tag :ac_3
  @tag :d_312
  test "P-CC-5 empty in_flight yields :clear (AC-3 / D-312)" do
    scope = %{
      deps: [],
      files: MapSet.new(["lib/tau/factory/coordinator.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    assert @cc_mod.clear?(scope, %{}) == :clear
  end
end
