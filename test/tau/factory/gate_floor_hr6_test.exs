defmodule Tau.Factory.GateFloorHR6Test do
  @moduledoc """
  Gating tests for HR-6 / D-322 / D-323 / D-354 — mechanical gate halves
  `:lint` and `:spec_membership` MUST be members of the engine-fixed gate floor
  AND MUST be dispatched as real mechanical gate halves by `Gate.run/1`.

  ## Defect history

  The original test file (commit a7b2806) only exercised `gate_floor/0` and
  `compose/1`. Those passed after the implementer added `:lint` and
  `:spec_membership` to the floor constant, but they never verified the halves
  actually EXECUTE through the real `Gate.run/1` entry point. Tests that only
  assert `gate_floor/0` contains `:spec_membership` do not gate the invariant
  that matters — that the half runs and produces a real result. This repair
  replaces those wrong-path assertions with tests through `Gate.run/1`.

  ## Invariants gated

  HR-6 (issue #542): All mechanizable halves of spec-discipline invariants
  (INV-23, INV-24) MUST move from critic prose into mechanical gate halves.

  - **D-322 / INV-23** — `Gate.SpecMembership` MUST be a mechanical gate half
    executed by `Gate.run/1`; the result in `verdict.halves[:spec_membership]`
    MUST be `:pass` (when override is `:pass`) or `:fail` (atom, not
    `{:error, {:unknown_half, _}}`).
  - **D-323 / INV-24** — the lint half MUST be executed by `Gate.run/1`; the
    result in `verdict.halves[:lint]` MUST be `:pass` when lint steps are empty.
  - **D-354** — the engine-fixed floor is non-shrinkable: a manifest omitting
    `:spec_membership` MUST cause `run/1` to return a `:fail` verdict AND
    `:spec_membership` MUST still appear in `verdict.halves`.

  ## Fail-before contract (why these tests fail at the merge-base)

  At the merge-base (`@gate_floor = [:mutation, :critic, :reviewer]`, no
  `run_half/4` clauses for `:lint` or `:spec_membership`):

  - Test 1: `run_half(:spec_membership, ...)` falls to the `unknown_half`
    catch-all → `{:error, {:unknown_half, :spec_membership}}` which is NOT
    `:pass`. `assert sm_result == :pass` FAILS.
  - Test 2: same catch-all → result is `{:error, _}` not the atom `:fail`.
    `assert sm_result == :fail` FAILS.
  - Test 3: `run_half(:lint, ...)` catch-all → `{:error, {:unknown_half, :lint}}`
    not `:pass`. `assert lint_result == :pass` FAILS.
  - Test 4: at merge-base `:spec_membership` is NOT in `@gate_floor`, so a
    manifest omitting it passes `compose/1` (no floor violation). `run/1` may
    return `:pass`, contradicting `assert verdict.status == :fail`.

  All assertions go through `Gate.run/1` — never a hand-built struct or a
  direct call to a private helper.

  AC linkage: HR-6, D-322, D-323, D-354 (the `@tag :hr_6` / `@tag :d_322` /
  `@tag :d_323` / `@tag :d_354` tokens satisfy Gate 5.1).
  """

  use ExUnit.Case, async: false

  @moduletag :hr_6
  @moduletag :d_322
  @moduletag :d_323
  @moduletag :d_354
  @moduletag :capture_log

  alias Tau.Toolchain.LintDescriptor

  @gate Tau.Factory.Gate
  @request_mod Tau.Factory.Gate.Request
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Setup: isolated Ledger Writer per test + tmp fixture root
  # ---------------------------------------------------------------------------

  setup do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"test_hr6_ledger_#{System.unique_integer([:positive])}"

    writer_pid =
      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: writer_name
      )

    fixture_root = Briefly.create!(directory: true)

    %{writer: writer_pid, writer_name: writer_name, db_path: db_path, fixture_root: fixture_root}
  end

  # ---------------------------------------------------------------------------
  # HR-6 / D-322 (test 1): Gate.run/1 dispatches :spec_membership and returns :pass
  #
  # The spec_membership_override: :pass seam causes run_spec_membership_half/1
  # to short-circuit to :pass. At the merge-base there is no run_half/4 clause
  # for :spec_membership, so the catch-all fires and returns
  # {:error, {:unknown_half, :spec_membership}} — NOT :pass — and the assertion
  # fails. After implementation run_half(:spec_membership, ...) dispatches to
  # run_spec_membership_half and honours the override.
  # ---------------------------------------------------------------------------

  describe "HR-6 / D-322: Gate.run/1 dispatches the :spec_membership half" do
    @tag :hr_6
    @tag :d_322
    test "HR-6/D-322: verdict.halves[:spec_membership] MUST be :pass when override is :pass",
         %{writer: writer, fixture_root: root} do
      repo = build_genuine_repo(root)

      req =
        build_request(repo, writer, %{
          gate_manifest: [:mutation, :critic, :reviewer, :lint, :spec_membership],
          gate_concurrency: 4,
          gate_timeout: 120_000,
          oracle: %{critic: :pass, reviewer: :pass},
          spec_membership_override: :pass,
          lint_override: %LintDescriptor{steps: []}
        })

      verdict = @gate.run(req)

      sm_result = Map.get(verdict.halves, :spec_membership, :absent)

      assert sm_result == :pass,
             "HR-6/D-322: Gate.run/1 MUST dispatch the :spec_membership gate half " <>
               "via run_half/4 and return :pass when spec_membership_override: :pass is " <>
               "set. At the merge-base, no run_half/4 clause exists for :spec_membership, " <>
               "so the catch-all fires and returns {:error, {:unknown_half, :spec_membership}}. " <>
               "Got verdict.halves[:spec_membership] = #{inspect(sm_result)}\n" <>
               "Full verdict: #{inspect(verdict)}"
    end
  end

  # ---------------------------------------------------------------------------
  # HR-6 / D-322 (test 2): Gate.run/1 returns :fail (atom) for :spec_membership
  #
  # When spec_membership_override: :fail is provided, run_spec_membership_half/1
  # MUST return the atom :fail. At the merge-base, the catch-all returns
  # {:error, {:unknown_half, :spec_membership}} — not the atom :fail — so the
  # strict equality assertion fails.
  # ---------------------------------------------------------------------------

  describe "HR-6 / D-322: Gate.run/1 returns :fail atom for a failing :spec_membership" do
    @tag :hr_6
    @tag :d_322
    test "HR-6/D-322: verdict.halves[:spec_membership] MUST be atom :fail when override is :fail",
         %{writer: writer, fixture_root: root} do
      repo = build_genuine_repo(root)

      req =
        build_request(repo, writer, %{
          gate_manifest: [:mutation, :critic, :reviewer, :lint, :spec_membership],
          gate_concurrency: 4,
          gate_timeout: 120_000,
          oracle: %{critic: :pass, reviewer: :pass},
          spec_membership_override: :fail,
          lint_override: %LintDescriptor{steps: []}
        })

      verdict = @gate.run(req)

      sm_result = Map.get(verdict.halves, :spec_membership, :absent)

      assert sm_result == :fail,
             "HR-6/D-322: Gate.run/1 MUST return the atom :fail (not {:error, _}) for " <>
               "the :spec_membership half when spec_membership_override: :fail is set. " <>
               "At the merge-base, the unknown_half catch-all returns " <>
               "{:error, {:unknown_half, :spec_membership}} which is not the atom :fail. " <>
               "Got verdict.halves[:spec_membership] = #{inspect(sm_result)}"

      assert verdict.status == :fail,
             "HR-6/D-322: verdict.status MUST be :fail when the :spec_membership half " <>
               "fails. Got: #{inspect(verdict.status)}"
    end
  end

  # ---------------------------------------------------------------------------
  # HR-6 / D-323 (test 3): Gate.run/1 dispatches :lint half and returns :pass
  #
  # lint_override: %LintDescriptor{steps: []} → run_lint_steps([], _) → :pass.
  # At the merge-base, no run_half/4 clause exists for :lint, so the catch-all
  # fires and returns {:error, {:unknown_half, :lint}} — NOT :pass.
  # ---------------------------------------------------------------------------

  describe "HR-6 / D-323: Gate.run/1 dispatches the :lint half" do
    @tag :hr_6
    @tag :d_323
    test "HR-6/D-323: verdict.halves[:lint] MUST be :pass when lint steps are empty",
         %{writer: writer, fixture_root: root} do
      repo = build_genuine_repo(root)

      req =
        build_request(repo, writer, %{
          gate_manifest: [:mutation, :critic, :reviewer, :lint, :spec_membership],
          gate_concurrency: 4,
          gate_timeout: 120_000,
          oracle: %{critic: :pass, reviewer: :pass},
          spec_membership_override: :pass,
          lint_override: %LintDescriptor{steps: []}
        })

      verdict = @gate.run(req)

      lint_result = Map.get(verdict.halves, :lint, :absent)

      assert lint_result == :pass,
             "HR-6/D-323: Gate.run/1 MUST dispatch the :lint gate half via run_half/4 " <>
               "and return :pass when lint_override has empty steps " <>
               "(run_lint_steps([], _) returns :pass immediately). " <>
               "At the merge-base, no run_half/4 clause exists for :lint, so the " <>
               "catch-all fires and returns {:error, {:unknown_half, :lint}}. " <>
               "Got verdict.halves[:lint] = #{inspect(lint_result)}\n" <>
               "Full verdict: #{inspect(verdict)}"
    end
  end

  # ---------------------------------------------------------------------------
  # HR-6 / D-354 (test 4): Gate.run/1 rejects a manifest omitting :spec_membership
  #
  # Once :spec_membership is in @gate_floor, a manifest that omits it causes
  # compose/1 to return {:error, {:gate_floor_violation, _}} and run/1 to return
  # a :fail verdict. At the merge-base (@gate_floor = [:mutation, :critic,
  # :reviewer]), omitting :spec_membership from the manifest passes compose/1
  # (no floor violation) and run/1 may return :pass — this test FAILS.
  # ---------------------------------------------------------------------------

  describe "HR-6 / D-354: Gate.run/1 rejects manifests that omit :spec_membership" do
    @tag :hr_6
    @tag :d_354
    test "HR-6/D-354: run/1 MUST return :fail verdict when :spec_membership is omitted from manifest",
         %{writer: writer, fixture_root: root} do
      repo = build_genuine_repo(root)

      req =
        build_request(repo, writer, %{
          gate_manifest: [:mutation, :critic, :reviewer, :lint],
          gate_concurrency: 4,
          gate_timeout: 120_000,
          oracle: %{critic: :pass, reviewer: :pass},
          lint_override: %LintDescriptor{steps: []}
        })

      verdict = @gate.run(req)

      assert verdict.status == :fail,
             "HR-6/D-354: Gate.run/1 MUST return a :fail verdict when the manifest " <>
               "omits :spec_membership — the engine-fixed floor is non-shrinkable by " <>
               "policy. At the merge-base, :spec_membership is NOT in @gate_floor so " <>
               "compose/1 does not detect a floor violation and run/1 may return :pass. " <>
               "Got verdict: #{inspect(verdict)}"

      assert :spec_membership in Map.keys(verdict.halves),
             "HR-6/D-354: :spec_membership MUST appear in verdict.halves even when the " <>
               "manifest omits it (floor violation surfaced per-half, not silenced). " <>
               "Got halves keys: #{inspect(Map.keys(verdict.halves))}"
    end
  end

  # ---------------------------------------------------------------------------
  # Fixture builder: genuine discriminating git worktree
  #
  # merge-base: minimal Mix project, no production module
  # HEAD: lib/widget.ex added + test that fails without it
  #
  # The mutation half sees a PASS (the gating test fails on the reverted tree),
  # so the spec_membership and lint halves drive the verdict in these tests.
  # ---------------------------------------------------------------------------

  defp build_genuine_repo(root) do
    dir = Path.join(root, "repo_hr6_#{System.unique_integer([:positive])}")
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
      test "HR-6 widget value is 42" do
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
    defmodule FixtureHR6.MixProject do
      use Mix.Project
      def project, do: [app: :fixture_hr6, version: "0.1.0", elixir: "~> 1.14"]
    end
    """
  end

  defp build_request(repo, writer, policy_pin) do
    {diff, _} = System.cmd("git", ["diff", repo.merge_base, repo.head], cd: repo.dir)

    struct!(@request_mod, %{
      unit: "pr-hr6-#{System.unique_integer([:positive])}",
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
