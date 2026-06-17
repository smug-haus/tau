defmodule Tau.Factory.IncompleteFix.Test do
  @moduledoc """
  Gating tests for D-308 (INV-9) — the incomplete-fix mechanical test.

  ## What this gates (SPEC-FACTORY-GATE §4 D-308 / AC-8)

  A critic/reviewer finding that **falsifies a named `AC-N`/`D-NNN`** the PR
  claims (in its `## Acceptance criteria` section) MUST force **reopen-and-refine**
  — it MUST NOT be deflected to an admissible follow-up, regardless of finding
  severity.

  Enforcement home (SPEC-FACTORY-GATE §4 D-308, line 490-492):
  `Gate.Oracle adjudication + incomplete_fix_test.exs` — a verdict rule in
  `Tau.Factory.Gate.Oracle` that, given a finding and the PR's claimed AC tokens,
  determines whether the finding falsifies any named AC (=> :reopen) or is
  outside every named AC (=> :admissible_followup).

  ## The invariant (D-308 / INV-9)

  The test is mechanical:
  - For each named AC in the PR's `## Acceptance criteria` section, does the
    finding describe a state that falsifies it? If yes for any AC: :reopen.
  - Only if every named AC remains true after the finding: :admissible_followup.

  AC-falsification is the criterion, not severity — `info`/`suggestion` findings
  do NOT lower the bar (SPEC-FACTORY-GATE §4 line 487-488).

  ## Boundary under test

  `Tau.Factory.Gate.Oracle.incomplete_fix_check/2` — the designated verdict rule
  in `Gate.Oracle` adjudication. Called via the real `Gate.Oracle` module
  (never a hand-built struct). AC linkage: D-308, AC-8.

  These tests are authored BEFORE any production implementation of
  `incomplete_fix_check/2` exists (oracle-separation phase, D-304).
  They MUST FAIL (UndefinedFunctionError) until the implementer lands the
  production code. That fail-before is the correct state and MUST NOT be
  resolved by adding production code in this test file.
  """

  use ExUnit.Case, async: true

  @moduletag :d_308
  @moduletag :ac_8

  # Runtime module reference — the file compiles even before this function exists.
  @oracle Tau.Factory.Gate.Oracle

  # ---------------------------------------------------------------------------
  # Fixtures — minimal finding maps + claimed AC token lists
  # ---------------------------------------------------------------------------

  # A finding whose text explicitly falsifies "AC-5" (a named AC token in the
  # PR's ## Acceptance criteria section). The text is the string the critic or
  # reviewer returns as evidence that the named AC is broken.
  defp ac_falsifying_finding do
    %{
      severity: :critical,
      text:
        "The headless path drops the frontmatter, so AC-5 is broken: " <>
          "allowed-tools are always exposed regardless of the persona file."
    }
  end

  # A finding whose text does NOT mention or falsify any named AC.
  # It is a legitimate observation but outside the scope of the PR's ACs.
  defp admissible_followup_finding do
    %{
      severity: :suggestion,
      text:
        "The module could be refactored to use a more idiomatic pattern; " <>
          "this is a style observation with no bearing on any claimed AC."
    }
  end

  # A finding whose severity is :info — lowest possible. D-308 specifies
  # severity does NOT lower the AC-falsification bar.
  defp info_severity_ac_falsifying_finding do
    %{
      severity: :info,
      text:
        "Note: AC-3 invariant is not maintained — the retry counter is " <>
          "incremented on terminal eject, contradicting the stated D-NNN guarantee."
    }
  end

  # The named AC tokens from the PR's ## Acceptance criteria section.
  defp claimed_acs do
    ["AC-1", "AC-2", "AC-3", "AC-4", "AC-5", "D-308"]
  end

  # An empty claimed-AC list (a PR claiming no ACs — out-of-scope exemption).
  defp empty_claimed_acs, do: []

  # ---------------------------------------------------------------------------
  # AC-8 / D-308: a finding that falsifies a named AC MUST return :reopen
  # ---------------------------------------------------------------------------

  describe "D-308 / AC-8: a finding that falsifies a named AC forces :reopen (never a follow-up)" do
    @tag :d_308
    @tag :ac_8
    test "D-308: incomplete_fix_check/2 returns :reopen when a finding falsifies a named AC" do
      finding = ac_falsifying_finding()
      acs = claimed_acs()

      result = @oracle.incomplete_fix_check(finding, acs)

      assert result == :reopen,
             "D-308 / AC-8: a finding whose text falsifies a named AC-N/D-NNN token " <>
               "(here AC-5, present in claimed_acs) MUST return :reopen — it MUST NOT " <>
               "be treated as an admissible follow-up regardless of severity. " <>
               "Got: #{inspect(result)}"
    end

    @tag :d_308
    @tag :ac_8
    test "D-308: AC-falsification verdict is :reopen even when finding severity is :info" do
      # D-308 explicitly states: `info`/`suggestion` severity does NOT lower the bar.
      # An :info finding that falsifies a named AC MUST still force :reopen.
      finding = info_severity_ac_falsifying_finding()
      acs = claimed_acs()

      result = @oracle.incomplete_fix_check(finding, acs)

      assert result == :reopen,
             "D-308 / AC-8: severity :info does NOT lower the AC-falsification bar. " <>
               "A finding that falsifies AC-3 (named in claimed_acs) MUST return :reopen " <>
               "regardless of its :info severity. Got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-8 / D-308: a finding outside every named AC MUST return :admissible_followup
  # ---------------------------------------------------------------------------

  describe "D-308 / AC-8: a finding outside every named AC is an admissible follow-up" do
    @tag :d_308
    @tag :ac_8
    test "D-308: incomplete_fix_check/2 returns :admissible_followup when the finding does not falsify any named AC" do
      finding = admissible_followup_finding()
      acs = claimed_acs()

      result = @oracle.incomplete_fix_check(finding, acs)

      assert result == :admissible_followup,
             "D-308 / AC-8: a finding that does not falsify any named AC-N/D-NNN " <>
               "MUST return :admissible_followup (it is outside the scope of the PR's " <>
               "acceptance criteria). Got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-8 / D-308: empty claimed-AC list — no AC can be falsified
  # ---------------------------------------------------------------------------

  describe "D-308 / AC-8: when no ACs are claimed, every finding is an admissible follow-up" do
    @tag :d_308
    @tag :ac_8
    test "D-308: incomplete_fix_check/2 returns :admissible_followup when claimed_acs is empty" do
      # A PR that claims no AC-N/D-NNN tokens (e.g. a formatting-only PR).
      # No AC can be falsified -> every finding is an admissible follow-up.
      finding = ac_falsifying_finding()
      acs = empty_claimed_acs()

      result = @oracle.incomplete_fix_check(finding, acs)

      assert result == :admissible_followup,
             "D-308 / AC-8: when the PR claims no AC-N/D-NNN tokens (empty list), " <>
               "no finding can falsify a named AC — every finding is an admissible " <>
               "follow-up. Got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-8 / D-308: D-NNN tokens are covered, not only AC-N tokens
  # ---------------------------------------------------------------------------

  describe "D-308 / AC-8: the verdict covers D-NNN tokens as well as AC-N tokens" do
    @tag :d_308
    @tag :ac_8
    test "D-308: a finding that falsifies a named D-NNN token (not only AC-N) also returns :reopen" do
      # D-308 covers both AC-N AND D-NNN tokens: a finding that falsifies a named
      # D-NNN in the acceptance criteria section MUST also trigger :reopen.
      finding = %{
        severity: :critical,
        text:
          "D-308 is not enforced: the Unit FSM gating/3 clause treats every " <>
            "{:fail, findings} identically without inspecting findings for AC falsification."
      }

      acs = ["D-308", "AC-1", "AC-2"]

      result = @oracle.incomplete_fix_check(finding, acs)

      assert result == :reopen,
             "D-308 / AC-8: a finding that falsifies a named D-NNN token (D-308, present " <>
               "in claimed_acs) MUST return :reopen, not :admissible_followup. " <>
               "D-308 covers both AC-N and D-NNN tokens. Got: #{inspect(result)}"
    end
  end
end
