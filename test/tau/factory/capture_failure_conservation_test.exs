defmodule Tau.Factory.CaptureFailureConservationTest do
  @moduledoc """
  Gating test for issue #637 — D-334 capture-failure conservation gap.

  The audit finding (severity: high): in `WorkspaceJanitor.handle_info/2`,
  when `capture_workspace/3` returns `{:error, err}`, the janitor logs the
  error but then calls `reclaim_workspace(ws)` UNCONDITIONALLY, destroying
  all dirty artifacts.  This falsifies D-334's "never lost by omission"
  clause — the dirty state ends up in NONE of {committed, captured,
  discarded_by_decision}.

  Correct behaviour: a capture failure MUST NOT trigger reclaim.  The
  worktree must remain intact so the operator can recover the artifacts
  manually; the absence of reclaim is itself the conservation proof.

  ## Entry point

  The real user-facing path under test:
    `WorkspaceJanitor.register/6` (registers the worker pid + ws)
    → `Process.exit(worker_pid, :kill)` (drives the `:DOWN` handler)
    → `capture_workspace/3` returns `{:error, _}` (via a failing ledger)
    → assert `File.dir?(ws)` remains true (reclaim was NOT called)

  ## AC linkage
    - D-334: the single test in this file
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  @janitor Tau.Factory.WorkspaceJanitor
  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # FailingLedger — a test-only GenServer that always returns {:error, _} for
  # {:capture, ...} calls, simulating the reachable Exqlite failure path
  # (ledger/writer.ex:640–649).  All other calls return sensible defaults so
  # the janitor and worker can start cleanly; only the capture call fails.
  # ---------------------------------------------------------------------------

  defmodule FailingLedger do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, %{}, name: name)
    end

    def child_spec(opts) do
      name = Keyword.fetch!(opts, :name)

      %{
        id: name,
        start: {__MODULE__, :start_link, [opts]},
        type: :worker,
        restart: :permanent,
        shutdown: 5_000
      }
    end

    @impl GenServer
    def init(_opts), do: {:ok, %{}}

    @impl GenServer
    # Simulate the {error, reason} return path from do_capture/3 — the path
    # the issue identifies as the unguarded failure that falsifies D-334.
    def handle_call({:capture, _worker_id, _attrs}, _from, state),
      do: {:reply, {:error, :simulated_ledger_failure}, state}

    # Passthrough defaults for all other calls the janitor/worker may make.
    def handle_call(_msg, _from, state), do: {:reply, {:ok, nil}, state}
  end

  # ---------------------------------------------------------------------------
  # Hermetic git repo setup (same pattern as workspace_janitor_test.exs)
  # ---------------------------------------------------------------------------

  defp setup_git_repo(tmp_dir) do
    repo_dir = Path.join(tmp_dir, "repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_dir)

    git = fn args ->
      System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    end

    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])

    File.write!(Path.join(repo_dir, "README"), "initial\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial commit"])
    {sha, 0} = git.(["rev-parse", "HEAD"])

    %{repo_dir: repo_dir, base_ref: String.trim(sha)}
  end

  defp slow_agent_bin(tmp_dir) do
    bin_path = Path.join(tmp_dir, "slow_capfail_agent")

    File.write!(bin_path, """
    #!/bin/sh
    exec cat
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  # ---------------------------------------------------------------------------
  # D-334 — Capture-failure conservation
  # ---------------------------------------------------------------------------

  describe "D-334 — capture-failure conservation" do
    @tag :d_334
    test "D-334: when capture_workspace returns {:error,_}, reclaim MUST NOT run — dirty worktree must be preserved" do
      # This test exercises the failure path identified by issue #637:
      #
      #   handle_info :DOWN
      #     capture_result = capture_workspace(ledger, worker_id, ws)
      #     case capture_result do
      #       {:ok, _} -> :ok
      #       {:error, err} -> Logger.error(...)   # <-- current code: falls through
      #     end
      #     reclaim_workspace(ws)   # <-- UNCONDITIONAL — the D-334 violation
      #
      # With a FailingLedger that returns {:error, :simulated_ledger_failure},
      # the current code deletes the worktree (reclaim runs), so
      # `File.dir?(ws)` returns false — the assertion below fails, proving
      # the invariant is violated against current production code.
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_capfail334_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir)

      # Start the failing ledger (responds {:error, :simulated_ledger_failure}
      # to every {:capture, ...} call).
      n = System.unique_integer([:positive])
      failing_ledger_name = :"failing_ledger_#{n}"

      {:ok, _} =
        start_supervised(
          {FailingLedger, name: failing_ledger_name},
          id: :"failing_ledger_sv_#{n}"
        )

      # Start fleet (registry + supervisor).
      registry_name = :"capfail_reg_#{n}"
      sup_name = :"capfail_sup_#{n}"

      {:ok, _} =
        start_supervised(
          {@worker_registry, name: registry_name},
          id: :"capfail_rreg_#{n}"
        )

      {:ok, sup} =
        start_supervised(
          {@worker_supervisor, name: sup_name, registry: registry_name},
          id: :"capfail_rsup_#{n}"
        )

      # Start janitor wired to the failing ledger.
      # WorkspaceJanitor always registers under __MODULE__ (Tau.Factory.WorkspaceJanitor)
      # regardless of the :name opt (which is only used as the supervisor child id).
      # Pass the pid directly so we can reference the exact instance we started.
      report_to = self()
      jan_name = :"capfail_jan_#{n}"

      {:ok, jan_pid} =
        start_supervised(
          {@janitor, ledger: failing_ledger_name, name: jan_name, report_to: report_to},
          id: :"capfail_jan_sv_#{n}"
        )

      # Spawn a worker.
      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      assert Process.alive?(worker_pid), "D-334: worker must be alive before kill"

      {:ok, ws} = GenServer.call(worker_pid, :get_ws)
      assert File.dir?(ws), "D-334: worktree must exist before kill; ws=#{ws}"

      # Write a dirty untracked artifact so the worktree is non-trivially dirty.
      untracked_content = "conserved-artifact-#{System.unique_integer([:positive])}\n"
      File.write!(Path.join(ws, "conserved.txt"), untracked_content)

      # Kill the worker — drives the :DOWN handler in the janitor.
      Process.exit(worker_pid, :kill)

      # Allow enough time for the :DOWN handler to run to completion (or crash).
      # We do NOT assert {:worker_exit, ...} here because the current buggy code
      # may reach the death-cert send (after the reclaim) or may not (if it
      # crashes before); what matters is the worktree state.
      Process.sleep(2_000)

      # D-334 invariant: capture failed → reclaim MUST NOT have run.
      # The worktree must still exist so the dirty artifact is recoverable.
      #
      # Against current production code this assertion FAILS because
      # reclaim_workspace/1 is called unconditionally after the {:error, _}
      # branch, destroying the worktree and the conserved.txt artifact.
      assert File.dir?(ws),
             "D-334: capture failure must NOT trigger reclaim — " <>
               "worktree #{ws} must remain intact so dirty artifacts are recoverable; " <>
               "File.dir? returned false, which means reclaim_workspace ran despite " <>
               "capture returning {:error, :simulated_ledger_failure}. " <>
               "This falsifies D-334: dirty(w) ≠ committed ⊎ captured ⊎ discarded_by_decision — " <>
               "the artifact ended up in none of the three sets (silently lost)."

      assert File.exists?(Path.join(ws, "conserved.txt")),
             "D-334: the dirty untracked artifact (conserved.txt) must still be " <>
               "accessible in the worktree after a capture failure; it was destroyed."
    end
  end
end
