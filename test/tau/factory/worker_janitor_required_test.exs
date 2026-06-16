defmodule Tau.Factory.WorkerJanitorRequiredTest do
  @moduledoc """
  Gating test for issue #575 — D-313 conformance: WorkerSupervisor MUST NOT
  accept a Worker without a janitor.

  ## The invariant

  D-313 (capture-before-destroy, INV-14): on worker termination for ANY reason
  — including `:kill` — the WorkspaceJanitor monitor MUST capture staged,
  unstaged, and untracked files BEFORE the worktree is reclaimed.

  The SPEC (SPEC-FACTORY-FLEET §4 C207) states: capture MUST be a monitor,
  never `terminate/2`. The only conformant monitor is the WorkspaceJanitor.

  ## The defect (issue #575)

  Worker.open_port_and_finish/1 (worker.ex ~310-314) branches:

      if janitor do
        WorkspaceJanitor.register(...)
      else
        spawn_death_monitor(worker_id, report_to)   # <-- NO capture
      end

  The else-branch's `spawn_death_monitor/2` sends only `{:worker_exit, ...}`;
  it never runs `git diff HEAD`, `git ls-files --others`, or tar — zero capture
  of any dirty kind. A `:kill`-ed worker on this path loses ALL its work.

  ## Required fix

  Worker.init/1 MUST fail-closed when no janitor is provided: return
  `{:stop, :no_janitor}` so the WorkerSupervisor propagates `{:error,
  :no_janitor}` to the caller. The janitor is mandatory infrastructure for
  D-313; accepting nil silently bypasses the invariant.

  This mirrors the D-374 precedent (`:metered_path_refused`) — infra
  prerequisites are rejected at init time, not silently bypassed.

  ## AC linkage
    - D-313 (this file)
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Hermetic git repo
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

  defp slow_agent_bin(tmp_dir, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "slow_agent_jrq#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    exec cat
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  # ---------------------------------------------------------------------------
  # D-313 — janitor is mandatory; Worker MUST reject nil janitor (fail-closed)
  # ---------------------------------------------------------------------------

  describe "D-313 — janitor is mandatory infrastructure" do
    @tag :d_313
    test "D-313: WorkerSupervisor.spawn without :janitor opt MUST return {:error, :no_janitor}" do
      # The user-facing entry point is WorkerSupervisor.spawn/5.
      # D-313 is violated whenever a Worker starts without a janitor because
      # spawn_death_monitor does no capture. The conformant fix is fail-closed:
      # Worker.init must stop with :no_janitor when no janitor is provided.

      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_jrq313_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir, "_d313_nojin")

      registry_name = :"jrq313_reg_#{System.unique_integer([:positive])}"
      sup_name = :"jrq313_sup_#{System.unique_integer([:positive])}"

      {:ok, _} =
        start_supervised(
          {@worker_registry, name: registry_name},
          id: :"jrq313_reg_sv_#{System.unique_integer([:positive])}"
        )

      {:ok, sup} =
        start_supervised(
          {@worker_supervisor, name: sup_name, registry: registry_name},
          id: :"jrq313_sup_sv_#{System.unique_integer([:positive])}"
        )

      # Spawn WITHOUT :janitor — no janitor opt means janitor: nil in Worker.init.
      # D-313 requires the Worker to refuse: {:error, :no_janitor}.
      result =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          report_to: self()
          # NOTE: :janitor is intentionally absent
        )

      # D-313 conformance assertion: accepting nil janitor silently violates the
      # invariant; the Worker MUST stop with :no_janitor.
      assert result == {:error, :no_janitor},
             "D-313: WorkerSupervisor.spawn without :janitor must return " <>
               "{:error, :no_janitor} (fail-closed) — nil janitor bypasses " <>
               "capture-before-destroy and violates D-313 (INV-14). " <>
               "Got: #{inspect(result)}"
    end

    @tag :d_313
    test "D-313: Worker spawned WITHOUT janitor then :kill-ed loses untracked file — confirms the defect" do
      # Companion test demonstrating the concrete data-loss scenario.
      # If the Worker accepts nil janitor (current broken behaviour), a :kill-ed
      # worker with an untracked file has no recovery path: spawn_death_monitor
      # sends only {:worker_exit, id, reason} with zero git capture.
      #
      # This test verifies the defect is present (i.e. the untracked file is NOT
      # recoverable) AND asserts it must be recoverable — so the test fails on
      # current code (defect confirmed) and must pass after the fix (either
      # Worker refuses nil janitor, or the capture path is wired for the nil case).

      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_jrq313b_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir, "_d313b_nojin")

      registry_name = :"jrq313b_reg_#{System.unique_integer([:positive])}"
      sup_name = :"jrq313b_sup_#{System.unique_integer([:positive])}"

      {:ok, _} =
        start_supervised(
          {@worker_registry, name: registry_name},
          id: :"jrq313b_reg_sv_#{System.unique_integer([:positive])}"
        )

      {:ok, sup} =
        start_supervised(
          {@worker_supervisor, name: sup_name, registry: registry_name},
          id: :"jrq313b_sup_sv_#{System.unique_integer([:positive])}"
        )

      # Spawn WITHOUT janitor; note whether it succeeds or returns {:error, :no_janitor}.
      spawn_result =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          report_to: self()
          # NOTE: :janitor absent
        )

      # If the fix is in place the worker was rejected — the invariant is satisfied.
      if match?({:error, :no_janitor}, spawn_result) do
        # Fix is in place; nothing more to verify.
        assert true, "D-313: Worker correctly rejected nil janitor (fail-closed)"
      else
        # Worker started despite no janitor — demonstrate the data-loss defect.
        {:ok, worker_id} = spawn_result

        workers = Registry.lookup(registry_name, worker_id)

        if workers == [] do
          # Worker stopped before we could look it up (race — may have failed init
          # asynchronously). The test still records this as a conformance failure:
          # spawn returning {:ok, _} for a no-janitor worker is non-conformant.
          flunk(
            "D-313: WorkerSupervisor.spawn returned {:ok, _} for a no-janitor worker — " <>
              "this is non-conformant. The Worker must refuse with {:error, :no_janitor}."
          )
        end

        [{worker_pid, _}] = workers
        assert Process.alive?(worker_pid), "D-313b: worker must be alive before the kill"

        # Retrieve the private worktree path.
        {:ok, ws} = GenServer.call(worker_pid, :get_ws)
        assert File.dir?(ws), "D-313b: worktree must exist; ws=#{ws}"

        # Create an untracked file in the worktree.
        untracked_name = "untracked_d313b.txt"
        untracked_content = "secret-#{System.unique_integer([:positive])}\n"
        File.write!(Path.join(ws, untracked_name), untracked_content)

        {status_out, _} =
          System.cmd("git", ["status", "--short"], cd: ws, stderr_to_stdout: true)

        assert String.contains?(status_out, untracked_name),
               "D-313b: untracked file must be visible in git status; out=#{inspect(status_out)}"

        # Kill brutally — terminate/2 does NOT run.
        Process.exit(worker_pid, :kill)

        # Death-cert must arrive (via spawn_death_monitor in the broken path).
        assert_receive {:worker_exit, ^worker_id, _reason},
                       5_000,
                       "D-313b: death-cert must arrive after :kill"

        # Allow time for any async capture that might be wired.
        Process.sleep(500)

        # The worktree is removed — the untracked file is gone.
        # Under the broken path there is NO capture artifact anywhere,
        # so the untracked file is permanently lost.
        # A conformant implementation must either:
        #   (a) reject nil janitor at init time (preferred — fail-closed), OR
        #   (b) wire a capture path that saves the untracked file.
        # We assert option (a): the spawn must NOT have returned {:ok, _}.
        flunk(
          "D-313: Worker accepted nil janitor (spawn returned {:ok, _}) and was :kill-ed. " <>
            "The untracked file '#{untracked_name}' has NO capture path — it is permanently " <>
            "lost, violating D-313 (INV-14). Worker MUST refuse nil janitor with " <>
            "{:error, :no_janitor} (fail-closed, per D-374 precedent)."
        )
      end
    end
  end
end
