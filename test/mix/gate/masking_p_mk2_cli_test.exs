defmodule Mix.Gate.MaskingPMK2CLITest do
  @moduledoc """
  Gating test for P-MK2 (issue #566) at the CLI-shim boundary:

    "Masking path-violation detection: any diff hunk whose path is in
     gating_paths MUST yield a Finding, independent of commit authorship
     (path-based, not attribution-based; INV-6). Falsified if an implementer
     edit to a declared gating-test path does not produce a Finding."

  The audit finding (issue #566) identified TWO independent nullifications of
  P-MK2 in the CLI shim layer (`lib/mix/gate/masking.ex`):

    1. `masking_violations/1` always passes `MapSet.new()` (empty set) to
       `PureMasking.scan/2`, so `gating_path_modified?/3` can never return
       true. Path-violation detection is structurally nullified at the call site.

    2. Even if (1) were fixed, findings are then filtered to
       `reason == :assertion_deleted`, structurally discarding every
       `:gating_path_edited` finding.

  These defects live in the CLI shim (`Mix.Gate.Masking`) — NOT in the pure
  scanner (`Tau.Factory.Gate.Masking.scan/2`), which correctly implements P-MK2.
  The existing `masking_property_test.exs` tests pass because they call
  `Tau.Factory.Gate.Masking.scan/2` directly. This test targets the shim.

  ## What this test asserts

  `Mix.Gate.Masking.masking_violations/2` (arity 2) MUST exist and accept a
  gating-path set alongside the diff. When the diff contains an edit to a
  declared gating-test path, it MUST return a non-empty list containing at
  least one finding whose `:file` matches the edited path (path-based
  detection, independent of authorship).  `:gating_path_edited` findings must
  NOT be discarded by the shim.

  ## FAILS against current code

  All tests fail because `masking_violations/2` does not exist (current arity
  is /1 only — `UndefinedFunctionError`).

  Entry point: `Mix.Gate.Masking.masking_violations/2` (CLI shim).
  Invariant id: P-MK2 (issue #566).
  Pure-module contract (already enforced): `Tau.Factory.Gate.Masking.scan/2`.
  SPEC: SPEC-FACTORY-GATE §4 B2 / C207-B6.
  """

  use ExUnit.Case, async: true

  @moduletag :p_mk2

  alias Mix.Gate.Masking, as: CLIMasking

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A gating-test path that will be in the declared set.
  @gating_path "test/tau/factory/gate/masking_property_test.exs"

  # A diff that edits a declared gating-test path WITHOUT removing any assertion
  # (pure path-violation — only P-MK2 fires, not P-MK1).
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

  # A diff that edits a production file — NOT in the declared gating-path set.
  # No assertion removed either. Must be clean.
  @diff_prod_edit_only """
  diff --git a/lib/tau/factory/gate.ex b/lib/tau/factory/gate.ex
  index cccccc..dddddd 100644
  --- a/lib/tau/factory/gate.ex
  +++ b/lib/tau/factory/gate.ex
  @@ -1,3 +1,3 @@ defmodule Tau.Factory.Gate do
  -  def run(req), do: :old
  +  def run(req), do: :new
  """

  # ---------------------------------------------------------------------------
  # 1. masking_violations/2 MUST exist and flag an edit to a declared path.
  #
  # FAILS: UndefinedFunctionError — masking_violations/2 does not exist.
  # ---------------------------------------------------------------------------

  @tag :p_mk2
  test "P-MK2: masking_violations/2 flags an edit to a declared gating-test path (path-based, not attribution-based)" do
    gating_paths = MapSet.new([@gating_path])

    # Against current code: UndefinedFunctionError — masking_violations/2 does
    # not exist; only masking_violations/1 exists (always passes empty set).
    violations = CLIMasking.masking_violations(@diff_path_violation_only, gating_paths)

    assert is_list(violations),
           "P-MK2: masking_violations/2 must return a list; got #{inspect(violations)}"

    assert violations != [],
           "P-MK2: masking_violations/2 MUST return at least one finding when the diff " <>
             "contains an edit to the declared gating-test path '#{@gating_path}'. " <>
             "Got: [] — path-violation detection is nullified in the CLI shim. " <>
             "Issue #566 nullification 1: masking_violations/1 always passes MapSet.new() to " <>
             "PureMasking.scan/2, so gating_path_modified?/3 can never return true. " <>
             "Issue #566 nullification 2: findings are filtered to reason == :assertion_deleted, " <>
             "structurally discarding :gating_path_edited findings."

    assert Enum.any?(violations, fn v ->
             Map.get(v, :file) == @gating_path or Map.get(v, :path) == @gating_path
           end),
           "P-MK2: the returned finding(s) must reference the gating-test path " <>
             "'#{@gating_path}'. Got: #{inspect(violations)}"
  end

  # ---------------------------------------------------------------------------
  # 2. masking_violations/2 MUST NOT discard :gating_path_edited findings.
  #    The legacy `Enum.filter(&(... :assertion_deleted))` must not apply to
  #    path-violation findings.
  #
  # FAILS: UndefinedFunctionError — masking_violations/2 does not exist.
  # ---------------------------------------------------------------------------

  @tag :p_mk2
  test "P-MK2: masking_violations/2 does NOT discard :gating_path_edited findings (second nullification in issue #566)" do
    gating_paths = MapSet.new([@gating_path])

    # @diff_path_violation_only has NO removed assert lines — only a path edit.
    # After the fix, masking_violations/2 must return the path-violation finding.
    # Issue #566 nullification 2: current code filters to :assertion_deleted only,
    # which would discard :gating_path_edited even if the empty-set bug were fixed.
    violations = CLIMasking.masking_violations(@diff_path_violation_only, gating_paths)

    assert violations != [],
           "P-MK2: the :gating_path_edited finding for '#{@gating_path}' MUST NOT be " <>
             "discarded by a filter targeting only :assertion_deleted findings. " <>
             "Both finding types are mandatory review items for the critic (INV-6 / C207-B6). " <>
             "Issue #566 nullification 2: `|> Enum.filter(&(Map.get(&1, :reason) == :assertion_deleted))`."
  end

  # ---------------------------------------------------------------------------
  # 3. masking_violations/2 with an empty gating_paths set MUST return [] for a
  #    path-only edit (path-based check fires ONLY for declared paths).
  #
  # FAILS: UndefinedFunctionError — masking_violations/2 does not exist.
  # ---------------------------------------------------------------------------

  @tag :p_mk2
  test "P-MK2: masking_violations/2 returns [] when gating_paths is empty and no assertion is deleted" do
    violations = CLIMasking.masking_violations(@diff_path_violation_only, MapSet.new())

    assert violations == [],
           "P-MK2: with an empty gating_paths set, a path-only edit must not produce " <>
             "a finding — path-violation detection is declared-paths-only, not heuristic. " <>
             "Got: #{inspect(violations)}"
  end

  # ---------------------------------------------------------------------------
  # 4. masking_violations/2 for a production-file edit with the gating path
  #    declared MUST return [] (edit is not to a declared gating path).
  #
  # FAILS: UndefinedFunctionError — masking_violations/2 does not exist.
  # ---------------------------------------------------------------------------

  @tag :p_mk2
  test "P-MK2: masking_violations/2 returns [] when the diff edits a non-gating production file" do
    gating_paths = MapSet.new([@gating_path])

    # @diff_prod_edit_only touches a production file NOT in the gating-path set,
    # and removes no assertion. Must be clean.
    violations = CLIMasking.masking_violations(@diff_prod_edit_only, gating_paths)

    assert violations == [],
           "P-MK2: a diff editing a production file not in the declared gating-path " <>
             "set must not yield a path-violation finding. Got: #{inspect(violations)}"
  end
end
