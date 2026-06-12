defmodule Tau.Factory.WorkerReclaimTest do
  @moduledoc """
  Gating tests for PR #446 (P4d-3 — WorkspaceJanitor capture-before-destroy).

  Covers D-314 (supervised reclaim) — every exit reason leaves no leaked
  worktree or namespace dir, and the janitor reconciles orphans on restart.

  Written BEFORE production code exists (oracle-separation phase, D-304).
  Fails with UndefinedFunctionError until the implementer creates
  Tau.Factory.WorkspaceJanitor and extends Ledger.Writer with capture/3 +
  captures_for/2.

  ## AC linkage
    - D-314: all tests in this file
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  @janitor Tau.Factory.WorkspaceJanitor
  @writer Tau.Factory.Ledger.Writer
  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Hermetic git repo setup (same idiom as worker_test.exs)
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
    bin_path = Path.join(tmp_dir, "slow_reclaim#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    while true; do sleep 60; done
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp dummy_agent_bin(tmp_dir, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "dummy_reclaim#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  # Agent that crashes with non-zero exit.
  defp crash_agent_bin(tmp_dir, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "crash_reclaim#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    exit 1
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp start_ledger(tmp_dir, tag) do
    n = System.unique_integer([:positive])
    db_path = Path.join(tmp_dir, "ledger_rec_#{tag}_#{n}.db")
    name = :"ledger_rec_#{tag}_#{n}"

    {:ok, _} =
      start_supervised(
        {@writer, db_path: db_path, name: name},
        id: :"ledger_rec_sv_#{n}"
      )

    name
  end

  defp start_fleet(tag) do
    n = System.unique_integer([:positive])
    registry_name = :"reclaim_reg_#{tag}_#{n}"
    sup_name = :"reclaim_sup_#{tag}_#{n}"

    {:ok, _} =
      start_supervised(
        {@worker_registry, name: registry_name},
        id: :"rreg_#{n}"
      )

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"rsup_#{n}"
      )

    {sup_name, sup, registry_name}
  end

  defp start_janitor(ledger, tag, report_to \\ nil) do
    n = System.unique_integer([:positive])
    name = :"reclaim_jan_#{tag}_#{n}"

    opts = [ledger: ledger, name: name]
    opts = if report_to, do: Keyword.put(opts, :report_to, report_to), else: opts

    {:ok, pid} =
      start_supervised(
        {@janitor, opts},
        id: :"rjan_sv_#{n}"
      )

    {name, pid}
  end

  # Obtain a worker's ws path via the pinned GenServer.call(:get_ws) contract.
  defp get_ws(worker_pid) do
    {:ok, ws} = GenServer.call(worker_pid, :get_ws)
    ws
  end

  # Poll until File.exists?(path) is false or timeout; returns :reclaimed | :leaked.
  defp poll_reclaimed(path, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_reclaimed(path, deadline, interval_ms)
  end

  defp do_poll_reclaimed(path, deadline, interval_ms) do
    cond do
      not File.exists?(path) ->
        :reclaimed

      System.monotonic_time(:millisecond) >= deadline ->
        :leaked

      true ->
        Process.sleep(interval_ms)
        do_poll_reclaimed(path, deadline, interval_ms)
    end
  end

  # ---------------------------------------------------------------------------
  # D-314 — Supervised reclaim: every exit reason leaves no leaked worktree
  # ---------------------------------------------------------------------------

  describe "D-314 — supervised reclaim on every exit reason" do
    @tag :d_314
    test "D-314: normal Port exit (exit 0) — worktree is reclaimed, no leak" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_normal_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      ledger = start_ledger(tmp_dir, :normal)
      {_sup_name, sup, registry_name} = start_fleet(:normal)
      {_jan_name, jan_pid} = start_janitor(ledger, :normal, self())

      # slow agent first so we can get ws before the Port exits.
      agent_bin = dummy_agent_bin(tmp_dir, "_normal")

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      # Wait for natural exit.
      assert_receive {:worker_exit, ^worker_id, _reason},
                     5_000,
                     "D-314/normal: death-cert must arrive on normal exit"

      # The worktree path: we cannot call get_ws after the worker is dead;
      # instead we poll the git worktree list of the repo to verify nothing leaked.
      {wt_list, _} =
        System.cmd("git", ["worktree", "list", "--porcelain"],
          cd: repo_dir,
          stderr_to_stdout: true
        )

      worker_wt_entries =
        wt_list
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "worktree "))
        |> Enum.reject(&String.ends_with?(String.trim(&1), repo_dir))

      assert worker_wt_entries == [],
             "D-314/normal: all private worktrees must be reclaimed after normal exit; " <>
               "leaked entries: #{inspect(worker_wt_entries)}"
    end

    @tag :d_314
    test "D-314: crash (exit 1) — worktree is reclaimed, no leak" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_crash_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      ledger = start_ledger(tmp_dir, :crash)
      {_sup_name, sup, registry_name} = start_fleet(:crash)
      {_jan_name, jan_pid} = start_janitor(ledger, :crash, self())

      agent_bin = crash_agent_bin(tmp_dir, "_crash")

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      assert_receive {:worker_exit, ^worker_id, _reason},
                     5_000,
                     "D-314/crash: death-cert must arrive on crash (exit 1)"

      {wt_list, _} =
        System.cmd("git", ["worktree", "list", "--porcelain"],
          cd: repo_dir,
          stderr_to_stdout: true
        )

      worker_wt_entries =
        wt_list
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "worktree "))
        |> Enum.reject(fn line ->
          trimmed = String.trim_leading(line, "worktree ")
          line == "" or trimmed == repo_dir or String.starts_with?(trimmed, repo_dir <> "/")
        end)

      assert worker_wt_entries == [],
             "D-314/crash: private worktrees must be reclaimed after Port crash; " <>
               "leaked: #{inspect(worker_wt_entries)}"
    end

    @tag :d_314
    test "D-314: :kill — worktree is reclaimed, no leak" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_kill_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      ledger = start_ledger(tmp_dir, :kill)
      {_sup_name, sup, registry_name} = start_fleet(:kill)
      {_jan_name, jan_pid} = start_janitor(ledger, :kill, self())

      agent_bin = slow_agent_bin(tmp_dir, "_kill")

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      ws = get_ws(worker_pid)
      assert File.dir?(ws), "D-314/kill: ws must exist before kill"

      Process.exit(worker_pid, :kill)

      assert_receive {:worker_exit, ^worker_id, _reason},
                     5_000,
                     "D-314/kill: death-cert must arrive after :kill"

      assert poll_reclaimed(ws, 5_000) == :reclaimed,
             "D-314/kill: worktree at #{ws} must be reclaimed (removed) after :kill"
    end

    @tag :d_314
    test "D-314: :shutdown — worktree is reclaimed, no leak" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_shutdown_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      ledger = start_ledger(tmp_dir, :shutdown)
      {_sup_name, sup, registry_name} = start_fleet(:shutdown)
      {_jan_name, jan_pid} = start_janitor(ledger, :shutdown, self())

      agent_bin = slow_agent_bin(tmp_dir, "_shutdown")

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      ws = get_ws(worker_pid)
      assert File.dir?(ws), "D-314/shutdown: ws must exist before shutdown"

      Process.exit(worker_pid, :shutdown)

      assert_receive {:worker_exit, ^worker_id, _reason},
                     5_000,
                     "D-314/shutdown: death-cert must arrive after :shutdown"

      assert poll_reclaimed(ws, 5_000) == :reclaimed,
             "D-314/shutdown: worktree at #{ws} must be reclaimed after :shutdown"
    end

    @tag :d_314
    test "D-314: namespace dirs inside ws are also reclaimed" do
      # When the worker has namespace dirs (e.g. .factory-ns/XDG_DATA_HOME),
      # they live inside ws; reclaiming ws reclaims them too.
      # Assert that after reclaim, no .factory-ns subdir remains.
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_ns_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      ledger = start_ledger(tmp_dir, :ns)
      {_sup_name, sup, registry_name} = start_fleet(:ns)
      {_jan_name, jan_pid} = start_janitor(ledger, :ns, self())

      agent_bin = slow_agent_bin(tmp_dir, "_ns")

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      ws = get_ws(worker_pid)
      ns_dir = Path.join(ws, ".factory-ns")

      Process.exit(worker_pid, :kill)

      assert_receive {:worker_exit, ^worker_id, _reason},
                     5_000,
                     "D-314/ns: death-cert must arrive"

      assert poll_reclaimed(ws, 5_000) == :reclaimed,
             "D-314/ns: ws must be reclaimed; still exists at #{ws}"

      # If the ns dir was inside ws, it is gone too (subdir of reclaimed ws).
      refute File.exists?(ns_dir),
             "D-314/ns: namespace dir #{ns_dir} must also be gone after ws reclaim"
    end
  end

  # ---------------------------------------------------------------------------
  # D-314 — Orphan reconciliation on janitor restart
  # ---------------------------------------------------------------------------

  describe "D-314 — orphan reconciliation on restart" do
    @tag :d_314
    test "D-314/orphan: janitor reconciles and reclaims an orphan worktree on init" do
      # Simulate an orphan: manually create a worktree dir that is NOT registered
      # in the live WorkerRegistry. The janitor, on startup, must reconcile:
      # any worktree path it knows about (from the Ledger or its init-time
      # worktree-directory scan) that has no live Registry entry is an orphan
      # and must be reclaimed.
      #
      # PIN: WorkspaceJanitor.start_link accepts an :orphan_dirs opt —
      # a list of absolute dir paths to treat as orphans on init.
      # On init, any dir in :orphan_dirs that still exists is reclaimed
      # (File.rm_rf!/1 equivalent).
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_orphan_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      # Create an orphan dir (simulates a leaked locked worktree).
      orphan_dir = Path.join(tmp_dir, "orphan_wt_#{System.unique_integer([:positive])}")
      File.mkdir_p!(orphan_dir)
      File.write!(Path.join(orphan_dir, "stale_file"), "orphan content\n")
      assert File.dir?(orphan_dir), "D-314/orphan: setup — orphan dir must exist"

      ledger = start_ledger(tmp_dir, :orphan)

      n = System.unique_integer([:positive])
      jan_name = :"orphan_jan_#{n}"

      # Start the janitor with :orphan_dirs declared.
      {:ok, _jan_pid} =
        start_supervised(
          {@janitor, ledger: ledger, name: jan_name, orphan_dirs: [orphan_dir]},
          id: :"orphan_jan_sv_#{n}"
        )

      # Allow init to complete reconciliation.
      Process.sleep(300)

      assert poll_reclaimed(orphan_dir, 3_000) == :reclaimed,
             "D-314/orphan: janitor must reclaim the orphan dir #{orphan_dir} on init; " <>
               "still exists"
    end
  end
end
