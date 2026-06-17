defmodule Mix.Gate.SpecMembershipPSP2Test do
  @moduledoc """
  Gating tests for D-322 (P-SP2) at the pure-function and CLI-shim boundaries.

  ## Why this file exists — repairing vacuous tests

  `test/tau/factory/spec_membership_property_test.exs` tested P-SP2
  (non-SPEC'd-only diff => :pass) through `Gate.run/1` under `Oracle.Stub`.
  Because `Oracle.Stub` returns `:pass` for any unmapped half by default, tests
  that assert `:pass` via Gate.run/1 are VACUOUS: they pass even when
  `Tau.Factory.Gate.SpecMembership` does not exist (the stub never invokes the
  real checker, it just returns :pass). This is the defect the REVIEWER
  identified (#568).

  This file repairs P-SP2 by testing at TWO boundaries that are NOT subject to
  oracle-stub vacuity:

  1. **`Tau.Factory.Gate.SpecMembership.check/3` directly** (the pure-function
     boundary). At the merge-base this module does not exist =>
     `UndefinedFunctionError` => genuine fail-before.

  2. **`Mix.Gate.SpecMembership.spec_membership_violations/3`** (the CLI shim
     boundary). This module does not exist at the merge-base or at the current
     branch state (only `lib/tau/factory/gate/spec_membership.ex` exists;
     `lib/mix/gate/spec_membership.ex` is absent — the lift target called out
     in issue #568's evidence: "No spec_membership lift target despite
     SPEC-FACTORY-GATE.md:543 naming it for lift.").

  ## Properties tested

  - **P-SP2** (non-SPEC'd-only => PASS regardless of body): a diff whose changed
    paths are absent from all source-map boundaries must yield `:pass` /
    `{:pass, []}` / `[]` (no violations) regardless of PR body content.

  - **P-SP1 corollary** (SPEC'd boundary WITH reference => PASS): a diff touching
    a source-map boundary, where the PR body references the SPEC, yields
    `{:pass, []}` — the reference clears the violation.

  - **P-SP1 D-NNN variant** (D-NNN token alone satisfies the check): a D-NNN
    token in the PR body (without a SPEC-* token) clears a SPEC'd boundary touch.

  ## Fail-before contract

  ALL tests in this file fail at the merge-base (`origin/main`):

  - Tests calling `Tau.Factory.Gate.SpecMembership.check/3`: module absent at
    merge-base => `UndefinedFunctionError`.
  - Tests calling `Mix.Gate.SpecMembership.spec_membership_violations/3`: module
    absent at merge-base AND at current branch state =>
    `UndefinedFunctionError`. `lib/mix/gate/spec_membership.ex` does not exist.

  AC linkage: AC-7, D-322 (the `@tag :ac_7` / `@tag :d_322` / `@tag :property`
  tokens satisfy Gate 5.1).
  """

  use ExUnit.Case, async: true

  @moduletag :ac_7
  @moduletag :d_322
  @moduletag :property

  alias Tau.Factory.Gate.SpecMembership

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A SPEC source-map boundary entry (path => spec_ref).
  @test_boundary "lib/tau/tui/app.ex"
  @test_spec_ref "SPEC-TUI-HEADLESS"

  # Source maps: only @test_boundary is a SPEC'd path.
  @source_maps [{@test_boundary, @test_spec_ref}]

  # A diff touching ONLY a non-SPEC'd path (not in @source_maps).
  @non_boundary_diff """
  --- a/lib/totally_unrelated/helper.ex
  +++ b/lib/totally_unrelated/helper.ex
  @@ -1,1 +1,2 @@
   existing line
  +new line
  """

  # A diff touching the SPEC'd boundary (@test_boundary).
  @boundary_touching_diff """
  --- a/lib/tau/tui/app.ex
  +++ b/lib/tau/tui/app.ex
  @@ -1,2 +1,3 @@
   defmodule Tau.TUI.App do
  +  # new line
     def init(_), do: {:ok, %{}}
  """

  # ---------------------------------------------------------------------------
  # P-SP2 via SpecMembership.check/3 (pure function)
  #
  # A diff touching only non-SPEC'd paths MUST yield {:pass, []} regardless
  # of PR body content.
  #
  # FAILS at merge-base: Tau.Factory.Gate.SpecMembership does not exist =>
  # UndefinedFunctionError.
  #
  # NOT vacuous: calling check/3 directly requires the module to exist. The
  # oracle stub path is not involved — there is no stub here.
  # ---------------------------------------------------------------------------

  @tag :ac_7
  @tag :d_322
  test "P-SP2 (D-322, pure): SpecMembership.check/3 returns {:pass, []} for non-SPEC'd diff with empty body" do
    # FAILS at merge-base: UndefinedFunctionError — Tau.Factory.Gate.SpecMembership absent.
    result = SpecMembership.check(@non_boundary_diff, "", @source_maps)

    assert result == {:pass, []},
           "P-SP2 (D-322): SpecMembership.check/3 MUST return {:pass, []} when the diff " <>
             "touches only non-SPEC'd paths (empty PR body). " <>
             "Diff touches 'lib/totally_unrelated/helper.ex' which is NOT in source_maps. " <>
             "Got: #{inspect(result)}"
  end

  @tag :ac_7
  @tag :d_322
  test "P-SP2 (D-322, pure): SpecMembership.check/3 returns {:pass, []} for non-SPEC'd diff regardless of PR body content" do
    # Variant 1: PR body contains a SPEC ref — must not cause a false :fail
    result_with_spec =
      SpecMembership.check(
        @non_boundary_diff,
        "This PR advances SPEC-TUI-HEADLESS D-066.",
        @source_maps
      )

    assert result_with_spec == {:pass, []},
           "P-SP2 (D-322): SpecMembership.check/3 MUST return {:pass, []} for non-SPEC'd " <>
             "diff even when PR body references a SPEC. The invariant is: " <>
             "non-SPEC'd-only => :pass REGARDLESS of body content. Got: #{inspect(result_with_spec)}"

    # Variant 2: PR body contains adversarial text that looks SPEC-like
    result_adversarial =
      SpecMembership.check(
        @non_boundary_diff,
        "see spec for background; this is not a spec reference",
        @source_maps
      )

    assert result_adversarial == {:pass, []},
           "P-SP2 (D-322): non-SPEC'd diff must yield {:pass, []} even with adversarial body. " <>
             "Got: #{inspect(result_adversarial)}"
  end

  @tag :ac_7
  @tag :d_322
  test "P-SP2 (D-322, pure): SpecMembership.check/3 returns {:pass, []} when source_maps is empty" do
    # When no source-map entries are registered, no boundary can be violated.
    result = SpecMembership.check(@boundary_touching_diff, "", [])

    assert result == {:pass, []},
           "P-SP2 (D-322): SpecMembership.check/3 MUST return {:pass, []} when source_maps " <>
             "is empty — no boundaries registered, no violations possible. " <>
             "Got: #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # P-SP1 corollary via SpecMembership.check/3 (pure function)
  #
  # A diff touching a SPEC'd boundary WITH a SPEC-* token in the PR body
  # MUST yield {:pass, []} — the reference clears the violation.
  #
  # FAILS at merge-base: UndefinedFunctionError.
  # ---------------------------------------------------------------------------

  @tag :ac_7
  @tag :d_322
  test "P-SP1 corollary (D-322, pure): SpecMembership.check/3 returns {:pass, []} when SPEC'd boundary is referenced in PR body" do
    result =
      SpecMembership.check(
        @boundary_touching_diff,
        "This PR advances SPEC-TUI-HEADLESS D-066.",
        @source_maps
      )

    assert result == {:pass, []},
           "P-SP1 corollary (D-322): SpecMembership.check/3 MUST return {:pass, []} when " <>
             "the diff touches boundary '#{@test_boundary}' AND the PR body contains " <>
             "a SPEC-* token for that boundary. " <>
             "Got: #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # P-SP1 D-NNN variant via SpecMembership.check/3 (pure function)
  #
  # A D-NNN token in the PR body (without a SPEC-* token) MUST clear a touched
  # SPEC'd boundary — D-NNN coverage alone satisfies the D-322 contract.
  #
  # FAILS at merge-base: UndefinedFunctionError.
  # ---------------------------------------------------------------------------

  @tag :ac_7
  @tag :d_322
  test "P-SP1 D-NNN variant (D-322, pure): SpecMembership.check/3 returns {:pass, []} when PR body has a D-NNN token" do
    result =
      SpecMembership.check(
        @boundary_touching_diff,
        "Closes D-322 invariant enforcement.",
        @source_maps
      )

    assert result == {:pass, []},
           "P-SP1 D-NNN variant (D-322): SpecMembership.check/3 MUST return {:pass, []} " <>
             "when the PR body contains a D-NNN token (e.g. 'D-322') without a SPEC-* token. " <>
             "D-NNN coverage alone satisfies the D-322 contract. Got: #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # P-SP2 CLI shim boundary: Mix.Gate.SpecMembership.spec_membership_violations/3
  #
  # The CLI shim `lib/mix/gate/spec_membership.ex` (analogous to
  # `lib/mix/gate/masking.ex`) is identified as missing in issue #568's evidence.
  # `Mix.Gate.SpecMembership.spec_membership_violations/3` MUST exist and return
  # `[]` (no violations) for a non-SPEC'd diff.
  #
  # FAILS at merge-base AND at current branch state:
  # `lib/mix/gate/spec_membership.ex` does not exist =>
  # `Mix.Gate.SpecMembership` is undefined => UndefinedFunctionError.
  # ---------------------------------------------------------------------------

  @tag :ac_7
  @tag :d_322
  test "P-SP2 CLI (D-322): Mix.Gate.SpecMembership.spec_membership_violations/3 returns [] for non-SPEC'd diff" do
    # FAILS: UndefinedFunctionError — Mix.Gate.SpecMembership does not exist.
    # lib/mix/gate/spec_membership.ex is absent (the lift target called out in
    # issue #568 evidence: "No spec_membership lift target despite
    # SPEC-FACTORY-GATE.md:543 naming it for lift.")
    violations =
      Mix.Gate.SpecMembership.spec_membership_violations(
        @non_boundary_diff,
        "",
        @source_maps
      )

    assert violations == [],
           "P-SP2 CLI (D-322): Mix.Gate.SpecMembership.spec_membership_violations/3 MUST " <>
             "return [] (no violations) when the diff touches only non-SPEC'd paths. " <>
             "The diff touches 'lib/totally_unrelated/helper.ex' which is NOT in source_maps. " <>
             "Got: #{inspect(violations)}"
  end

  @tag :ac_7
  @tag :d_322
  test "P-SP1 CLI (D-322): Mix.Gate.SpecMembership.spec_membership_violations/3 returns non-empty list for SPEC'd boundary without reference" do
    # FAILS: UndefinedFunctionError — Mix.Gate.SpecMembership does not exist.
    violations =
      Mix.Gate.SpecMembership.spec_membership_violations(
        @boundary_touching_diff,
        "",
        @source_maps
      )

    assert is_list(violations),
           "P-SP1 CLI (D-322): spec_membership_violations/3 must return a list. " <>
             "Got: #{inspect(violations)}"

    assert violations != [],
           "P-SP1 CLI (D-322): Mix.Gate.SpecMembership.spec_membership_violations/3 MUST " <>
             "return at least one violation when the diff touches SPEC'd boundary " <>
             "'#{@test_boundary}' and the PR body has no SPEC-*/D-NNN token. " <>
             "Got: []"

    assert Enum.any?(violations, fn v ->
             Map.get(v, :boundary) == @test_boundary or
               Map.get(v, :file) == @test_boundary or
               Map.get(v, :path) == @test_boundary
           end),
           "P-SP1 CLI (D-322): the violation(s) must name the violated boundary " <>
             "'#{@test_boundary}'. Got: #{inspect(violations)}"
  end

  @tag :ac_7
  @tag :d_322
  test "P-SP1 corollary CLI (D-322): Mix.Gate.SpecMembership.spec_membership_violations/3 returns [] when PR body references the SPEC" do
    # FAILS: UndefinedFunctionError — Mix.Gate.SpecMembership does not exist.
    violations =
      Mix.Gate.SpecMembership.spec_membership_violations(
        @boundary_touching_diff,
        "This PR advances SPEC-TUI-HEADLESS D-066.",
        @source_maps
      )

    assert violations == [],
           "P-SP1 corollary CLI (D-322): spec_membership_violations/3 MUST return [] " <>
             "when the PR body contains a SPEC-* token covering the touched boundary. " <>
             "Got: #{inspect(violations)}"
  end
end
