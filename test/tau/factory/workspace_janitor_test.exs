defmodule Tau.Factory.WorkspaceJanitorTest do
  @moduledoc """
  Gating tests for PR #446 (P4d-3 — WorkspaceJanitor capture-before-destroy).

  Written BEFORE production code exists (oracle-separation phase, D-304).
  These tests fail with UndefinedFunctionError / FunctionClauseError until
  the implementer creates:
    - lib/tau/factory/workspace_janitor.ex  (Tau.Factory.WorkspaceJanitor)
    - Tau.Factory.Ledger.Writer gains capture/3 + captures_for/2

  ## Pinned interface (oracle-declared; implementer MUST conform)

  ### WorkspaceJanitor
  A `GenServer` independent monitor (NOT linked to workers).

      start_link(opts) :: {:ok, pid}
        required opts:
          :ledger   — pid/server ref for Tau.Factory.Ledger.Writer
          :name     — atom registered name
        optional opts:
          :report_to — pid (may be omitted; janitor still reclaims)

      register(janitor, worker_id, worker_pid, ws, ns_dirs, report_to) :: :ok
        worker_id  — String.t()
        worker_pid — pid()
        ws         — abs path to the worker's private worktree
        ns_dirs    — list of absolute dirs to reclaim (namespace dirs inside ws)
        report_to  — pid() | nil; receives {:worker_exit, worker_id, reason}

  On the monitored worker's :DOWN (for EVERY exit reason incl. :kill):
    1. capture: run capture_commands(ws) — git diff HEAD (patch),
       git ls-files --others --exclude-standard (untracked names),
       git status --short (status)
    2. if untracked names non-empty, tar them into a binary (untracked_tgz)
    3. Ledger.Writer.capture(ledger, worker_id,
         %{patch: binary, untracked_tgz: binary | nil, status: binary,
           disposition: :captured})
    4. reclaim: File.rm_rf!(ws) (or git worktree remove --force) + remove ns_dirs
    5. if report_to non-nil: send {:worker_exit, worker_id, reason}

  On restart: reconcile — any worktree dir in the capture registry that is NOT
  in the live registry MUST be reclaimed (orphan reclaim — D-314).

  ### Ledger.Writer additions
  capture(server, worker_id, attrs) :: {:ok, ref}
    attrs: %{patch: binary, untracked_tgz: binary | nil, status: binary,
             disposition: atom}

  captures_for(server, worker_id) :: [map()]
    returns list of capture row maps for the worker_id (most-recent-first)

  ## AC linkage
    - D-313: the `:kill` recovery test (primary test in this file)
    - D-334: see artifact_conservation_test.exs
    - D-314: see worker_reclaim_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  # Runtime references — absent until implementer ships.
  # Using module-attribute @mod pattern to avoid compile-time resolution of
  # absent modules (credo strict: no apply/2,3).
  @janitor Tau.Factory.WorkspaceJanitor
  @writer Tau.Factory.Ledger.Writer
  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Hermetic git repo setup (reused from worker_test.exs idiom)
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

    tracked_path = Path.join(repo_dir, "README")
    File.write!(tracked_path, "initial\n")
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

  # Returns a blocking agent bin — stays alive until killed.
  defp slow_agent_bin(tmp_dir, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "slow_janitor_agent#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    # blocking agent — stays alive until the process is killed
    while true; do sleep 60; done
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  # Start an isolated Ledger.Writer for a single test.
  defp start_ledger(tmp_dir, tag) do
    n = System.unique_integer([:positive])
    db_path = Path.join(tmp_dir, "ledger_#{tag}_#{n}.db")
    name = :"ledger_#{tag}_#{n}"

    {:ok, pid} =
      start_supervised(
        {@writer, db_path: db_path, name: name},
        id: :"ledger_sv_#{n}"
      )

    {name, pid}
  end

  # Start an isolated WorkerRegistry + WorkerSupervisor.
  defp start_fleet(tag) do
    n = System.unique_integer([:positive])
    registry_name = :"jtest_registry_#{tag}_#{n}"
    sup_name = :"jtest_sup_#{tag}_#{n}"

    {:ok, _} =
      start_supervised(
        {@worker_registry, name: registry_name},
        id: :"jreg_#{n}"
      )

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"jsup_#{n}"
      )

    {sup_name, sup, registry_name}
  end

  # Start an isolated WorkspaceJanitor.
  defp start_janitor(ledger, tag, report_to \\ nil) do
    n = System.unique_integer([:positive])
    name = :"janitor_#{tag}_#{n}"

    opts = [ledger: ledger, name: name]
    opts = if report_to, do: Keyword.put(opts, :report_to, report_to), else: opts

    {:ok, pid} =
      start_supervised(
        {@janitor, opts},
        id: :"jan_sv_#{n}"
      )

    {name, pid}
  end

  # ---------------------------------------------------------------------------
  # D-313 — Capture-before-destroy, all three dirty kinds (the :kill recovery test)
  # ---------------------------------------------------------------------------
  #
  # This is the PRIMARY gate for D-313.  AC-5 from SPEC-FACTORY-FLEET §7:
  # "a worker holding an untracked file is :kill-ed and the untracked file is
  # recovered from the capture artifact"
  # ---------------------------------------------------------------------------

  describe "D-313 — capture-before-destroy (:kill recovery)" do
    @tag :d_313
    test "D-313: :kill a dirty worker — all three kinds captured; untracked file is byte-for-byte recoverable" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_jan313_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir, "_d313")

      {ledger_name, _ledger_pid} = start_ledger(tmp_dir, :d313)
      {_sup_name, sup, registry_name} = start_fleet(:d313)
      report_to = self()
      {_jan_name, _jan_pid} = start_janitor(ledger_name, :d313, report_to)

      # Spawn worker WITH the janitor registered.
      janitor_server = @janitor |> Process.whereis() || ledger_name

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: janitor_server
        )

      # Resolve worker pid via registry (identity by key, never stored pid — C218).
      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      assert Process.alive?(worker_pid), "D-313: worker must be alive before kill"

      # Obtain the worker's private worktree path — the janitor must expose it
      # OR the Worker exposes it; we use GenServer.call to retrieve state.
      # PIN: Worker exposes `ws` via GenServer.call(pid, :get_ws) :: {:ok, String.t()}
      {:ok, ws} = GenServer.call(worker_pid, :get_ws)

      assert File.dir?(ws), "D-313: worker's private worktree must exist before kill; ws=#{ws}"

      # --- Make the worktree dirty in ALL THREE kinds ---

      # Kind 1: STAGED change — modify a tracked file and git add it.
      readme = Path.join(ws, "README")
      File.write!(readme, "staged modification\n")
      {_, 0} = System.cmd("git", ["add", "README"], cd: ws, stderr_to_stdout: true)

      # Kind 2: UNSTAGED change — modify a tracked file WITHOUT git add.
      File.write!(readme, "staged modification\nunstaged modification\n")

      # Kind 3: UNTRACKED new file — never git-add'd.
      untracked_name = "secret_output.txt"
      untracked_content = "untracked-content-#{System.unique_integer([:positive])}\n"
      File.write!(Path.join(ws, untracked_name), untracked_content)

      # Verify setup — git status must show all three kinds.
      {status_out, _} = System.cmd("git", ["status", "--short"], cd: ws, stderr_to_stdout: true)

      assert String.contains?(status_out, untracked_name),
             "D-313: test setup: untracked file must appear in git status --short; " <>
               "status=#{inspect(status_out)}"

      # --- Kill the worker brutally (terminate/2 NEVER runs) ---
      Process.exit(worker_pid, :kill)

      # (a) Death-certificate must arrive via janitor monitor.
      assert_receive {:worker_exit, ^worker_id, kill_reason},
                     5_000,
                     "D-313: {:worker_exit, worker_id, :kill} must arrive after Process.exit(pid, :kill)"

      assert kill_reason == :kill or match?({:kill, _}, kill_reason),
             "D-313: death-cert reason must be :kill; got #{inspect(kill_reason)}"

      # (b) Ledger must have a capture row for this worker.
      # Poll — capture write is async after :DOWN fires.
      captures = poll_captures(ledger_name, worker_id, 5_000)

      assert captures != [],
             "D-313: Ledger must have at least one capture row for worker_id=#{worker_id} " <>
               "after :kill; got []"

      [capture | _] = captures

      # (c) patch (staged + unstaged diff) must be non-empty.
      assert is_binary(capture.patch),
             "D-313: capture.patch must be a binary; got #{inspect(capture.patch)}"

      assert byte_size(capture.patch) > 0,
             "D-313: capture.patch must be non-empty (staged+unstaged diff); " <>
               "patch=#{inspect(capture.patch)}"

      # (d) status must be non-empty.
      assert is_binary(capture.status),
             "D-313: capture.status must be a binary"

      assert byte_size(capture.status) > 0,
             "D-313: capture.status must be non-empty; status=#{inspect(capture.status)}"

      # (e) untracked_tgz must be non-nil and non-empty.
      assert capture.untracked_tgz != nil,
             "D-313: capture.untracked_tgz must be non-nil (untracked file present); " <>
               "a naïve git diff would have missed it (F-4)"

      assert is_binary(capture.untracked_tgz),
             "D-313: capture.untracked_tgz must be a binary"

      assert byte_size(capture.untracked_tgz) > 0,
             "D-313: capture.untracked_tgz must be non-empty"

      # (f) THE LOAD-BEARING F-4 ASSERTION:
      # Extract the tar and verify the untracked file is byte-for-byte present.
      extract_dir =
        Path.join(tmp_dir, "extracted_#{System.unique_integer([:positive])}")

      File.mkdir_p!(extract_dir)

      tgz_path = Path.join(tmp_dir, "wip_untracked.tgz")
      File.write!(tgz_path, capture.untracked_tgz)

      {_, 0} =
        System.cmd("tar", ["-C", extract_dir, "-xzf", tgz_path], stderr_to_stdout: true)

      recovered_path = Path.join(extract_dir, untracked_name)

      assert File.exists?(recovered_path),
             "D-313: untracked file '#{untracked_name}' must be recoverable from " <>
               "the captured tar; file NOT found at #{recovered_path}"

      assert File.read!(recovered_path) == untracked_content,
             "D-313: recovered file content must match exactly; " <>
               "expected=#{inspect(untracked_content)}, " <>
               "got=#{inspect(File.read!(recovered_path))}"

      # (g) AFTER capture, the worktree must be reclaimed.
      refute File.exists?(ws),
             "D-313: worktree must be reclaimed (removed) after capture; ws=#{ws} still exists"

      # Companion assertion (SPEC-FACTORY-FLEET §6 D-313):
      # Verify that a naïve git diff HEAD would NOT have caught the untracked file.
      # (The untracked file was never git-added, so diff HEAD produces no line for it.)
      # We verify this by checking that `untracked_name` is NOT in the patch.
      refute String.contains?(capture.patch, untracked_name),
             "D-313 companion: the untracked file '#{untracked_name}' must NOT appear " <>
               "in the git diff HEAD patch — proving the tar path was required (F-4)"
    end

    @tag :d_313
    test "D-313: janitor uses monitor not terminate/2 — capture fires on :kill where terminate/2 is never called" do
      # Structural verification: the WorkspaceJanitor must be a monitor, not linked.
      # If the janitor were linked, a :kill on the worker would kill the janitor too.
      # We verify the janitor stays alive after the worker is killed.
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_jan313b_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir, "_d313b")

      {ledger_name, _} = start_ledger(tmp_dir, :d313b)
      {_sup_name, sup, registry_name} = start_fleet(:d313b)
      {_jan_name, jan_pid} = start_janitor(ledger_name, :d313b, self())

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      assert Process.alive?(worker_pid), "D-313b: worker must be alive before kill"
      assert Process.alive?(jan_pid), "D-313b: janitor must be alive before kill"

      Process.exit(worker_pid, :kill)

      # Death-cert must arrive.
      assert_receive {:worker_exit, ^worker_id, _reason},
                     5_000,
                     "D-313b: death-cert must arrive"

      # Janitor must STILL be alive — it is a monitor, not linked.
      assert Process.alive?(jan_pid),
             "D-313b: WorkspaceJanitor must survive worker :kill — it is a monitor, " <>
               "NOT linked (C207/SPEC-FACTORY-FLEET §4 B5)"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Poll Ledger for captures; returns list or [] after timeout.
  defp poll_captures(ledger, worker_id, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_poll_captures(ledger, worker_id, deadline, interval_ms)
  end

  defp do_poll_captures(ledger, worker_id, deadline, interval_ms) do
    captures = @writer.captures_for(ledger, worker_id)

    cond do
      captures != [] ->
        captures

      System.monotonic_time(:millisecond) >= deadline ->
        []

      true ->
        Process.sleep(interval_ms)
        do_poll_captures(ledger, worker_id, deadline, interval_ms)
    end
  end
end
