defmodule Tau.Factory.WorkerReclaimTest do
  @moduledoc """
  Gating tests for D-314 (supervised reclaim, INV-15) — every exit reason leaves
  no leaked worktree or namespace dir, and the janitor reconciles orphans on restart.

  ## D-314 invariant

  `terminates(w) ↝ reclaimed(workspace(w))` on EVERY exit path including `:kill`.
  Nothing leaks: no filesystem dir, no git worktree registration, no namespaced
  cache dir. Closing F-3 (leaked locked worktrees) and F-7 (stale-parent recovery
  must be unreachable). Reference: SPEC-FACTORY-FLEET §3 D-314 / AC-7.

  ## Entry point

  Tests exercise the real user-facing path: `WorkerSupervisor.spawn/5`.
  Workers are spawned with role `:test_author` (which is exempt from the D-304
  oracle-separation ordering constraint that requires a prior `:test_author`
  registration before any `:implementer`). The D-314 reclaim invariant governs
  ALL worker roles; using `:test_author` role exercises the correct boundary.

  ## Why :test_author role

  The D-304 spawn-order constraint (added in commit 73eba0c) requires that
  `:implementer` workers are only spawned after a `:test_author` is registered.
  The original D-314 tests used `:implementer` role without satisfying this
  constraint, causing them to fail with {:error, :no_test_author_registered}
  before exercising the reclaim path. The D-314 invariant applies to ALL worker
  roles; `:test_author` workers are created by WorkspaceJanitor the same way
  as `:implementer` workers, making them the correct boundary to test.

  ## AC linkage
    - D-314: all tests in this file (SPEC-FACTORY-FLEET AC-7)
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  @janitor Tau.Factory.WorkspaceJanitor
  @writer Tau.Factory.Ledger.Writer
  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Hermetic git repo setup
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

  defp slow_agent_bin(tmp_dir, suffix) do
    bin_path = Path.join(tmp_dir, "slow_reclaim#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    exec cat
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp dummy_agent_bin(tmp_dir, suffix) do
    bin_path = Path.join(tmp_dir, "dummy_reclaim#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp crash_agent_bin(tmp_dir, suffix) do
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

  defp start_janitor(ledger, tag, report_to) do
    n = System.unique_integer([:positive])
    name = :"reclaim_jan_#{tag}_#{n}"

    opts = [ledger: ledger, name: name, report_to: report_to]

    {:ok, pid} =
      start_supervised(
        {@janitor, opts},
        id: :"rjan_sv_#{n}"
      )

    {name, pid}
  end

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

  # Return all private worker worktree entries from `git worktree list --porcelain`.
  # Filters out the main repo worktree entry; any remaining entries are leaked.
  defp private_worktree_entries(repo_dir) do
    {wt_list, _} =
      System.cmd("git", ["worktree", "list", "--porcelain"],
        cd: repo_dir,
        stderr_to_stdout: true
      )

    wt_list
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "worktree "))
    |> Enum.reject(fn line ->
      path = String.replace_prefix(line, "worktree ", "")
      path == repo_dir or String.starts_with?(path, repo_dir <> "/")
    end)
  end

  # ---------------------------------------------------------------------------
  # D-314 — Supervised reclaim: every exit reason leaves no leaked worktree
  # ---------------------------------------------------------------------------

  describe "D-314 — supervised reclaim on every exit reason" do
    @tag :d_314
    test "D-314: normal Port exit (exit 0) — worktree is reclaimed, no git registration leak" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_normal_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      ledger = start_ledger(tmp_dir, :normal)
      {_sup_name, sup, registry_name} = start_fleet(:normal)
      {_jan_name, jan_pid} = start_janitor(ledger, :normal, self())

      # Role: :test_author — exempt from D-304 ordering constraint.
      # D-314 governs ALL worker roles; :test_author exercises the reclaim boundary.
      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :test_author, "write gating tests", base_ref,
          repo_dir: repo_dir,
          agent_bin: dummy_agent_bin(tmp_dir, "_normal"),
          registry: registry_name,
          janitor: jan_pid
        )

      assert_receive {:worker_exit, ^worker_id, _reason},
                     5_000,
                     "D-314/normal: death-cert must arrive on normal exit"

      Process.sleep(300)

      leaked = private_worktree_entries(repo_dir)

      assert leaked == [],
             "D-314/normal: all private worktrees must be reclaimed after normal exit; " <>
               "leaked git entries: #{inspect(leaked)}"
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

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :test_author, "write gating tests", base_ref,
          repo_dir: repo_dir,
          agent_bin: crash_agent_bin(tmp_dir, "_crash"),
          registry: registry_name,
          janitor: jan_pid
        )

      assert_receive {:worker_exit, ^worker_id, _reason},
                     5_000,
                     "D-314/crash: death-cert must arrive on crash (exit 1)"

      Process.sleep(300)

      leaked = private_worktree_entries(repo_dir)

      assert leaked == [],
             "D-314/crash: private worktrees must be reclaimed after Port crash; " <>
               "leaked: #{inspect(leaked)}"
    end

    @tag :d_314
    test "D-314: :kill — worktree is reclaimed, no filesystem or git leak" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_kill_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      ledger = start_ledger(tmp_dir, :kill)
      {_sup_name, sup, registry_name} = start_fleet(:kill)
      {_jan_name, jan_pid} = start_janitor(ledger, :kill, self())

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :test_author, "write gating tests", base_ref,
          repo_dir: repo_dir,
          agent_bin: slow_agent_bin(tmp_dir, "_kill"),
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

      leaked = private_worktree_entries(repo_dir)

      assert leaked == [],
             "D-314/kill: no private git worktree registrations must remain after :kill; " <>
               "leaked: #{inspect(leaked)}"
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

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :test_author, "write gating tests", base_ref,
          repo_dir: repo_dir,
          agent_bin: slow_agent_bin(tmp_dir, "_shutdown"),
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

      leaked = private_worktree_entries(repo_dir)

      assert leaked == [],
             "D-314/shutdown: no private git registrations must remain after :shutdown; " <>
               "leaked: #{inspect(leaked)}"
    end

    @tag :d_314
    test "D-314: namespace dirs inside ws are also reclaimed" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_ns_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      ledger = start_ledger(tmp_dir, :ns)
      {_sup_name, sup, registry_name} = start_fleet(:ns)
      {_jan_name, jan_pid} = start_janitor(ledger, :ns, self())

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :test_author, "write gating tests", base_ref,
          repo_dir: repo_dir,
          agent_bin: slow_agent_bin(tmp_dir, "_ns"),
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

      refute File.exists?(ns_dir),
             "D-314/ns: namespace dir #{ns_dir} must also be gone after ws reclaim"
    end

    @tag :d_314
    test "D-314: no-janitor spawn is fail-closed — no leaked worktree after rejection" do
      # D-314 requires that even the fail-closed path (nil janitor → :no_janitor)
      # leaves no leaked worktree. The Worker must call cleanup_worktree before
      # returning {:stop, :no_janitor}. This verifies the guard that prevents
      # spawn_death_monitor from being used: all paths that could leak a worktree
      # are blocked at init time (D-313 fail-closed as a D-314 prerequisite).
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_njan_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      {_sup_name, sup, registry_name} = start_fleet(:njan)

      result =
        @worker_supervisor.spawn(sup, :test_author, "write gating tests", base_ref,
          repo_dir: repo_dir,
          agent_bin: slow_agent_bin(tmp_dir, "_njan"),
          registry: registry_name
          # :janitor intentionally absent — D-313 fail-closed
        )

      assert result == {:error, :no_janitor},
             "D-314/no-janitor: spawn without :janitor must return {:error, :no_janitor}; " <>
               "got: #{inspect(result)}"

      Process.sleep(300)

      leaked = private_worktree_entries(repo_dir)

      assert leaked == [],
             "D-314/no-janitor: Worker must call cleanup_worktree before {:stop, :no_janitor}; " <>
               "no leaked git worktree registrations permitted. " <>
               "Leaked: #{inspect(leaked)}"

      leaked_dirs = Path.wildcard(Path.join(Path.dirname(repo_dir), ".worker-wt-*"))

      assert leaked_dirs == [],
             "D-314/no-janitor: no .worker-wt-* dirs must remain after :no_janitor rejection; " <>
               "leaked: #{inspect(leaked_dirs)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-314 — Orphan reconciliation on janitor restart
  # ---------------------------------------------------------------------------

  describe "D-314 — orphan reconciliation on restart" do
    @tag :d_314
    test "D-314/orphan: janitor reconciles and reclaims an orphan worktree on init" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_orphan_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      orphan_dir = Path.join(tmp_dir, "orphan_wt_#{System.unique_integer([:positive])}")
      File.mkdir_p!(orphan_dir)
      File.write!(Path.join(orphan_dir, "stale_file"), "orphan content\n")
      assert File.dir?(orphan_dir), "D-314/orphan: setup — orphan dir must exist"

      ledger = start_ledger(tmp_dir, :orphan)

      n = System.unique_integer([:positive])
      jan_name = :"orphan_jan_#{n}"

      {:ok, _jan_pid} =
        start_supervised(
          {@janitor, ledger: ledger, name: jan_name, orphan_dirs: [orphan_dir]},
          id: :"orphan_jan_sv_#{n}"
        )

      Process.sleep(300)

      assert poll_reclaimed(orphan_dir, 3_000) == :reclaimed,
             "D-314/orphan: janitor must reclaim the orphan dir #{orphan_dir} on init; " <>
               "still exists"
    end
  end


  # ---------------------------------------------------------------------------
  # D-314 x HR-7 -- registry metadata: Worker registers with %{role, author_id}
  # so WorkerSupervisor.any_test_author_registered?/1 (D-304) can select by role.
  #
  # Discriminating gate: at merge-base, Worker registered WITHOUT metadata
  # ({:via, Registry, {registry, worker_id}}); Registry.lookup returned
  # [{pid, nil}]. At HEAD, Worker registers WITH metadata
  # ({:via, Registry, {registry, worker_id, %{role: ..., author_id: ...}}});
  # Registry.lookup returns [{pid, %{role: :test_author, author_id: nil}}].
  #
  # These tests fail at merge-base (metadata is nil / spawn guard absent) and
  # pass at HEAD. They are the discriminating gate making the D-314 suite
  # genuinely fail-before against the merge-base production code.
  # ---------------------------------------------------------------------------

  describe "D-314 x HR-7 -- Worker registers with role metadata for D-304 oracle-separation" do
    @tag :d_314
    @tag :hr_7
    test "D-314/HR-7: spawned :test_author worker registry entry has %{role: :test_author} metadata" do
      # Gate: Worker.start_link/1 must store role metadata in the registry.
      # Used by WorkerSupervisor.any_test_author_registered?/1 (D-304 sub-mechanism (a)).
      # At merge-base: {:via, Registry, {reg, worker_id}} -- no metadata -> nil.
      # At HEAD:       {:via, Registry, {reg, worker_id, %{role: :test_author, ...}}} -> map.
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_hr7_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      ledger = start_ledger(tmp_dir, :hr7)
      {_sup_name, sup, registry_name} = start_fleet(:hr7)
      {_jan_name, jan_pid} = start_janitor(ledger, :hr7, self())

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :test_author, "write gating tests", base_ref,
          repo_dir: repo_dir,
          agent_bin: slow_agent_bin(tmp_dir, "_hr7"),
          registry: registry_name,
          janitor: jan_pid
        )

      # Look up registry entry; the value field is the stored metadata.
      entries = Registry.lookup(registry_name, worker_id)

      assert entries != [],
             "D-314/HR-7: worker must be registered in registry under worker_id=#{inspect(worker_id)}"

      [{_pid, metadata}] = entries

      assert is_map(metadata),
             "D-314/HR-7: registry value (metadata) MUST be a map; " <>
               "at merge-base Worker registered without metadata so value is nil. " <>
               "Got: #{inspect(metadata)}"

      assert Map.get(metadata, :role) == :test_author,
             "D-314/HR-7: metadata[:role] MUST be :test_author; " <>
               "WorkerSupervisor.any_test_author_registered?/1 (D-304) selects by this key. " <>
               "Got metadata: #{inspect(metadata)}"

      # Cleanup: kill the slow agent worker.
      [{pid, _}] = Registry.lookup(registry_name, worker_id)
      Process.exit(pid, :kill)
      assert_receive {:worker_exit, ^worker_id, _}, 3_000
    end

    @tag :d_314
    @tag :d_304
    test "D-314/D-304: spawning :implementer without prior :test_author -- rejected AND no leaked worktree" do
      # D-314 x D-304 composite gate.
      #
      # At merge-base: WorkerSupervisor has NO spawn-order guard; spawn/5 returns
      # {:ok, worker_id} and starts a worker (possibly creating a worktree).
      # The assert below fails because result != {:error, :no_test_author_registered}.
      #
      # At HEAD: the D-304 guard rejects the spawn BEFORE git worktree add runs,
      # returning {:error, :no_test_author_registered}. D-314 requires no leaked
      # worktree after any rejection path.
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_rec314_d304_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      {_sup_name, sup, registry_name} = start_fleet(:d304_no_leak)

      # NO :test_author registered -- D-304 guard must reject :implementer.
      result =
        @worker_supervisor.spawn(sup, :implementer, "implement feature", base_ref,
          repo_dir: repo_dir,
          agent_bin: slow_agent_bin(tmp_dir, "_d304"),
          registry: registry_name
          # No :janitor -- the D-304 guard fires BEFORE janitor check.
        )

      assert result == {:error, :no_test_author_registered},
             "D-314/D-304: spawning :implementer without a prior :test_author " <>
               "MUST return {:error, :no_test_author_registered}. " <>
               "At merge-base this guard is absent and spawn returns {:ok, worker_id}. " <>
               "Got: #{inspect(result)}"

      # D-314: the D-304 rejection must leave NO leaked worktree.
      # The guard fires before git worktree add, so the worktree count must stay at 1.
      Process.sleep(100)

      leaked = private_worktree_entries(repo_dir)

      assert leaked == [],
             "D-314/D-304: a D-304 rejection must leave no leaked git worktree entries. " <>
               "Leaked: #{inspect(leaked)}"
    end
  end
end
