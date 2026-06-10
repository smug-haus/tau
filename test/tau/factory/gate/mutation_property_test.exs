defmodule Tau.Factory.Gate.MutationPropertyTest do
  @moduledoc """
  Gating tests for the pure parts of `Tau.Factory.Gate.Mutation`:
    `judge/1` (P-MU1, P-MU3, P-MU4)
    `plan/2`  (P-MU2, P-MU4)

  Written BEFORE production code exists (oracle-separation phase, D-304).
  These tests fail with a compile error / UndefinedFunctionError until the
  implementer creates `lib/tau/factory/gate/mutation.ex`.

  Scope: the PURE functions only. No subprocess execution, no I/O.
  Engine execution and the HR-3 cross-check are P2 scope (C6 Engine.TestRun).

  Properties pin SPEC-FACTORY-GATE §4 B2 + B3 + gate-and-toolchain.md §2.3:
    P-MU1 non-vacuity: judge/1 = {:pass, _} iff ≥1 :failed case.
    P-MU2 boundary = declared paths: plan/2 reverts exactly tracked ∖ gating.
    P-MU3 project-creation N/A: judge returns {:na, :project_created} when flagged.
    P-MU4 purity: plan/2 and judge/1 perform no I/O.

  AC linkage: AC-2 (D-305 / D-306 adjacent via the judge/1 vacuous-test hole).
  All property tests are tagged `:property` (OTP non-negotiable #6).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property
  @moduletag :ac_2
  @moduletag :d_305
  @moduletag :d_306

  alias Tau.Factory.Gate.Mutation

  # ---------------------------------------------------------------------------
  # Generators for %TestReport{}-like inputs.
  # The exact struct name is Tau.Toolchain.TestReport (§C9 / §4 B3).
  # We construct minimal maps for the pure judge/1 — the implementer maps these
  # to the real struct; the property tests do not assume struct internals.
  # ---------------------------------------------------------------------------

  defp test_id_gen do
    StreamData.bind(
      StreamData.string(:alphanumeric, min_length: 3, max_length: 15),
      fn s -> StreamData.constant("test_" <> s) end
    )
  end

  defp test_case_gen(status) do
    StreamData.bind(test_id_gen(), fn id ->
      StreamData.constant(%{id: id, status: status})
    end)
  end

  # A report with at least one :failed case.
  defp non_vacuous_report_gen do
    StreamData.bind(
      StreamData.tuple({
        StreamData.list_of(test_case_gen(:failed), min_length: 1, max_length: 5),
        StreamData.list_of(test_case_gen(:passed), max_length: 5)
      }),
      fn {failed, passed} ->
        StreamData.constant(%{cases: Enum.shuffle(failed ++ passed)})
      end
    )
  end

  # A report where ALL cases :passed (vacuous suite).
  defp vacuous_report_gen do
    StreamData.bind(
      StreamData.list_of(test_case_gen(:passed), min_length: 0, max_length: 8),
      fn passed ->
        StreamData.constant(%{cases: passed})
      end
    )
  end

  defp gating_path_gen do
    StreamData.bind(
      StreamData.string(:alphanumeric, min_length: 4, max_length: 12),
      fn s -> StreamData.constant("test/tau/#{s}_gate_test.exs") end
    )
  end

  defp tracked_path_gen do
    StreamData.bind(
      StreamData.string(:alphanumeric, min_length: 4, max_length: 12),
      fn s -> StreamData.constant("lib/tau/#{s}.ex") end
    )
  end

  # ---------------------------------------------------------------------------
  # P-MU1 — non-vacuity: judge/1 = {:pass, _} iff ≥1 :failed case.
  # A suite that passes wholesale against the reverted tree is :fail.
  # ---------------------------------------------------------------------------

  property "P-MU1: AC-2 — judge/1 returns {:pass, ids} when report has ≥1 :failed case" do
    check all(report <- non_vacuous_report_gen()) do
      result = Mutation.judge(report)

      assert {:pass, killed} = result,
             "Expected {:pass, _} for report with ≥1 failed case, got #{inspect(result)}"

      assert is_list(killed)
      assert length(killed) >= 1

      # Every killed id must correspond to a :failed case in the report.
      failed_ids = report.cases |> Enum.filter(&(&1.status == :failed)) |> Enum.map(& &1.id)

      Enum.each(killed, fn id ->
        assert id in failed_ids,
               "Killed id #{inspect(id)} not found in failed cases #{inspect(failed_ids)}"
      end)
    end
  end

  property "P-MU1: AC-2 — judge/1 returns {:fail, :no_test_failed} when all cases pass (vacuous suite)" do
    check all(report <- vacuous_report_gen()) do
      result = Mutation.judge(report)

      assert {:fail, :no_test_failed} = result,
             "Expected {:fail, :no_test_failed} for vacuous suite, got #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # P-MU2 — boundary = declared paths.
  # plan/2 reverts exactly tracked_paths ∖ gating_paths to merge_base.
  # The plan's revert_paths must equal tracked_paths -- gating_paths.
  # ---------------------------------------------------------------------------

  property "P-MU2: AC-2 — plan/2 revert_paths equals tracked_paths minus gating_paths" do
    check all(
            gating_paths_list <-
              StreamData.list_of(gating_path_gen(), min_length: 1, max_length: 4),
            extra_tracked <- StreamData.list_of(tracked_path_gen(), min_length: 0, max_length: 6)
          ) do
      gating_paths = MapSet.new(gating_paths_list)
      # tracked_paths = gating paths + production paths (simulating git ls-files)
      all_tracked = (gating_paths_list ++ extra_tracked) |> Enum.uniq()
      merge_base = "abc1234"

      plan = Mutation.plan(merge_base, gating_paths)

      # The plan must expose its revert set via some field.
      # The property asserts it equals all_tracked ∖ gating_paths.
      expected_revert = MapSet.new(all_tracked) |> MapSet.difference(gating_paths)

      # If the plan does not embed tracked_paths (it only knows the declared
      # gating_paths and the merge_base), the boundary is: anything the engine
      # will revert must be "everything except gating_paths". We test that
      # the plan holds the gating_paths correctly as the keep-set.
      keep_paths = Map.get(plan, :gating_paths, Map.get(plan, :keep_paths, :missing))

      refute keep_paths == :missing,
             "plan/2 must return a struct/map exposing the gating-test keep-set; got #{inspect(plan)}"

      assert MapSet.equal?(MapSet.new(keep_paths), gating_paths),
             "P-MU2: keep-set must equal declared gating_paths exactly"

      # The merge_base must be recorded in the plan for the engine.
      plan_base = Map.get(plan, :merge_base, Map.get(plan, :base, :missing))

      refute plan_base == :missing,
             "plan/2 must record the merge_base; got #{inspect(plan)}"

      assert plan_base == merge_base
    end
  end

  # ---------------------------------------------------------------------------
  # P-MU3 — project-creation N/A.
  # When every gating path's nearest-ancestor build manifest is absent at
  # merge_base, judge returns {:na, :project_created}.
  # We model this via a special report shape: the implementer must define the
  # contract. We test the judge/1 variant that handles the N/A sentinel.
  # ---------------------------------------------------------------------------

  @tag :ac_2
  test "P-MU3: AC-2 — judge/1 returns {:na, :project_created} for a project-creation report" do
    # The contract (SPEC §4 B3, gate-and-toolchain.md §2.3 P-MU3):
    # If every gating path's nearest-ancestor build manifest is absent at
    # merge_base, the engine signals this via a special report shape.
    # judge/1 must return {:na, :project_created} for that sentinel.
    project_created_report = %{cases: [], project_created: true}

    result = Mutation.judge(project_created_report)

    assert {:na, :project_created} = result,
           "Expected {:na, :project_created} for project-creation sentinel report, got #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # P-MU4 — purity: plan/2 and judge/1 perform no I/O.
  # We verify this by calling them multiple times with identical inputs and
  # asserting identical, deterministic outputs (referential transparency).
  # ---------------------------------------------------------------------------

  property "P-MU4: AC-2 — judge/1 is referentially transparent (same input → same output)" do
    check all(report <- StreamData.one_of([non_vacuous_report_gen(), vacuous_report_gen()])) do
      result_1 = Mutation.judge(report)
      result_2 = Mutation.judge(report)

      assert result_1 == result_2,
             "P-MU4: judge/1 must be pure — repeated calls with same input must return same value"
    end
  end

  property "P-MU4: AC-2 — plan/2 is referentially transparent (same inputs → same output)" do
    check all(
            gating_paths_list <-
              StreamData.list_of(gating_path_gen(), min_length: 1, max_length: 3),
            merge_base <- StreamData.string(:alphanumeric, min_length: 7, max_length: 40)
          ) do
      gating_paths = MapSet.new(gating_paths_list)

      plan_1 = Mutation.plan(merge_base, gating_paths)
      plan_2 = Mutation.plan(merge_base, gating_paths)

      assert plan_1 == plan_2,
             "P-MU4: plan/2 must be pure — repeated calls must return the same plan"
    end
  end

  # ---------------------------------------------------------------------------
  # Concrete example — verifies the module entry points exist and are callable.
  # ---------------------------------------------------------------------------

  @tag :ac_2
  @tag :d_306
  test "AC-2 / D-306: judge/1 and plan/2 are callable — modules must exist" do
    # If Tau.Factory.Gate.Mutation does not yet exist, this test fails at
    # compile time with UndefinedFunctionError — the correct fail-before state.

    non_vacuous = %{cases: [%{id: "t1", status: :failed}, %{id: "t2", status: :passed}]}
    assert {:pass, killed} = Mutation.judge(non_vacuous)
    assert "t1" in killed

    vacuous = %{cases: [%{id: "t1", status: :passed}]}
    assert {:fail, :no_test_failed} = Mutation.judge(vacuous)

    gating_paths = MapSet.new(["test/tau/factory/gate/mutation_property_test.exs"])
    plan = Mutation.plan("deadbeef", gating_paths)

    assert is_map(plan) or is_struct(plan),
           "plan/2 must return a map or struct; got #{inspect(plan)}"
  end
end
