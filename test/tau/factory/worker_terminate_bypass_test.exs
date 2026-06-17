defmodule Tau.Factory.WorkerTerminateBypassTest do
  @moduledoc """
  Gating test for issue #610 — INV-ST-15 conformance: capture MUST be done
  by the independent monitor process (WorkspaceJanitor), not by terminate/2.

  ## The invariant (INV-ST-15)

  `terminate/2` MUST NOT be relied on for must-happen cleanup. Capture MUST
  be done by an independent monitor process that survives `:kill` and ALL
  exit reasons. Falsified by: a cleanup action being registered only in
  `terminate/2` and therefore missed on `:kill` or a supervisor `:shutdown`
  to a non-trapping child.

  ## What this test verifies

  When a Worker process is killed with `Process.exit(pid, :kill)`:

    1. `terminate/2` does NOT run (`:kill` is untrappable).
    2. The WorkspaceJanitor (independent monitor) receives the `:DOWN` signal.
    3. The janitor — as the SOLE capture agent — has the responsibility to
       preserve dirty workspace state when it cannot durably record the capture.
    4. If the janitor's Ledger write fails (infrastructure failure), the janitor
       MUST NOT reclaim the workspace — the dirty artifacts must survive so the
       operator can recover them manually.

  ## Why this must fail against current code

  `WorkspaceJanitor.handle_info/2` calls `reclaim_workspace(ws)` unconditionally
  after `capture_workspace/3` — even when capture returns `{:error, _}`.
  Because `terminate/2` does not run on `:kill`, the janitor is the ONLY agent
  that can preserve this state.  When the janitor unconditionally destroys the
  workspace on a capture failure, the dirty artifacts are permanently lost —
  they fall into none of {committed, captured, discarded_by_decision}.

  This test kills the Worker with `:kill` (INV-ST-15's key exit reason),
  injects a Ledger that always fails `capture/3`, and asserts the workspace
  directory still exists.  The assertion fails because the current code
  unconditionally reclaims the workspace.

  ## AC linkage
    - INV-ST-15: this test
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  @janitor Tau.Factory.WorkspaceJanitor
  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # FailingLedger — test-only GenServer that always returns {:error, _}
  # for capture/3 calls, simulating a real Exqlite infra failure.
  # All other calls return safe defaults so the Worker can start cleanly.
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
    # Simulate the infra-failure path: capture always fails.
    # This forces the janitor into its error branch.
    def handle_call({:capture, _worker_id, _attrs}, _from, state),
      do: {:reply, {:error, :simulated_ledger_failure}, state}

    # Pass-through all other calls so start-up is clean.
    def handle_call(_msg, _from, state), do: {:reply, {:ok, nil}, state}
  end

  # ---------------------------------------------------------------------------
  # Hermetic git repo helpers
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
    bin_path = Path.join(tmp_dir, "slow_inv_st15")

    # `exec cat` replaces the shell so SIGKILL reaches the actual blocking
    # process; `cat` with no args reads stdin and exits on EOF (Port close).
    # This avoids leaking orphaned grandchild processes that hold the Port
    # pipe FD open and stall BEAM shutdown after the suite finishes.
    File.write!(bin_path, """
    #!/bin/sh
    exec cat
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  # ---------------------------------------------------------------------------
  # INV-ST-15 — terminate/2 bypass: independent monitor must preserve workspace
  # ---------------------------------------------------------------------------

  describe "INV-ST-15 — terminate/2 bypass: independent monitor must not reclaim on capture failure" do
    @tag :inv_st_15
    test "INV-ST-15: Worker killed via :kill (terminate/2 bypassed) — janitor MUST preserve workspace when capture fails" do
      # Entry point: WorkerSupervisor.spawn/5 — the real user-facing path.
      # The path under test:
      #   WorkerSupervisor.spawn → Worker.init (registers with janitor) →
      #   Process.exit(worker_pid, :kill) → terminate/2 DOES NOT RUN →
      #   janitor receives :DOWN(:killed) → janitor runs capture →
      #   capture returns {:error, _} → janitor MUST NOT reclaim workspace.
      #
      # INV-ST-15 clause: "Capture MUST be done by an independent monitor
      # process that survives :kill and all exit reasons."
      #
      # The critical implication: because terminate/2 is bypassed by :kill,
      # the independent monitor is the SOLE agent responsible for cleanup.
      # If the monitor cannot safely capture (Ledger failure), it MUST preserve
      # the workspace rather than destroying dirty artifacts with no durable
      # record — a reclaim without capture is a silent data loss.
      #
      # Current code (workspace_janitor.ex) calls reclaim_workspace/1
      # unconditionally after the {:error, _} branch, destroying the workspace.
      # This test FAILS against current code: File.dir?(ws) returns false
      # because the janitor reclaimed the workspace despite capture failing.

      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_inv_st15_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir)

      n = System.unique_integer([:positive])

      # Failing ledger: capture/3 always returns {:error, :simulated_ledger_failure}.
      failing_ledger_name = :"inv_st15_failing_ledger_#{n}"

      {:ok, _} =
        start_supervised(
          {FailingLedger, name: failing_ledger_name},
          id: :"inv_st15_fl_sv_#{n}"
        )

      # Fleet (registry + supervisor).
      registry_name = :"inv_st15_reg_#{n}"
      sup_name = :"inv_st15_sup_#{n}"

      {:ok, _} =
        start_supervised(
          {@worker_registry, name: registry_name},
          id: :"inv_st15_rreg_#{n}"
        )

      {:ok, sup} =
        start_supervised(
          {@worker_supervisor, name: sup_name, registry: registry_name},
          id: :"inv_st15_rsup_#{n}"
        )

      # Janitor wired to the failing ledger.
      jan_name = :"inv_st15_jan_#{n}"

      {:ok, jan_pid} =
        start_supervised(
          {@janitor, ledger: failing_ledger_name, name: jan_name, report_to: self()},
          id: :"inv_st15_jan_sv_#{n}"
        )

      # Spawn the worker via the real entry point.
      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      assert Process.alive?(worker_pid), "INV-ST-15: worker must be alive before :kill"

      {:ok, ws} = GenServer.call(worker_pid, :get_ws)
      assert File.dir?(ws), "INV-ST-15: workspace must exist before :kill; ws=#{ws}"

      # Write a dirty untracked artifact so the workspace is non-trivially dirty.
      # This artifact must survive the :kill — it can only be recovered if the
      # workspace is preserved (not reclaimed) after a capture failure.
      artifact_content = "inv-st-15-artifact-#{System.unique_integer([:positive])}\n"
      artifact_path = Path.join(ws, "inv_st15_artifact.txt")
      File.write!(artifact_path, artifact_content)

      # Confirm the artifact is visible in git status (untracked).
      {status_out, _} =
        System.cmd("git", ["status", "--short"], cd: ws, stderr_to_stdout: true)

      assert String.contains?(status_out, "inv_st15_artifact.txt"),
             "INV-ST-15: setup — dirty artifact must appear in git status; " <>
               "status=#{inspect(status_out)}"

      # Monitor the worker BEFORE sending :kill so the :DOWN message arrives
      # in this test's mailbox regardless of timing.
      worker_ref = Process.monitor(worker_pid)

      # Kill the Worker with :kill.
      # terminate/2 does NOT run on :kill — it is untrappable.
      # The WorkspaceJanitor is the ONLY mechanism that observes this death.
      Process.exit(worker_pid, :kill)

      # Confirm the worker is truly dead by waiting for our own :DOWN.
      # The worker may already be dead (race), so accept :noproc too.
      receive do
        {:DOWN, ^worker_ref, :process, ^worker_pid, reason}
        when reason in [:killed, :noproc] ->
          :ok
      after
        5_000 -> flunk("INV-ST-15: worker did not die within 5s after :kill")
      end

      # Allow the janitor's :DOWN handler to run.
      # We do NOT assert on {:worker_exit, ...} because the current buggy
      # implementation may or may not deliver it after unconditional reclaim;
      # what matters is the workspace state.
      Process.sleep(2_000)

      # INV-ST-15 — core assertion:
      # The independent monitor (janitor) received the :DOWN for :kill
      # (terminate/2 was bypassed), attempted capture, got {:error, _} from
      # the failing ledger, and MUST NOT have reclaimed the workspace.
      #
      # Correct behaviour: capture failure → preserve workspace intact so
      # the operator can recover the dirty artifacts manually.
      #
      # Current buggy behaviour: unconditional reclaim_workspace(ws) call
      # after the {:error, err} branch destroys the workspace regardless,
      # making File.dir?(ws) return false — this assertion FAILS.
      assert File.dir?(ws),
             "INV-ST-15: capture failure on :kill path MUST NOT trigger reclaim. " <>
               "The independent monitor (WorkspaceJanitor) is the sole agent for " <>
               "workspace cleanup when terminate/2 is bypassed by :kill. " <>
               "When the Ledger write fails, the monitor MUST preserve the workspace " <>
               "rather than unconditionally destroying dirty artifacts. " <>
               "Workspace #{ws} was reclaimed despite capture returning {:error, _}. " <>
               "This violates INV-ST-15: cleanup registration in the monitor must be " <>
               "conditional on durable record success, never unconditional on :kill."

      # Secondary: the dirty artifact must be recoverable at the preserved workspace.
      assert File.exists?(artifact_path),
             "INV-ST-15: dirty artifact '#{artifact_path}' must still exist " <>
               "in the preserved workspace after a :kill with capture failure. " <>
               "The artifact was destroyed by unconditional reclaim, violating " <>
               "the independent-monitor contract for INV-ST-15."
    end
  end
end
