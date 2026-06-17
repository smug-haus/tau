defmodule Mix.Gate.MaskingD305CLITaskTest do
  @moduledoc """
  Gating test for D-305 (issue #571) — INV-6 gating-test immutability at the
  Mix CLI task boundary.

  D-305 states:
    "INV-6 gating-test immutability: implementers MUST NOT modify declared
     gating-test paths; Gate.Masking performs a path-scan of the diff against
     the frozen paths_g set. Falsified by: an implementer diff touching a path
     in paths_g without being flagged."

  The factory-loop rule (SPEC-FACTORY-GATE AC-11, factory-loop.md §"three
  mechanical gates") specifies that Gate 5.2 is "Verified by CI via
  `mix tau.gate.masking` in the `lint` job." For the path-violation limb of
  D-305 (P-MK2) to fire in CI, the Mix CLI task MUST accept declared gating-
  test paths as arguments alongside the diff and pass them to the scanner.

  The current `Mix.Tasks.Tau.Gate.Masking.run/1` accepts only `[diff_source]`
  (one-element argv) and calls `Masking.masking_violations(diff)` (arity 1,
  empty gating_paths). A diff that edits a declared gating-test path fires NO
  path-violation finding because gating_paths is always empty — the path-
  violation limb of D-305 (P-MK2) is structurally unreachable from the CI
  entrypoint.

  Tests:
    1. masking_violations/1 baseline: returns [] for a pure path-violation diff
       (no declared paths — path-violation detection requires the declared set).
    2. masking_violations/2: returns path-violation finding when path is declared
       (the call the task MUST make for D-305 to work in CI).
    3. mix tau.gate.masking CLI: invoked via System.cmd with [DIFF_FILE,
       GATING_PATHS_FILE] MUST exit 0 (not 2=usage error) and output a violation
       report. FAILS: current task only accepts [diff_source]; two args → halt(2).

  Entry point: Mix.Tasks.Tau.Gate.Masking.run/1 (CLI gate for Gate 5.2 in CI).
  Invariant id: D-305.
  SPEC: SPEC-FACTORY-GATE §4 B6 / AC-11 / C207-B6.
  Issue: #571.
  """

  use ExUnit.Case, async: true

  @moduletag :d_305
  @moduletag :capture_log

  alias Mix.Gate.Masking, as: CLIMasking

  @gating_path "test/tau/factory/gate/masking_property_test.exs"

  # A diff that edits a declared gating-test path WITHOUT removing any assertion.
  @diff_path_violation_only """
  diff --git a/test/tau/factory/gate/masking_property_test.exs b/test/tau/factory/gate/masking_property_test.exs
  index aaaaaa..bbbbbb 100644
  --- a/test/tau/factory/gate/masking_property_test.exs
  +++ b/test/tau/factory/gate/masking_property_test.exs
  @@ -1,4 +1,4 @@ defmodule Tau.Factory.Gate.MaskingPropertyTest do
  -  # original comment
  +  # implementer-edited comment (path-based edit, no assertion removed)
     use ExUnit.Case
  """

  # ---------------------------------------------------------------------------
  # D-305 test 1: arity-1 baseline — no path-violation without declared paths.
  # ---------------------------------------------------------------------------

  @tag :d_305
  test "D-305: masking_violations/1 returns [] for a diff that only edits a gating-test path (no declared paths — baseline)" do
    violations = CLIMasking.masking_violations(@diff_path_violation_only)

    assert violations == [],
           "D-305 baseline: masking_violations/1 (empty gating_paths) on a diff with " <>
             "no assertion deletions MUST return []. Got: #{inspect(violations)}. Issue #571."
  end

  # ---------------------------------------------------------------------------
  # D-305 test 2: masking_violations/2 with declared path MUST return a finding.
  # ---------------------------------------------------------------------------

  @tag :d_305
  test "D-305: masking_violations/2 returns a path-violation finding for a diff editing the declared gating-test path" do
    gating_paths = MapSet.new([@gating_path])
    violations = CLIMasking.masking_violations(@diff_path_violation_only, gating_paths)

    assert violations != [],
           "D-305: masking_violations/2 MUST return at least one finding when the diff " <>
             "edits the declared gating-test path '#{@gating_path}'. " <>
             "Got: []. Issue #571 / D-305."

    path_violation =
      Enum.find(violations, fn v ->
        Map.get(v, :file) == @gating_path or Map.get(v, :path) == @gating_path
      end)

    assert path_violation != nil,
           "D-305: the finding must reference '#{@gating_path}'. " <>
             "Got: #{inspect(violations)}. Issue #571 / D-305."
  end

  # ---------------------------------------------------------------------------
  # D-305 test 3 (FAILING): the CLI task `mix tau.gate.masking` MUST accept
  # [DIFF_FILE, GATING_PATHS_FILE] argv, exit 0, and output a violation report.
  #
  # FAILS against current code: the task only handles [diff_source]; a two-
  # element argv hits the catch-all error clause and calls System.halt(2).
  # We verify via System.cmd so halt(2) terminates the child OS process, not
  # the test runner.
  # ---------------------------------------------------------------------------

  @tag :d_305
  test "D-305: `mix tau.gate.masking DIFF_FILE GATING_PATHS_FILE` exits 0 and surfaces the path-violation finding" do
    unique = System.unique_integer([:positive])
    tmp = System.tmp_dir!()
    diff_file = Path.join(tmp, "d305_diff_#{unique}.txt")
    gating_paths_file = Path.join(tmp, "d305_gating_#{unique}.txt")

    File.write!(diff_file, @diff_path_violation_only)
    File.write!(gating_paths_file, @gating_path <> "\n")

    # Run the Mix CLI task in a child OS process.
    # Current task handles [diff_source] only — two args → error + System.halt(2).
    # The child process exits with code 2, confirming D-305 path-violation
    # detection is unreachable from CI.
    {output, exit_code} =
      System.cmd(
        "mix",
        ["tau.gate.masking", diff_file, gating_paths_file],
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    # FAILS: current task exits 2 (usage error) for two-element argv.
    assert exit_code == 0,
           "D-305: `mix tau.gate.masking DIFF_FILE GATING_PATHS_FILE` MUST exit 0. " <>
             "Got exit_code=#{exit_code}. " <>
             "Current task only handles [diff_source] (one arg); a two-element argv " <>
             "hits the error clause and calls System.halt(2). " <>
             "The path-violation limb of D-305 (P-MK2 / INV-6) is structurally " <>
             "unreachable from the CI entrypoint (mix tau.gate.masking). " <>
             "Output: #{output}. Issue #571 / D-305."

    # If exit_code == 0, also assert the output contains the path-violation report.
    assert String.contains?(output, @gating_path) or String.contains?(output, "VIOLATIONS"),
           "D-305: `mix tau.gate.masking DIFF_FILE GATING_PATHS_FILE` MUST surface " <>
             "the path-violation finding for '#{@gating_path}'. " <>
             "Got output: #{output}. Issue #571 / D-305."
  end
end
