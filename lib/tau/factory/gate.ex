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

  ## Mutation half (HR-3 / D-306)

  The mutation half runs directly in the `workspace` directory (the engine-
  isolated checkout). It uses `Tau.Factory.Gate.Mutation.plan/2` (pure planner)
  and `Tau.Factory.Gate.Mutation.judge/1` (pure judge) as the two seams, never
  bypassing them with an ad-hoc inline judgement.

  The §C203 ordered cross-check is applied: run the real (un-reverted) gating
  tests → `passing_ids`; run the reverted tree → `killed_ids`; assert
  `killed_ids ⊆ passing_ids`. PASS iff judge={:pass,_} ∧ cross-check=:pass.

  Fail-closed (D-306 / HR-3): a runner crash on the reverted tree (e.g. the
  gating test fails to compile because it references an absent production module)
  yields `{:error, {:runner_crashed, _}}` → `:fail`. A crash is
  indistinguishable from an infrastructure failure and MUST NOT be treated as a
  discriminating PASS.
  """

  alias Tau.Factory.Gate.{Mutation, Oracle, Request, Verdict}
  alias Tau.Factory.Ledger.Writer

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
  # Mutation half — engine-owned execution (HR-3 / D-306)
  # ---------------------------------------------------------------------------

  # The mutation half applies the §C203 ordered cross-check:
  #
  #   1. Run the REAL (un-reverted) gating tests → real_report.
  #   2. Revert tracked ∖ frozen_paths to merge_base in workspace (engine-owned).
  #   3. Run the gating tests on the reverted tree → reverted_report or crash.
  #   4. Apply Mutation.judge/1 to reverted_report (pure judge — no ad-hoc logic).
  #   5. Apply Mutation.cross_check/2: killed_ids ⊆ passing_ids(real_report).
  #   6. PASS iff judge={:pass,_} ∧ cross-check=:pass.
  #
  # Fail-closed (D-306 / HR-3): a reverted-tree runner crash → :fail, never :pass.
  defp run_mutation_half(%Request{} = req) do
    gating_paths = MapSet.to_list(req.frozen_paths)
    workspace = req.workspace
    merge_base = req.merge_base

    # Plan is the pure data record for the engine seam (Mutation.plan/2).
    _plan = Mutation.plan(merge_base, req.frozen_paths)

    # The gate orchestrator always runs the mutation check — the N/A shortcut
    # ("no production delta → skip") used by Mix.Gate.Mutation for CI is NOT
    # applied here: a suite that passes with zero production code is exactly
    # the vacuous-test hole (D-306 / AC-4). We do apply the project-creation
    # N/A (mix.exs absent at merge_base → no production to revert → pass).
    if project_creation_na?(gating_paths, merge_base, workspace) do
      :pass
    else
      execute_mutation_check(gating_paths, merge_base, workspace)
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

  defp execute_mutation_check(gating_paths, merge_base, workspace) do
    # Step 1: run the REAL (un-reverted) tree to get passing_ids for the cross-check.
    case run_test_subprocess(gating_paths, workspace) do
      {:error, :runner_crashed} ->
        # Real tree itself crashes: infrastructure failure → fail-closed.
        Logger.warning("Mutation half: real-tree runner crashed in #{workspace}")
        :fail

      {:ok, real_report} ->
        execute_reverted_check(gating_paths, merge_base, workspace, real_report)
    end
  end

  defp execute_reverted_check(gating_paths, merge_base, workspace, real_report) do
    {all_files_str, 0} = System.cmd("git", ["ls-files"], cd: workspace)
    all_files = all_files_str |> String.split("\n", trim: true)
    paths_to_revert = all_files -- gating_paths

    gating_snapshots = snapshot_files(gating_paths, workspace)

    try do
      # Step 2: revert tracked ∖ gating_paths to merge_base.
      revert_to_base(paths_to_revert, merge_base, workspace)
      restore_snapshots(gating_snapshots, workspace)

      # Step 3: run the reverted tree.
      case run_test_subprocess(gating_paths, workspace) do
        {:error, :runner_crashed} ->
          # Reverted-tree crash → fail-closed (D-306 / HR-3). A crash is
          # indistinguishable from infrastructure failure: MUST NOT be :pass.
          Logger.warning(
            "Mutation half: reverted-tree runner crashed (fail-closed) in #{workspace}"
          )

          {:error, {:runner_crashed, :compile_error}}

        {:ok, reverted_report} ->
          # Step 4: apply Mutation.judge/1 (pure — no inline ad-hoc judgement).
          case Mutation.judge(reverted_report) do
            {:fail, reason} ->
              Logger.debug("Mutation half: reverted-tree judge fail — #{inspect(reason)}")
              :fail

            {:pass, killed_ids} ->
              # Step 5: §C203 cross-check: killed_ids ⊆ passing_ids(real_report).
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
    after
      restore_head(all_files, workspace)
    end
  end

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

  # Run the gating tests in `workspace`, returning a report map compatible with
  # `Mutation.judge/1`:
  #   {:ok, %{cases: [%{id: String.t(), status: :passed | :failed}]}}
  # or
  #   {:error, :runner_crashed}   — no valid summary (compile crash, etc.)
  #
  # We build a synthetic report from the ExUnit text summary line. Individual
  # test IDs are not available from ExUnit text output; we use positional keys
  # ("test_N") consistently across both real-tree and reverted-tree runs so
  # Mutation.cross_check/2 can compare killed_ids to real passing_ids.
  #
  # Fallback: if mix test fails to produce a summary (e.g. minimal fixture has
  # no test_helper.exs), we fall back to the elixir runner. If that also fails
  # to produce a summary, we return {:error, :runner_crashed}.
  defp run_test_subprocess(gating_paths, workspace) do
    mix_output =
      if File.exists?(Path.join(workspace, "mix.exs")) do
        run_via_mix(gating_paths, workspace)
      else
        nil
      end

    output =
      case mix_output && parse_test_summary(mix_output) do
        {:ok, _, _} ->
          # mix produced a valid summary; use it.
          mix_output

        _ ->
          # Fall back to the elixir runner for minimal repos without mix setup.
          run_via_elixir(gating_paths, workspace)
      end

    case parse_test_summary(output) do
      {:ok, total, failures} ->
        cases =
          if total == 0 do
            []
          else
            Enum.map(1..total, fn i ->
              status = if i <= failures, do: :failed, else: :passed
              %{id: "test_#{i}", status: status}
            end)
          end

        {:ok, %{cases: cases}}

      :no_summary ->
        {:error, :runner_crashed}
    end
  end

  defp run_via_mix(gating_paths, workspace) do
    {output, _} =
      System.cmd("mix", ["test" | gating_paths], cd: workspace, stderr_to_stdout: true)

    output
  end

  defp run_via_elixir(gating_paths, workspace) do
    lib_files = find_lib_files_recursive(workspace)

    requires =
      (lib_files ++ gating_paths)
      |> Enum.map_join("\n", fn p -> ~s[Code.require_file("#{p}", "#{workspace}")] end)

    runner = """
    ExUnit.start()
    #{requires}
    ExUnit.run()
    """

    runner_path =
      Path.join(workspace, "_gate_runner_#{:erlang.unique_integer([:positive])}.exs")

    File.write!(runner_path, runner)

    {output, _} =
      try do
        System.cmd("elixir", [runner_path], cd: workspace, stderr_to_stdout: true)
      after
        File.rm(runner_path)
      end

    output
  end

  defp parse_test_summary(output) do
    case Regex.run(~r/(\d+) tests?,\s*(\d+) failures?/, output) do
      [_, total_str, failures_str] ->
        {:ok, String.to_integer(total_str), String.to_integer(failures_str)}

      nil ->
        :no_summary
    end
  end

  defp find_lib_files_recursive(workspace) do
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
