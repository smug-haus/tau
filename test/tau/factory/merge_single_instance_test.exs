defmodule Tau.Factory.MergeSingleInstanceTest do
  @moduledoc """
  Gating test for issue #594 (INV-DIST-R5 — MergeAuthority is node-local,
  single-instance with concurrency-1; no distributed lock).

  INV-DIST-R5 statement:
    "The merge CAS (M) is node-local and single-instance with concurrency-1;
     no distributed lock. Falsified by: finding a design path that runs two M
     instances concurrently or a node-crossing CAS."

  Structural mechanism (merge_authority.ex:73-76):
    `:gen_statem.start_link({:local, name}, __MODULE__, opts, [])` — the
    `{:local, name}` registration guarantees that a second attempt to start a
    MergeAuthority under the same name on the same node is rejected.

  The PARTIAL verdict on INV-DIST-R5 arises because a second MA started under
  a DIFFERENT name targeting the SAME `repo_dir` is not rejected.  The
  concurrency-1 invariant asserts a single writer of `origin/main`; the
  `{:local, name}` registration only prevents duplicate-name instances, NOT
  duplicate-repo instances.  There is no per-repo exclusivity guard in
  `MergeAuthority.init/1`.

  This test confirms the gap: starting a second MA with a different name but
  the same `repo_dir` MUST be rejected (so that only one M instance per repo
  is permitted on the node), but the current implementation permits it —
  returning `{:ok, pid}` for the second start_link.

  The failing assertion: `refute match?({:ok, _}, second_result)` — the
  second start_link currently returns `{:ok, pid}` (not an error), falsifying
  the per-repo single-instance invariant that INV-DIST-R5 documents.

  AC linkage: @tag :inv_dist_r5
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  @merge_authority Tau.Factory.MergeAuthority
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_writer(tmp_dir, suffix) do
    db_path = Path.join(tmp_dir, "test_#{suffix}.db")
    writer_name = :"test_ma_si_writer_#{suffix}_#{System.unique_integer([:positive])}"

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

  defp blocking_build_fun do
    fn _units, _base ->
      # Block indefinitely — keeps the MA in :integrating state.
      receive do
        :never -> {:built, [], "base", "tip"}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # INV-DIST-R5: per-repo single-instance enforcement
  # ---------------------------------------------------------------------------

  describe "INV-DIST-R5 — starting a second MergeAuthority for the same repo_dir must be rejected" do
    @tag :inv_dist_r5
    test "INV-DIST-R5: second start_link with different name but same repo_dir must return an error, not {:ok, pid}" do
      tmp_dir = Briefly.create!(type: :directory)
      work_path = setup_git_repo(tmp_dir)

      writer1 = start_writer(tmp_dir, "w1")
      writer2 = start_writer(tmp_dir, "w2")

      ma_name_1 = :"test_ma_inv_dist_r5_a_#{System.unique_integer([:positive])}"
      ma_name_2 = :"test_ma_inv_dist_r5_b_#{System.unique_integer([:positive])}"

      tasks_name_1 = :"test_ma_si_tasks_1_#{System.unique_integer([:positive])}"
      tasks_name_2 = :"test_ma_si_tasks_2_#{System.unique_integer([:positive])}"

      opts_1 = [
        name: ma_name_1,
        ledger: writer1,
        repo_dir: work_path,
        required_halves: [:critic, :reviewer],
        tasks_name: tasks_name_1,
        build_fun: blocking_build_fun()
      ]

      opts_2 = [
        name: ma_name_2,
        ledger: writer2,
        # SAME repo_dir — this is the gap: no per-repo exclusion guard.
        repo_dir: work_path,
        required_halves: [:critic, :reviewer],
        tasks_name: tasks_name_2,
        build_fun: blocking_build_fun()
      ]

      # First MA starts successfully.
      first_result = @merge_authority.start_link(opts_1)

      assert match?({:ok, _}, first_result),
             "INV-DIST-R5: first start_link must succeed; got #{inspect(first_result)}"

      {:ok, first_pid} = first_result

      on_exit(fn ->
        if Process.alive?(first_pid), do: Process.exit(first_pid, :kill)
      end)

      # Second MA with a DIFFERENT name but the SAME repo_dir:
      # INV-DIST-R5 requires single-instance per repo (the invariant is about the
      # sole-writer-of-origin/main property, not only about duplicate names).
      # A conformant implementation MUST reject a second MA for the same repo_dir,
      # e.g., by registering the repo_dir path in a per-node ETS table in init/1
      # and returning {:stop, {:already_registered, repo_dir}} on collision.
      #
      # Current implementation: init/1 does not check repo_dir for exclusivity
      # (merge_authority.ex:99-153). The second start_link therefore returns
      # {:ok, pid2} — a NEW, live MA process that shares repo_dir with the first.
      # This violates INV-DIST-R5's concurrency-1 / sole-writer claim on this node.
      second_result = @merge_authority.start_link(opts_2)

      # Clean up any process that was started before asserting.
      case second_result do
        {:ok, pid2} ->
          on_exit(fn ->
            if Process.alive?(pid2), do: Process.exit(pid2, :kill)
          end)

        _ ->
          :ok
      end

      # FAILING ASSERTION (INV-DIST-R5):
      # The second start_link MUST NOT return {:ok, _}. A conformant implementation
      # returns {:error, {:already_registered, ^work_path}} or similar, enforcing
      # per-repo single-instance on this node.
      #
      # Currently fails: init/1 has no repo_dir exclusion guard, so the call
      # returns {:ok, pid2} — two MA instances for the same repo are running.
      refute match?({:ok, _}, second_result),
             "INV-DIST-R5: starting a second MergeAuthority for the same repo_dir " <>
               "(even with a different registered name) MUST return an error, not {:ok, _}. " <>
               "Two MA instances for the same repo_dir violates the concurrency-1 / " <>
               "sole-writer-of-origin/main invariant on this node " <>
               "(SPEC-FACTORY-MERGE §4 B4 / [C200], D-302). " <>
               "Got: #{inspect(second_result)}. " <>
               "Gap: MergeAuthority.init/1 (merge_authority.ex:99-153) performs no " <>
               "per-repo_dir exclusion check; add a node-local ETS-backed repo registry " <>
               "owned by MergeAuthority (or its supervisor) that rejects duplicate repo_dir " <>
               "registrations on init."
    end
  end
end
