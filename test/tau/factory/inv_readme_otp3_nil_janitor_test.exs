defmodule Tau.Factory.InvReadmeOtp3NilJanitorTest do
  @moduledoc """
  Gating test for issue #555 — INV-README-OTP3 conformance.

  The invariant (SPEC-FACTORY-FLEET §3 C207, B5; SPEC-FACTORY-CORE D-315):

    > A worker's uncommitted work MUST be captured by an independent monitor
    > (not terminate/2, which misses :kill).

  The audit finding (issue #555): when `Worker.start_link` is called with
  `janitor: nil` (or without a `:janitor` key), the nil-janitor path
  (`spawn_death_monitor/2`, worker.ex lines 310-313) fires a `:DOWN`-based
  monitor that delivers `{:worker_exit, …}` to `report_to` on `:kill`, but
  performs NO capture sequence — no `git diff HEAD`, no untracked-file tar,
  no Ledger write.  The nil-janitor path is reachable in production because
  `Worker.init/1` has no guard requiring a non-nil janitor.

  This test asserts the FULL conformant behaviour the invariant documents:
  a worker started via the real `WorkerSupervisor.spawn/5` entry point with
  `janitor: nil`, holding an untracked file and a staged change in its private
  worktree, MUST have its uncommitted work captured (all three dirty kinds)
  before the worktree is reclaimed — regardless of whether a janitor was
  supplied.

  The test MUST fail against current production code (the nil-janitor path
  has no capture path today).  It exists to gate the fix that closes #555.

  ## AC/D-NNN linkage

  - @tag :inv_readme_otp3 — the invariant id from issue #555
  - D-313: capture-before-destroy, all three dirty kinds
  - D-314: worktree reclaimed after capture (not leaked)
  - D-315: capture disposition written to Ledger WAL-before-ack (RPO=0)
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :inv_readme_otp3

  @writer Tau.Factory.Ledger.Writer
  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Helpers
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

    readme_path = Path.join(repo_dir, "README")
    File.write!(readme_path, "initial\n")
    {_, 0} = git.(["add", "README"])

    {staged, _} = git.(["diff", "--cached", "--name-only"])

    unless String.contains?(staged, "README") do
      raise "setup_git_repo: git add did not stage README; staged=#{inspect(staged)}"
    end

    {_, 0} = git.(["commit", "-m", "initial commit"])
    {sha, 0} = git.(["rev-parse", "HEAD"])
    base_ref = String.trim(sha)

    %{repo_dir: repo_dir, base_ref: base_ref}
  end

  # Blocking agent that stays alive until killed.  Uses `exec cat` so the
  # BEAM's SIGKILL on Port close hits `cat` directly — no orphaned grandchild.
  defp slow_agent_bin(tmp_dir, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "slow_agent_otp3#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    exec cat
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp start_ledger(tmp_dir, tag) do
    n = System.unique_integer([:positive])
    db_path = Path.join(tmp_dir, "ledger_otp3_#{tag}_#{n}.db")
    name = :"ledger_otp3_#{tag}_#{n}"

    {:ok, _pid} =
      start_supervised(
        {@writer, db_path: db_path, name: name},
        id: :"ledger_sv_otp3_#{n}"
      )

    {name, db_path}
  end

  defp start_fleet(tag) do
    n = System.unique_integer([:positive])
    registry_name = :"otp3_registry_#{tag}_#{n}"
    sup_name = :"otp3_sup_#{tag}_#{n}"

    {:ok, _reg} =
      start_supervised(
        {@worker_registry, name: registry_name},
        id: :"otp3_reg_#{n}"
      )

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"otp3_sup_sv_#{n}"
      )

    {sup_name, sup, registry_name}
  end

  # ---------------------------------------------------------------------------
  # INV-README-OTP3 — nil-janitor path MUST still capture on :kill
  # ---------------------------------------------------------------------------

  describe "INV-README-OTP3 — nil-janitor path: capture-before-destroy on :kill" do
    @tag :inv_readme_otp3
    @tag :d_313
    @tag :d_315
    test "INV-README-OTP3: Worker started with janitor: nil, :kill-ed with dirty worktree — capture (all three kinds) MUST be written to Ledger before worktree is reclaimed" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_otp3_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir)
      {ledger_name, _db_path} = start_ledger(tmp_dir, :otp3)
      {_sup_name, sup, registry_name} = start_fleet(:otp3)
      report_to = self()

      # Spawn worker with janitor: nil — the nil-janitor path under test.
      # This exercises the real entry point (WorkerSupervisor.spawn/5), not a
      # hand-built Worker struct.
      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          report_to: report_to,
          janitor: nil
        )

      # Resolve live worker pid via registry key (C218 — no stored pids).
      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      assert Process.alive?(worker_pid), "INV-README-OTP3: worker must be alive before kill"

      # Obtain the worker's private worktree path.
      # PIN: Worker exposes ws via GenServer.call(pid, :get_ws) :: {:ok, String.t()}
      {:ok, ws} = GenServer.call(worker_pid, :get_ws)
      assert File.dir?(ws), "INV-README-OTP3: worker's private worktree must exist; ws=#{ws}"

      # Create dirty state: a staged change + an untracked file.
      tracked_path = Path.join(ws, "README")
      File.write!(tracked_path, "modified by worker\n")
      {_, 0} = System.cmd("git", ["add", "README"], cd: ws, stderr_to_stdout: true)

      untracked_name = "untracked_otp3_#{System.unique_integer([:positive])}.txt"
      untracked_content = "untracked content #{System.unique_integer([:positive])}"
      File.write!(Path.join(ws, untracked_name), untracked_content)

      # Verify dirty state exists before kill.
      {status_out, 0} = System.cmd("git", ["status", "--short"], cd: ws, stderr_to_stdout: true)

      assert String.contains?(status_out, untracked_name),
             "INV-README-OTP3: untracked file must appear in git status before kill; " <>
               "status=#{inspect(status_out)}"

      # Kill the worker with :kill — the exact exit reason terminate/2 misses.
      Process.exit(worker_pid, :kill)

      # Wait for the death-certificate.
      kill_reason =
        receive do
          {:worker_exit, ^worker_id, reason} -> reason
        after
          5_000 ->
            flunk(
              "INV-README-OTP3: {:worker_exit, #{inspect(worker_id)}, _} must arrive after :kill"
            )
        end

      assert kill_reason == :kill,
             "INV-README-OTP3: death-cert reason must be :kill; got #{inspect(kill_reason)}"

      # --- The invariant assertion ---
      # The nil-janitor path MUST have written a capture row to the Ledger
      # BEFORE the death-certificate arrived (WAL-before-ack, D-315).
      #
      # This is the assertion that currently FAILS: spawn_death_monitor sends
      # {:worker_exit, ...} but writes nothing to the Ledger.
      captures = @writer.captures_for(ledger_name, worker_id)

      assert length(captures) >= 1,
             "INV-README-OTP3: Ledger MUST have at least one capture row for " <>
               "worker_id=#{worker_id} — the nil-janitor path does not write to the Ledger; " <>
               "captures=#{inspect(captures)}"

      capture = List.first(captures)

      assert is_binary(capture.patch),
             "INV-README-OTP3: capture.patch must be a binary; got #{inspect(capture.patch)}"

      assert byte_size(capture.patch) > 0,
             "INV-README-OTP3: capture.patch must be non-empty (staged change present); " <>
               "patch=#{inspect(capture.patch)}"

      assert is_binary(capture.status),
             "INV-README-OTP3: capture.status must be a binary"

      assert byte_size(capture.status) > 0,
             "INV-README-OTP3: capture.status must be non-empty; status=#{inspect(capture.status)}"

      assert capture.untracked_tgz != nil,
             "INV-README-OTP3: capture.untracked_tgz must be non-nil " <>
               "(untracked file was present); got nil"

      assert is_binary(capture.untracked_tgz),
             "INV-README-OTP3: capture.untracked_tgz must be a binary"

      assert byte_size(capture.untracked_tgz) > 0,
             "INV-README-OTP3: capture.untracked_tgz must be non-empty"

      # Worktree MUST be reclaimed after capture (D-314 / INV-15).
      # Allow a brief settle for any async reclaim path.
      Process.sleep(200)

      refute File.dir?(ws),
             "INV-README-OTP3: worktree must be reclaimed (removed) after capture; " <>
               "ws=#{ws} still exists"
    end
  end
end
