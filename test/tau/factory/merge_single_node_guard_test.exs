defmodule Tau.Factory.MergeSingleNodeGuardTest do
  @moduledoc """
  Gating test for issue #561 (INV-ST-11 — control plane MUST stay single-node).

  INV-ST-11 statement:
    "The control plane (L, S, K, M) MUST stay single-node. The merge
     serialization point must be strongly consistent; distributing it would
     import split-brain risk. Falsified by: any component of L/S/K/M running
     on multiple BEAM nodes simultaneously."

  Source: `docs/arch/04-software-architecture/distribution-readiness.md` §1:
    "M is the merge serialization point. Its entire value is that a single
     concurrency-1 mailbox *is* INV-3 — no lock discipline, no distributed
     transaction. Cluster M and you replace a free, local, total order with a
     distributed consensus that can split-brain."

  The PARTIAL verdict on INV-ST-11 arises because MergeAuthority (and K, S, L)
  register node-locally only — `{:local, name}` or `name:` — with NO startup
  guard that checks whether the BEAM node is running in distributed mode. A
  conformant implementation MUST refuse to start when `Node.list/0` is non-empty
  (i.e., when connected nodes are visible), because two distributed BEAM nodes
  could each start their own M, L, S, or K processes, silently violating the
  single-node invariant.

  M (MergeAuthority) is the most critical component to guard: it is the sole
  writer of `origin/main` and the one place where split-brain risk is FATAL
  (arch §4: "two M instances under partition = two concurrent `origin/main`
  writers = the catastrophe D-S1's safety wall exists to forbid").

  Gap (merge_authority.ex:114-178):
    `init/1` does not check `Node.list/0` or accept a `node_list_fun:` injection.
    The call `Node.list()` (or the injected override) is never made; no error
    is returned if other BEAM nodes are visible.

  Conformant implementation:
    `start_link/1` (or `init/1`) MUST:
      1. Accept a `node_list_fun: (-> [node()])` option (default: `&Node.list/0`)
         so the check is injectable for test isolation.
      2. Call `node_list_fun.()` during startup.
      3. Return `{:error, {:multi_node_detected, nodes}}` (or equivalent) when
         `node_list_fun.()` is non-empty.

  Boundary exercised: `Tau.Factory.MergeAuthority.start_link/1` — the real
  user-facing entry point (not a hand-built struct or injected seam that
  bypasses `init/1`).

  Failure mode before implementation:
    The `node_list_fun:` option is not recognized. `init/1` completes without
    error regardless of what the injected function returns. `start_link/1`
    returns `{:ok, pid}` when it MUST return `{:error, _}`.
    The `refute match?({:ok, _}, result)` assertion therefore fails.

  AC / D-NNN linkage: @tag :inv_st_11
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  @merge_authority Tau.Factory.MergeAuthority
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_writer(tmp_dir, suffix) do
    db_path = Path.join(tmp_dir, "ledger_#{suffix}.db")
    writer_name = :"test_ma_sng_writer_#{suffix}_#{System.unique_integer([:positive])}"

    start_supervised!(
      {@writer, db_path: db_path, name: writer_name},
      id: writer_name
    )
  end

  defp setup_git_repo(tmp_dir) do
    origin_path = Path.join(tmp_dir, "origin.git")
    work_path = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])

    git_work = fn args ->
      System.cmd("git", args, cd: work_path, stderr_to_stdout: true)
    end

    git_work.(["config", "user.email", "test@tau.test"])
    git_work.(["config", "user.name", "Tau Test"])

    File.write!(Path.join(work_path, "README"), "initial")
    git_work.(["add", "README"])
    {_, 0} = git_work.(["commit", "-m", "initial commit"])

    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
    {_, 0} = git_work.(["remote", "add", "origin", origin_path])
    {_, 0} = git_work.(["push", "-u", "origin", "main"])

    work_path
  end

  defp base_opts(ma_name, tasks_name, writer, work_path) do
    [
      name: ma_name,
      ledger: writer,
      repo_dir: work_path,
      required_halves: [:critic, :reviewer],
      tasks_name: tasks_name,
      # Never completes — keeps MA busy without real git work.
      build_fun: fn _units, _base ->
        receive do
          :never -> {:built, [], "base", "tip"}
        end
      end
    ]
  end

  # ---------------------------------------------------------------------------
  # INV-ST-11: single-node startup guard
  # ---------------------------------------------------------------------------

  describe "INV-ST-11 — MergeAuthority MUST reject startup when connected BEAM nodes are visible" do
    @tag :inv_st_11
    test "INV-ST-11: start_link with node_list_fun returning non-empty list MUST return {:error, _}" do
      tmp_dir = Briefly.create!(type: :directory)
      work_path = setup_git_repo(tmp_dir)
      writer = start_writer(tmp_dir, "sng")

      ma_name = :"test_ma_inv_st_11_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_sng_tasks_#{System.unique_integer([:positive])}"

      # Simulate being in distributed mode: node_list_fun returns a non-empty
      # list of connected nodes, as Node.list/0 would on a multi-node BEAM.
      simulated_peers = [:"worker_a@remote.example", :"worker_b@remote.example"]

      opts =
        base_opts(ma_name, tasks_name, writer, work_path) ++
          [node_list_fun: fn -> simulated_peers end]

      # INV-ST-11: MergeAuthority MUST refuse to start when connected nodes are
      # visible.  The conformant path returns {:error, {:multi_node_detected, _}}
      # (or any error tuple) — it MUST NOT return {:ok, pid}.
      #
      # Current implementation: init/1 does not accept or call node_list_fun;
      # it completes unconditionally and returns {:ok, :idle, data}, causing
      # start_link to return {:ok, pid} — a live MA running on a "distributed"
      # node, violating INV-ST-11.
      #
      # The assertion below FAILS on the current implementation because
      # start_link returns {:ok, pid} instead of {:error, _}.
      result = @merge_authority.start_link(opts)

      # Clean up any live process before asserting.
      case result do
        {:ok, pid} ->
          on_exit(fn ->
            if Process.alive?(pid), do: Process.exit(pid, :kill)
          end)

        _ ->
          :ok
      end

      # FAILING ASSERTION (INV-ST-11):
      # When node_list_fun.() returns non-empty, start_link MUST return an error.
      # The current implementation returns {:ok, pid} — two MA processes could
      # run concurrently on different BEAM nodes sharing the same origin/main,
      # which is the split-brain catastrophe D-S4 / INV-ST-11 forbids.
      refute match?({:ok, _}, result),
             "INV-ST-11: MergeAuthority.start_link/1 MUST return {:error, _} when " <>
               "node_list_fun.() returns non-empty connected nodes #{inspect(simulated_peers)}. " <>
               "Two MA instances on different BEAM nodes sharing origin/main is the " <>
               "split-brain catastrophe SPEC-FACTORY-MERGE [C219] / distribution-readiness §1 " <>
               "forbids. Conformant implementation: accept node_list_fun: (-> [node()]) option " <>
               "(default &Node.list/0), call it in init/1, and return " <>
               "{:stop, {:multi_node_detected, nodes}} when non-empty. " <>
               "Got: #{inspect(result)}. " <>
               "Gap: MergeAuthority.init/1 (merge_authority.ex:114-178) does not accept " <>
               "or call node_list_fun; no Node.list/0 check exists anywhere in lib/tau/factory/."
    end

    @tag :inv_st_11
    test "INV-ST-11: start_link with node_list_fun returning [] MUST succeed (single-node BEAM)" do
      # Positive case: ensure the guard does not block startup on a genuine
      # single-node deployment.  node_list_fun.() returns [] — no peers visible.
      tmp_dir = Briefly.create!(type: :directory)
      work_path = setup_git_repo(tmp_dir)
      writer = start_writer(tmp_dir, "sng_pos")

      ma_name = :"test_ma_inv_st_11_pos_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_sng_tasks_pos_#{System.unique_integer([:positive])}"

      opts =
        base_opts(ma_name, tasks_name, writer, work_path) ++
          [node_list_fun: fn -> [] end]

      result = @merge_authority.start_link(opts)

      case result do
        {:ok, pid} ->
          on_exit(fn ->
            if Process.alive?(pid), do: Process.exit(pid, :kill)
          end)

        _ ->
          :ok
      end

      assert match?({:ok, _}, result),
             "INV-ST-11: MergeAuthority.start_link/1 MUST succeed when node_list_fun.() " <>
               "returns [] (no connected nodes — genuine single-node BEAM). Got: #{inspect(result)}."
    end
  end
end
