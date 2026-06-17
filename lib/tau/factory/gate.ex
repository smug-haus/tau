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

  The engine-fixed floor is `[:mutation, :critic, :reviewer]`. `compose/1` adds
  these to any policy manifest and rejects a manifest that tries to omit them.
  An operator cannot policy away a floor member.

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
  alias Tau.Factory.Gate.{Mutation, Oracle, Request, Verdict}
  alias Tau.Factory.Ledger.Writer
  alias Tau.Factory.Toolchain

  require Logger

  @gate_floor [:mutation, :critic, :reviewer]

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
          Verdict.fold([{:floor, :fail}])

        {:ok, manifest} ->
          run_halves(req, manifest)
      end

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

    Verdict.fold(half_results)
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
  # D-S2: dispatch through Toolchain.for(req.language); fail closed on unknown lang.
  defp run_mutation_half(%Request{} = req) do
    language = Map.get(req, :language, :elixir)

    case Toolchain.for(language) do
      {:error, {:unsupported_language, lang}} ->
        Logger.warning("Mutation half: unsupported language #{inspect(lang)} — fail closed (D-S2)")

        {:error, {:unsupported_language, lang}}

      adapter when is_atom(adapter) ->
        gating_paths = MapSet.to_list(req.frozen_paths)
        workspace = req.workspace
        merge_base = req.merge_base
        ctx = %{}

        # plan/2 produces the pure data record for the engine seam (used below).
        plan = Mutation.plan(merge_base, req.frozen_paths)

        if project_creation_na?(adapter, gating_paths, merge_base, workspace, ctx) do
          :pass
        else
          execute_mutation_check(adapter, plan, gating_paths, workspace, ctx)
        end
    end
  end

  # Returns true iff every gating-test path's enclosing build manifest is absent
  # at merge_base (PR-created sub-project; no production to revert → N/A → pass).
  #
  # D-S2: the manifest filename comes from the adapter (not hardcoded "mix.exs").
  defp project_creation_na?(_adapter, [], _merge_base, _workspace, _ctx), do: false

  defp project_creation_na?(adapter, gating_paths, merge_base, workspace, ctx) do
    manifest_file = adapter.project_manifest_file(ctx)

    if is_nil(manifest_file) do
      false
    else
      Enum.all?(gating_paths, fn test_path ->
        case find_enclosing_manifest(test_path, manifest_file, workspace) do
          nil -> false
          manifest_relpath -> not path_exists_at_ref?(manifest_relpath, merge_base, workspace)
        end
      end)
    end
  end

  defp find_enclosing_manifest(test_path, manifest_file, workspace) do
    start_dir = Path.dirname(test_path)
    do_find_manifest(start_dir, manifest_file, workspace)
  end

  defp do_find_manifest(rel_dir, manifest_file, workspace) do
    manifest_relpath =
      if rel_dir == "." do
        manifest_file
      else
        Path.join(rel_dir, manifest_file)
      end

    abs_manifest = Path.join(workspace, manifest_relpath)

    if File.exists?(abs_manifest) do
      manifest_relpath
    else
      parent = Path.dirname(rel_dir)

      if parent == rel_dir do
        nil
      else
        do_find_manifest(parent, manifest_file, workspace)
      end
    end
  end

  defp execute_mutation_check(adapter, plan, gating_paths, workspace, ctx) do
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

      case run_via_engine(adapter, gating_paths, workspace, ctx) do
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

          case run_via_engine(adapter, gating_paths, workspace, ctx) do
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
  # Engine seam — Engine.TestRun.execute/2 + Toolchain.ReportParser (§C203-B3)
  # ---------------------------------------------------------------------------

  # Run the gating tests via Engine.TestRun.execute/2, which internally calls
  # Toolchain.ReportParser.parse/2 to produce a real %TestReport{} with stable,
  # non-positional test ids. Never falls back to text-scraping or positional ids.
  #
  # D-S2: the descriptor is obtained from adapter.mutation_descriptor(ctx) — the
  # adapter supplies the argv, env, report format, and artifact path. The engine
  # executes the descriptor verbatim and parses the artifact itself (HR-3).
  #
  # The engine generates a temporary runner script in the workspace before
  # requesting the descriptor. The adapter is passed the script and artifact
  # paths via ctx so it can reference them in the descriptor without hard-coding
  # workspace-specific details. The engine cleans up both temp files afterward.
  defp run_via_engine(adapter, gating_paths, workspace, ctx) do
    nonce = :erlang.unique_integer([:positive])
    script_rel = "_gate_runner_#{nonce}.exs"
    artifact_rel = "_gate_report_#{nonce}.xml"
    script_abs = Path.join(workspace, script_rel)
    artifact_abs = Path.join(workspace, artifact_rel)

    # Build the runner script and write it to the workspace.
    # The script is an ExUnit runner with an inline JUnit formatter — no
    # external deps required. The engine (not the adapter) authors the script
    # content; the adapter only declares how to invoke it (argv, report format).
    script_content = build_junit_runner(gating_paths, artifact_abs, workspace)
    File.write!(script_abs, script_content)

    # The engine passes ctx with the script/artifact paths so the adapter can
    # reference them in the descriptor. Adapters that don't need these fields
    # (non-Elixir adapters) ignore them per the Toolchain ctx contract.
    enriched_ctx = Map.merge(ctx, %{script_rel: script_rel, artifact_rel: artifact_rel})
    descriptor = adapter.mutation_descriptor(enriched_ctx)

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

  # Build a self-contained ExUnit runner script that writes JUnit XML to
  # `artifact_abs`. The script:
  #   1. Defines an inline JUnit formatter (no external deps required).
  #   2. Starts ExUnit with the inline formatter (autorun: false).
  #   3. Compiles lib source files so production modules are available.
  #   4. Requires the gating test files (registers test cases with ExUnit).
  #   5. Runs ExUnit; the inline formatter writes JUnit XML to `artifact_abs`.
  #
  # The JUnit XML format produces stable, meaningful test ids:
  #   classname="ModuleName" name="test description"
  # — the same classname+name pair the cross-check uses to bind reverted-run
  # failures to real-run passes (§C203-B3 anti-forgery).
  defp build_junit_runner(gating_paths, artifact_abs, workspace) do
    lib_files = find_lib_ex_files(workspace)

    lib_compiles =
      Enum.map_join(lib_files, "\n", fn f ->
        ~s[Code.compile_file("#{f}")]
      end)

    test_requires =
      Enum.map_join(gating_paths, "\n", fn f ->
        ~s[Code.require_file("#{f}")]
      end)

    # JUnit formatter module: inline GenServer — uses ~S to suppress interpolation.
    # The nested xml string uses explicit concatenation (no heredoc) to avoid
    # conflicting with the outer ~S sigil's """ terminator.
    junit_formatter = ~S"""
    defmodule Gate.JUnitFormatter do
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

        entry = %{
          classname: to_string(test.module),
          name: to_string(test.name),
          status: status
        }

        {:noreply, %{state | cases: [entry | state.cases]}}
      end

      def handle_cast({:suite_finished, _}, state) do
        cases = Enum.reverse(state.cases)

        testcase_xml =
          Enum.map_join(cases, "\n", fn %{classname: cls, name: nm, status: st} ->
            body =
              if st == :failed do
                "  <failure message=\"test failed\" />"
              else
                ""
              end

            if body == "" do
              ~s[  <testcase classname="#{cls}" name="#{nm}" />]
            else
              ~s[  <testcase classname="#{cls}" name="#{nm}">\n#{body}\n  </testcase>]
            end
          end)

        count = length(cases)

        xml =
          "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" <>
            "<testsuite tests=\"#{count}\" failures=\"0\" name=\"gate\">\n" <>
            testcase_xml <>
            "\n</testsuite>\n"

        File.write!(state.artifact, xml)
        {:noreply, state}
      end

      def handle_cast(_, state), do: {:noreply, state}
    end
    """

    """
    #{junit_formatter}
    ExUnit.start(autorun: false, formatters: [Gate.JUnitFormatter], artifact: "#{artifact_abs}")
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
