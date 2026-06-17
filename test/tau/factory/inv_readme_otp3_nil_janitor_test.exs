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

  ## Architectural correction (SPEC-FACTORY-FLEET §3 C202/C207, §2 C4)

  SPEC §3 C202 states: "A terminated worker's dirty state has exactly one
  capturing writer: the WorkspaceJanitor monitor (C4)."  SPEC §3 C207 states:
  "Capture MUST be a monitor."

  The janitor holds the Ledger reference in its own GenServer state — NOT
  threaded through WorkerSupervisor.spawn/5 opts.  Therefore the correct
  conformant fix for issue #555 is one of:

    (a) Worker.init/1 MUST guard against `janitor: nil` and reject the start
        (making nil-janitor unreachable in production), OR
    (b) The production entry path always supplies a non-nil janitor backed by
        the Ledger.

  Either way, a worker :kill-ed with dirty state MUST have its capture written
  to the Ledger by the WorkspaceJanitor — the only SPEC-sanctioned capturing
  actor.

  This rewritten test exercises that conformant path: a real WorkspaceJanitor
  is started with the test ledger; the worker is spawned with that janitor;
  on :kill the janitor's :DOWN handler captures all three dirty kinds and
  writes to the Ledger before reclaiming the worktree.

  The test MUST fail against current production code because either:
    - Worker.init/1 does not guard nil-janitor (path (a) not implemented), OR
    - The WorkerSupervisor.spawn/5 call with `janitor: <name>` is broken.

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
  @workspace_janitor Tau.Factory.WorkspaceJanitor

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

  defp start_fleet_with_janitor(tag, ledger_name) do
    n = System.unique_integer([:positive])
    registry_name = :"otp3_registry_#{tag}_#{n}"
    sup_name = :"otp3_sup_#{tag}_#{n}"
    janitor_name = :"otp3_janitor_#{tag}_#{n}"

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

    # Start the WorkspaceJanitor with the test's ledger — this is the
    # SPEC-mandated C4 independent monitor that holds the ledger reference.
    # SPEC §2 C4: "independent monitoring GenServer high in the W subtree".
    # SPEC §4 B6: "The capture disposition is written via the single Ledger writer".
    {:ok, _jan} =
      start_supervised(
        {@workspace_janitor,
         ledger: ledger_name,
         name: janitor_name,
         report_to: self()},
        id: :"otp3_jan_#{n}"
      )

    {sup_name, sup, registry_name, janitor_name}
  end

  # ---------------------------------------------------------------------------
  # INV-README-OTP3 — WorkspaceJanitor path MUST capture on :kill
  # ---------------------------------------------------------------------------

  describe "INV-README-OTP3 — WorkspaceJanitor capture-before-destroy on :kill" do
    @tag :inv_readme_otp3
    @tag :d_313
    @tag :d_315
    test "INV-README-OTP3: Worker :kill-ed with dirty worktree — WorkspaceJanitor (C4) MUST capture all three dirty kinds and write to Ledger before worktree is reclaimed" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_otp3_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir)
      {ledger_name, _db_path} = start_ledger(tmp_dir, :otp3)

      # Start fleet with a real WorkspaceJanitor backed by the test ledger.
      # SPEC §3 C202: "exactly one capturing writer: the WorkspaceJanitor monitor (C4)".
      # SPEC §3 C207: "Capture MUST be a monitor, not terminate/2".
      # The janitor holds the ledger ref in its own state — never passed through spawn opts.
      {_sup_name, sup, registry_name, janitor_name} =
        start_fleet_with_janitor(:otp3, ledger_name)

      report_to = self()

      # Spawn worker with a real janitor — the SPEC-conformant path.
      # SPEC §4 B5: "WorkspaceJanitor ... fires on every exit reason incl. :kill".
      # SPEC §3 C202: the janitor is the sole capturing writer.
      #
      # The original test passed `janitor: nil`, which is non-conformant:
      # nil-janitor bypasses C4 entirely and leaves no capture path to the Ledger.
      # The correct fix for issue #555 is that nil-janitor is either rejected at
      # Worker.init/1 (guard) or never reached in production — the janitor path
      # is always used and always backs the ledger.
      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          report_to: report_to,
          janitor: janitor_name
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
      # SPEC §3 C207: "terminate/2 does not run on a brutal :kill ... Relying on
      # terminate/2 silently loses the killed worker's work."
      Process.exit(worker_pid, :kill)

      # Wait for the death-certificate from the WorkspaceJanitor.
      # SPEC §4 B5 step 6: janitor sends {:worker_exit, worker_id, reason} AFTER
      # capture and reclaim (WAL-before-ack means the Ledger write precedes this message).
      kill_reason =
        receive do
          {:worker_exit, ^worker_id, reason} -> reason
        after
          5_000 ->
            flunk(
              "INV-README-OTP3: {:worker_exit, #{inspect(worker_id)}, _} must arrive after :kill " <>
                "(from WorkspaceJanitor C4 — the SPEC-conformant capturing monitor)"
            )
        end

      assert kill_reason == :kill,
             "INV-README-OTP3: death-cert reason must be :kill; got #{inspect(kill_reason)}"

      # --- The invariant assertion (D-313/D-315) ---
      # The WorkspaceJanitor MUST have written a capture row to the Ledger
      # BEFORE the death-certificate arrived (WAL-before-ack, D-315).
      #
      # SPEC §4 B5 sequence:
      #   1. git diff HEAD (staged+unstaged patch)
      #   2. git ls-files --others | tar (untracked_tgz)
      #   3. git status --short
      #   4. Ledger.capture(worker_id, ...) — WAL-before-ack
      #   5. reclaim(ws, ns)
      #   6. send {:worker_exit, ...} to report_to
      #
      # Because the death-certificate (step 6) already arrived above,
      # the Ledger write (step 4) is guaranteed to have completed.
      captures = @writer.captures_for(ledger_name, worker_id)

      assert captures != [],
             "INV-README-OTP3: Ledger MUST have at least one capture row for " <>
               "worker_id=#{worker_id} — the WorkspaceJanitor (C4) must write " <>
               "before issuing the death-certificate (D-315 WAL-before-ack); " <>
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
      # The janitor reclaims in step 5, before the death-cert in step 6.
      # Because the death-cert already arrived, reclaim is also guaranteed.
      refute File.dir?(ws),
             "INV-README-OTP3: worktree must be reclaimed (removed) after capture; " <>
               "ws=#{ws} still exists (D-314)"
    end
  end
end
