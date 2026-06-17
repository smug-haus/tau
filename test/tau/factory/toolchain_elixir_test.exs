defmodule Tau.Factory.Toolchain.ElixirGateTest do
  @moduledoc """
  Gating test for D-323 (INV-24 — OTP non-negotiables mechanised via the
  Toolchain) — PR-GATE-4.

  AC-10 (SPEC-FACTORY-GATE §7):

    The `Tau.Factory.Toolchain.Elixir` adapter's `lint/1` descriptor runs
    (engine-executed) and a non-zero lint exit folds the half FAIL;
    `toolchain_elixir_test.exs` passes — every callback returns a declarative
    struct, none returns a verdict. Signal: a stubbed crashing recipe ⇒
    half FAIL (fail-closed).

  D-323 (SPEC-FACTORY-GATE §4):

    The mechanizable part of INV-24 (`mix compile --warnings-as-errors`,
    `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer` —
    and per-language analogues) runs as a gate half through `Toolchain.lint/1`,
    **executed by the engine** exactly as the mutation descriptor is (HR-3):
    the adapter supplies the `%LintDescriptor{}` recipe; the engine runs it
    and judges `exit_status`. A non-zero exit ⇒ half FAIL.

  ## What this test covers

  The boundary under test is `Gate.run/1` — the real user-facing entry point.

  Finding (issue #582): `Gate.run/1` fans out only
  `@gate_floor = [:mutation, :critic, :reviewer]`. The `:lint` half is NOT in
  the floor; `run_half/4` has no `:lint` clause. `Toolchain.Elixir.lint/1`
  returns the correct `%LintDescriptor{}` but is never called from any
  execution path in `lib/`. The mechanizable OTP-non-negotiables check is
  therefore entirely absent from the gate.

  This test asserts the conformant behaviour:

    1. `Gate.gate_floor/0` MUST include `:lint`.
    2. `Gate.run/1` with a genuine discriminating fixture MUST include a
       `:lint` half in the folded `verdict.halves` (i.e. the engine executes
       the lint descriptor, not just the `[:mutation,:critic,:reviewer]` floor).
    3. When the lint steps in the `%LintDescriptor{}` exit non-zero, the
       `:lint` half MUST fold FAIL, making `verdict.status == :fail` even
       when the mutation half passes.

  The oracle seam (policy_pin `oracle:` map) is used for the critic/reviewer
  floor halves so no real LLM is needed. All assertions are against the REAL
  `Gate.run/1` entry point — no hand-built `%Verdict{}`, no stub bypassing
  the orchestrator.
  """

  use ExUnit.Case, async: false

  @moduletag :ac_10
  @moduletag :d_323
  @moduletag :capture_log

  # Runtime module references — the file compiles even before these exist.
  @gate Tau.Factory.Gate
  @request_mod Tau.Factory.Gate.Request
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Setup: isolated Ledger Writer per test + a tmp fixture worktree root
  # ---------------------------------------------------------------------------

  setup do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"test_d323_ledger_#{System.unique_integer([:positive])}"

    writer_pid =
      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: writer_name
      )

    fixture_root = Briefly.create!(directory: true)

    %{writer: writer_pid, writer_name: writer_name, db_path: db_path, fixture_root: fixture_root}
  end

  # ---------------------------------------------------------------------------
  # D-323 (1) — Gate.gate_floor/0 MUST include :lint
  #
  # The current floor is [:mutation, :critic, :reviewer] (gate.ex:61).
  # D-323 requires :lint to be an engine-executed half, so :lint MUST appear
  # in the floor (or at minimum be dispatched on every run). The simplest
  # mechanically-checkable contract: gate_floor/0 returns a list that includes
  # :lint.
  # ---------------------------------------------------------------------------

  describe "D-323 / AC-10: Gate.gate_floor/0 includes :lint" do
    @tag :d_323
    @tag :ac_10
    test "D-323: gate_floor/0 MUST include :lint (OTP non-negotiables are mechanised as a gate half)" do
      floor = @gate.gate_floor()

      assert is_list(floor),
             "D-323: gate_floor/0 must return a list. Got: #{inspect(floor)}"

      assert :lint in floor,
             "D-323 / AC-10: gate_floor/0 MUST include :lint. " <>
               "The mechanizable OTP non-negotiables (warnings-as-errors, format, credo, " <>
               "dialyzer) MUST run as an engine-executed gate half (SPEC-FACTORY-GATE §4). " <>
               "Current floor: #{inspect(floor)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-323 (2) — Gate.run/1 includes :lint in the folded verdict halves
  #
  # Even if :lint is added to the floor, this test asserts the engine actually
  # dispatches it and the result appears in verdict.halves — confirming execution,
  # not just floor membership.
  # ---------------------------------------------------------------------------

  describe "D-323 / AC-10: Gate.run/1 includes a :lint half in the folded verdict" do
    @tag :d_323
    @tag :ac_10
    test "D-323: run/1 MUST include :lint in verdict.halves (lint half is executed, not skipped)",
         %{writer: writer, fixture_root: root} do
      repo = build_genuine_repo(root)
      req = build_request(repo, writer, policy_pin: passing_policy_pin())

      verdict = @gate.run(req)

      half_ids = extract_half_ids(verdict)

      assert :lint in half_ids,
             "D-323 / AC-10: Gate.run/1 MUST execute the :lint half (engine-runs " <>
               "Toolchain.lint/1 descriptor, judges exit_status). The :lint half result " <>
               "MUST appear in verdict.halves. " <>
               "Current halves: #{inspect(half_ids)}\nFull verdict: #{inspect(verdict)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-323 (3) — A failing lint (non-zero exit) folds :fail and makes verdict :fail
  #
  # This is the load-bearing AC-10 assertion:
  #   "a stubbed crashing recipe ⇒ half FAIL (fail-closed)"
  #
  # The policy_pin includes a lint_override that substitutes a failing lint
  # recipe (a command guaranteed to exit non-zero, e.g. `false` or a non-
  # existent binary). When this override is honoured by the gate, the :lint
  # half MUST fold FAIL and verdict.status MUST be :fail.
  #
  # The oracle seam for critic/reviewer returns :pass so only the lint half
  # drives the failure. This confirms that:
  #   - the lint half is executed (not just present in the floor)
  #   - a non-zero exit is the failure signal (not a soft warning)
  #   - the fold rule propagates lint failure to the overall verdict
  # ---------------------------------------------------------------------------

  describe "D-323 / AC-10: a non-zero lint exit folds the :lint half FAIL and verdict :fail" do
    @tag :d_323
    @tag :ac_10
    test "D-323: run/1 returns %Verdict{status: :fail} when the lint step exits non-zero (fail-closed)",
         %{writer: writer, fixture_root: root} do
      repo = build_genuine_repo(root)

      # A policy_pin that injects a failing lint recipe — a command guaranteed
      # to exit non-zero so we can assert the fail-closed behaviour without
      # requiring a real linting failure in the worktree.
      req =
        build_request(repo, writer, policy_pin: failing_lint_policy_pin())

      verdict = @gate.run(req)

      half_ids = extract_half_ids(verdict)

      # The :lint half MUST appear — it was executed.
      assert :lint in half_ids,
             "D-323: :lint half must be present in verdict.halves even on failure. " <>
               "Current halves: #{inspect(half_ids)}"

      # The :lint half result MUST be :fail (not :pass, not absent).
      lint_result = extract_half_result(verdict, :lint)

      refute lint_result == :pass,
             "D-323 / AC-10: a non-zero lint exit MUST NOT fold as :pass. " <>
               "Lint result: #{inspect(lint_result)}"

      assert lint_result == :fail or match?({:error, _}, lint_result),
             "D-323 / AC-10: a non-zero lint exit MUST fold the :lint half as :fail " <>
               "or {:error, _} (fail-closed, SPEC-FACTORY-GATE §4). " <>
               "Lint result: #{inspect(lint_result)}"

      # The overall verdict MUST be :fail when the lint half fails.
      assert verdict.status == :fail,
             "D-323 / AC-10: Gate.run/1 MUST return %Verdict{status: :fail} when the " <>
               "lint half fails-closed (non-zero exit). The mechanizable OTP non-negotiables " <>
               "are an engine-fixed gate half — a lint failure MUST NOT be silent. " <>
               "Got verdict: #{inspect(verdict)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Fixture builder: a genuine discriminating git repo
  #
  # This is the minimal fixture the mutation half needs to see a PASS —
  # a production module added by the implementer commit and a gating test
  # that depends on it (fails when production is reverted to merge-base).
  # The same fixture is used for both the lint-present and lint-fail assertions
  # so the mutation half does not contribute failure on its own.
  # ---------------------------------------------------------------------------

  defp build_genuine_repo(root) do
    dir = Path.join(root, "repo_d323_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    git = fn args -> {_out, 0} = System.cmd("git", args, cd: dir) end
    git.(["init", "-q"])
    git.(["config", "user.email", "t@t"])
    git.(["config", "user.name", "t"])

    # --- merge-base commit: minimal mix project, no production module ---
    File.write!(Path.join(dir, "mix.exs"), fixture_mix_exs())
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "base"])
    {merge_base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    merge_base = String.trim(merge_base)

    # --- implementer commit: production module + gating test ---
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
      test "D-323 widget value is 42" do
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
    defmodule Fixture.MixProject do
      use Mix.Project
      def project, do: [app: :fixture, version: "0.1.0", elixir: "~> 1.14"]
    end
    """
  end

  # ---------------------------------------------------------------------------
  # Policy pin helpers
  # ---------------------------------------------------------------------------

  # A policy_pin whose oracle halves both return :pass and whose lint
  # configuration uses the real Elixir adapter (a real lint run against the
  # fixture repo). The lint result on the fixture repo may or may not pass,
  # but the `:lint` half MUST appear in verdict.halves regardless.
  defp passing_policy_pin do
    %{
      gate_manifest: [:mutation, :critic, :reviewer, :lint],
      gate_concurrency: 4,
      gate_timeout: 120_000,
      oracle: %{critic: :pass, reviewer: :pass}
    }
  end

  # A policy_pin that injects a failing lint recipe — a non-existent binary
  # that will exit non-zero, so the :lint half MUST fail-closed regardless
  # of the actual project state. The oracle halves return :pass so only
  # the lint half drives verdict failure.
  #
  # The `lint_override` key is the seam the engine (or the Gate) uses to
  # substitute the LintDescriptor for testing. If the implementation uses a
  # different key or seam, the test will fail (correct: it should) and the
  # implementer should either conform to this seam or a SPEC §3 amendment
  # must be filed to formalise the seam name.
  defp failing_lint_policy_pin do
    %{
      gate_manifest: [:mutation, :critic, :reviewer, :lint],
      gate_concurrency: 4,
      gate_timeout: 120_000,
      oracle: %{critic: :pass, reviewer: :pass},
      lint_override: %Tau.Toolchain.LintDescriptor{
        steps: [
          # `false` is a POSIX command guaranteed to exit 1.
          %{argv: ~w(false), report: :exit_status}
        ]
      }
    }
  end

  defp build_request(repo, writer, opts) do
    policy_pin = Keyword.get(opts, :policy_pin, passing_policy_pin())
    {diff, _} = System.cmd("git", ["diff", repo.merge_base, repo.head], cd: repo.dir)

    struct!(@request_mod, %{
      unit: "pr-d323",
      diff: diff,
      frozen_paths: repo.gating_paths,
      policy_pin: policy_pin,
      workspace: repo.dir,
      merge_base: repo.merge_base,
      hash: repo.head,
      run: Keyword.get(opts, :run, "run-1"),
      ledger: writer
    })
  end

  # ---------------------------------------------------------------------------
  # Verdict inspection helpers — robust to halves being a map or a list
  # ---------------------------------------------------------------------------

  defp extract_half_ids(verdict) do
    case verdict.halves do
      %{} = m ->
        Map.keys(m)

      list when is_list(list) ->
        Enum.map(list, fn
          {id, _result} -> id
          %{id: id} -> id
          %{half: id} -> id
          id when is_atom(id) -> id
        end)
    end
  end

  defp extract_half_result(verdict, half_id) do
    case verdict.halves do
      %{} = m ->
        Map.get(m, half_id, :absent)

      list when is_list(list) ->
        Enum.find_value(list, :absent, fn
          {^half_id, result} -> result
          %{id: ^half_id, result: result} -> result
          %{half: ^half_id, result: result} -> result
          _ -> false
        end)
    end
  end
end
