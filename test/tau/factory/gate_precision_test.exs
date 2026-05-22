defmodule Tau.Factory.GatePrecisionTest do
  @moduledoc """
  Precision gating tests for PR #382 (issues #380 + #381).

  Tests AC-2, AC-4, and AC-5 — the gate-precision fixes for
  `Tau.Factory.Gate`. Written as failing fail-before tests (AC-2, AC-4)
  and a regression guard (AC-5) before the implementer lands the fix.

  AC-1, AC-3, AC-6 are meta-ACs (CI/inspection-verified) and are out of
  this file's scope.
  """
  use ExUnit.Case, async: true

  alias Tau.Factory.Gate

  # ---------------------------------------------------------------------------
  # AC-2 — mutation_check/2 returns :not_applicable for a project-creation PR
  #
  # When every declared gating-test path lives in a Mix project whose nearest-
  # ancestor mix.exs is absent at base_ref, the check cannot meaningfully
  # mutate the pre-implementer tree (the project didn't exist yet).
  # The fix makes mutation_check/2 detect this and return :not_applicable.
  #
  # Fail-before: the current implementation has no N/A detection — it attempts
  # to revert the sub-project files and the runner crashes or returns an error
  # (NOT :not_applicable). The assertion `== :not_applicable` fails.
  # ---------------------------------------------------------------------------

  describe "mutation_check/2 (AC-2)" do
    @describetag :ac_2
    @describetag tmp_dir: true

    setup %{tmp_dir: tmp_dir} do
      run = fn args -> {_, 0} = System.cmd("git", args, cd: tmp_dir) end

      run.(["init", "-q"])
      run.(["config", "user.email", "test@example.com"])
      run.(["config", "user.name", "Test"])

      # --- base commit: a root-level project only (NO sub/ directory) ---
      File.mkdir_p!(Path.join(tmp_dir, "lib"))

      File.write!(Path.join(tmp_dir, "mix.exs"), """
      defmodule Root.MixProject do
        use Mix.Project
        def project, do: [app: :root, version: "0.1.0"]
      end
      """)

      File.write!(Path.join(tmp_dir, "lib/root.ex"), """
      defmodule Root do
        def hello, do: :world
      end
      """)

      run.(["add", "-A"])
      run.(["commit", "-q", "-m", "base: root project only"])
      {base_ref, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp_dir)
      base_ref = String.trim(base_ref)

      # --- HEAD commit: adds an entirely new sub-project (sub/) ---
      File.mkdir_p!(Path.join(tmp_dir, "sub/lib"))
      File.mkdir_p!(Path.join(tmp_dir, "sub/test"))

      File.write!(Path.join(tmp_dir, "sub/mix.exs"), """
      defmodule Sub.MixProject do
        use Mix.Project
        def project, do: [app: :sub, version: "0.1.0"]
      end
      """)

      File.write!(Path.join(tmp_dir, "sub/lib/sub.ex"), """
      defmodule Sub do
        def run, do: :ok
      end
      """)

      File.write!(Path.join(tmp_dir, "sub/test/sub_gate_test.exs"), """
      defmodule SubGateTest do
        use ExUnit.Case
        @tag :ac_2
        test "AC-2: sub project runs ok" do
          assert Sub.run() == :ok
        end
      end
      """)

      run.(["add", "-A"])
      run.(["commit", "-q", "-m", "head: add sub project"])

      {:ok, tmp_dir: tmp_dir, base_ref: base_ref}
    end

    test "AC-2: returns :not_applicable when gating tests are in a PR-created Mix project",
         %{tmp_dir: tmp_dir, base_ref: base_ref} do
      # The gating test lives in sub/test/sub_gate_test.exs. The nearest-
      # ancestor mix.exs for that path is sub/mix.exs, which does NOT exist at
      # base_ref (the sub/ project is PR-created). The fix should detect this
      # and return :not_applicable without attempting to run the tests.
      #
      # Fail-before: current implementation returns {:error, {:runner_crashed, _}}
      # or similar — NOT :not_applicable.
      original_dir = File.cwd!()

      try do
        File.cd!(tmp_dir)
        result = Gate.mutation_check(["sub/test/sub_gate_test.exs"], base_ref)
        assert result == :not_applicable
      after
        File.cd!(original_dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AC-4 — ac_linkage/2 ignores tokens cited only as background prose
  #
  # The current whole-body scan extracts AC/D tokens from ALL sections —
  # including Background sections where tokens are mentioned as context, not
  # claimed as acceptance criteria to be tested. The fix should restrict
  # extraction to the "Acceptance criteria" section only (or an equivalent
  # claimed-tokens section), ignoring prose references.
  #
  # Fail-before: the current implementation finds D-090 in the Background
  # section, treats it as a claimed token, finds no coverage, and returns
  # {:error, ["D-090"]} instead of :ok.
  # ---------------------------------------------------------------------------

  describe "ac_linkage/2 (AC-4)" do
    @describetag :ac_4

    @pr_body_with_background_prose """
    ## Background

    This PR is related to the permission system (D-090 describes the
    permission FSM invariants). It does not claim D-090 as a gating
    acceptance criterion — D-090 is cited for context only.

    ## Acceptance criteria

    - **AC-1** the fix is implemented and tested.

    ## Test plan

    See gating test.
    """

    test "AC-4: ignores AC/D-NNN tokens cited only in background prose (not in AC section)" do
      # We provide a gating source that covers AC-1 (the only claimed token),
      # but nothing for D-090 (which appears only in the Background section).
      # The fix should return :ok because D-090 is not a claimed AC.
      #
      # Fail-before: current whole-body scan sees D-090, marks it missing,
      # returns {:error, ["D-090"]}.
      covering_source = """
      defmodule FixGateTest do
        @tag :ac_1
        test "AC-1: fix implemented" do
          assert true
        end
      end
      """

      result = Gate.ac_linkage(@pr_body_with_background_prose, [covering_source])
      assert result == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # AC-5 — regression guard: ac_linkage/2 STILL flags a genuinely claimed token
  #
  # This test verifies that the AC-4 fix (section-scoped extraction) does NOT
  # accidentally suppress legitimate missing-token detection. A token that
  # appears in the Acceptance criteria section and has no gating coverage MUST
  # still be reported as missing.
  #
  # NOTE: This is a regression guard — the behavior is preserved by the fix,
  # so this test passes BOTH before and after the change. There is no
  # fail-before for AC-5. This is expected and correct.
  # ---------------------------------------------------------------------------

  describe "ac_linkage/2 (AC-5)" do
    @describetag :ac_5

    @pr_body_with_uncovered_ac """
    ## Acceptance criteria

    - **AC-9** a claimed acceptance criterion with no gating test.

    ## Test plan

    No test provided for AC-9 — this exercises the missing-token path.
    """

    test "AC-5: still flags a genuinely claimed AC-9 that has no gating test coverage" do
      # AC-9 is in the Acceptance criteria section with no covering source.
      # The gate MUST still return {:error, missing} with "AC-9" in missing.
      result = Gate.ac_linkage(@pr_body_with_uncovered_ac, [])
      assert {:error, missing} = result
      assert "AC-9" in missing
    end
  end
end
