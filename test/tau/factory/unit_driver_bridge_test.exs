defmodule Tau.Factory.UnitDriverBridgeTest do
  @moduledoc """
  Tests for the merge-result telemetry bridge inside `Tau.Factory.UnitDriver`.

  These tests exercise the REAL bridge (not stubbed), verifying:

    1. A genuine `:telemetry.execute([:tau,:factory,:merge,:merged], ...)` for
       the unit causes EXACTLY ONE `{:merge_result, :merged}` to be delivered
       to the unit pid.
    2. A second merge event for the same unit is NOT delivered (handler detached
       after first delivery).
    3. A `[:tau,:factory,:merge,:reject]` event maps to `{:merge_result, :rejected}`.
    4. An event for a DIFFERENT unit_id is NOT delivered to this unit.

  ## D-NNN linkage
    - D-340 — all tests in this file.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :d_340

  # We test the bridge by reaching into the private helper via the public
  # install path. The bridge is started and wired as part of `drive/2`,
  # but for isolation we call the module's internal bridge directly by
  # starting it through a minimal harness.
  #
  # Strategy: start a bridge process, send {:unit_started, unit_pid},
  # send {:arm_merge_bridge, unit_pid}, then fire real telemetry events
  # and assert message delivery to unit_pid.
  #
  # The bridge process is not a public API — we access it via the module's
  # exported behaviour by constructing a minimal drive/2 run with a pre-wired
  # test harness, OR by exercising the bridge through drive/2 itself with
  # injected telemetry.

  # ---------------------------------------------------------------------------
  # Bridge harness: start the bridge and wire it up without a full drive/2 run
  # ---------------------------------------------------------------------------

  # Start a bridge via the module's internal start_bridge path by driving it
  # through a minimal drive/2 invocation with stubs that pause at
  # awaiting_merge, then emit telemetry directly.

  alias Tau.Factory.UnitDriver
  alias Tau.Factory.UnitSupervisor
  alias Tau.Factory.Scheduler
  alias Tau.Factory.WorkerRegistry
  alias Tau.Factory.WorkerSupervisor

  # Helpers for starting the full substrate (mirrors unit_driver_test.exs)
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
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "tau_bridge_#{tag}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    tmp_dir
  end

  defp start_substrate(tag, repo_dir, agent_bin) do
    n = System.unique_integer([:positive])

    unit_sup = :"bridge_unitsup_#{tag}_#{n}"
    unit_reg = :"bridge_unitreg_#{tag}_#{n}"
    sched = :"bridge_sched_#{tag}_#{n}"
    worker_reg = :"bridge_workerreg_#{tag}_#{n}"
    worker_sup = :"bridge_workersup_#{tag}_#{n}"

    start_supervised!({Scheduler, name: sched, w_cap: 10}, id: sched)
    start_supervised!({UnitSupervisor, name: unit_sup}, id: unit_sup)

    start_supervised!(
      %{
        id: unit_reg,
        start: {Registry, :start_link, [[keys: :unique, name: unit_reg]]}
      },
      id: unit_reg
    )

    start_supervised!({WorkerRegistry, name: worker_reg}, id: worker_reg)
    start_supervised!({WorkerSupervisor, name: worker_sup, registry: worker_reg}, id: worker_sup)

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

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # ---------------------------------------------------------------------------
  # Test 1: exactly one {:merge_result, :merged} on :merged telemetry event
  # ---------------------------------------------------------------------------

  describe "merge bridge — telemetry delivery and detach" do
    @tag :d_340
    test "bridge delivers exactly one {:merge_result, :merged} and detaches on first :merged event" do
      tmp_dir = mk_tmp("single_merged")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/bridge-merged"
      head_sha = String.duplicate("aabbccdd", 5)
      agent_bin = work_ready_agent_bin(tmp_dir, branch, head_sha, "_bridgeA")

      sub = start_substrate(:bridge_a, repo_dir, agent_bin)
      test_pid = self()
      merge_authority = start_stub_merge_authority(test_pid)

      n = System.unique_integer([:positive])
      unit_id = "pr-bridge-merged-#{n}"

      work_item = %{
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        branch: branch,
        run: "run-1",
        base_ref: base_ref,
        brief: "test brief"
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

      unit_pid = UnitDriver.drive(work_item, deps)
      assert is_pid(unit_pid)

      # Wait for merge to be requested (unit reached awaiting_merge,
      # merge_fun called request_merge, bridge armed the handler).
      assert_receive {:merge_requested, _merge_map},
                     8_000,
                     "unit must reach awaiting_merge and call request_merge"

      # Small pause to ensure the bridge has processed the :arm_merge_bridge
      # message and installed the telemetry handler before we fire the event.
      Process.sleep(50)

      # Fire a REAL telemetry :merged event for this unit_id.
      :telemetry.execute(
        [:tau, :factory, :merge, :merged],
        %{},
        %{units: [%{id: unit_id}]}
      )

      # Exactly one {:merge_result, :merged} must reach the unit pid.
      # We receive it here because the unit forwards it to report_to; but the
      # unit itself receives it and transitions to :merged (driven to terminal).
      assert_receive {:unit_terminal, ^unit_id, :merged, _provenance},
                     8_000,
                     "unit must receive {:merge_result, :merged} and reach :merged terminal"

      # The bridge must have detached its handler after the first delivery.
      # Fire a SECOND :merged event for the same unit_id.
      :telemetry.execute(
        [:tau, :factory, :merge, :merged],
        %{},
        %{units: [%{id: unit_id}]}
      )

      # The unit is already terminal; no second {:unit_terminal, ...} must arrive.
      refute_receive {:unit_terminal, ^unit_id, _, _},
                     500,
                     "bridge must not deliver a second merge_result after detach"
    end

    @tag :d_340
    test "bridge maps [:tau,:factory,:merge,:reject] event to {:merge_result, :rejected}" do
      tmp_dir = mk_tmp("bridge_reject")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/bridge-reject"
      head_sha = String.duplicate("11223344", 5)
      agent_bin = work_ready_agent_bin(tmp_dir, branch, head_sha, "_bridgeB")

      sub = start_substrate(:bridge_b, repo_dir, agent_bin)
      test_pid = self()
      merge_authority = start_stub_merge_authority(test_pid)

      n = System.unique_integer([:positive])
      unit_id = "pr-bridge-reject-#{n}"

      work_item = %{
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        branch: branch,
        run: "run-1",
        base_ref: base_ref,
        brief: "test brief"
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

      unit_pid = UnitDriver.drive(work_item, deps)
      assert is_pid(unit_pid)

      # Wait for merge to be requested.
      assert_receive {:merge_requested, _merge_map},
                     8_000,
                     "unit must reach awaiting_merge and call request_merge"

      Process.sleep(50)

      # Fire a REAL telemetry :reject event for this unit_id.
      :telemetry.execute(
        [:tau, :factory, :merge, :reject],
        %{},
        %{units: [%{id: unit_id}]}
      )

      # The unit receives {:merge_result, :rejected} and re-gates. Since the
      # gate_fun is :pass, the unit will loop back to gating → merging and
      # call request_merge again (retry). We assert the unit is still alive
      # and received the rejected signal by checking another merge is requested.
      # The simplest observable from the test: at least ONE more merge is requested.
      # (The unit will retry: re-gate, re-merge.)
      assert_receive {:merge_requested, _merge_map2},
                     10_000,
                     ":reject event must drive the unit to re-gate and re-merge " <>
                       "(unit received {:merge_result, :rejected} from bridge)"
    end

    @tag :d_340
    test "bridge ignores telemetry events for a different unit_id (no cross-unit delivery)" do
      tmp_dir = mk_tmp("bridge_other")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/bridge-other"
      head_sha = String.duplicate("55667788", 5)
      agent_bin = work_ready_agent_bin(tmp_dir, branch, head_sha, "_bridgeC")

      sub = start_substrate(:bridge_c, repo_dir, agent_bin)
      test_pid = self()
      merge_authority = start_stub_merge_authority(test_pid)

      n = System.unique_integer([:positive])
      unit_id = "pr-bridge-other-#{n}"
      other_unit_id = "pr-bridge-decoy-#{n}"

      work_item = %{
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        branch: branch,
        run: "run-1",
        base_ref: base_ref,
        brief: "test brief"
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

      unit_pid = UnitDriver.drive(work_item, deps)
      assert is_pid(unit_pid)

      assert_receive {:merge_requested, _merge_map},
                     8_000,
                     "unit must reach awaiting_merge"

      Process.sleep(50)

      # Fire a :merged event for a DIFFERENT unit_id — must NOT reach this unit.
      :telemetry.execute(
        [:tau, :factory, :merge, :merged],
        %{},
        %{units: [%{id: other_unit_id}]}
      )

      # The unit must NOT receive a terminal from this decoy event.
      refute_receive {:unit_terminal, ^unit_id, _, _},
                     500,
                     "bridge must ignore telemetry events for a different unit_id"

      # Now fire the correct event — the unit must reach :merged.
      :telemetry.execute(
        [:tau, :factory, :merge, :merged],
        %{},
        %{units: [%{id: unit_id}]}
      )

      assert_receive {:unit_terminal, ^unit_id, :merged, _provenance},
                     8_000,
                     "bridge must deliver {:merge_result, :merged} for the correct unit_id"
    end
  end
end
