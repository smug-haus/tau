defmodule Tau.Factory.GateTest do
  @moduledoc """
  Gating tests for #370 — factory "oracle separation" PR-B: the three
  mechanical CI gates of `Tau.Factory.Gate`.

  Authored by the `test-author` agent BEFORE any production code exists.
  `Tau.Factory.Gate` does not yet exist; these tests are expected to fail
  (compile error / UndefinedFunctionError) until the implementer lands the
  module — that fail-before is the correct state.

  Each test references the AC it gates (AC-1 / AC-2 / AC-3).
  """
  use ExUnit.Case, async: true

  alias Tau.Factory.Gate

  # ---------------------------------------------------------------------------
  # AC-1 — Tau.Factory.Gate.ac_linkage/2
  #
  # "ac_linkage/2 returns {:error, [...]} for a PR body whose claimed AC-N has
  #  no matching gating-test name/tag, and :ok when every claimed AC is present."
  #
  # Contract: ac_linkage(pr_body, gating_test_sources) ::
  #             :ok | {:error, [missing :: String.t()]}
  # ---------------------------------------------------------------------------

  describe "ac_linkage/2 (AC-1)" do
    @describetag :ac_1

    @pr_body """
    ## Acceptance criteria

    - **AC-1** the linkage gate parses claimed ACs.
    - **AC-2** the masking gate scans diffs.
    - **D-200** the mutation check reverts non-gating paths.

    ## Test plan
    fixture-driven fail-before/pass-after cases.
    """

    test "AC-1: returns {:error, [missing]} when a claimed AC has no matching test name/tag" do
      # A gating-test source that covers AC-1 and D-200 but NOT AC-2.
      sources = [
        """
        defmodule SomeTest do
          @tag :ac_1
          test "AC-1: something" do
          end

          @tag :d_200
          test "D-200: mutation revert" do
          end
        end
        """
      ]

      assert {:error, missing} = Gate.ac_linkage(@pr_body, sources)
      assert "AC-2" in missing
      refute "AC-1" in missing
      refute "D-200" in missing
    end

    test "AC-1: returns :ok when every claimed AC/D-NNN appears in a gating-test source" do
      sources = [
        """
        defmodule FullCoverageTest do
          @tag :ac_1
          test "AC-1: linkage" do
          end

          @tag :ac_2
          test "AC-2: masking" do
          end

          @tag :d_200
          test "D-200: mutation" do
          end
        end
        """
      ]

      assert :ok = Gate.ac_linkage(@pr_body, sources)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-2 — Tau.Factory.Gate.masking_violations/1
  #
  # "masking_violations/1 returns the removed-assertion list for a diff that
  #  deletes an assert, and [] for a diff that deletes no assertion."
  #
  # Contract: masking_violations(unified_diff) :: [%{file, line, removed}]
  # ---------------------------------------------------------------------------

  describe "masking_violations/1 (AC-2)" do
    @describetag :ac_2

    @diff_with_removed_assert """
    diff --git a/test/tau/example_test.exs b/test/tau/example_test.exs
    index 1111111..2222222 100644
    --- a/test/tau/example_test.exs
    +++ b/test/tau/example_test.exs
    @@ -3,7 +3,6 @@ defmodule Tau.ExampleTest do
       test "it works" do
         result = Tau.Example.run()
    -    assert result == :ok
         refute result == :error
       end
     end
    """

    @diff_without_removed_assert """
    diff --git a/test/tau/example_test.exs b/test/tau/example_test.exs
    index 1111111..2222222 100644
    --- a/test/tau/example_test.exs
    +++ b/test/tau/example_test.exs
    @@ -3,6 +3,7 @@ defmodule Tau.ExampleTest do
       test "it works" do
         result = Tau.Example.run()
         assert result == :ok
    +    refute result == :error
       end
     end
    """

    test "AC-2: returns the removed-assertion list for a diff that deletes an assert" do
      violations = Gate.masking_violations(@diff_with_removed_assert)

      assert is_list(violations)
      assert length(violations) == 1
      [violation] = violations

      assert %{file: file, line: line, removed: removed} = violation
      assert file == "test/tau/example_test.exs"
      assert is_integer(line)
      assert removed =~ "assert result == :ok"
    end

    test "AC-2: returns [] for a diff that deletes no assertion" do
      assert [] = Gate.masking_violations(@diff_without_removed_assert)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-3 — Tau.Factory.Gate.mutation_check/2
  #
  # "mutation_check/2 returns {:error, :all_passed} for a synthetic case where
  #  the gating tests pass against the reverted (pre-implementer) tree, and :ok
  #  when ≥1 gating test fails against it."
  #
  # Contract: mutation_check(gating_test_paths, base_ref) ::
  #             :ok | {:error, :all_passed}
  #
  # The check keeps the declared gating-test paths at HEAD, reverts every other
  # path to base_ref, runs the gating tests, and reports :ok iff ≥1 gating test
  # fails against the reverted tree.
  #
  # Fixture: a real synthetic git repo under the per-test :tmp_dir, with a base
  # commit (production module absent / wrong) and a HEAD commit (production
  # module correct + gating test added). Self-contained and deterministic.
  # ---------------------------------------------------------------------------

  describe "mutation_check/2 (AC-3)" do
    @describetag :ac_3
    @describetag tmp_dir: true

    setup %{tmp_dir: tmp_dir} do
      # Build a synthetic two-state git repo:
      #   base commit: prod module returns :wrong  (gating test would FAIL here)
      #   HEAD commit: prod module returns :ok      (gating test PASSES here)
      #                + the gating test itself is added at HEAD.
      run = fn args -> {_, 0} = System.cmd("git", args, cd: tmp_dir) end

      run.(["init", "-q"])
      run.(["config", "user.email", "test@example.com"])
      run.(["config", "user.name", "Test"])

      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.mkdir_p!(Path.join(tmp_dir, "test"))

      prod = Path.join(tmp_dir, "lib/widget.ex")
      gating = Path.join(tmp_dir, "test/widget_gate_test.exs")

      # --- base commit: production code is "wrong", no gating test yet ---
      File.write!(prod, "defmodule Widget do\n  def run, do: :wrong\nend\n")
      run.(["add", "-A"])
      run.(["commit", "-q", "-m", "base"])
      {base_ref, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp_dir)
      base_ref = String.trim(base_ref)

      # --- HEAD commit: production code fixed + gating test added ---
      File.write!(prod, "defmodule Widget do\n  def run, do: :ok\nend\n")

      %{tmp_dir: tmp_dir, base_ref: base_ref, prod: prod, gating: gating, run: run}
    end

    test "AC-3: returns :ok when ≥1 gating test fails against the reverted tree",
         %{tmp_dir: tmp_dir, base_ref: base_ref, gating: gating, run: run} do
      # The gating test asserts run() == :ok. Against the reverted base tree
      # (run() == :wrong) it FAILS — so the gate must return :ok.
      File.write!(gating, """
      defmodule WidgetGateTest do
        use ExUnit.Case
        test "AC: widget runs ok" do
          assert Widget.run() == :ok
        end
      end
      """)

      run.(["add", "-A"])
      run.(["commit", "-q", "-m", "head"])

      assert :ok =
               Gate.mutation_check(["test/widget_gate_test.exs"], base_ref)
    after
      _ = tmp_dir
    end

    test "AC-3: returns {:error, :all_passed} when the gating tests pass against the reverted tree",
         %{tmp_dir: tmp_dir, base_ref: base_ref, gating: gating, run: run} do
      # This gating test does NOT bind to the implementer's change — it asserts
      # something true in BOTH trees. Against the reverted base tree it still
      # PASSES — a vacuous gating suite — so the gate must return
      # {:error, :all_passed}.
      File.write!(gating, """
      defmodule WidgetGateTest do
        use ExUnit.Case
        test "AC: widget module is defined" do
          assert function_exported?(Widget, :run, 0)
        end
      end
      """)

      run.(["add", "-A"])
      run.(["commit", "-q", "-m", "head"])

      assert {:error, :all_passed} =
               Gate.mutation_check(["test/widget_gate_test.exs"], base_ref)
    after
      _ = tmp_dir
    end
  end
end
