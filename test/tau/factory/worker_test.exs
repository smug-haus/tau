defmodule Tau.Factory.WorkerTest do
  @moduledoc """
  Gating tests for PR #444 (P4d-2 — Worker + WorkerSupervisor + WorkerRegistry).

  Written BEFORE production code exists (oracle-separation phase, D-304).
  These tests fail with UndefinedFunctionError until the implementer creates:
    - lib/tau/factory/worker_registry.ex  (Tau.Factory.WorkerRegistry)
    - lib/tau/factory/worker_supervisor.ex (Tau.Factory.WorkerSupervisor)
    - lib/tau/factory/worker.ex            (Tau.Factory.Worker)

  ## Pinned interface (oracle-declared; implementer MUST conform)

  ### WorkerRegistry
  A `Registry` with `keys: :unique`. Provides `child_spec/1` and `start_link/1`.
  Worker processes register under `{WorkerRegistry, worker_id}`.

  ### WorkerSupervisor
  A `DynamicSupervisor` (`one_for_one`) of `:temporary` workers.

      start_link(opts) :: {:ok, pid}
        opts: :name (atom), :registry (atom)

      spawn(sup, role, brief, base_ref, opts) :: {:ok, worker_id}
        opts:
          :repo_dir        — path to git repo for `git worktree add`
          :agent_bin       — path to injectable executable (default: real agent)
          :toolchain       — atom (default: :elixir)
          :report_to       — pid receiving {:worker_exit, worker_id, reason}
          :heartbeat_interval — ms (optional)
          :worker_id       — override (optional; supervisor generates one if absent)
          :expected_head   — SHA string (optional; overrides expected HEAD in
                             verify_position; used by tests to inject a mismatch
                             without making git worktree add fail)

  ### Worker
  A `GenServer` (`restart: :temporary`) registered via
  `{:via, Registry, {WorkerRegistry, worker_id}}`.

  `init/1` sequence:
    1. `git worktree add <ws> <base_ref>` in `repo_dir`.
    2. `Worker.Isolation.resolve_namespace(ws, Toolchain.declare_resource_namespace(tc))`
       -> mkdir each dir in the map inside `ws`.
    3. `Worker.Isolation.verify_position(ws, observed, expected)`
       where `observed = %{head: actual_ws_head, ...}` and
       `expected.head = opts[:expected_head] || base_ref_sha`.
       On `{:error, _}` abort with `{:stop, {:position_unverified, ws, base_ref}}`.
    4. `Port.open({:spawn_executable, agent_bin}, [:binary, {:packet, 4},
       :exit_status, {:env, ns}, {:cd, ws}])` — linked into the worker.
    5. Start heartbeat timer at `heartbeat_interval`.
    6. On Port `{:exit_status, n}` -> send `{:worker_exit, worker_id, reason}`
       to `report_to` and stop normally.

  `role` is a data field (`atom()`), not a subclass.

  Death-certificate message shape: `{:worker_exit, worker_id :: String.t(), reason :: term()}`

  The death-certificate is delivered by an unlinked monitor (WorkspaceJanitor or
  equivalent) on the worker's `:DOWN` event — for EVERY exit reason (normal, :kill,
  crash). There is NO separate drain window; the certificate arrives via the monitor.

  ## Position-mismatch injection (D-311)

  The `:expected_head` opt (pinned above) allows tests to inject a HEAD mismatch
  without breaking `git worktree add`. The implementer MUST:
    - After `git worktree add <ws> <base_ref>` succeeds, resolve the actual HEAD SHA
      of the allocated worktree.
    - Compare that SHA against `opts[:expected_head] || resolved_base_ref_sha`.
    - If they differ, call `{:stop, {:position_unverified, ws, base_ref}}` and do NOT
      open the agent Port.

  Test injection: create two commits (A, B). Allocate with `base_ref = commit_A`
  (git worktree add succeeds, worktree is AT commit_A). Pass `expected_head: commit_B`.
  The worker's verify_position sees actual_head=A vs expected=B -> mismatch -> abort.
  The marker-agent Port must NEVER be opened.

  ## AC linkage
    - D-310: `worker_no_shared_tree` tests below
    - D-311: `worker_verify_position` tests below
    - D-316: `worker_crash_containment` tests below
    - B1/B4 lifecycle: `worker_lifecycle` tests below
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  # Runtime module references — file compiles even when modules do not yet exist.
  # Using @mod_* pattern per oracle-separation convention: reference at runtime,
  # never at compile time (the modules are absent until the implementer ships).
  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Hermetic git repo setup
  # ---------------------------------------------------------------------------

  # Creates a minimal local git repo suitable for `git worktree add`.
  # Returns %{repo_dir: path, base_ref: sha, alt_ref: sha | nil}.
  #
  # Determinism guarantee: after `git add`, assert staging before committing,
  # so "nothing to commit" MatchError is caught early with a clear message.
  defp setup_git_repo(tmp_dir, opts \\ []) do
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

    # Verify staging actually happened before committing.
    {staged, _} = git.(["diff", "--cached", "--name-only"])

    unless String.contains?(staged, "README") do
      raise "setup_git_repo: git add did not stage README; staged=#{inspect(staged)}"
    end

    {_, 0} = git.(["commit", "-m", "initial commit"])
    {sha, 0} = git.(["rev-parse", "HEAD"])
    base_ref = String.trim(sha)

    alt_ref =
      if Keyword.get(opts, :two_commits, false) do
        second_path = Path.join(repo_dir, "second")
        File.write!(second_path, "second\n")
        {_, 0} = git.(["add", "second"])

        # Verify staging of second file before committing.
        {staged2, _} = git.(["diff", "--cached", "--name-only"])

        unless String.contains?(staged2, "second") do
          raise "setup_git_repo: git add did not stage 'second'; staged=#{inspect(staged2)}"
        end

        {_, 0} = git.(["commit", "-m", "second commit"])
        {sha2, 0} = git.(["rev-parse", "HEAD"])
        String.trim(sha2)
      end

    %{repo_dir: repo_dir, base_ref: base_ref, alt_ref: alt_ref}
  end

  # Returns a path to a dummy agent executable (exits 0 immediately).
  defp dummy_agent_bin(tmp_dir, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "dummy_agent#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  # Returns a path to a blocking dummy agent (sleeps until killed).
  defp slow_agent_bin(tmp_dir, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "slow_agent#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    read -r line || true
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  # Starts isolated WorkerRegistry + WorkerSupervisor for a single test.
  # Returns {sup_name, sup_pid, registry_name}.
  defp start_fleet(test_tag) do
    n = System.unique_integer([:positive])
    registry_name = :"#{test_tag}_registry_#{n}"
    sup_name = :"#{test_tag}_sup_#{n}"

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
  # D-310 — No shared tree: private worktrees, disjoint, parent HEAD unchanged
  # ---------------------------------------------------------------------------

  describe "D-310 — no shared tree" do
    @tag :d_310
    test "D-310: spawned worker gets a PRIVATE worktree from base_ref; parent HEAD is unchanged" do
      tmp_dir =
        System.tmp_dir!() |> Path.join("tau_w310_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir)

      {_sup_name, sup, registry_name} = start_fleet(:d310_single)

      {parent_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_dir)
      parent_head = String.trim(parent_head)

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name
        )

      assert is_binary(worker_id),
             "D-310: spawn/5 must return {:ok, worker_id} where worker_id is a string; " <>
               "got #{inspect(worker_id)}"

      # Use slow_agent so the worker is alive during registry lookup.
      [{pid, _}] = Registry.lookup(registry_name, worker_id)
      assert Process.alive?(pid), "D-310: worker must be alive"

      # The parent HEAD must not have moved.
      {post_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_dir)
      post_head = String.trim(post_head)

      assert post_head == parent_head,
             "D-310: spawn must NOT mutate the parent repo HEAD; " <>
               "before=#{parent_head}, after=#{post_head}"

      # A private worktree directory must exist: git worktree list shows >= 2 entries.
      {worktree_list, 0} =
        System.cmd("git", ["worktree", "list", "--porcelain"], cd: repo_dir)

      worktree_count =
        worktree_list
        |> String.split("\n")
        |> Enum.count(&String.starts_with?(&1, "worktree "))

      assert worktree_count >= 2,
             "D-310: worker must have added a private git worktree; " <>
               "`git worktree list` shows only #{worktree_count} worktree(s):\n#{worktree_list}"

      Process.exit(pid, :kill)
    end

    @tag :d_310
    test "D-310: two workers spawned from the same repo get DISJOINT private worktrees" do
      tmp_dir =
        System.tmp_dir!() |> Path.join("tau_w310_2_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir)

      {_sup_name, sup, registry_name} = start_fleet(:d310_two)

      {:ok, worker_id1} =
        @worker_supervisor.spawn(sup, :implementer, "brief1", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name
        )

      {:ok, worker_id2} =
        @worker_supervisor.spawn(sup, :test_author, "brief2", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name
        )

      refute worker_id1 == worker_id2,
             "D-310: two spawned workers must have distinct worker_ids"

      # Resolve pids from registry — identity is the key, never a stored pid ([C218]).
      [{pid1, _}] = Registry.lookup(registry_name, worker_id1)
      [{pid2, _}] = Registry.lookup(registry_name, worker_id2)

      assert pid1 != pid2,
             "D-310: two spawned workers must be distinct processes"

      assert Process.alive?(pid1), "D-310: worker1 must be alive after spawn"
      assert Process.alive?(pid2), "D-310: worker2 must be alive after spawn"

      # Worktree list must show >= 3 entries (main + w1 + w2).
      {worktree_list, 0} =
        System.cmd("git", ["worktree", "list", "--porcelain"], cd: repo_dir)

      worktree_entries =
        worktree_list
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "worktree "))
        |> Enum.map(&String.trim_leading(&1, "worktree "))

      assert length(worktree_entries) >= 3,
             "D-310: two workers must each add a distinct private worktree; " <>
               "worktree list:\n#{worktree_list}"

      # All worktree paths must be distinct (disjoint).
      assert length(worktree_entries) == length(Enum.uniq(worktree_entries)),
             "D-310: worktree paths must be pairwise disjoint; list:\n#{worktree_list}"

      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
    end
  end

  # ---------------------------------------------------------------------------
  # D-311 — Verified position: mismatch aborts worker before any work
  # ---------------------------------------------------------------------------

  describe "D-311 — verified position" do
    @tag :d_311
    test "D-311: worker with an unresolvable base_ref aborts; no Port launched" do
      tmp_dir =
        System.tmp_dir!() |> Path.join("tau_w311_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir} = setup_git_repo(tmp_dir)

      # Marker file: if the agent writes this, the Port was opened (D-311 violation).
      marker = Path.join(tmp_dir, "port_launched")

      bin_path = Path.join(tmp_dir, "marker_agent_unresolvable")

      File.write!(bin_path, """
      #!/bin/sh
      touch #{marker}
      exit 0
      """)

      File.chmod!(bin_path, 0o755)

      {_sup_name, sup, registry_name} = start_fleet(:d311_unresolvable)

      # A syntactically-valid 40-hex SHA absent from the repo.
      # git worktree add <ws> <bad_sha> fails; worker must surface as
      # {:stop, {:position_unverified, _, _}}.
      bad_base_ref = String.duplicate("deadbeef", 5)

      result =
        @worker_supervisor.spawn(sup, :implementer, "brief", bad_base_ref,
          repo_dir: repo_dir,
          agent_bin: bin_path,
          registry: registry_name
        )

      # Allow the worker process to complete its failing init.
      Process.sleep(200)

      case result do
        {:error, {:position_unverified, _, _}} ->
          :ok

        {:error, _reason} ->
          :ok

        {:ok, worker_id} ->
          registry_entries = Registry.lookup(registry_name, worker_id)

          assert registry_entries == [] or
                   (registry_entries != [] and
                      not Process.alive?(elem(hd(registry_entries), 0))),
                 "D-311: worker must not remain alive/registered after {:stop, :position_unverified}; " <>
                   "worker_id=#{inspect(worker_id)}, registry=#{inspect(registry_entries)}"
      end

      # The Port must NEVER have been opened.
      refute File.exists?(marker),
             "D-311: agent Port must NOT be launched when base_ref is unresolvable; " <>
               "marker appeared at #{marker}"
    end

    @tag :d_311
    test "D-311: HEAD-mismatch via :expected_head injection — worker aborts; no Port launched" do
      # This is the GENUINE D-311 test. It drives verify_position to {:error, _}
      # via the pinned :expected_head injection opt without making git worktree add fail.
      #
      # Injection: two commits (commit_A, commit_B).
      #   - Allocate with base_ref = commit_A -> git worktree add succeeds; worktree at A.
      #   - Pass expected_head: commit_B -> verify_position sees actual=A vs expected=B.
      #   - Mismatch -> {:stop, {:position_unverified, ws, commit_A}}.
      #   - The marker-agent Port must NEVER be opened.
      #
      # Implementer MUST honour opts[:expected_head]: after git worktree add, resolve
      # the actual HEAD SHA in the worktree and compare against
      # (opts[:expected_head] || resolved_base_ref_sha). If they differ, abort.
      tmp_dir =
        System.tmp_dir!() |> Path.join("tau_w311b_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: commit_a, alt_ref: commit_b} =
        setup_git_repo(tmp_dir, two_commits: true)

      # Marker: presence means the Port was opened despite position failure.
      marker = Path.join(tmp_dir, "port_launched_mismatch")

      bin_path = Path.join(tmp_dir, "marker_agent_mismatch")

      File.write!(bin_path, """
      #!/bin/sh
      touch #{marker}
      exit 0
      """)

      File.chmod!(bin_path, 0o755)

      {_sup_name, sup, registry_name} = start_fleet(:d311_mismatch)

      # Allocate with base_ref = commit_A; inject expected_head = commit_B.
      result =
        @worker_supervisor.spawn(sup, :implementer, "brief", commit_a,
          repo_dir: repo_dir,
          agent_bin: bin_path,
          expected_head: commit_b,
          registry: registry_name
        )

      # Allow the worker process to complete its failing init.
      Process.sleep(200)

      # The worker MUST abort — it must not be alive or registered.
      case result do
        {:error, {:position_unverified, _, _}} ->
          :ok

        {:error, _reason} ->
          :ok

        {:ok, worker_id} ->
          registry_entries = Registry.lookup(registry_name, worker_id)

          assert registry_entries == [] or
                   (registry_entries != [] and
                      not Process.alive?(elem(hd(registry_entries), 0))),
                 "D-311: worker must not remain alive/registered after HEAD mismatch; " <>
                   "worker_id=#{inspect(worker_id)}, registry=#{inspect(registry_entries)}, " <>
                   "expected_head=#{commit_b} but worktree was at #{commit_a}"
      end

      # The definitive D-311 assertion: Port was never opened.
      refute File.exists?(marker),
             "D-311: agent Port must NOT be launched when verify_position detects HEAD mismatch; " <>
               "expected_head=#{commit_b} != actual_worktree_head=#{commit_a}; " <>
               "marker appeared at #{marker}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-316 — Crash containment: kill one worker; sibling stays alive
  # ---------------------------------------------------------------------------

  describe "D-316 — crash containment" do
    @tag :d_316
    test "D-316: killing one worker delivers death-certificate; supervisor does NOT restart it; sibling stays alive" do
      tmp_dir =
        System.tmp_dir!() |> Path.join("tau_w316_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      # slow_agent so workers stay alive during registry lookup and kill.
      agent_bin = slow_agent_bin(tmp_dir)

      {_sup_name, sup, registry_name} = start_fleet(:d316)

      report_to = self()

      {:ok, worker_id1} =
        @worker_supervisor.spawn(sup, :implementer, "brief1", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          report_to: report_to,
          registry: registry_name
        )

      {:ok, worker_id2} =
        @worker_supervisor.spawn(sup, :critic, "brief2", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          report_to: report_to,
          registry: registry_name
        )

      # Resolve pids via registry — never store pids durably ([C218]).
      [{pid1, _}] = Registry.lookup(registry_name, worker_id1)
      [{pid2, _}] = Registry.lookup(registry_name, worker_id2)

      assert Process.alive?(pid1), "D-316: worker1 must be alive before kill"
      assert Process.alive?(pid2), "D-316: worker2 must be alive before kill"

      # Kill worker1 brutally.
      Process.exit(pid1, :kill)

      # (a) Death-certificate must arrive via the unlinked monitor — no drain window.
      assert_receive {:worker_exit, ^worker_id1, _reason},
                     2_000,
                     "D-316: {:worker_exit, worker_id1, _} must be delivered to report_to after :kill"

      # (b) Supervisor must NOT restart worker1 (restart: :temporary).
      Process.sleep(100)

      restarted = Registry.lookup(registry_name, worker_id1)

      assert restarted == [],
             "D-316: `:temporary` supervisor must NOT restart worker1 after :kill; " <>
               "registry still has: #{inspect(restarted)}"

      # (c) Worker2 must stay alive and registered — crash is contained.
      [{pid2_post, _}] = Registry.lookup(registry_name, worker_id2)

      assert Process.alive?(pid2_post),
             "D-316: worker2 must stay alive after worker1 crash (crash containment)"

      assert pid2_post == pid2,
             "D-316: worker2 pid must not have changed (must be same process)"

      Process.exit(pid2, :kill)
    end
  end

  # ---------------------------------------------------------------------------
  # B1/B4 — Lifecycle: spawn returns {:ok, worker_id}; Port exits; death-cert delivered
  # ---------------------------------------------------------------------------

  describe "B1/B4 — lifecycle" do
    @tag :b1_b4
    test "B1/B4: spawn/5 returns {:ok, worker_id}; Port exit delivers {:worker_exit, worker_id, :normal}" do
      tmp_dir =
        System.tmp_dir!() |> Path.join("tau_b1b4_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      # Fast dummy agent: exits 0 immediately.
      agent_bin = dummy_agent_bin(tmp_dir, "_fast")

      {_sup_name, sup, registry_name} = start_fleet(:b1b4)

      report_to = self()

      result =
        @worker_supervisor.spawn(sup, :implementer, "test brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          report_to: report_to,
          registry: registry_name
        )

      # B1: spawn/5 must return {:ok, worker_id}.
      assert {:ok, worker_id} = result,
             "B1: spawn/5 must return {:ok, worker_id}; got #{inspect(result)}"

      assert is_binary(worker_id),
             "B1: worker_id must be a binary string; got #{inspect(worker_id)}"

      # B4: death-certificate delivered by unlinked monitor on Port exit-0.
      # No drain window — the monitor fires on :DOWN for every reason.
      assert_receive {:worker_exit, ^worker_id, reason},
                     5_000,
                     "B4: {:worker_exit, worker_id, :normal} must be sent to report_to " <>
                       "after the Port exits with status 0"

      assert reason == :normal or match?({:exit_status, 0}, reason) or
               match?({:normal, _}, reason),
             "B4: worker_exit reason for exit-0 must be :normal (or {:exit_status, 0}); " <>
               "got #{inspect(reason)}"

      # Death-cert has arrived; allow cleanup a moment.
      Process.sleep(100)

      assert Registry.lookup(registry_name, worker_id) == [],
             "B1/B4: after normal exit, worker must be deregistered (restart: :temporary)"
    end

    @tag :b1_b4
    test "B1/B4: worker_id is the identity key; resolve pid from registry, not from spawn result" do
      tmp_dir =
        System.tmp_dir!() |> Path.join("tau_b1b4b_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      # Blocking agent: stays alive so we can lookup by key before it exits.
      agent_bin = slow_agent_bin(tmp_dir, "_id_test")

      {_sup_name, sup, registry_name} = start_fleet(:b1b4b)

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :reviewer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name
        )

      # Resolve pid from registry using the logical key — this is [C218].
      entries = Registry.lookup(registry_name, worker_id)

      assert entries != [],
             "B1: worker must be registered in WorkerRegistry under worker_id=#{inspect(worker_id)}"

      [{pid, _meta}] = entries
      assert Process.alive?(pid), "B1: the registered worker process must be alive"

      Process.exit(pid, :kill)
    end

    @tag :b1_b4
    test "B1/B4: :kill on worker delivers {:worker_exit, worker_id, :kill} via monitor" do
      tmp_dir =
        System.tmp_dir!() |> Path.join("tau_b1b4c_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      # Blocking agent so the worker is alive when we kill it.
      agent_bin = slow_agent_bin(tmp_dir, "_kill_test")

      {_sup_name, sup, registry_name} = start_fleet(:b1b4c)

      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          report_to: report_to,
          registry: registry_name
        )

      [{pid, _}] = Registry.lookup(registry_name, worker_id)
      assert Process.alive?(pid), "B1/B4: worker must be alive before kill"

      Process.exit(pid, :kill)

      # Monitor must deliver the death-certificate for :kill — uniform cert for all reasons.
      assert_receive {:worker_exit, ^worker_id, kill_reason},
                     2_000,
                     "B4: {:worker_exit, worker_id, :kill} must arrive via monitor on :kill"

      assert kill_reason == :kill or match?({:kill, _}, kill_reason),
             "B4: death-cert reason for :kill exit must be :kill; got #{inspect(kill_reason)}"
    end
  end
end
