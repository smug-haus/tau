defmodule Tau.Factory.UnitDriverTest do
  @moduledoc """
  Gating tests for PR #477 (P5c-3b — `Tau.Factory.UnitDriver`, the real
  `drive_fun` the Coordinator calls).

  Closes #473 / advances #458. Exercises D-340 — the real `drive_fun` that
  wires a single `Tau.Factory.Unit` through the now-built substrate:

    * the REAL Worker fleet (`WorkerSupervisor.spawn/5` →
      `WorkerRegistry`-resolved pid → the D-326 in-band `work_ready`
      completion event — the `:worker_fun` seam), driven against a stub
      `agent_bin` inside a throwaway git repo;
    * a `:gate_fun` seam wrapping the gate result into `:pass | {:fail, _}`;
    * a `:merge_fun` seam that builds the `%{id, hash, run, branch}` merge map,
      reaches a (stubbed) `MergeAuthority.request_merge/2`, and BRIDGES the
      async merge result back to the Unit as `{:merge_result, :merged | :rejected}`
      (merge-and-integration.md ~65-70; control-plane.md §line 597 — M's result
      arrives on a per-PR topic, NOT a blocking call).

  The Unit emits `{:unit_terminal, unit_id, outcome, provenance}` (4-arg, D-340)
  to the coordinator seam (`:report_to`).

  Written BEFORE production code exists (oracle-separation phase, factory-loop
  §4b). These tests MUST FAIL against current `main` because
  `Tau.Factory.UnitDriver` does not exist (`UndefinedFunctionError`). A
  compile/undefined/timeout failure is the correct fail-before state and MUST
  NOT be resolved by writing production code in this PR.

  ## PINNED contract — `Tau.Factory.UnitDriver.drive/2`

  `UnitDriver.drive(work_item, deps) :: pid()`

  Returns the pid of the started `Tau.Factory.Unit` (started under the supplied
  `UnitSupervisor` via `start_unit/2`, with `report_to: deps.report_to`). The
  Unit, once terminal, sends `{:unit_terminal, unit_id, outcome, provenance}` to
  `deps.report_to`.

  `work_item` (a map; co-designed with P5c-4's `{issue, scope, hash, branch}`):

    * `:unit_id`        — String.t(); the unit identity (== the PR/unit id used
                          in the merge map's `:id`).
    * `:declared_scope` — `ConflictCheck.scope()` passed to `Scheduler.admit/3`.
    * `:hash`           — String.t(); content/HEAD hash for the PR.
    * `:branch`         — String.t(); the feature branch (passed in the merge map).
    * `:run`            — String.t(); the run identifier (merge-map `:run`).
    * `:base_ref`       — String.t(); the git ref `WorkerSupervisor.spawn/5`
                          checks out for the worker worktree.
    * `:brief`          — String.t(); the worker brief.

  `deps` (a map carrying the live substrate the driver wires the seams to):

    * `:unit_supervisor`   — atom/pid of a running `UnitSupervisor`.
    * `:unit_registry`     — atom of a running `UnitRegistry` (passed to the Unit
                             as `:registry_name`).
    * `:scheduler`         — atom/pid of a running `Scheduler`.
    * `:worker_supervisor` — atom/pid of a running `WorkerSupervisor`.
    * `:worker_registry`   — atom of a running `WorkerRegistry`.
    * `:repo_dir`          — String.t(); the parent git repo for worker worktrees.
    * `:agent_bin`         — String.t(); the agent executable each worker runs.
    * `:gate_fun`          — `(-> :pass | {:fail, findings})`; the gate seam. (The
                             driver MAY also build this from a real `Gate.run/1`
                             over the worker worktree; this test injects it so the
                             gate outcome is hermetic and deterministic.)
    * `:merge_authority`   — atom/pid of a (stubbed) `MergeAuthority`; the driver's
                             `:merge_fun` calls `request_merge/2` against it.
    * `:report_to`         — pid receiving `{:unit_terminal, ...}` (the coordinator
                             seam) AND the merge-result bridge anchor.
    * `:ledger`            — optional; `GenServer.server()` | nil.

  ## PINNED — the `:merge_fun` bridge (D-340 / merge-and-integration.md)

  The driver constructs a `:merge_fun` of the Unit-required arity
  `(unit_id, hash -> :queued | {:error, reason})` that:

    1. builds the merge map `%{id: unit_id, hash: hash, run: run, branch: branch}`,
    2. calls `MergeAuthority.request_merge(merge_authority, merge_map)`, and
    3. bridges the async merge result (telemetry `[:tau, :factory, :merge, :merged]`
       / `[:tau, :factory, :merge, :reject]`, or the per-PR PubSub projection)
       back to the Unit pid as `{:merge_result, :merged}` / `{:merge_result, :rejected}`.

  These tests assert the merge map REACHES the MergeAuthority (the stub forwards
  it to the test) and that a `:queued`-then-merged bridge drives the Unit to
  `:merged`.

  ## AC / D-NNN linkage
    - D-340 — every test in this file.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :d_340

  # Runtime module references — @mod.fun form (Credo strict), never apply/2,3.
  # The file compiles while UnitDriver is absent; the call sites below raise
  # UndefinedFunctionError until the implementer lands it.
  @unit_driver Tau.Factory.UnitDriver
  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler
  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

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
  # Mirrors worker_completion_event_test.exs's framing exactly.
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

  # Start the full substrate the UnitDriver wires its seams to.
  defp start_substrate(tag, repo_dir, agent_bin) do
    n = System.unique_integer([:positive])

    unit_sup = :"udrv_unitsup_#{tag}_#{n}"
    unit_reg = :"udrv_unitreg_#{tag}_#{n}"
    sched = :"udrv_sched_#{tag}_#{n}"
    worker_reg = :"udrv_workerreg_#{tag}_#{n}"
    worker_sup = :"udrv_workersup_#{tag}_#{n}"

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

    %{
      unit_supervisor: unit_sup,
      unit_registry: unit_reg,
      scheduler: sched,
      worker_registry: worker_reg,
      worker_supervisor: worker_sup,
      repo_dir: repo_dir,
      agent_bin: agent_bin
    }
  end

  # A stubbed MergeAuthority: a tiny process exposing the `request_merge/2`
  # contract shape via the {:"$gen_call", from, {:request_merge, map}} protocol
  # (so `:gen_statem.call/2` / `GenServer.call/2` against it work unchanged). It
  # forwards the received merge map to the test, then replies :queued. The
  # :merge_result the Unit needs is delivered separately (driver bridge / test),
  # standing in for the real async MergeAuthority result projection.
  #
  # The real MergeAuthority is heavy (runs a real rebase+push build), so this
  # stub stands in at the request_merge boundary to let the test assert the
  # EXACT merge map the driver built reaches the authority.
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

  # ---------------------------------------------------------------------------
  # D-340a — Happy path: real Unit + real Worker → 4-arg {:unit_terminal,…,:merged}
  # ---------------------------------------------------------------------------

  describe "D-340 — UnitDriver.drive/2 happy path reaches :merged via the real substrate" do
    @tag :d_340
    test "D-340: drive/2 runs a real Unit+Worker to a 4-arg {:unit_terminal, id, :merged, prov}; worktree created+reclaimed" do
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

      # gate_fun PASSes deterministically (hermetic — the real Gate.run/1 is too
      # heavy here; the driver accepts an injected gate_fun seam, per the contract).
      deps = %{
        unit_supervisor: sub.unit_supervisor,
        unit_registry: sub.unit_registry,
        scheduler: sub.scheduler,
        worker_supervisor: sub.worker_supervisor,
        worker_registry: sub.worker_registry,
        repo_dir: repo_dir,
        agent_bin: agent_bin,
        gate_fun: fn -> :pass end,
        merge_authority: merge_authority,
        report_to: test_pid
      }

      unit_pid = @unit_driver.drive(work_item, deps)

      assert is_pid(unit_pid),
             "D-340: drive/2 must return the started Unit pid; got #{inspect(unit_pid)}"

      # The driver's :merge_fun must have built the merge map and reached the
      # (stubbed) MergeAuthority with the EXACT %{id, hash, run, branch} shape.
      assert_receive {:merge_requested, merge_map},
                     5_000,
                     "D-340: the driver's :merge_fun must call MergeAuthority.request_merge/2 " <>
                       "with a %{id, hash, run, branch} map (the merge seam was never reached)."

      assert merge_map.id == unit_id,
             "D-340: merge map :id must be the unit_id; got #{inspect(merge_map)}"

      assert merge_map.hash == "hash-#{unit_id}",
             "D-340: merge map :hash must be the work_item hash; got #{inspect(merge_map)}"

      assert merge_map.branch == branch,
             "D-340: merge map :branch must be the work_item branch; got #{inspect(merge_map)}"

      assert merge_map.run == "run-1",
             "D-340: merge map :run must be the work_item run; got #{inspect(merge_map)}"

      # Bridge the merge outcome back to the Unit (the driver's bridge or the test
      # standing in for the async MergeAuthority projection). After request_merge,
      # an external :merged result must drive the Unit to terminal :merged.
      send(unit_pid, {:merge_result, :merged})

      # The coordinator seam receives the 4-arg D-340 terminal report.
      assert_receive {:unit_terminal, ^unit_id, :merged, provenance},
                     10_000,
                     "D-340: coordinator seam must receive the 4-arg {:unit_terminal, id, :merged, prov}."

      assert is_map(provenance),
             "D-340: provenance must be a map; got #{inspect(provenance)}"

      # The Scheduler released the unit on terminal.
      in_flight = @scheduler.in_flight(sub.scheduler)

      refute Map.has_key?(in_flight, unit_id),
             "D-340: after :merged the unit must be released from Scheduler in_flight"

      # The real Worker created a private worktree under the repo and the fleet
      # reclaimed it on the worker's normal exit (no leaked private worktree).
      assert worker_worktrees(repo_dir) == [],
             "D-340: all private worker worktrees must be reclaimed after the run; a leak " <>
               "means the real Worker fleet was not driven, or reclaim did not fire."
    end
  end

  # ---------------------------------------------------------------------------
  # D-340b — Gate fail drives the retry ladder → terminal :escalated
  # ---------------------------------------------------------------------------

  describe "D-340 — a failing gate_fun drives the retry ladder to terminal :escalated" do
    @tag :d_340
    test "D-340: a :gate_fun always returning {:fail,_} exhausts the ladder → {:unit_terminal, id, :escalated, prov}" do
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

      # gate_fun ALWAYS fails → the Unit's bounded retry ladder (D-318) re-spawns
      # workers via the driver's :worker_fun until exhaustion, then escalates.
      deps = %{
        unit_supervisor: sub.unit_supervisor,
        unit_registry: sub.unit_registry,
        scheduler: sub.scheduler,
        worker_supervisor: sub.worker_supervisor,
        worker_registry: sub.worker_registry,
        repo_dir: repo_dir,
        agent_bin: agent_bin,
        gate_fun: fn -> {:fail, [:always_fails]} end,
        merge_authority: merge_authority,
        report_to: test_pid
      }

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

      refute_receive {:unit_terminal, ^unit_id, :merged, _},
                     500,
                     "D-340: a permanently-failing gate must never reach :merged."
    end
  end

  # ---------------------------------------------------------------------------
  # D-340c — The merge seam: request_merge map shape + the bridged :merged result
  # ---------------------------------------------------------------------------

  describe "D-340 — the merge seam bridges the async result to the Unit" do
    @tag :d_340
    test "D-340: the :merge_fun builds %{id, hash, run, branch} for MergeAuthority and the :merged bridge reaches :merged" do
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

      deps = %{
        unit_supervisor: sub.unit_supervisor,
        unit_registry: sub.unit_registry,
        scheduler: sub.scheduler,
        worker_supervisor: sub.worker_supervisor,
        worker_registry: sub.worker_registry,
        repo_dir: repo_dir,
        agent_bin: agent_bin,
        gate_fun: fn -> :pass end,
        merge_authority: merge_authority,
        report_to: test_pid
      }

      unit_pid = @unit_driver.drive(work_item, deps)
      assert is_pid(unit_pid), "D-340: drive/2 must return the Unit pid"

      # The merge map reaches the (stubbed) MergeAuthority with the full,
      # MergeAuthority-required key set %{id, hash, run, branch} (request_merge/2
      # contract — merge_authority.ex line 70-73).
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

      # The async merge result is bridged to the Unit as {:merge_result, :merged};
      # the Unit reaches terminal :merged (control-plane.md §line 597).
      send(unit_pid, {:merge_result, :merged})

      assert_receive {:unit_terminal, ^unit_id, :merged, _provenance},
                     8_000,
                     "D-340: the bridged :merged result must drive the Unit to terminal :merged."
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
end
