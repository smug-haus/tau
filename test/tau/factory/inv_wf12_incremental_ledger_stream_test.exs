defmodule Tau.Factory.InvWf12IncrementalLedgerStreamTest do
  @moduledoc """
  Gating test for issue #564 (INV-WF-12 — incremental worker output streaming to Ledger).

  ## Invariant under test

  INV-WF-12: Worker incremental output (decisions and outcomes) SHOULD be
  streamed to the Ledger continuously so the :DOWN capture is a thin backstop
  over a near-empty volatile tree.

  **GAP verdict:** The :DOWN capture (WorkspaceJanitor.capture_workspace/3 called
  from the :DOWN handler at workspace_janitor.ex:162) is the SOLE mechanism for
  preserving worker output. The Worker process (worker.ex) contains NO
  Ledger/Writer call whatsoever. Worker decisions — specifically the `work_ready`
  signal that represents the primary decision/outcome of worker execution — are
  forwarded to `report_to` via `send/2` (pure in-memory) but NEVER committed to
  the durable Ledger during Worker execution.

  ## What the test asserts

  When a Worker receives a `work_ready` frame from the agent Port (its primary
  decision/outcome), it MUST write a durable record to the Ledger before the
  Worker process terminates. This is the boundary the invariant governs: the
  Worker's `dispatch/2` path for `%WorkReady{}` frames must commit incrementally
  so that the Ledger contains the decision BEFORE the :DOWN fires.

  The test exercises the real user-facing entry point (`WorkerSupervisor.spawn/5`)
  with a real Ledger.Writer and WorkspaceJanitor, and asserts that
  `Ledger.Writer.captures_for/2` (or an equivalent incremental-stream API)
  returns non-empty data AFTER `{:work_ready, ...}` is received by report_to
  but BEFORE the Worker's `:DOWN` has propagated to the Ledger's :DOWN-only
  path.

  ## Fail-before state

  This test MUST FAIL against current production code:
  - `worker.ex` dispatches `%WorkReady{}` via `send(state.report_to, ...)` only.
    There is no `Ledger.Writer` call in `dispatch/2` or anywhere in `worker.ex`.
  - `captures_for/2` returns `[]` until the Worker dies and WorkspaceJanitor
    writes the :DOWN capture.
  - The assertion `captures_before_exit != []` will fail as long as the Worker
    does not stream incrementally.

  ## AC linkage

  @tag :inv_wf_12  — see test name and module tag below.

  Ref: #564
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :inv_wf_12

  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor
  @janitor Tau.Factory.WorkspaceJanitor
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Hermetic git repo setup (mirroring worker_test.exs idiom)
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

    {staged, _} = git.(["diff", "--cached", "--name-only"])

    unless String.contains?(staged, "README") do
      raise "setup_git_repo: git add did not stage README; staged=#{inspect(staged)}"
    end

    {_, 0} = git.(["commit", "-m", "initial commit"])
    {sha, 0} = git.(["rev-parse", "HEAD"])

    %{repo_dir: repo_dir, base_ref: String.trim(sha)}
  end

  # An agent_bin that:
  #   1. Writes a {:packet,4}-framed JSON work_ready frame.
  #   2. Sleeps briefly so the Worker can process the frame before the Port
  #      closes (giving the incremental write a chance to land before :DOWN).
  #   3. Exits 0.
  #
  # The sleep is intentionally short (0.5s) — long enough to decouple the
  # work_ready dispatch from the exit_status, not long enough to cause
  # test timeouts.
  defp work_ready_then_exit_agent_bin(tmp_dir, branch, head_sha, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "wr_slow_agent#{suffix}")

    json = ~s({"type":"work_ready","branch":"#{branch}","head_sha":"#{head_sha}"})
    len = byte_size(json)

    b0 = Bitwise.band(Bitwise.bsr(len, 24), 0xFF)
    b1 = Bitwise.band(Bitwise.bsr(len, 16), 0xFF)
    b2 = Bitwise.band(Bitwise.bsr(len, 8), 0xFF)
    b3 = Bitwise.band(len, 0xFF)

    oct = fn b -> "\\" <> (b |> Integer.to_string(8) |> String.pad_leading(3, "0")) end
    len_prefix = oct.(b0) <> oct.(b1) <> oct.(b2) <> oct.(b3)

    File.write!(bin_path, """
    #!/bin/sh
    printf '#{len_prefix}'
    printf '%s' '#{json}'
    sleep 0.5
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp start_ledger(tmp_dir, tag) do
    n = System.unique_integer([:positive])
    db_path = Path.join(tmp_dir, "ledger_#{tag}_#{n}.db")
    name = :"ledger_#{tag}_#{n}"

    {:ok, _pid} =
      start_supervised(
        {@writer, db_path: db_path, name: name},
        id: :"ledger_sv_#{n}"
      )

    name
  end

  defp start_janitor(ledger, tag, report_to) do
    n = System.unique_integer([:positive])
    name = :"janitor_#{tag}_#{n}"

    opts = [ledger: ledger, name: name]
    opts = if report_to, do: Keyword.put(opts, :report_to, report_to), else: opts

    {:ok, _pid} =
      start_supervised(
        {@janitor, opts},
        id: :"jan_sv_#{n}"
      )

    name
  end

  defp start_fleet(tag) do
    n = System.unique_integer([:positive])
    registry_name = :"wf12_registry_#{tag}_#{n}"
    sup_name = :"wf12_sup_#{tag}_#{n}"

    {:ok, _reg} =
      start_supervised(
        {@worker_registry, name: registry_name},
        id: :"reg_#{n}"
      )

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"sup_#{n}"
      )

    {sup_name, sup, registry_name}
  end

  # ---------------------------------------------------------------------------
  # INV-WF-12 — incremental Ledger write on work_ready (primary gating test)
  # ---------------------------------------------------------------------------

  describe "INV-WF-12 — Worker streams decisions to Ledger before :DOWN" do
    @tag :inv_wf_12
    test "INV-WF-12: when a Worker processes a work_ready frame, a durable Ledger record exists BEFORE the Worker's :DOWN fires" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_wf12_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/wf12-branch"
      head_sha = String.duplicate("a1b2c3d4", 5)

      # Agent emits work_ready, sleeps briefly, then exits.
      # The sleep window is the observation interval: we check the Ledger
      # AFTER work_ready is received by report_to but BEFORE the Worker exits
      # and WorkspaceJanitor fires its :DOWN write.
      agent_bin = work_ready_then_exit_agent_bin(tmp_dir, branch, head_sha)

      ledger_name = start_ledger(tmp_dir, :wf12)
      report_to = self()

      # WorkspaceJanitor monitors the Worker and captures at :DOWN.
      # It is the production :DOWN path; INV-WF-12 requires it NOT be the FIRST
      # (and only) Ledger writer — the Worker must write incrementally.
      janitor_name = start_janitor(ledger_name, :wf12, report_to)

      {_sup_name, sup, registry_name} = start_fleet(:wf12)

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          report_to: report_to,
          registry: registry_name,
          janitor: janitor_name
        )

      assert is_binary(worker_id),
             "INV-WF-12: spawn/5 must return {:ok, worker_id}; got #{inspect(worker_id)}"

      # Wait for the Worker to forward the work_ready event (confirms the Worker
      # has processed the frame from the Port). The 0.5s sleep in the agent bin
      # means the Worker process has NOT yet exited at this point — the Port is
      # still open and the :DOWN has not fired.
      assert_receive {:work_ready, ^worker_id, ^branch, ^head_sha},
                     5_000,
                     "INV-WF-12 prerequisite: Worker must forward work_ready to report_to. " <>
                       "If THIS fails, D-326 is not satisfied (a separate invariant). " <>
                       "INV-WF-12 cannot be evaluated without D-326 being satisfied first."

      # -----------------------------------------------------------------------
      # THE INVARIANT ASSERTION (INV-WF-12):
      #
      # The Worker has processed the work_ready frame (evidenced by the
      # {:work_ready, ...} message above). The agent is still sleeping (Port
      # still open, Worker still alive, :DOWN has NOT fired yet).
      #
      # The Ledger MUST already contain a durable record for this worker's
      # decision — because INV-WF-12 requires incremental streaming during
      # Worker execution, not only at death.
      #
      # Current code: the Worker dispatches work_ready to report_to via
      # send/2 (worker.ex, dispatch/2, line 510) with NO Ledger.Writer call.
      # captures_for/2 returns [] here because the :DOWN has not fired.
      # This assertion therefore FAILS against current production code.
      #
      # The implementer must add a Ledger.Writer call in the Worker's
      # dispatch path for %WorkReady{} (or equivalent incremental path) so
      # captures_for/2 (or a purpose-built streaming API) returns a non-empty
      # result at this observation point.
      # -----------------------------------------------------------------------
      captures_before_exit = @writer.captures_for(ledger_name, worker_id)

      assert captures_before_exit != [],
             "INV-WF-12 FAILED: Ledger.Writer.captures_for/2 returned [] for worker " <>
               "#{inspect(worker_id)} AFTER {:work_ready,...} was received by report_to " <>
               "but BEFORE the Worker's :DOWN fired. " <>
               "The :DOWN capture (WorkspaceJanitor) is the SOLE Ledger-write path — " <>
               "incremental streaming is absent. The invariant requires the Worker to commit " <>
               "a durable record on processing work_ready so the :DOWN backstop covers a " <>
               "near-empty volatile tree, not ALL accumulated worker output."
    end
  end
end
