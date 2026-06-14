defmodule Tau.Factory.Dogfood.GateFun do
  @moduledoc """
  Builds the arity-1 `gate_fun` closure for the `mix tau.factory.dogfood` harness.

  The Unit's `:gate_fun` seam is `(coordinate :: String.t() -> :pass | {:fail, [finding]})`.
  The real gate is `Tau.Factory.Gate.run/1` over a `%Tau.Factory.Gate.Request{}`. This
  module builds the request-bearing arity-1 closure that adapts
  `Gate.run/1`-over-`Request` to the Unit's arity-1 seam, as specified in
  SPEC-FACTORY-CORE §4 B11 ("gate_fun completion", P5c-7, D-361).

  The closure creates a **host-isolated gate workspace** (a `git worktree add`
  of `repo_dir` on the feature branch) at call time — AFTER the worker has
  committed — so the mutation half has a clean reverted-friendly checkout
  distinct from the worker's writable worktree (D-309/C201). The workspace is
  cleaned up (removed) before the closure returns.

  ## Oracle override

  The `policy_pin` uses `oracle: %{critic: :pass, reviewer: :pass}` to make
  the critic and reviewer halves deterministic (the stub oracle from
  `Gate.Oracle.Stub`). The mutation half is fully real: Gate 5.3 reverts
  `lib/sandbox.ex` to merge_base, runs the gating test (which then fails
  because `Sandbox.answer/0` is absent), and then verifies it passes on the
  real tree.
  """

  alias Tau.Factory.Gate
  alias Tau.Factory.Gate.{Request, Verdict}

  require Logger

  @doc """
  Build the arity-1 `gate_fun` closure for the dogfood harness.

  The closure captures:
    - `repo_dir`     — the sandbox working repo (worker's parent git dir).
    - `unit_id`      — the stable unit identity string (e.g. `"unit-1"`).
    - `run`          — the run identifier string (e.g. `"run-1"`).
    - `frozen_paths` — the declared gating-test path set (D-304; a
                       `MapSet.t(String.t())`).
    - `ledger`       — the started `Tau.Factory.Ledger.Writer` name/pid
                       (WAL-before-ack, D-335).

  The returned closure is arity-1: `(coordinate :: String.t() -> :pass | {:fail, [term()]})`.
  The Unit supplies the coordinate (`data.head_sha || data.hash`) at call time (D-361).
  The coordinate becomes the `Gate.Request.hash` — i.e. the captured head_sha (or the
  declared work_item.hash via nil-fallback per D-363) is used as the gate's hash key.
  """
  @spec build(
          repo_dir: String.t(),
          unit_id: String.t(),
          run: String.t(),
          frozen_paths: MapSet.t(String.t()),
          ledger: GenServer.server()
        ) :: (String.t() -> :pass | {:fail, [term()]})
  def build(params) do
    repo_dir = Keyword.fetch!(params, :repo_dir)
    unit_id = Keyword.fetch!(params, :unit_id)
    run = Keyword.fetch!(params, :run)
    frozen_paths = Keyword.fetch!(params, :frozen_paths)
    ledger = Keyword.fetch!(params, :ledger)

    # The oracle pin makes critic/reviewer deterministic (stub returns :pass).
    # The mutation half is fully real (no oracle pin for :mutation).
    policy_pin = %{oracle: %{critic: :pass, reviewer: :pass}}

    fn coordinate ->
      run_gate(repo_dir, unit_id, coordinate, run, frozen_paths, ledger, policy_pin)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — gate execution at call time
  # ---------------------------------------------------------------------------

  # Build a host-isolated gate workspace, run Gate.run/1, fold the verdict,
  # and clean up the workspace. Fail-closed: any error → {:fail, [reason]}.
  defp run_gate(repo_dir, unit_id, hash, run, frozen_paths, ledger, policy_pin) do
    nonce = :erlang.unique_integer([:positive])
    gate_ws = Path.join(Path.dirname(repo_dir), ".gate-ws-#{nonce}")
    branch = unit_id_to_branch(unit_id)

    case setup_gate_workspace(repo_dir, gate_ws, branch) do
      :ok ->
        try do
          execute_gate(gate_ws, unit_id, hash, run, frozen_paths, ledger, policy_pin)
        after
          cleanup_gate_workspace(gate_ws, repo_dir)
        end

      {:error, reason} ->
        Logger.warning("[Dogfood.GateFun] failed to set up gate workspace: #{inspect(reason)}")
        {:fail, [{:gate_workspace_setup_failed, reason}]}
    end
  end

  # Create the gate workspace via `git worktree add --detach`.
  # Using --detach avoids holding the named branch lock, which allows the
  # implementing worker's worktree to be reclaimed concurrently (D-313/D-314).
  # The detached HEAD still points to the branch's current tip commit, giving
  # the gate the exact same content without requiring branch exclusivity.
  defp setup_gate_workspace(repo_dir, gate_ws, branch) do
    case System.cmd(
           "git",
           ["worktree", "add", "--detach", gate_ws, branch],
           cd: repo_dir,
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:git_worktree_add, code, out}}
    end
  end

  # Remove the gate workspace via `git worktree remove --force`.
  defp cleanup_gate_workspace(gate_ws, repo_dir) do
    System.cmd(
      "git",
      ["worktree", "remove", "--force", gate_ws],
      cd: repo_dir,
      stderr_to_stdout: true
    )

    :ok
  end

  # Run the gate against the already-set-up workspace.
  defp execute_gate(gate_ws, unit_id, hash, run, frozen_paths, ledger, policy_pin) do
    # merge_base: the commit where origin/main and the feature branch diverge.
    merge_base = compute_merge_base(gate_ws)

    # diff: unified diff between merge_base and HEAD in the gate workspace.
    diff = compute_diff(gate_ws, merge_base)

    req = %Request{
      unit: unit_id,
      diff: diff,
      frozen_paths: frozen_paths,
      policy_pin: policy_pin,
      workspace: gate_ws,
      merge_base: merge_base,
      hash: hash,
      run: run,
      ledger: ledger
    }

    case Gate.run(req) do
      %Verdict{status: :pass} ->
        :pass

      %Verdict{status: :fail, halves: halves} ->
        failing = Map.keys(halves) |> Enum.filter(fn h -> halves[h] != :pass end)
        {:fail, failing}
    end
  end

  # Compute the merge-base SHA between origin/main and HEAD in the workspace.
  defp compute_merge_base(workspace) do
    case System.cmd(
           "git",
           ["merge-base", "origin/main", "HEAD"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        String.trim(out)

      {_out, _code} ->
        # Fallback: if origin/main doesn't exist, use the first commit (bare sandbox).
        case System.cmd("git", ["rev-list", "--max-parents=0", "HEAD"],
               cd: workspace,
               stderr_to_stdout: true
             ) do
          {out, 0} -> String.trim(out)
          _ -> "HEAD"
        end
    end
  end

  # Compute the unified diff between merge_base and HEAD in the workspace.
  defp compute_diff(workspace, merge_base) do
    case System.cmd(
           "git",
           ["diff", merge_base, "HEAD"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {out, _} -> out
    end
  end

  # Derive branch name from unit_id (the dogfood convention: "unit-1" → "unit-1").
  defp unit_id_to_branch(unit_id), do: unit_id
end
