defmodule Tau.Factory.Gate do
  @moduledoc """
  Component G (C1) — the transient gate orchestrator.

  `run/1` fans out the engine-fixed floor halves via
  `Task.Supervisor.async_stream_nolink`, folds the results into a `%Verdict{}`,
  and appends the verdict to the Ledger (WAL-before-ack; D-335).

  `compose/1` reads the `policy_pin` and re-asserts the floor members, rejecting
  any pin that omits a floor member (`{:error, {:gate_floor_violation, _}}`).

  ## OTP design

  G is a **transient computation** — no GenServer state between runs (OTP
  non-negotiable #3). Fan-out is bounded by `policy_pin.gate_concurrency` via
  `Task.Supervisor.async_stream_nolink` under `Tau.Tools.TaskSupervisor`.

  ## Floor (D-354, non-shrinkable)

  The engine-fixed floor is `[:mutation, :critic, :reviewer, :lint, :spec_membership]`.
  `compose/1` adds these to any policy manifest and rejects a manifest that tries
  to omit them. An operator cannot policy away a floor member.

  ### Backward-compatibility note (D-322 / D-323 / HR-6)

  Pre-extended-floor manifests (those omitting both `:lint` and `:spec_membership`,
  e.g. the legacy `[:mutation, :critic, :reviewer]` form used in tests authored
  before the extended floor landed) receive a soft-run path: extended missing
  members are dispatched through the oracle stub, which returns `:pass` for
  unmapped halves. This is a deliberate compatibility seam for gating tests frozen
  before HR-6/D-322/D-323 landed. When a manifest includes `:lint` but omits
  `:spec_membership` (a lint-aware caller), the omission is a hard D-354 floor
  violation and the half is pre-failed. The soft-run path only applies to manifests
  entirely unaware of the extended floor (omitting both `:lint` and
  `:spec_membership`).

  ## Oracle seam (§4 B1/B2 amendment — PR #464)

  The critic and reviewer halves are dispatched through `Gate.Oracle.select/1`,
  which reads `policy_pin.oracle`. When it is a map of pre-pinned results, the
  `Stub` implementation is used (deterministic, hermetic). When absent, the
  `Real` implementation is selected (LLM-backed, lands in P5c-3).

  ## Mutation half (HR-3 / D-306 / §C203-B3)

  The mutation half uses `Tau.Factory.Engine.TestRun.execute/2` (the engine-owned,
  reverted-worktree-capable test primitive) and `Tau.Toolchain.ReportParser` to
  produce real `%Tau.Toolchain.TestReport{}` structs with REAL, stable test ids
  (classname.testname, never positional "test_N" fakes). This is the §C203-B3
  anti-forgery guarantee: `killed_ids ⊆ passing_ids(real)` is verified BY REAL
  ID, not by count.

  The §C203 mandated order:
    1. Run the REVERTED tree (tracked ∖ gating_paths → merge_base) FIRST → reverted_report.
    2. Apply `Mutation.judge/1` to reverted_report → `{:pass, killed_ids}` (real ids).
    3. Run the REAL (un-reverted) tree SECOND → real_report.
    4. Apply `Mutation.cross_check/2`: `killed_ids ⊆ passing_ids(real_report)` by real id.
    5. PASS iff judge={:pass,_} ∧ cross-check=:pass.

  Fail-closed (D-306 / HR-3): a runner crash on the reverted tree (e.g. the
  gating test fails to compile because it references an absent production module)
  yields `{:error, {:runner_crashed, _}}` → `:fail`. A crash is
  indistinguishable from an infrastructure failure and MUST NOT be treated as a
  discriminating PASS.
  """

  alias Tau.Factory.Engine.TestRun
  alias Tau.Factory.Gate.{Masking, Mutation, Oracle, Request, SpecMembership, Verdict}
  alias Tau.Factory.Ledger.Writer
  alias Tau.Toolchain.{LintDescriptor, TestDescriptor}

  require Logger

  @gate_floor [:mutation, :critic, :reviewer, :lint, :spec_membership]

  @doc "The engine-fixed, non-shrinkable gate floor (D-354)."
  @spec gate_floor() :: [atom()]
  def gate_floor, do: @gate_floor

  @doc """
  Validate a `policy_pin` against the engine-fixed floor.

  Returns `{:ok, manifest}` when the pin's `gate_manifest` contains every floor
  member (or the manifest is absent — the floor alone is used). Returns
  `{:error, {:gate_floor_violation, missing}}` when the manifest explicitly
  omits a floor member.

  The manifest returned on `:ok` is the union of `gate_floor()` and any
  policy-requested extras.
  """
  @spec compose(map()) :: {:ok, [atom()]} | {:error, {:gate_floor_violation, [atom()]}}
  def compose(%{gate_manifest: requested_manifest} = _policy_pin)
      when is_list(requested_manifest) do
    missing_floor = Enum.reject(@gate_floor, &(&1 in requested_manifest))

    case missing_floor do
      [] ->
        manifest = Enum.uniq(@gate_floor ++ requested_manifest)
        {:ok, manifest}

      missing ->
        {:error, {:gate_floor_violation, missing}}
    end
  end

  def compose(_policy_pin) do
    {:ok, @gate_floor}
  end

  @doc """
  Fan out the gate halves, fold into a `%Verdict{}`, and append to L.

  Returns a `%Verdict{}` with `:status` (`:pass` or `:fail`) and `:halves`
  (a map of `half_id => result`).

  A vacuous/empty-production diff folds the mutation half FAIL (D-306/D-354).
  A policy pin omitting a floor member returns a `:fail` verdict (D-354).

  WAL-before-ack: the verdict is appended to the Ledger before `run/1` returns
  (D-335).
  """
  @spec run(Request.t()) :: Verdict.t()
  def run(%Request{} = req) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:tau, :factory, :gate, :run, :start],
      %{system_time: System.system_time()},
      %{unit: req.unit, hash: req.hash, run: req.run}
    )

    verdict =
      case compose(req.policy_pin) do
        {:error, {:gate_floor_violation, missing}} ->
          Logger.warning("Gate floor violation for unit=#{req.unit}: missing #{inspect(missing)}")

          # Split missing floor members into buckets:
          #
          # - original_missing: core floor ([:mutation, :critic, :reviewer]) — always
          #   pre-fail. These represent a genuine gate contract violation.
          #
          # - extended_missing: new mechanical floor ([:lint, :spec_membership]).
          #   These are handled via "lint-awareness":
          #
          #   When the requested manifest includes :lint (indicating the caller is
          #   aware of the extended floor), :spec_membership MUST also be present.
          #   An absent :spec_membership in that context is a hard D-354 violation —
          #   pre-fail it (D-322 / HR-6).
          #
          #   When the requested manifest omits BOTH :lint and :spec_membership
          #   (old-style pre-extended-floor manifests), route extended missing members
          #   through run_half via the oracle stub seam (hermetic mode: unmapped halves
          #   default to :pass). This preserves backward compatibility with test
          #   fixtures authored before the extended floor landed (D-323 backward compat).
          core_floor = [:mutation, :critic, :reviewer]
          original_missing = Enum.filter(missing, &(&1 in core_floor))
          extended_missing = Enum.reject(missing, &(&1 in core_floor))

          requested_manifest_list = requested_manifest(req.policy_pin)
          lint_aware = :lint in requested_manifest_list

          # :spec_membership is a hard floor violation when the caller is lint-aware
          # (includes :lint in their manifest but omits :spec_membership — D-354/HR-6).
          {hard_fail_extended, soft_run_extended} =
            Enum.split_with(extended_missing, fn
              :spec_membership when lint_aware -> true
              _ -> false
            end)

          all_hard_fail = original_missing ++ hard_fail_extended
          run_manifest = Enum.uniq(requested_manifest_list ++ soft_run_extended)
          base_verdict = run_halves(req, run_manifest)

          fail_results = Map.new(all_hard_fail, fn half -> {half, :fail} end)
          merged_halves = Map.merge(base_verdict.halves, fail_results)

          overall_status =
            if all_hard_fail == [] do
              base_verdict.status
            else
              :fail
            end

          %Verdict{status: overall_status, halves: merged_halves}

        {:ok, manifest} ->
          run_halves(req, manifest)
      end

    # D-307 mechanizable narrowing: when policy_pin.entry_symbol is declared,
    # assert the symbol appears in at least one gating test source file.
    # If absent from all gating test sources, fold :fail into the verdict.
    verdict = apply_entry_symbol_check(req, verdict)

    append_to_ledger(req, verdict)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:tau, :factory, :gate, :run, :stop],
      %{duration: duration},
      %{unit: req.unit, hash: req.hash, run: req.run, status: verdict.status}
    )

    verdict
  end

  # ---------------------------------------------------------------------------
  # Private — half execution
  # ---------------------------------------------------------------------------

  # Extract the caller-supplied manifest from the policy pin, or fall back to
  # the floor. Used when compose/1 detects a floor violation so we can still
  # execute the halves the caller did request (D-323: :lint MUST appear in
  # verdict.halves even when another floor member is absent from the manifest).
  defp requested_manifest(%{gate_manifest: m}) when is_list(m), do: m
  defp requested_manifest(_), do: @gate_floor

  defp run_halves(req, manifest) do
    concurrency = Map.get(req.policy_pin, :gate_concurrency, 4)
    timeout = Map.get(req.policy_pin, :gate_timeout, 60_000)

    {oracle_mod, oracle_arg} = Oracle.select(req.policy_pin)

    half_results =
      Task.Supervisor.async_stream_nolink(
        Tau.Tools.TaskSupervisor,
        manifest,
        fn half -> {half, run_half(half, req, oracle_mod, oracle_arg)} end,
        max_concurrency: concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {half, result}} -> {half, result}
        {:exit, reason} -> {:unknown, {:error, {:half_crashed, reason}}}
      end)

    verdict = Verdict.fold(half_results)
    run_masking_scan(req)
    verdict
  end

  # Masking scan — detection-only (C207-B6 / INV-MASKING-DETECTION-ONLY).
  #
  # Masking is always invoked during a gate run — it is detection-only and does not
  # affect the verdict. Findings are surfaced via telemetry so the critic can treat
  # them as mandatory review items (SPEC-FACTORY-GATE §4 B6 / arch §8).
  defp run_masking_scan(%Request{} = req) do
    case Masking.scan(req.diff, req.frozen_paths) do
      {:clean, []} ->
        :ok

      {:flagged, findings} ->
        :telemetry.execute(
          [:tau, :factory, :gate, :masking, :flagged],
          %{count: length(findings)},
          %{unit: req.unit, findings: findings}
        )
    end
  end

  # Run a single half, returning :pass | :fail | {:error, reason}.
  defp run_half(:mutation, req, _oracle_mod, _oracle_arg) do
    run_mutation_half(req)
  end

  defp run_half(:critic, _req, oracle_mod, oracle_arg) do
    try do
      oracle_mod.judge(:critic, oracle_arg)
    rescue
      e -> {:error, {:oracle_crashed, e}}
    catch
      k, v -> {:error, {:oracle_caught, k, v}}
    end
  end

  defp run_half(:reviewer, _req, oracle_mod, oracle_arg) do
    try do
      oracle_mod.judge(:reviewer, oracle_arg)
    rescue
      e -> {:error, {:oracle_crashed, e}}
    catch
      k, v -> {:error, {:oracle_caught, k, v}}
    end
  end

  # When the oracle is a Stub (hermetic test mode), mechanical halves that
  # are not explicitly overridden via lint_override / spec_membership_override
  # are routed through the oracle stub. The stub returns :pass for unmapped
  # halves, so a test fixture that does not supply those overrides still passes.
  # When the oracle is Real (production), the real toolchain / spec-check runs.
  #
  # D-322 hermetic-seam routing: when the test supplies spec_membership_diff,
  # spec_membership_pr_body, or spec_membership_source_maps, those keys signal
  # intent to exercise the real SpecMembership.check/3 path end-to-end, even
  # under Oracle.Stub. Route to run_spec_membership_half/1 in that case.
  defp run_half(:lint, req, Oracle.Stub, oracle_arg) do
    case Map.fetch(req.policy_pin, :lint_override) do
      {:ok, _} -> run_lint_half(req)
      :error -> Oracle.Stub.judge(:lint, oracle_arg)
    end
  end

  defp run_half(:lint, req, _oracle_mod, _oracle_arg) do
    run_lint_half(req)
  end

  @spec_membership_seam_keys [
    :spec_membership_diff,
    :spec_membership_pr_body,
    :spec_membership_source_maps
  ]

  defp run_half(:spec_membership, req, Oracle.Stub, oracle_arg) do
    has_seam_key = Enum.any?(@spec_membership_seam_keys, &Map.has_key?(req.policy_pin, &1))

    if has_seam_key or Map.has_key?(req.policy_pin, :spec_membership_override) do
      run_spec_membership_half(req)
    else
      Oracle.Stub.judge(:spec_membership, oracle_arg)
    end
  end

  defp run_half(:spec_membership, req, _oracle_mod, _oracle_arg) do
    run_spec_membership_half(req)
  end

  defp run_half(half, _req, _oracle_mod, _oracle_arg) do
    Logger.warning("Unknown gate half: #{inspect(half)}")
    {:error, {:unknown_half, half}}
  end

  # ---------------------------------------------------------------------------
  # Mutation half — engine-owned execution (HR-3 / D-306 / §C203-B3)
  # ---------------------------------------------------------------------------

  # The mutation half applies the §C203 ordered cross-check using
  # Engine.TestRun.execute/2 (the engine-owned, reverted-worktree-capable test
  # primitive) and Toolchain.ReportParser to produce real %TestReport{} structs.
  # Real, stable test ids from the parsed artifact (never positional "test_N" fakes)
  # are what make killed_ids ⊆ passing_ids(real) meaningful (§C203-B3).
  #
  # §C203 mandated order:
  #   1. REVERTED tree first (tracked ∖ gating_paths → merge_base) → reverted_report.
  #   2. Mutation.judge/1 on reverted_report → {judge_result, killed_ids} (real ids).
  #   3. REAL tree second (HEAD restored) → real_report.
  #   4. Mutation.cross_check/2: killed_ids ⊆ passing_ids(real_report) by real id.
  #   5. PASS iff judge={:pass,_} ∧ cross-check=:pass.
  #
  # Fail-closed (D-306 / HR-3): a reverted-tree runner crash → :fail, never :pass.
  defp run_mutation_half(%Request{} = req) do
    gating_paths = MapSet.to_list(req.frozen_paths)
    workspace = req.workspace
    merge_base = req.merge_base

    # plan/2 produces the pure data record for the engine seam (used below).
    plan = Mutation.plan(merge_base, req.frozen_paths)

    if project_creation_na?(gating_paths, merge_base, workspace) do
      :pass
    else
      execute_mutation_check(plan, gating_paths, workspace)
    end
  end

  # Returns true iff every gating-test path's enclosing mix.exs is absent at
  # merge_base (PR-created sub-project; no production to revert → N/A → pass).
  defp project_creation_na?([], _merge_base, _workspace), do: false

  defp project_creation_na?(gating_paths, merge_base, workspace) do
    Enum.all?(gating_paths, fn test_path ->
      case find_enclosing_mix_exs(test_path, workspace) do
        nil -> false
        mix_exs_relpath -> not path_exists_at_ref?(mix_exs_relpath, merge_base, workspace)
      end
    end)
  end

  defp find_enclosing_mix_exs(test_path, workspace) do
    start_dir = Path.dirname(test_path)
    do_find_mix_exs(start_dir, workspace)
  end

  defp do_find_mix_exs(rel_dir, workspace) do
    mix_exs_relpath =
      if rel_dir == "." do
        "mix.exs"
      else
        Path.join(rel_dir, "mix.exs")
      end

    abs_mix_exs = Path.join(workspace, mix_exs_relpath)

    if File.exists?(abs_mix_exs) do
      mix_exs_relpath
    else
      parent = Path.dirname(rel_dir)

      if parent == rel_dir do
        nil
      else
        do_find_mix_exs(parent, workspace)
      end
    end
  end

  defp execute_mutation_check(plan, gating_paths, workspace) do
    # Snapshots preserve the gating-test file contents across the revert.
    {all_files_str, 0} = System.cmd("git", ["ls-files"], cd: workspace)
    all_files = all_files_str |> String.split("\n", trim: true)
    paths_to_revert = all_files -- gating_paths

    gating_snapshots = snapshot_files(gating_paths, workspace)

    try do
      # §C203 step 1: REVERTED tree first.
      # Revert tracked ∖ gating_paths to merge_base; restore frozen gating files.
      revert_to_base(paths_to_revert, plan.merge_base, workspace)
      restore_snapshots(gating_snapshots, workspace)

      case run_via_engine(gating_paths, workspace) do
        {:error, reason} ->
          # Reverted-tree crash → fail-closed (D-306 / HR-3). A crash is
          # indistinguishable from an infrastructure failure: MUST NOT be :pass.
          Logger.warning(
            "Mutation half: reverted-tree runner crashed (fail-closed) in #{workspace}: #{inspect(reason)}"
          )

          {:error, {:runner_crashed, reason}}

        {:ok, reverted_report} ->
          # §C203 step 2: judge the reverted report (pure — no inline ad-hoc judgement).
          reverted_judge = Mutation.judge(reverted_report)

          # §C203 step 3: restore HEAD then run the REAL tree.
          restore_head(all_files, workspace)
          restore_snapshots(gating_snapshots, workspace)

          case run_via_engine(gating_paths, workspace) do
            {:error, reason} ->
              # Real-tree crash: infrastructure failure → fail-closed.
              Logger.warning(
                "Mutation half: real-tree runner crashed in #{workspace}: #{inspect(reason)}"
              )

              :fail

            {:ok, real_report} ->
              # §C203 step 4–5: apply judge result + cross-check.
              apply_judge_and_cross_check(reverted_judge, real_report, workspace)
          end
      end
    after
      # Always restore HEAD so the workspace is left clean.
      restore_head(all_files, workspace)
      restore_snapshots(gating_snapshots, workspace)
    end
  end

  defp apply_judge_and_cross_check(reverted_judge, real_report, workspace) do
    case reverted_judge do
      {:na, :project_created} ->
        :pass

      {:fail, reason} ->
        Logger.debug("Mutation half: reverted-tree judge fail — #{inspect(reason)}")
        :fail

      {:pass, killed_ids} ->
        # §C203 step 5: cross-check killed_ids ⊆ passing_ids(real_report) by real id.
        case Mutation.cross_check(killed_ids, real_report) do
          :pass ->
            :pass

          {:fail, :cross_check_failed} ->
            Logger.warning(
              "Mutation half: §C203 cross-check failed — " <>
                "killed_ids not a subset of real passing_ids in #{workspace}"
            )

            :fail
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Lint half — Toolchain.lint/1 descriptor, engine-run (D-323 / HR-6)
  # ---------------------------------------------------------------------------

  # The lint half asks the Toolchain adapter for a %LintDescriptor{}, then runs
  # each step in order via System.cmd/3, judging by exit status (HR-3 analog for
  # the lint path). A non-zero exit from any step ⇒ :fail (fail-closed, D-323).
  #
  # The `policy_pin.lint_override` key is the hermetic-test seam: when present,
  # the gate substitutes the supplied %LintDescriptor{} for the adapter's recipe.
  # This lets tests inject a deterministic failing descriptor without requiring a
  # real linting failure in the worktree.
  defp run_lint_half(%Request{} = req) do
    descriptor = lint_descriptor(req)
    workspace = req.workspace
    run_lint_steps(descriptor.steps, workspace)
  end

  defp lint_descriptor(%Request{policy_pin: policy_pin, workspace: workspace}) do
    case Map.fetch(policy_pin, :lint_override) do
      {:ok, %LintDescriptor{} = override} ->
        override

      _ ->
        toolchain = toolchain_for(workspace)
        toolchain.lint(%{workspace: workspace, policy_pin: policy_pin})
    end
  end

  # Resolve the toolchain adapter for a given workspace.
  # Defaults to the Elixir adapter (self-host bootstrap); future adapters can
  # be selected by inspecting the workspace (e.g. presence of mix.exs).
  defp toolchain_for(_workspace), do: Tau.Factory.Toolchain.Elixir

  # Run lint steps sequentially; return :pass if all exit 0, :fail otherwise.
  defp run_lint_steps([], _workspace), do: :pass

  defp run_lint_steps([step | rest], workspace) do
    [cmd | args] = step.argv

    case System.cmd(cmd, args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} ->
        run_lint_steps(rest, workspace)

      {_output, exit_code} ->
        Logger.debug("Lint half: step #{inspect(step.argv)} exited #{exit_code} (fail-closed)")
        :fail
    end
  rescue
    e in ErlangError ->
      Logger.warning("Lint half: step failed to start — #{inspect(e.original)} (fail-closed)")
      :fail

    _ ->
      Logger.warning("Lint half: step execution error (fail-closed)")
      :fail
  catch
    kind, reason ->
      Logger.warning(
        "Lint half: unexpected throw/exit — " <>
          inspect(kind) <> ": " <> inspect(reason) <> " (fail-closed)"
      )

      :fail
  end

  # ---------------------------------------------------------------------------
  # SpecMembership half — mechanized spec-before-code check (D-322 / HR-6)
  # ---------------------------------------------------------------------------

  # The spec-membership half checks that any diff path touching a SPEC source-map
  # boundary is accompanied by a SPEC-* / D-NNN reference in the PR body.
  # The `policy_pin.spec_membership_override` key is the hermetic-test seam:
  # when present as `:pass` or `:fail`, the gate short-circuits to that value.
  # When `:diff` and `:pr_body` keys are present in `policy_pin`, they are used
  # directly (no filesystem I/O), which enables hermetic testing.
  defp run_spec_membership_half(%Request{} = req) do
    case Map.fetch(req.policy_pin, :spec_membership_override) do
      {:ok, :pass} ->
        :pass

      {:ok, :fail} ->
        :fail

      _ ->
        diff = Map.get(req.policy_pin, :spec_membership_diff, req.diff)
        pr_body = Map.get(req.policy_pin, :spec_membership_pr_body, "")
        source_maps = Map.get(req.policy_pin, :spec_membership_source_maps, [])

        case SpecMembership.check(diff, pr_body, source_maps) do
          {:pass, []} ->
            :pass

          {:fail, boundaries} ->
            Logger.debug(
              "SpecMembership half: FAIL — boundaries without SPEC ref: #{inspect(boundaries)}"
            )

            :fail
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Engine seam — Engine.TestRun.execute/2 + Toolchain.ReportParser (§C203-B3)
  # ---------------------------------------------------------------------------

  # Run the gating tests via Engine.TestRun.execute/2, which internally calls
  # Toolchain.ReportParser.parse/2 to produce a real %TestReport{} with stable,
  # non-positional test ids. Never falls back to text-scraping or positional ids.
  #
  # Writes a TAP-producing elixir script to the workspace, builds a TestDescriptor
  # pointing to it and the artifact file, calls Engine.TestRun.execute/2, then
  # cleans up the temp files. The TAP formatter produces stable test ids of the
  # form "ModuleName.test name" (to_string(module) <> "." <> to_string(test.name)).
  defp run_via_engine(gating_paths, workspace) do
    nonce = :erlang.unique_integer([:positive])
    script_rel = "_gate_runner_#{nonce}.exs"
    artifact_rel = "_gate_report_#{nonce}.tap"
    script_abs = Path.join(workspace, script_rel)
    artifact_abs = Path.join(workspace, artifact_rel)

    lib_files = find_lib_ex_files(workspace)

    script = build_tap_runner(lib_files, gating_paths, artifact_abs)
    File.write!(script_abs, script)

    descriptor = %TestDescriptor{
      argv: ["elixir", script_rel],
      env: %{},
      report: :tap,
      artifact: artifact_rel
    }

    try do
      case TestRun.execute(descriptor, workspace) do
        {:ok, %{cases: _} = report} ->
          {:ok, report}

        {:error, reason} ->
          {:error, reason}
      end
    after
      _ = File.rm(script_abs)
      _ = File.rm(artifact_abs)
    end
  end

  # Build a TAP-producing elixir script that runs the gating tests and writes
  # TAP output to `artifact_abs`. The script:
  #   1. Defines an inline GenServer TAP formatter that captures test events.
  #   2. Starts ExUnit with the custom formatter (autorun: false).
  #   3. Compiles lib source files so production modules are available.
  #   4. Requires the gating test files (registers test cases with ExUnit).
  #   5. Runs ExUnit; the formatter writes TAP to the artifact file.
  #
  # Uses ~S sigil for the formatter module body to avoid Elixir interpolation of
  # the module's own string literals when building the script string.
  defp build_tap_runner(lib_files, gating_paths, artifact_abs) do
    lib_compiles =
      Enum.map_join(lib_files, "\n", fn f ->
        ~s[Code.compile_file("#{f}")]
      end)

    test_requires =
      Enum.map_join(gating_paths, "\n", fn f ->
        ~s[Code.require_file("#{f}")]
      end)

    # Formatter module: uses ~S to avoid #{} interpolation in this compile unit.
    # The formatter collects test events and writes TAP on suite_finished.
    formatter_mod = ~S"""
    defmodule Gate.TapFormatter do
      use GenServer

      def init(opts) do
        {:ok, %{artifact: opts[:artifact], cases: []}}
      end

      def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
        status =
          cond do
            test.state == nil -> :passed
            match?({:failed, _}, test.state) -> :failed
            match?({:invalid, _}, test.state) -> :failed
            match?({:skip, _}, test.state) -> :skipped
            true -> :passed
          end

        id = to_string(test.module) <> "." <> to_string(test.name)
        {:noreply, %{state | cases: [{id, status} | state.cases]}}
      end

      def handle_cast({:suite_finished, _}, state) do
        cases = Enum.reverse(state.cases)
        total = length(cases)
        header = "TAP version 13\n1.." <> Integer.to_string(total)

        tap_lines =
          cases
          |> Enum.with_index(1)
          |> Enum.map(fn {{id, status}, n} ->
            prefix = if status == :failed, do: "not ok", else: "ok"
            prefix <> " " <> Integer.to_string(n) <> " " <> id
          end)

        content = Enum.join([header | tap_lines], "\n") <> "\n"
        File.write!(state.artifact, content)
        {:noreply, state}
      end

      def handle_cast(_, state), do: {:noreply, state}
    end
    """

    """
    #{formatter_mod}
    ExUnit.start(autorun: false, formatters: [Gate.TapFormatter], artifact: "#{artifact_abs}")
    #{lib_compiles}
    #{test_requires}
    ExUnit.run()
    """
  end

  # Collect all .ex source files under `workspace/lib/`.
  defp find_lib_ex_files(workspace) do
    lib_dir = Path.join(workspace, "lib")

    if File.dir?(lib_dir) do
      do_find_ex_files(lib_dir, workspace)
    else
      []
    end
  end

  defp do_find_ex_files(dir, workspace) do
    case File.ls(dir) do
      {:error, _} ->
        []

      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          abs = Path.join(dir, entry)
          rel = Path.relative_to(abs, workspace)

          cond do
            File.regular?(abs) and String.ends_with?(entry, ".ex") -> [rel]
            File.dir?(abs) -> do_find_ex_files(abs, workspace)
            true -> []
          end
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # Revert / restore helpers (workspace-level git ops for the mutation check)
  # ---------------------------------------------------------------------------

  defp snapshot_files(paths, workspace) do
    Enum.map(paths, fn rel_path ->
      abs = Path.join(workspace, rel_path)

      content =
        case File.read(abs) do
          {:ok, c} -> c
          {:error, _} -> nil
        end

      {rel_path, content}
    end)
  end

  defp revert_to_base([], _merge_base, _workspace), do: :ok

  defp revert_to_base(paths, merge_base, workspace) do
    Enum.each(paths, fn rel_path ->
      if path_exists_at_ref?(rel_path, merge_base, workspace) do
        {_, 0} = System.cmd("git", ["checkout", merge_base, "--", rel_path], cd: workspace)
      else
        abs = Path.join(workspace, rel_path)
        _ = File.rm(abs)
      end
    end)

    :ok
  end

  defp path_exists_at_ref?(rel_path, ref, workspace) do
    case System.cmd(
           "git",
           ["cat-file", "-e", "#{ref}:#{rel_path}"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp restore_snapshots(snapshots, workspace) do
    Enum.each(snapshots, fn {rel_path, content} ->
      if content != nil do
        abs = Path.join(workspace, rel_path)
        File.mkdir_p!(Path.dirname(abs))
        File.write!(abs, content)
      end
    end)
  end

  defp restore_head(paths, workspace) do
    {_, _} = System.cmd("git", ["checkout", "HEAD", "--" | paths], cd: workspace)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Entry-symbol-presence check (D-307 ◐ mechanizable narrowing)
  # ---------------------------------------------------------------------------

  # When policy_pin.entry_symbol is declared, assert the declared symbol appears
  # as a literal string in at least one of the frozen gating test source files.
  # This is the mechanizable narrowing of INV-8 (HR-3): "appears in the test
  # source" is not "is the exercised path" — the under-asserting/wrong-path
  # residual remains critic-bounded by design (D-307 states ◐ PARTIAL honestly).
  #
  # Absent symbol → fold :fail into the verdict (%Verdict{status: :fail}).
  # Present symbol → return the verdict unchanged.
  # No entry_symbol declared → return the verdict unchanged (no-op).
  defp apply_entry_symbol_check(%Request{} = req, %Verdict{} = verdict) do
    case Map.fetch(req.policy_pin, :entry_symbol) do
      :error ->
        verdict

      {:ok, nil} ->
        verdict

      {:ok, symbol} when is_binary(symbol) ->
        if entry_symbol_present?(symbol, req.frozen_paths, req.workspace) do
          verdict
        else
          Logger.debug(
            "Gate D-307: entry symbol #{inspect(symbol)} absent from all gating test sources — folding :fail"
          )

          halves = Map.put(verdict.halves, :entry_symbol, :fail)
          %Verdict{verdict | status: :fail, halves: halves}
        end
    end
  end

  # Returns true iff `symbol` appears as a literal substring in at least one
  # of the gating test files listed in `frozen_paths` (relative to `workspace`).
  defp entry_symbol_present?(symbol, frozen_paths, workspace) do
    Enum.any?(frozen_paths, fn rel_path ->
      abs_path = Path.join(workspace, rel_path)

      case File.read(abs_path) do
        {:ok, source} -> String.contains?(source, symbol)
        {:error, _} -> false
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Ledger append (D-335, WAL-before-ack)
  # ---------------------------------------------------------------------------

  defp append_to_ledger(%Request{} = req, %Verdict{} = verdict) do
    Enum.each(verdict.halves, fn {half, result} ->
      status =
        case result do
          :pass -> :pass
          _ -> :fail
        end

      idempotency_key = "#{req.hash}:#{req.run}:#{half}:#{status}"

      attrs = %{
        hash: req.hash,
        run: req.run,
        half: half,
        status: status,
        idempotency_key: idempotency_key
      }

      case Writer.append_verdict(req.ledger, attrs) do
        {:ok, _ref} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Gate ledger append failed for #{req.hash}/#{req.run}/#{half}: #{inspect(reason)}"
          )
      end
    end)
  end
end
