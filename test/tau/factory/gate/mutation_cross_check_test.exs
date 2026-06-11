defmodule Tau.Factory.Gate.MutationCrossCheckTest do
  @moduledoc """
  Gating tests for PR #431 (Closes #420) — the mutation cross-check contract
  (AC-4, D-306, SPEC-FACTORY-GATE §3 [C203-B3]).

  Written BEFORE production code exists (oracle-separation phase, D-304).
  These tests fail until the implementer creates:
    - `lib/tau/factory/gate/mutation.ex` (specifically the cross-check logic)
    - `lib/tau/toolchain/test_report.ex`

  The cross-check (SPEC-FACTORY-GATE §3 [C203-B3], §4 B3):
    Given:
      - reverted_report: the engine-parsed report from running tests on the
        REVERTED tree (production removed). Must have ≥1 :failed case.
      - real_report: the engine-parsed report from running tests on the REAL
        (green) tree.
    Assert: `killed_ids ⊆ passing_ids(real_report)`
      where killed_ids = the :failed case ids from reverted_report.

    The half PASSes iff:
      1. judge(reverted_report) = {:pass, killed_ids}  (≥1 :failed case), AND
      2. killed_ids ⊆ passing_ids(real_report)         (cross-check holds).

    The half FAILs if:
      - judge(reverted_report) = {:fail, :no_test_failed}  (vacuous suite), OR
      - killed_ids ⊄ passing_ids(real_report)  (cross-check fails — suspicious).

  The function tested is `Tau.Factory.Gate.Mutation.cross_check/2`:
    @spec cross_check(killed_ids :: [term()], real_report :: TestReport.t()) ::
            :pass | {:fail, :cross_check_failed}

  This is a PURE function (P-MU4) — no I/O, property-testable in isolation.

  AC linkage (SPEC-FACTORY-GATE §7):
    AC-4 (D-306/D-354): the strictly-ordered mutation cross-check.

  All property tests are tagged `:property`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Factory.Gate.Mutation

  @moduletag :ac_4
  @moduletag :d_306

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp test_id_gen do
    StreamData.bind(
      StreamData.string(:alphanumeric, min_length: 3, max_length: 20),
      fn s -> StreamData.constant("test_" <> s) end
    )
  end

  defp unique_ids_gen(min, max) do
    StreamData.bind(
      StreamData.list_of(test_id_gen(), min_length: min, max_length: max),
      fn ids -> StreamData.constant(Enum.uniq(ids)) end
    )
  end

  # A report containing the given ids all as :passed.
  defp passing_report(ids) do
    %{cases: Enum.map(ids, &%{id: &1, status: :passed})}
  end

  # A report containing the given ids all as :failed.
  defp failing_report(ids) do
    %{cases: Enum.map(ids, &%{id: &1, status: :failed})}
  end

  # A report mixing some passed (passed_ids) and some failed (failed_ids).
  defp mixed_report(passed_ids, failed_ids) do
    passed = Enum.map(passed_ids, &%{id: &1, status: :passed})
    failed = Enum.map(failed_ids, &%{id: &1, status: :failed})
    %{cases: passed ++ failed}
  end

  # ---------------------------------------------------------------------------
  # AC-4 / D-306 — Cross-check: killed_ids ⊆ passing_ids(real_report)
  #
  # SPEC-FACTORY-GATE §4 B3: "the engine asserts killed_ids ⊆ passing_ids(real_report)"
  # ---------------------------------------------------------------------------

  describe "AC-4 / D-306: cross_check/2 — killed_ids ⊆ passing_ids(real_report)" do
    @tag :ac_4
    @tag :d_306
    test "cross_check passes when all killed_ids appear :passed in the real report" do
      killed_ids = ["test_gating_1", "test_gating_2"]
      # Real run: ALL the killed ids now pass (production is present).
      real_report = passing_report(killed_ids ++ ["test_extra_passing"])

      result = Mutation.cross_check(killed_ids, real_report)

      assert result == :pass,
             "cross_check/2 must return :pass when killed_ids ⊆ passing_ids(real); " <>
               "got #{inspect(result)}"
    end

    @tag :ac_4
    @tag :d_306
    test "cross_check fails when a killed_id is NOT passing in the real report" do
      killed_ids = ["test_gating_1", "test_gating_2"]
      # Real run: only one of the killed ids is passing.
      real_report = passing_report(["test_gating_1"])

      result = Mutation.cross_check(killed_ids, real_report)

      assert match?({:fail, _}, result),
             "cross_check/2 must return {:fail, _} when killed_ids ⊄ passing_ids(real); " <>
               "got #{inspect(result)}"
    end

    @tag :ac_4
    @tag :d_306
    test "cross_check fails when a killed_id appears :failed in the real report (suspicious — should be fixed)" do
      killed_ids = ["test_gating_1"]
      # Real run: the killed id is STILL failing on the real tree — suspicious.
      real_report = failing_report(["test_gating_1"])

      result = Mutation.cross_check(killed_ids, real_report)

      assert match?({:fail, _}, result),
             "cross_check/2 must return {:fail, _} when killed_id is :failed on real tree; " <>
               "got #{inspect(result)}"
    end

    @tag :ac_4
    @tag :d_306
    test "cross_check passes with empty killed_ids (vacuous cross-check — though judge would have failed)" do
      # If killed_ids is empty, the cross-check vacuously holds (∅ ⊆ anything).
      # In practice judge/1 would have returned {:fail, :no_test_failed} before
      # cross_check is invoked, so this is an edge-case boundary test.
      real_report = passing_report(["some_other_test"])

      result = Mutation.cross_check([], real_report)

      # ∅ ⊆ anything = true → cross_check should pass.
      assert result == :pass,
             "cross_check/2 with empty killed_ids should return :pass (vacuous ⊆); " <>
               "got #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-4 / D-306 — Vacuous suite detection: judge/1 rejects all-pass reverted run
  #
  # This is the non-vacuity gate. A gating test that passes even when production
  # is removed is worthless — it does not depend on the production code.
  # SPEC-FACTORY-GATE §3 [C203-B3] step 5: judge/1 yields {:fail, :no_test_failed}
  # for a vacuous suite; the half FAILs.
  # ---------------------------------------------------------------------------

  describe "AC-4 / D-306: vacuous suite → half FAIL (non-vacuity gate)" do
    @tag :ac_4
    @tag :d_306
    test "judge/1 on all-pass reverted report returns {:fail, :no_test_failed}" do
      # ALL tests pass on the reverted (production-absent) tree — the test suite
      # does not depend on production code. This is the vacuous test hole.
      vacuous_report = passing_report(["test_a", "test_b"])

      result = Mutation.judge(vacuous_report)

      assert {:fail, :no_test_failed} = result,
             "AC-4 / D-306: judge/1 must return {:fail, :no_test_failed} for a vacuous suite; " <>
               "got #{inspect(result)}"
    end

    @tag :ac_4
    @tag :d_306
    test "judge/1 on partially-failing reverted report returns {:pass, killed_ids}" do
      # Some tests FAIL on the reverted tree — those tests DO depend on production.
      # The mutation gate passes; killed_ids names the ids to cross-check.
      report = mixed_report(["test_passing_anyway"], ["test_gating_1", "test_gating_2"])

      result = Mutation.judge(report)

      assert {:pass, killed} = result,
             "AC-4 / D-306: judge/1 must return {:pass, killed_ids} when ≥1 test fails; " <>
               "got #{inspect(result)}"

      assert MapSet.subset?(
               MapSet.new(killed),
               MapSet.new(["test_gating_1", "test_gating_2"])
             ),
             "killed_ids must be a subset of the :failed case ids; " <>
               "killed=#{inspect(killed)}"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-4 / D-306 — Full mutation half sequence (pure logic, no I/O)
  #
  # The ordered sequence from SPEC-FACTORY-GATE §3 [C203-B3]:
  # Step 5: judge(reverted_report) → {:pass, killed_ids}
  # Step 7: cross_check(killed_ids, real_report) → :pass
  # Step 8: half PASS iff 5 ∧ 7
  #
  # We test the combined logic: given two engine-produced reports, compute
  # whether the mutation half passes.
  # ---------------------------------------------------------------------------

  describe "AC-4 / D-306: full mutation half — judge + cross_check combined" do
    @tag :ac_4
    @tag :d_306
    test "half PASSES: reverted has failures, real has those ids passing" do
      reverted_report = mixed_report(["test_irrelevant"], ["test_gating_1"])
      real_report = mixed_report(["test_gating_1", "test_irrelevant"], [])

      {:pass, killed} = Mutation.judge(reverted_report)
      cross = Mutation.cross_check(killed, real_report)

      assert cross == :pass,
             "AC-4 / D-306: cross_check must pass when killed_ids all appear :passed in real report; " <>
               "killed=#{inspect(killed)}"
    end

    @tag :ac_4
    @tag :d_306
    test "half FAILS (vacuous): reverted all-pass → judge fails, cross_check never reached" do
      vacuous_reverted = passing_report(["test_gating_1"])

      result = Mutation.judge(vacuous_reverted)

      assert {:fail, :no_test_failed} = result,
             "AC-4 / D-306: vacuous reverted suite must fail judge/1; got #{inspect(result)}"
    end

    @tag :ac_4
    @tag :d_306
    test "half FAILS (cross-check): reverted has failures, but real does NOT have them passing" do
      reverted_report = failing_report(["test_gating_1", "test_gating_2"])
      real_report = passing_report(["test_gating_1"])

      # Only gating_1 passes in real — gating_2 is missing. Cross-check fails.
      {:pass, killed} = Mutation.judge(reverted_report)
      cross = Mutation.cross_check(killed, real_report)

      assert match?({:fail, _}, cross),
             "AC-4 / D-306: cross_check must fail when not all killed_ids pass in real; " <>
               "killed=#{inspect(killed)}, cross=#{inspect(cross)}"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-4 / D-306 — Properties (referential transparency of pure functions)
  # ---------------------------------------------------------------------------

  @tag :property
  @tag :ac_4
  @tag :d_306
  property "AC-4 (property): cross_check/2 is pure (same inputs → same output)" do
    check all(
            killed_ids <- unique_ids_gen(0, 5),
            passing_ids <- unique_ids_gen(0, 8)
          ) do
      real_report = passing_report(passing_ids)

      result1 = Mutation.cross_check(killed_ids, real_report)
      result2 = Mutation.cross_check(killed_ids, real_report)

      assert result1 == result2,
             "cross_check/2 must be pure (same inputs → same output); " <>
               "got #{inspect(result1)} then #{inspect(result2)}"
    end
  end

  @tag :property
  @tag :ac_4
  @tag :d_306
  property "AC-4 (property): cross_check passes iff killed_ids ⊆ passing_ids(real_report)" do
    check all(
            killed_ids <- unique_ids_gen(0, 4),
            extra_passing <- unique_ids_gen(0, 4)
          ) do
      # Build a real_report that has ALL killed_ids as :passed.
      all_passing = (killed_ids ++ extra_passing) |> Enum.uniq()
      real_report = passing_report(all_passing)

      result = Mutation.cross_check(killed_ids, real_report)

      assert result == :pass,
             "AC-4 (property): cross_check must pass when killed_ids ⊆ passing_ids; " <>
               "killed=#{inspect(killed_ids)}, passing=#{inspect(all_passing)}, got #{inspect(result)}"
    end
  end

  @tag :property
  @tag :ac_4
  @tag :d_306
  property "AC-4 (property): cross_check fails when a killed_id is absent from real_report" do
    check all(
            present_ids <- unique_ids_gen(1, 4),
            absent_id <- test_id_gen(),
            not Enum.member?(present_ids, absent_id)
          ) do
      killed_ids = [absent_id | present_ids]
      # Real report only has present_ids passing — absent_id is missing.
      real_report = passing_report(present_ids)

      result = Mutation.cross_check(killed_ids, real_report)

      assert match?({:fail, _}, result),
             "AC-4 (property): cross_check must fail when killed_id #{inspect(absent_id)} " <>
               "is absent from real_report passing ids; got #{inspect(result)}"
    end
  end
end
