defmodule Tau.Factory.ConflictCheckPCC5GatingPathsTest do
  @moduledoc """
  Gating tests for P-CC-5 — gating-test-path collision invariant (#623).

  Invariant (control-plane.md:308-309):
    "Two scopes sharing any gating-test path never clear
     (encodes the new shared-test/support collision surface)."

  Reference implementation (control-plane.md:289):
    disjoint_files?(a, b):
      MapSet.disjoint?(
        MapSet.union(a.files, a.gating_paths),
        MapSet.union(b.files, b.gating_paths)
      )

  The `scope` type MUST carry a `gating_paths` field (MapSet of String paths),
  and `clear?/2` / `clear?/3` MUST union it into the files set before
  performing the disjointness check.

  These tests exercise the invariant at its governing boundary via
  `Tau.Factory.Scheduler.admit/3` (the real user-facing admission entry point)
  and also directly via `Tau.Factory.ConflictCheck.clear?/2` to pin the
  low-level contract.

  ALL tests are tagged :p_cc_5 so the AC-to-test linkage gate can verify
  coverage of P-CC-5.
  """

  use ExUnit.Case, async: true

  @moduletag :p_cc_5

  alias Tau.Factory.ConflictCheck
  alias Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp scope(opts \\ []) do
    %{
      deps: Keyword.get(opts, :deps, []),
      files: MapSet.new(Keyword.get(opts, :files, [])),
      codepoints: MapSet.new(Keyword.get(opts, :codepoints, [])),
      specs: MapSet.new(Keyword.get(opts, :specs, [])),
      resources: MapSet.new(Keyword.get(opts, :resources, [])),
      gating_paths: MapSet.new(Keyword.get(opts, :gating_paths, []))
    }
  end

  defp start_scheduler(label) do
    name = :"scheduler_p_cc_5_#{label}_#{System.unique_integer([:positive])}"
    start_supervised!({Scheduler, name: name, w_cap: 10})
    name
  end

  # ---------------------------------------------------------------------------
  # P-CC-5 — ConflictCheck.clear?/2 direct boundary
  # ---------------------------------------------------------------------------

  @tag :p_cc_5
  test "P-CC-5 clear?/2: scopes sharing a gating_paths entry yield {:conflict, :disjoint_files} even when files are disjoint" do
    shared_gating_path = "test/tau/factory/my_feature_test.exs"

    # Files are fully disjoint — only gating_paths overlaps.
    scope_a =
      scope(
        files: ["lib/tau/factory/coordinator.ex"],
        gating_paths: [shared_gating_path]
      )

    scope_b =
      scope(
        files: ["lib/tau/factory/unit.ex"],
        gating_paths: [shared_gating_path]
      )

    result = ConflictCheck.clear?(scope_a, %{"unit_b" => scope_b})

    assert result == {:conflict, :disjoint_files},
           "P-CC-5 violated: scopes with a shared gating_path must not clear, " <>
             "but got #{inspect(result)}. The ConflictCheck scope type must include " <>
             "a gating_paths field and clear?/2 must union it into the files set " <>
             "before the disjointness test (control-plane.md:289)."
  end

  @tag :p_cc_5
  test "P-CC-5 clear?/2: scopes with disjoint gating_paths and disjoint files yield :clear" do
    scope_a =
      scope(
        files: ["lib/tau/factory/coordinator.ex"],
        gating_paths: ["test/tau/factory/coordinator_test.exs"]
      )

    scope_b =
      scope(
        files: ["lib/tau/factory/unit.ex"],
        gating_paths: ["test/tau/factory/unit_test.exs"]
      )

    result = ConflictCheck.clear?(scope_a, %{"unit_b" => scope_b})

    assert result == :clear,
           "P-CC-5 false-positive: fully disjoint scopes (files + gating_paths) " <>
             "must yield :clear, but got #{inspect(result)}."
  end

  @tag :p_cc_5
  test "P-CC-5 clear?/2: gating_path of one scope overlapping files of the other also yields {:conflict, :disjoint_files}" do
    # A path that appears in scope_a's gating_paths but scope_b's files
    # must also be caught — the union is symmetric.
    shared_path = "test/support/factory_helpers.exs"

    scope_a =
      scope(
        files: ["lib/tau/factory/coordinator.ex"],
        gating_paths: [shared_path]
      )

    # scope_b carries the shared path in files (not gating_paths)
    scope_b =
      scope(
        files: ["lib/tau/factory/unit.ex", shared_path],
        gating_paths: []
      )

    result = ConflictCheck.clear?(scope_a, %{"unit_b" => scope_b})

    assert result == {:conflict, :disjoint_files},
           "P-CC-5 violated: a path in scope_a's gating_paths that also appears " <>
             "in scope_b's files must conflict (union includes both sides), " <>
             "but got #{inspect(result)}."
  end

  @tag :p_cc_5
  test "P-CC-5 clear?/3: bidirectional form also blocks gating_path collision" do
    shared_gating_path = "test/tau/factory/shared_gate_test.exs"

    scope_a =
      scope(
        files: ["lib/tau/factory/coordinator.ex"],
        gating_paths: [shared_gating_path]
      )

    scope_b =
      scope(
        files: ["lib/tau/factory/unit.ex"],
        gating_paths: [shared_gating_path]
      )

    result = ConflictCheck.clear?("unit_a", scope_a, %{"unit_b" => scope_b})

    assert result == {:conflict, :disjoint_files},
           "P-CC-5 violated in clear?/3: bidirectional form must also catch " <>
             "gating_path collision, but got #{inspect(result)}."
  end

  @tag :p_cc_5
  test "P-CC-5 scope type must include gating_paths field and clear?/2 must not raise on it" do
    # If the scope type does not include gating_paths, Map.fetch!(scope, :gating_paths)
    # will raise KeyError — that error IS the expected failure mode pre-implementation.
    scope_with_gating =
      scope(
        files: ["lib/tau/factory/coordinator.ex"],
        gating_paths: ["test/tau/factory/coordinator_test.exs"]
      )

    assert Map.has_key?(scope_with_gating, :gating_paths),
           "scope map must carry :gating_paths key"

    # clear?/2 must accept and consume the field without raising
    result = ConflictCheck.clear?(scope_with_gating, %{})

    assert result == :clear,
           "Empty in_flight must yield :clear for any valid scope, " <>
             "but got #{inspect(result)}."
  end

  # ---------------------------------------------------------------------------
  # P-CC-5 — Scheduler.admit/3 (real user-facing entry point)
  # ---------------------------------------------------------------------------

  @tag :p_cc_5
  test "P-CC-5 Scheduler.admit/3: second unit sharing a gating_path is deferred with {:conflict, :disjoint_files}" do
    sched = start_scheduler(:admit_gating_path_collision)
    shared_gating_path = "test/tau/factory/shared_feature_test.exs"

    scope_a =
      scope(
        files: ["lib/tau/factory/coordinator.ex"],
        gating_paths: [shared_gating_path]
      )

    scope_b =
      scope(
        files: ["lib/tau/factory/unit.ex"],
        gating_paths: [shared_gating_path]
      )

    assert Scheduler.admit(sched, "unit_a", scope_a) == :admit,
           "First unit with unique scope must be admitted."

    result = Scheduler.admit(sched, "unit_b", scope_b)

    assert result == {:defer, {:conflict, :disjoint_files}},
           "P-CC-5 violated at Scheduler.admit/3: second unit sharing a " <>
             "gating_path must be deferred with {:defer, {:conflict, :disjoint_files}}, " <>
             "but got #{inspect(result)}. " <>
             "The scope type must carry :gating_paths and ConflictCheck.clear? " <>
             "must union gating_paths into files before the disjointness test."
  end

  @tag :p_cc_5
  test "P-CC-5 Scheduler.admit/3: after release, same gating_path can be admitted again" do
    sched = start_scheduler(:readmit_after_release)
    shared_gating_path = "test/tau/factory/shared_feature_readmit_test.exs"

    scope_a =
      scope(
        files: ["lib/tau/factory/coordinator.ex"],
        gating_paths: [shared_gating_path]
      )

    scope_b =
      scope(
        files: ["lib/tau/factory/unit.ex"],
        gating_paths: [shared_gating_path]
      )

    assert Scheduler.admit(sched, "unit_a", scope_a) == :admit
    assert Scheduler.admit(sched, "unit_b", scope_b) == {:defer, {:conflict, :disjoint_files}}

    assert Scheduler.release(sched, "unit_a") == :ok

    # After release, unit_b should now be admittable (no more collision in F).
    assert Scheduler.admit(sched, "unit_b", scope_b) == :admit,
           "P-CC-5 re-admission: after the conflicting unit is released, " <>
             "the second unit must be admittable."
  end
end
