defmodule Tau.Factory.InvSt14WalBeforeAckTest do
  @moduledoc """
  Gating test for issue #562 — INV-ST-14 (Clause B).

  ## Invariant

  > Every factory decision MUST be WAL-committed to SQLite before its effect is
  > visible. A worker's uncommitted work MUST be captured (staged+unstaged+untracked)
  > by a monitor before reclaim. Restart = recovery everywhere. Falsified by: a
  > factory decision taking effect before the Ledger write completes, or a worker
  > reclaim happening before capture.

  Verdict: PARTIAL — Clause A (capture-before-reclaim at the filesystem level) is
  enforced by `workspace_janitor_test.exs` and `artifact_conservation_test.exs`.

  ## This file: Clause B — WAL-committed before the death cert is received

  The INV-ST-14 statement says *"every factory decision MUST be WAL-committed to
  SQLite before its effect is visible."*

  For `WorkspaceJanitor`, the **effect** is the death certificate
  `{:worker_exit, worker_id, reason}` that the janitor sends to `report_to`. The
  Coordinator treats receipt of the death cert as the authoritative signal that a
  worker is gone. INV-ST-14 Clause B requires: by the time the death cert arrives,
  the capture row MUST already be WAL-committed and readable in the Ledger.

  The existing D-313 and D-334 tests verify:
  - The capture is written before reclaim (filesystem ordering — Clause A).
  - The capture row survives a Writer restart (durability — D-315 via D-334).

  Neither test asserts the DIRECT ordering guarantee: **that the capture row is
  readable in the Ledger in the same synchronous step that receives the death cert**
  — i.e., without polling, immediately after the death cert arrives, before any
  subsequent process step.

  `workspace_janitor.ex` at lines 162–178 executes, in order:
    1. `capture_workspace/3` → calls `Writer.capture/3` (a synchronous GenServer.call)
    2. `reclaim_workspace/1` (filesystem side-effect)
    3. `send(report_to, {:worker_exit, worker_id, reason})` (the death cert)

  The WAL-before-ack contract of `Writer.capture/3` (D-315, `synchronous=FULL`)
  guarantees the row is on disk when `capture_workspace/3` returns. Steps 2 and 3
  follow synchronously in the janitor's message-processing loop. Therefore, when
  the death cert is received by the test process, the row MUST already be in the
  Ledger.

  This test asserts that directly: immediately after `assert_receive
  {:worker_exit,...}`, it calls `Writer.captures_for/2` and asserts the row is
  already present — without any polling or sleep. If the janitor sends the death
  cert before calling `Writer.capture/3`, or if `Writer.capture/3` returns before
  the WAL is committed, this test will fail (either the row is missing or not yet
  visible).

  ## Why this is the MISSING test (fail-before validity)

  The current production code at `workspace_janitor.ex` lines 162–178 sends the
  death cert AFTER `capture_workspace/3` and `reclaim_workspace/1`. So this test
  passes against the correct implementation.

  However, if an implementer restructures the janitor to send the death cert
  BEFORE calling `Writer.capture/3` (violating INV-ST-14 Clause B), this test will
  fail: `captures_for/2` will return `[]` immediately after the death cert, because
  the Ledger write has not yet happened.

  This test is the MISSING gating oracle for Clause B that makes INV-ST-14's
  coverage complete: it asserts the causal ordering "write before notification"
  that the existing tests only indirectly imply via polling.

  ## Note on the inverted fail-before expectation

  This file exercises INV-ST-14 Clause B. The production code ALREADY implements
  the correct ordering. This test PASSES against the current codebase — it closes
  the coverage gap so that any future refactor that breaks the ordering (sends
  death cert before WAL commit) will be caught by this test FAILING.

  The "fail-before" property for this test is: the test fails if the ordering
  invariant is violated. It is a regression oracle, not a greenfield test. This
  is appropriate because PARTIAL means the invariant is implemented but untested.

  ## AC / D-NNN linkage

    - INV-ST-14 (Clause B) — WAL-committed before effect (death cert) visible
    - D-315 — RPO=0, `synchronous=FULL` WAL-before-ack
    - D-313 / D-334 — capture-before-reclaim (Clause A, cross-ref)

  See also: `workspace_janitor_test.exs` (D-313), `artifact_conservation_test.exs`
  (D-334), `ledger_durability_test.exs` (D-315 restart).
  """

  use ExUnit.Case, async: false

  @moduletag :inv_st_14
  @moduletag :capture_log

  @writer Tau.Factory.Ledger.Writer
  @janitor Tau.Factory.WorkspaceJanitor
  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Git repo and agent-bin helpers (mirror workspace_janitor_test.exs idiom)
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
    bin_path = Path.join(tmp_dir, "slow_inv14#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    exec cat
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp start_ledger(tmp_dir, tag) do
    n = System.unique_integer([:positive])
    db_path = Path.join(tmp_dir, "ledger_inv14_#{tag}_#{n}.db")
    name = :"ledger_inv14_#{tag}_#{n}"

    {:ok, _} =
      start_supervised(
        {@writer, db_path: db_path, name: name},
        id: :"ledger_inv14_sv_#{n}"
      )

    name
  end

  defp start_fleet(tag) do
    n = System.unique_integer([:positive])
    registry_name = :"inv14_reg_#{tag}_#{n}"
    sup_name = :"inv14_sup_#{tag}_#{n}"

    {:ok, _} =
      start_supervised(
        {@worker_registry, name: registry_name},
        id: :"inv14_rreg_#{n}"
      )

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"inv14_rsup_#{n}"
      )

    {sup_name, sup, registry_name}
  end

  defp start_janitor(ledger, tag, report_to \\ nil) do
    n = System.unique_integer([:positive])
    name = :"inv14_janitor_#{tag}_#{n}"

    opts = [ledger: ledger, name: name]
    opts = if report_to, do: Keyword.put(opts, :report_to, report_to), else: opts

    {:ok, pid} =
      start_supervised(
        {@janitor, opts},
        id: :"inv14_jan_sv_#{n}"
      )

    {name, pid}
  end

  # ---------------------------------------------------------------------------
  # INV-ST-14 Clause B — capture row WAL-committed BEFORE death cert is sent
  # ---------------------------------------------------------------------------
  #
  # The death cert ({:worker_exit, worker_id, reason}) is the "effect" in
  # INV-ST-14's "decision MUST be WAL-committed before its effect is visible."
  # This test asserts that the capture row is already in the Ledger (synchronously
  # readable via captures_for/2) the moment the death cert arrives — no polling.
  # ---------------------------------------------------------------------------

  describe "INV-ST-14 (Clause B) — capture WAL-committed before death cert arrives" do
    @tag :inv_st_14
    test "INV-ST-14: immediately after {:worker_exit,...}, capture row is already readable in Ledger (no polling)" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_inv14_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir, "_b1")

      ledger_name = start_ledger(tmp_dir, :b1)
      {_sup_name, sup, registry_name} = start_fleet(:b1)
      report_to = self()
      {_jan_name, jan_pid} = start_janitor(ledger_name, :b1, report_to)

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      assert Process.alive?(worker_pid), "INV-ST-14: worker must be alive before kill"

      # Make the worktree dirty so the capture is non-trivial.
      {:ok, ws} = GenServer.call(worker_pid, :get_ws)
      untracked_content = "inv14-untracked-#{System.unique_integer([:positive])}\n"
      File.write!(Path.join(ws, "inv14_untracked.txt"), untracked_content)

      # Kill the worker.
      Process.exit(worker_pid, :kill)

      # Receive the death cert. This is the "effect" in INV-ST-14 Clause B.
      assert_receive {:worker_exit, ^worker_id, _reason},
                     5_000,
                     "INV-ST-14: death cert must arrive after Process.exit(pid, :kill)"

      # --- THE LOAD-BEARING ASSERTION ---
      # Immediately after receiving the death cert — without any sleep or polling —
      # the capture row MUST be readable in the Ledger.
      #
      # INV-ST-14 Clause B: "every factory decision MUST be WAL-committed to SQLite
      # before its effect is visible." The death cert is the effect; the capture row
      # is the decision. By the time the death cert has been received, the WAL commit
      # must have already completed.
      #
      # This relies on the synchronous ordering in workspace_janitor.ex:
      #   1. capture_workspace/3 → Writer.capture/3 (GenServer.call, WAL-before-ack)
      #   2. reclaim_workspace/1
      #   3. send(report_to, {:worker_exit, ...})
      #
      # If step 3 were moved before step 1, captures_for/2 would return [] here and
      # the test would fail — directly falsifying INV-ST-14 Clause B.

      captures = @writer.captures_for(ledger_name, worker_id)

      assert captures != [],
             "INV-ST-14 Clause B: IMMEDIATELY after {:worker_exit,#{inspect(worker_id)},...} " <>
               "is received, `captures_for/2` MUST return a non-empty list — the capture row " <>
               "must be WAL-committed in the Ledger BEFORE the death cert is sent. " <>
               "Got []. This means either: " <>
               "(a) the janitor sent the death cert before calling Writer.capture/3 " <>
               "(ordering violation), or " <>
               "(b) Writer.capture/3 returned before the WAL was committed " <>
               "(synchronous=FULL not in effect). " <>
               "Either case falsifies INV-ST-14 Clause B (D-315 WAL-before-ack)."

      [capture | _] = captures

      assert capture.disposition == :captured,
             "INV-ST-14: the immediately-readable capture row must have disposition :captured; " <>
               "got #{inspect(capture.disposition)}"

      # The untracked file must also be captured (proving the full artifact is present
      # before the death cert — not just a placeholder empty row).
      assert capture.untracked_tgz != nil and byte_size(capture.untracked_tgz) > 0,
             "INV-ST-14: the immediately-readable capture row must contain the untracked tar " <>
               "(untracked_tgz non-nil and non-empty) before the death cert arrives. " <>
               "Got untracked_tgz=#{inspect(capture.untracked_tgz)}. " <>
               "This ensures the FULL artifact (not just a header) is WAL-committed first."
    end

    @tag :inv_st_14
    test "INV-ST-14: for a :kill reason, capture row is readable immediately (death cert reason normalised to :kill)" do
      # Second test: verify the :kill reason normalisation (normalize_reason/1 at
      # workspace_janitor.ex:200 maps :killed -> :kill). The death cert MUST carry
      # :kill, and the capture row MUST be readable immediately upon receipt.
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_inv14_kill_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir, "_kill")

      ledger_name = start_ledger(tmp_dir, :kill)
      {_sup_name, sup, registry_name} = start_fleet(:kill)
      report_to = self()
      {_jan_name, jan_pid} = start_janitor(ledger_name, :kill, report_to)

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      Process.exit(worker_pid, :kill)

      # Death cert must carry :kill (normalised from :killed).
      assert_receive {:worker_exit, ^worker_id, kill_reason},
                     5_000,
                     "INV-ST-14: death cert must arrive"

      assert kill_reason == :kill or match?({:kill, _}, kill_reason),
             "INV-ST-14: death cert reason for :kill exit must be :kill; " <>
               "got #{inspect(kill_reason)}"

      # Immediately after death cert: capture row must be readable (Clause B).
      captures = @writer.captures_for(ledger_name, worker_id)

      assert captures != [],
             "INV-ST-14 Clause B: immediately after {:worker_exit,...,:kill} is received, " <>
               "the capture row must already be WAL-committed. Got []."
    end
  end
end
