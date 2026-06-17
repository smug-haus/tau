defmodule Tau.Factory.SpecMembershipPropertyTest do
  @moduledoc """
  Gating tests for D-322 (INV-23 — spec-before-code mechanized) — PR-GATE-3.

  AC-7 (SPEC-FACTORY-GATE §7):

    `mix test --only property` passes including `spec_membership_property_test.exs`
    (P-SP1/P-SP2) — a diff touching a SPEC source-map boundary with no
    `SPEC-*`/`D-NNN` token in the PR body fails naming that boundary. Signal:
    the property asserts fail-with-named-boundary.

  D-322 (SPEC-FACTORY-GATE §4):

    `Gate.SpecMembership.check/3` FAILs a diff that touches any source-map
    boundary path without a `SPEC-*`/`D-NNN` token in the PR body, naming
    that boundary. A diff touching only non-SPEC'd paths ⇒ PASS regardless
    of body.

  ## Properties

  - **P-SP1** (SPEC'd-boundary-without-reference ⇒ FAIL): a diff touching a
    source-map boundary with no `SPEC-*`/`D-NNN` token in the PR body causes
    `Gate.run/1` to return `:fail` for the `:spec_membership` half, naming
    that boundary.

  - **P-SP2** (non-SPEC'd-only ⇒ PASS): when every path touched by the diff
    is absent from all source-map boundaries, `Gate.run/1` returns `:pass`
    for the `:spec_membership` half regardless of body content.

  ## Fail-before contract (why these tests fail at the merge-base)

  At the merge-base (`@gate_floor = [:mutation, :critic, :reviewer]`):

  - `run_half(:spec_membership, ...)` does not exist — the catch-all fires and
    returns `{:error, {:unknown_half, :spec_membership}}`.
  - `verdict.halves[:spec_membership]` is therefore `{:error, _}`, not `:pass`
    or `:fail`.
  - `assert verdict.halves[:spec_membership] == :fail` FAILS.
  - `assert verdict.halves[:spec_membership] == :pass` FAILS.

  The tests exercise `Gate.run/1` (the real user-facing path for D-322) using the
  `spec_membership_diff` / `spec_membership_pr_body` / `spec_membership_source_maps`
  hermetic seam keys — NOT the `spec_membership_override` bypass. This forces the
  gate to invoke the real `SpecMembership.check/3` logic end-to-end through the
  production path.

  AC linkage: AC-7, D-322 (the `@tag :ac_7` / `@tag :d_322` / `@tag :property`
  tokens satisfy Gate 5.1).
  """

  use ExUnit.Case, async: false

  @moduletag :ac_7
  @moduletag :d_322
  @moduletag :property
  @moduletag :capture_log

  alias Tau.Toolchain.LintDescriptor

  @gate Tau.Factory.Gate
  @request_mod Tau.Factory.Gate.Request
  @writer Tau.Factory.Ledger.Writer

  # A fixed SPEC-source-map boundary used across P-SP1/P-SP2 tests.
  @test_boundary "lib/spec_membership_test_boundary/module.ex"
  @test_spec_ref "SPEC-FACTORY-GATE"

  # A diff that touches @test_boundary — used to trigger the D-322 failure path.
  @boundary_touching_diff """
  --- a/lib/spec_membership_test_boundary/module.ex
  +++ b/lib/spec_membership_test_boundary/module.ex
  @@ -1,1 +1,2 @@
   existing line
  +new line
  """

  # A diff that does NOT touch @test_boundary — used for the P-SP2 pass path.
  @non_boundary_diff """
  --- a/lib/totally_unrelated/helper.ex
  +++ b/lib/totally_unrelated/helper.ex
  @@ -1,1 +1,2 @@
   existing line
  +new line
  """

  # Source maps provided via spec_membership_source_maps policy_pin key.
  @source_maps [{@test_boundary, @test_spec_ref}]

  # ---------------------------------------------------------------------------
  # Setup: isolated Ledger Writer + genuine git fixture per test
  # ---------------------------------------------------------------------------

  setup do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"test_sp1_sp2_ledger_#{System.unique_integer([:positive])}"

    writer_pid =
      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: writer_name
      )

    fixture_root = Briefly.create!(directory: true)
    repo = build_genuine_repo(fixture_root)

    %{writer: writer_pid, writer_name: writer_name, repo: repo}
  end

  # ---------------------------------------------------------------------------
  # P-SP1: SPEC'd-boundary-without-reference ⇒ :fail via Gate.run/1
  #
  # The diff (spec_membership_diff) touches @test_boundary. The PR body
  # (spec_membership_pr_body) is absent (defaults to ""), which contains no
  # SPEC-* / D-NNN token. SpecMembership.check/3 MUST return {:fail, [boundary]},
  # and Gate.run/1 MUST map this to verdict.halves[:spec_membership] == :fail.
  #
  # Fail-before: at the merge-base, run_half(:spec_membership, ...) hits the
  # unknown_half catch-all → {:error, {:unknown_half, :spec_membership}}.
  # The assertion `== :fail` FAILS.
  # ---------------------------------------------------------------------------

  @tag :ac_7
  @tag :d_322
  test "P-SP1 (D-322): Gate.run/1 returns :fail for :spec_membership when diff touches a SPEC'd boundary with no SPEC ref in PR body",
       %{writer: writer, repo: repo} do
    req =
      build_request(repo, writer, %{
        gate_manifest: [:mutation, :critic, :reviewer, :lint, :spec_membership],
        gate_concurrency: 4,
        gate_timeout: 120_000,
        oracle: %{critic: :pass, reviewer: :pass},
        lint_override: %LintDescriptor{steps: []},
        spec_membership_diff: @boundary_touching_diff,
        spec_membership_source_maps: @source_maps
        # spec_membership_pr_body intentionally absent — defaults to "" (no SPEC ref)
      })

    verdict = @gate.run(req)

    sm_result = Map.get(verdict.halves, :spec_membership, :absent)

    assert sm_result == :fail,
           "P-SP1 (D-322): Gate.run/1 MUST dispatch :spec_membership via the real " <>
             "SpecMembership.check/3 logic (not the override seam) and return :fail " <>
             "when the diff touches boundary #{inspect(@test_boundary)} and the PR body " <>
             "contains no SPEC-*/D-NNN token. " <>
             "At the merge-base, run_half(:spec_membership, ...) hits the catch-all and " <>
             "returns {:error, {:unknown_half, :spec_membership}}, not :fail. " <>
             "Got verdict.halves[:spec_membership] = #{inspect(sm_result)}\n" <>
             "Full verdict: #{inspect(verdict)}"

    assert verdict.status == :fail,
           "P-SP1 (D-322): verdict.status MUST be :fail when the :spec_membership half " <>
             "fails. Got: #{inspect(verdict.status)}"
  end

  # ---------------------------------------------------------------------------
  # P-SP1 corollary: SPEC'd-boundary WITH reference ⇒ :pass via Gate.run/1
  #
  # Same diff touches @test_boundary. The PR body (spec_membership_pr_body) DOES
  # contain a SPEC-* token. SpecMembership.check/3 MUST return {:pass, []}, and
  # Gate.run/1 MUST map this to verdict.halves[:spec_membership] == :pass.
  #
  # Fail-before: at the merge-base, the unknown_half catch-all fires →
  # {:error, {:unknown_half, :spec_membership}}, not :pass. FAILS.
  # ---------------------------------------------------------------------------

  @tag :ac_7
  @tag :d_322
  test "P-SP1 corollary (D-322): Gate.run/1 returns :pass for :spec_membership when diff touches a SPEC'd boundary AND PR body has a SPEC ref",
       %{writer: writer, repo: repo} do
    req =
      build_request(repo, writer, %{
        gate_manifest: [:mutation, :critic, :reviewer, :lint, :spec_membership],
        gate_concurrency: 4,
        gate_timeout: 120_000,
        oracle: %{critic: :pass, reviewer: :pass},
        lint_override: %LintDescriptor{steps: []},
        spec_membership_diff: @boundary_touching_diff,
        spec_membership_pr_body: "This PR advances SPEC-FACTORY-GATE D-322.",
        spec_membership_source_maps: @source_maps
      })

    verdict = @gate.run(req)

    sm_result = Map.get(verdict.halves, :spec_membership, :absent)

    assert sm_result == :pass,
           "P-SP1 corollary (D-322): Gate.run/1 MUST return :pass for :spec_membership " <>
             "when the PR body contains a SPEC-* token covering the touched boundary. " <>
             "At the merge-base, the unknown_half catch-all fires and returns " <>
             "{:error, {:unknown_half, :spec_membership}}, not :pass. " <>
             "Got verdict.halves[:spec_membership] = #{inspect(sm_result)}\n" <>
             "Full verdict: #{inspect(verdict)}"
  end

  # ---------------------------------------------------------------------------
  # P-SP2: non-SPEC'd-only diff ⇒ :pass via Gate.run/1
  #
  # The diff (spec_membership_diff) touches a path NOT in @source_maps.
  # Regardless of the PR body, SpecMembership.check/3 MUST return {:pass, []},
  # and Gate.run/1 MUST map this to verdict.halves[:spec_membership] == :pass.
  #
  # Fail-before: at the merge-base, the unknown_half catch-all fires →
  # {:error, {:unknown_half, :spec_membership}}, not :pass. FAILS.
  # ---------------------------------------------------------------------------

  @tag :ac_7
  @tag :d_322
  test "P-SP2 (D-322): Gate.run/1 returns :pass for :spec_membership when diff touches only non-SPEC'd paths",
       %{writer: writer, repo: repo} do
    req =
      build_request(repo, writer, %{
        gate_manifest: [:mutation, :critic, :reviewer, :lint, :spec_membership],
        gate_concurrency: 4,
        gate_timeout: 120_000,
        oracle: %{critic: :pass, reviewer: :pass},
        lint_override: %LintDescriptor{steps: []},
        spec_membership_diff: @non_boundary_diff,
        spec_membership_pr_body: "",
        spec_membership_source_maps: @source_maps
      })

    verdict = @gate.run(req)

    sm_result = Map.get(verdict.halves, :spec_membership, :absent)

    assert sm_result == :pass,
           "P-SP2 (D-322): Gate.run/1 MUST return :pass for :spec_membership when the " <>
             "diff touches only non-SPEC'd paths. The diff path 'lib/totally_unrelated/helper.ex' " <>
             "is NOT in @source_maps, so SpecMembership.check/3 returns {:pass, []} regardless " <>
             "of the PR body. " <>
             "At the merge-base, the unknown_half catch-all fires and returns " <>
             "{:error, {:unknown_half, :spec_membership}}, not :pass. " <>
             "Got verdict.halves[:spec_membership] = #{inspect(sm_result)}\n" <>
             "Full verdict: #{inspect(verdict)}"
  end

  # ---------------------------------------------------------------------------
  # P-SP1 D-NNN variant: PR body with D-NNN reference covers the boundary
  #
  # Same diff touches @test_boundary. The PR body contains a D-NNN token (D-322)
  # but no SPEC-* token. SpecMembership.check/3 MUST return {:pass, []} (D-NNN
  # coverage satisfies the contract), and Gate.run/1 MUST return :pass.
  #
  # Fail-before: at the merge-base, the unknown_half catch-all fires, not :pass.
  # ---------------------------------------------------------------------------

  @tag :ac_7
  @tag :d_322
  test "P-SP1 D-NNN variant (D-322): Gate.run/1 returns :pass for :spec_membership when PR body has a D-NNN token",
       %{writer: writer, repo: repo} do
    req =
      build_request(repo, writer, %{
        gate_manifest: [:mutation, :critic, :reviewer, :lint, :spec_membership],
        gate_concurrency: 4,
        gate_timeout: 120_000,
        oracle: %{critic: :pass, reviewer: :pass},
        lint_override: %LintDescriptor{steps: []},
        spec_membership_diff: @boundary_touching_diff,
        spec_membership_pr_body: "Closes D-322 invariant enforcement.",
        spec_membership_source_maps: @source_maps
      })

    verdict = @gate.run(req)

    sm_result = Map.get(verdict.halves, :spec_membership, :absent)

    assert sm_result == :pass,
           "P-SP1 D-NNN variant (D-322): Gate.run/1 MUST return :pass for :spec_membership " <>
             "when the PR body contains a D-NNN token (e.g. 'D-322') even without a SPEC-* " <>
             "token, because D-NNN coverage alone satisfies the D-322 contract. " <>
             "At the merge-base, the unknown_half catch-all fires → not :pass. " <>
             "Got verdict.halves[:spec_membership] = #{inspect(sm_result)}\n" <>
             "Full verdict: #{inspect(verdict)}"
  end

  # ---------------------------------------------------------------------------
  # Fixture builder: genuine discriminating git worktree
  #
  # merge-base: minimal Mix project
  # HEAD: lib/widget.ex added + test that fails without it
  #
  # The mutation half sees a PASS (the gating test fails on the reverted tree),
  # so the spec_membership half drives the verdict in these tests.
  # ---------------------------------------------------------------------------

  defp build_genuine_repo(root) do
    dir = Path.join(root, "repo_sp1sp2_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    git = fn args -> {_out, 0} = System.cmd("git", args, cd: dir) end
    git.(["init", "-q"])
    git.(["config", "user.email", "t@t"])
    git.(["config", "user.name", "t"])

    File.write!(Path.join(dir, "mix.exs"), fixture_mix_exs())
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "base"])
    {merge_base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    merge_base = String.trim(merge_base)

    File.write!(Path.join(dir, "lib/widget.ex"), """
    defmodule Widget do
      def value, do: 42
    end
    """)

    gating_rel = "test/widget_test.exs"

    File.write!(Path.join(dir, gating_rel), """
    defmodule WidgetTest do
      use ExUnit.Case
      @tag :gating
      test "P-SP1/P-SP2 widget value is 42" do
        assert Widget.value() == 42
      end
    end
    """)

    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "impl"])
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)

    %{
      dir: dir,
      merge_base: merge_base,
      head: String.trim(head),
      gating_paths: MapSet.new([gating_rel])
    }
  end

  defp fixture_mix_exs do
    """
    defmodule FixtureSP1SP2.MixProject do
      use Mix.Project
      def project, do: [app: :fixture_sp1sp2, version: "0.1.0", elixir: "~> 1.14"]
    end
    """
  end

  defp build_request(repo, writer, policy_pin) do
    {diff, _} = System.cmd("git", ["diff", repo.merge_base, repo.head], cd: repo.dir)

    struct!(@request_mod, %{
      unit: "pr-sp1sp2-#{System.unique_integer([:positive])}",
      diff: diff,
      frozen_paths: repo.gating_paths,
      policy_pin: policy_pin,
      workspace: repo.dir,
      merge_base: repo.merge_base,
      hash: repo.head,
      run: "run-#{System.unique_integer([:positive])}",
      ledger: writer
    })
  end
end
