defmodule Tau.Factory.UnitDriverTest do
  @moduledoc """
  Gating tests for `Tau.Factory.UnitDriver`, the real `drive_fun` the Coordinator
  calls (D-340), CORRECTED to the D-356 / arch-correct contract (PR #477).

  Advances #458 / D-340. Exercises the real `drive_fun` that wires a single
  `Tau.Factory.Unit` through the built substrate:

    * the REAL Worker fleet (`WorkerSupervisor.spawn/5` → `WorkerRegistry`-
      resolved pid → the D-326 in-band `work_ready` completion event), driven
      against a stub `agent_bin` inside a throwaway git repo;
    * a `:gate_fun` seam wrapping the gate result into `:pass | {:fail, _}`;
    * a `:merge_fun` seam that builds the `%{id, hash, run, branch}` merge map and
      reaches a (stubbed) `MergeAuthority.request_merge/2`. The async merge result
      is delivered the REAL way — a `Phoenix.PubSub.broadcast` of
      `{:merge_result, :merged | :rejected}` to `"factory:pr:\#{unit_id}"` on the
      shared `Tau.PubSub` (SPEC-FACTORY-MERGE / SPEC-FACTORY-CORE §6 D-356) — NOT a
      direct `send` to the unit pid, and NOT a driver-side telemetry→Unit bridge
      (the bridge is FORBIDDEN by MERGE D-356).

  ## Reclaim is the WorkspaceJanitor's, not the driver's (PR #477, §4 B8)

  The `UnitDriver` threads `:janitor` (a running `Tau.Factory.WorkspaceJanitor`)
  into the `worker_fun`'s `WorkerSupervisor.spawn/5` opts; the spawned `Worker`
  registers itself with the janitor, which `Process.monitor/1`s it and on its
  `:DOWN` (for ANY exit reason) executes capture-before-destroy and reclaims the
  worktree (D-313/D-314). The UnitDriver performs ZERO worktree reclaim of its
  own and starts NO bridge. These tests assert reclaim happened (no leaked
  private worktree) on BOTH the merge path AND the escalation path — satisfied by
  the janitor's `:DOWN` handler, never by a driver-side reclaim.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  On THIS branch the production code still: (a) delivers the merge result via a
  driver-side telemetry bridge and a direct `send` to the unit pid; (b) does NOT
  thread `:janitor` into the worker spawn opts; and (c) the Unit does NOT
  subscribe to `"factory:pr:\#{unit_id}"`. So a `{:merge_result, :merged}`
  broadcast on the topic is DROPPED (the Unit is not a subscriber) — the Unit
  never reaches `:merged` and escalates on `state_timeout`; the
  `assert_receive {:unit_terminal, _, :merged, _}` TIMES OUT. A test that passed
  against the current code would be vacuous.

  ## PINNED contract — `Tau.Factory.UnitDriver.drive/2`

  `UnitDriver.drive(work_item, deps) :: pid()` — returns the started Unit pid.
  The Unit, once terminal, sends `{:unit_terminal, unit_id, outcome, provenance}`
  to `deps.report_to`.

  `deps` carries the live substrate, INCLUDING the D-356/B8 additions:

    * `:janitor`  — atom/pid of a running `Tau.Factory.WorkspaceJanitor`; threaded
                    into the worker spawn opts so the janitor owns reclaim.
    * `:pubsub`   — the shared `Phoenix.PubSub` instance (`Tau.PubSub`); the Unit
                    subscribes to `"factory:pr:\#{unit_id}"` on awaiting_merge entry.

  ## AC / D-NNN linkage
    - D-340 — every test in this file.
    - D-356 — the merge-result-via-PubSub delivery exercised by the happy/merge tests.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :d_340
  @moduletag :d_356

  # Runtime module references — @mod.fun form (Credo strict), never apply/2,3.
  @unit_driver Tau.Factory.UnitDriver
  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler
  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor
  @janitor Tau.Factory.WorkspaceJanitor
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Hermetic git repo (mirrors worker_test.exs / worker_reclaim_test.exs idiom)
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

  # A stub agent_bin that emits ONE {:packet,4}-framed JSON work_ready frame then
  # exits 0 (the D-326 in-band success signal the Worker forwards to its Unit).
  defp work_ready_agent_bin(tmp_dir, branch, head_sha, suffix) do
    bin_path = Path.join(tmp_dir, "work_ready_agent#{suffix}")

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
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp mk_tmp(tag) do
    tmp_dir = Path.join(System.tmp_dir!(), "tau_udrv_#{tag}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    tmp_dir
  end

  # Start the full substrate the UnitDriver wires its seams to — now including a
  # real Ledger.Writer + WorkspaceJanitor (the reclaim owner) and the shared
  # Tau.PubSub. Mirrors the janitor wiring in workspace_janitor_test.exs /
  # worker_reclaim_test.exs.
  defp start_substrate(tag, repo_dir, agent_bin) do
    n = System.unique_integer([:positive])

    unit_sup = :"udrv_unitsup_#{tag}_#{n}"
    unit_reg = :"udrv_unitreg_#{tag}_#{n}"
    sched = :"udrv_sched_#{tag}_#{n}"
    worker_reg = :"udrv_workerreg_#{tag}_#{n}"
    worker_sup = :"udrv_workersup_#{tag}_#{n}"
    ledger = :"udrv_ledger_#{tag}_#{n}"
    janitor = :"udrv_janitor_#{tag}_#{n}"

    db_path = Path.join(System.tmp_dir!(), "udrv_ledger_#{tag}_#{n}.db")
    on_exit(fn -> File.rm_rf!(db_path) end)

    start_supervised!({@scheduler, name: sched, w_cap: 10}, id: sched)
    start_supervised!({@unit_supervisor, name: unit_sup}, id: unit_sup)

    start_supervised!(
      %{
        id: unit_reg,
        start: {Registry, :start_link, [[keys: :unique, name: unit_reg]]}
      },
      id: unit_reg
    )

    start_supervised!({@worker_registry, name: worker_reg}, id: worker_reg)
    start_supervised!({@worker_supervisor, name: worker_sup, registry: worker_reg}, id: worker_sup)

    # Real Ledger.Writer (the WorkspaceJanitor's capture sink) + WorkspaceJanitor
    # (the reclaim owner; monitors each worker, reclaims on every :DOWN — D-313/14).
    start_supervised!({@writer, db_path: db_path, name: ledger}, id: ledger)
    start_supervised!({@janitor, ledger: ledger, name: janitor}, id: janitor)

    %{
      unit_supervisor: unit_sup,
      unit_registry: unit_reg,
      scheduler: sched,
      worker_registry: worker_reg,
      worker_supervisor: worker_sup,
      ledger: ledger,
      janitor: janitor,
      repo_dir: repo_dir,
      agent_bin: agent_bin
    }
  end

  # A stubbed MergeAuthority: a tiny process exposing the `request_merge/2`
  # contract shape via the {:"$gen_call", from, {:request_merge, map}} protocol.
  # It forwards the merge map to the test, then replies :queued. The async result
  # the Unit needs is delivered the REAL way by the test — a Phoenix.PubSub
  # broadcast of {:merge_result, _} to "factory:pr:#{unit_id}" (D-356) — standing
  # in for the real MergeAuthority's emission half. There is NO direct send to the
  # unit pid and NO telemetry bridge.
  defp start_stub_merge_authority(report_to) do
    spawn(fn -> stub_merge_loop(report_to) end)
  end

  defp stub_merge_loop(report_to) do
    receive do
      {:"$gen_call", from, {:request_merge, merge_map}} ->
        send(report_to, {:merge_requested, merge_map})
        :gen.reply(from, :queued)
        stub_merge_loop(report_to)

      _other ->
        stub_merge_loop(report_to)
    end
  end

  defp pr_topic(unit_id), do: "factory:pr:#{unit_id}"

  defp deps_for(sub, gate_fun, merge_authority, report_to) do
    %{
      unit_supervisor: sub.unit_supervisor,
      unit_registry: sub.unit_registry,
      scheduler: sub.scheduler,
      worker_supervisor: sub.worker_supervisor,
      worker_registry: sub.worker_registry,
      ledger: sub.ledger,
      # #479 task 3: the WorkspaceJanitor is a singleton per node — it always
      # registers under `Tau.Factory.WorkspaceJanitor` (`__MODULE__`) and IGNORES
      # the `:name` opt (SPEC-FACTORY-FLEET §4 C4; worker-fleet.md). Threading the
      # bespoke per-test name (`sub.janitor`) here was a NO-OP masked by the
      # driver's `whereis(WorkspaceJanitor) || deps.janitor` resolution. Pass the
      # singleton MODULE so the `:janitor` test-injection seam names the real
      # running janitor — correct under both the current driver (`whereis || dep`)
      # and the #479 driver change (`deps[:janitor] || WorkspaceJanitor`).
      janitor: @janitor,
      pubsub: Tau.PubSub,
      repo_dir: sub.repo_dir,
      agent_bin: sub.agent_bin,
      gate_fun: gate_fun,
      merge_authority: merge_authority,
      report_to: report_to
    }
  end

  # ---------------------------------------------------------------------------
  # D-340a — Happy path: real Unit + real Worker → 4-arg {:unit_terminal,…,:merged}
  # The merge result is delivered via a Tau.PubSub broadcast on the per-PR topic
  # (D-356). The worker worktree is reclaimed by the JANITOR (not the driver).
  # ---------------------------------------------------------------------------

  describe "D-340/D-356 — UnitDriver.drive/2 happy path reaches :merged via the real substrate" do
    @tag :d_340
    @tag :d_356
    test "D-340/D-356: drive/2 runs a real Unit+Worker to {:unit_terminal, id, :merged, prov}; janitor reclaims the worktree" do
      tmp_dir = mk_tmp("happy")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/u-happy"
      head_sha = String.duplicate("ab12cd34", 5)
      agent_bin = work_ready_agent_bin(tmp_dir, branch, head_sha, "_happy")

      sub = start_substrate(:happy, repo_dir, agent_bin)
      test_pid = self()
      merge_authority = start_stub_merge_authority(test_pid)

      n = System.unique_integer([:positive])
      unit_id = "pr-happy-#{n}"

      work_item = %{
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        branch: branch,
        run: "run-1",
        base_ref: base_ref,
        brief: "implement the thing"
      }

      deps = deps_for(sub, fn -> :pass end, merge_authority, test_pid)

      unit_pid = @unit_driver.drive(work_item, deps)

      assert is_pid(unit_pid),
             "D-340: drive/2 must return the started Unit pid; got #{inspect(unit_pid)}"

      # The driver's :merge_fun must have built the merge map and reached the
      # (stubbed) MergeAuthority with the EXACT %{id, hash, run, branch} shape.
      assert_receive {:merge_requested, merge_map},
                     8_000,
                     "D-340: the driver's :merge_fun must call MergeAuthority.request_merge/2 " <>
                       "with a %{id, hash, run, branch} map (the merge seam was never reached)."

      assert merge_map.id == unit_id,
             "D-340: merge map :id must be the unit_id; got #{inspect(merge_map)}"

      # D-361: merge coordinate is the captured head_sha (from {:work_ready, id, branch, sha}),
      # NOT the pre-declared work_item.hash. The work_ready_agent_bin emits head_sha as the
      # coordinate, which the Unit captures and threads to merge_fun (D-362).
      assert merge_map.hash == head_sha,
             "D-361: merge map :hash must be the captured head_sha (#{inspect(head_sha)}), " <>
               "not the pre-declared work_item hash; got #{inspect(merge_map)}"

      assert merge_map.branch == branch,
             "D-340: merge map :branch must be the work_item branch; got #{inspect(merge_map)}"

      assert merge_map.run == "run-1",
             "D-340: merge map :run must be the work_item run; got #{inspect(merge_map)}"

      # Deliver the merge outcome the REAL way: broadcast {:merge_result, :merged}
      # to the per-PR topic on the shared Tau.PubSub (D-356). The Unit must have
      # subscribed to this topic on awaiting_merge entry; the broadcast reaches it
      # off its mailbox and drives it to terminal :merged. NO direct send, NO bridge.
      :ok = Phoenix.PubSub.broadcast(Tau.PubSub, pr_topic(unit_id), {:merge_result, :merged})

      # The coordinator seam receives the 4-arg D-340 terminal report.
      assert_receive {:unit_terminal, ^unit_id, :merged, provenance},
                     10_000,
                     "D-340/D-356: coordinator seam must receive {:unit_terminal, id, :merged, prov} " <>
                       "after the {:merge_result, :merged} broadcast on #{pr_topic(unit_id)}. A " <>
                       "timeout means the Unit never subscribed to the topic (the broadcast was " <>
                       "dropped) — it escalated on state_timeout instead of merging."

      assert is_map(provenance),
             "D-340: provenance must be a map; got #{inspect(provenance)}"

      # The Scheduler released the unit on terminal.
      in_flight = @scheduler.in_flight(sub.scheduler)

      refute Map.has_key?(in_flight, unit_id),
             "D-340: after :merged the unit must be released from Scheduler in_flight"

      # The real Worker created a private worktree under the repo and the JANITOR
      # reclaimed it on the worker's exit (no leaked private worktree). This is the
      # janitor's sole-ownership reclaim — NOT a driver-side reclaim.
      assert poll_no_worker_worktrees(repo_dir, 5_000),
             "D-340/D-356: all private worker worktrees must be reclaimed BY THE JANITOR after " <>
               "the run; a leak means the janitor was not wired (deps.janitor not threaded into " <>
               "the worker spawn opts) or the driver attempted its own (forbidden) reclaim."
    end
  end

  # ---------------------------------------------------------------------------
  # D-340b — Gate fail drives the retry ladder → terminal :escalated.
  # Reclaim still happens on EVERY worker :DOWN (the janitor reclaims on the
  # escalation path too, not just the merge path).
  # ---------------------------------------------------------------------------

  describe "D-340 — a failing gate_fun drives the retry ladder to terminal :escalated" do
    @tag :d_340
    test "D-340: a :gate_fun always returning {:fail,_} exhausts the ladder → {:unit_terminal, id, :escalated, prov}; janitor reclaims" do
      tmp_dir = mk_tmp("gatefail")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/u-gatefail"
      head_sha = String.duplicate("99887766", 5)
      agent_bin = work_ready_agent_bin(tmp_dir, branch, head_sha, "_gatefail")

      sub = start_substrate(:gatefail, repo_dir, agent_bin)
      test_pid = self()
      merge_authority = start_stub_merge_authority(test_pid)

      n = System.unique_integer([:positive])
      unit_id = "pr-gatefail-#{n}"

      work_item = %{
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        branch: branch,
        run: "run-1",
        base_ref: base_ref,
        brief: "implement the thing"
      }

      deps = deps_for(sub, fn -> {:fail, [:always_fails]} end, merge_authority, test_pid)

      unit_pid = @unit_driver.drive(work_item, deps)
      assert is_pid(unit_pid), "D-340: drive/2 must return the Unit pid"

      # The terminal outcome reflects ladder exhaustion: :escalated, NOT :merged.
      assert_receive {:unit_terminal, ^unit_id, outcome, provenance},
                     20_000,
                     "D-340: a permanently-failing gate must drive a terminal {:unit_terminal,…}."

      assert outcome == :escalated,
             "D-340: a gate that never passes must terminate :escalated (retry ladder " <>
               "exhausted), not #{inspect(outcome)}."

      assert is_map(provenance) and Map.get(provenance, :reason) != nil,
             "D-340: an escalation provenance must carry a non-nil :reason; got " <>
               "#{inspect(provenance)}"

      # A failing gate must NEVER reach the merge seam.
      refute_received {:merge_requested, _map},
                      "D-340: a failing gate must never request a merge."

      # Reclaim-on-escalation: the janitor reclaims on EVERY worker :DOWN, not only
      # the merge path. After ladder exhaustion every spawned worker has exited, so
      # no private worktree may remain.
      assert poll_no_worker_worktrees(repo_dir, 5_000),
             "D-340: after :escalated all private worker worktrees must be reclaimed BY THE " <>
               "JANITOR (it reclaims on every :DOWN, including the escalation path). A leak means " <>
               "reclaim was tied to the merge path only (the forbidden driver-side reclaim)."
    end
  end

  # ---------------------------------------------------------------------------
  # D-340c — The merge seam: request_merge map shape + the PubSub-delivered result
  # ---------------------------------------------------------------------------

  describe "D-340/D-356 — the merge seam delivers the async result via the per-PR topic" do
    @tag :d_340
    @tag :d_356
    test "D-340/D-356: the :merge_fun builds %{id, hash, run, branch} for MergeAuthority and the :merged broadcast reaches :merged" do
      tmp_dir = mk_tmp("mergeseam")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/u-mergeseam"
      head_sha = String.duplicate("deadbeef", 5)
      agent_bin = work_ready_agent_bin(tmp_dir, branch, head_sha, "_mergeseam")

      sub = start_substrate(:mergeseam, repo_dir, agent_bin)
      test_pid = self()
      merge_authority = start_stub_merge_authority(test_pid)

      n = System.unique_integer([:positive])
      unit_id = "pr-mergeseam-#{n}"
      run_id = "run-#{n}"

      work_item = %{
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        branch: branch,
        run: run_id,
        base_ref: base_ref,
        brief: "implement the thing"
      }

      deps = deps_for(sub, fn -> :pass end, merge_authority, test_pid)

      unit_pid = @unit_driver.drive(work_item, deps)
      assert is_pid(unit_pid), "D-340: drive/2 must return the Unit pid"

      # The merge map reaches the (stubbed) MergeAuthority with the full,
      # MergeAuthority-required key set %{id, hash, run, branch}.
      assert_receive {:merge_requested, merge_map},
                     8_000,
                     "D-340: the driver's :merge_fun must reach MergeAuthority.request_merge/2."

      for key <- [:id, :hash, :run, :branch] do
        assert Map.has_key?(merge_map, key),
               "D-340: the merge map must carry :#{key} (MergeAuthority.request_merge/2 requires " <>
                 ":id, :hash, :run, :branch); got #{inspect(merge_map)}"
      end

      assert merge_map.id == unit_id and merge_map.run == run_id,
             "D-340: merge map :id/:run must round-trip the work_item; got #{inspect(merge_map)}"

      # The async merge result is delivered via the per-PR PubSub topic (D-356);
      # the Unit (subscribed on awaiting_merge entry) reaches terminal :merged.
      :ok = Phoenix.PubSub.broadcast(Tau.PubSub, pr_topic(unit_id), {:merge_result, :merged})

      assert_receive {:unit_terminal, ^unit_id, :merged, _provenance},
                     8_000,
                     "D-340/D-356: the {:merge_result, :merged} broadcast on #{pr_topic(unit_id)} " <>
                       "must drive the Unit to terminal :merged (it subscribed on entry)."
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A scope clearing all five ConflictCheck clauses against any other empty scope.
  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # List private worker worktrees registered in the repo (everything that is not
  # the repo's own main worktree). [] means all were reclaimed.
  defp worker_worktrees(repo_dir) do
    {wt_list, _} =
      System.cmd("git", ["worktree", "list", "--porcelain"],
        cd: repo_dir,
        stderr_to_stdout: true
      )

    wt_list
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "worktree "))
    |> Enum.map(&String.trim_leading(&1, "worktree "))
    |> Enum.reject(fn path ->
      path == "" or path == repo_dir or String.starts_with?(path, repo_dir <> "/")
    end)
  end

  # Poll until no private worker worktrees remain (janitor reclaim is async after
  # the worker :DOWN fires) or the deadline passes.
  defp poll_no_worker_worktrees(repo_dir, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_no_worker_worktrees(repo_dir, deadline, interval_ms)
  end

  defp do_poll_no_worker_worktrees(repo_dir, deadline, interval_ms) do
    cond do
      worker_worktrees(repo_dir) == [] ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(interval_ms)
        do_poll_no_worker_worktrees(repo_dir, deadline, interval_ms)
    end
  end
end
