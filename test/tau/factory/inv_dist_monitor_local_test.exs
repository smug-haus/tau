defmodule Tau.Factory.InvDistMonitorLocalTest do
  @moduledoc """
  Gating test for issue #592 — INV-DIST-MONITOR-LOCAL.

  ## The invariant

  INV-DIST-MONITOR-LOCAL: Worker liveness (capture-before-destroy) MUST use
  the queue (Oban job lease/heartbeat) as the liveness authority for OFF-NODE
  work, NOT a raw distributed `Process.monitor`. Falsified by: using a
  distributed Erlang process monitor as the sole liveness signal for an
  off-node worker.

  Rationale (`docs/arch/04-software-architecture/distribution-readiness.md` §4):

  > `Process.monitor` fires `:DOWN` on **suspicion** (network partition), not
  > just death. A live remote worker looks dead; capture-before-destroy may fire
  > on a worker still writing.

  The prescribed mitigation (distribution-readiness.md §4, row "Monitors across
  a partition"):

  > Worker isolation + capture is **node-local** (`worker-fleet.md` §8);
  > the queue (Oban) is the liveness authority for off-node work
  > (job lease/heartbeat), not a raw distributed monitor.

  ## Audit verdict

  `NOT-YET-BUILT`: neither the off-node execution path nor its prescribed
  enforcement exists in executable code. This test enforces the architectural
  wall that must be built before any off-node worker path can be introduced.

  ## What is asserted

  Two sub-assertions, both at the real `WorkerSupervisor.spawn/5` boundary:

  ### A. Structural refusal of off-node spawn without an Oban queue

  `WorkerSupervisor.spawn/5` MUST return `{:error, :use_oban_for_remote_workers}`
  when given a `:node` option naming a remote node (any node != `node()`).
  This prevents an off-node worker from being started under the current
  `Process.monitor`-based liveness path.

  ### B. Liveness authority classification

  `WorkerSupervisor.liveness_authority/1` MUST return:
    - `:local_process_monitor` for `node()` (the local node)
    - `:oban_queue` for any other node atom

  This classifies the liveness contract per node at the supervisor boundary,
  making INV-DIST-MONITOR-LOCAL machine-checkable before a worker is spawned.

  ## Entry point

  Tests exercise the REAL user-facing entry point: `WorkerSupervisor.spawn/5`
  and the new `WorkerSupervisor.liveness_authority/1` function. No hand-built
  structs or injected seams bypass the real default path.

  ## AC / invariant linkage
    - INV-DIST-MONITOR-LOCAL: all tests in this file (#592)
  """

  use ExUnit.Case, async: true

  @moduletag :inv_dist_monitor_local

  alias Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # A. Structural refusal of off-node spawn
  # ---------------------------------------------------------------------------

  @tag :inv_dist_monitor_local
  test "INV-DIST-MONITOR-LOCAL: WorkerSupervisor.spawn/5 rejects a spawn targeting a remote node" do
    # Any atom that is not the current node simulates a remote node name.
    # The remote node does not need to be alive — the guard must fire before any
    # connection attempt, purely on the node identity comparison.
    remote_node = :"remote@127.0.0.2"

    # Start a minimal supervisor + registry hermetically so we exercise
    # the real spawn/5 boundary.
    registry_name = :"inv_dist_monitor_local_registry_#{System.unique_integer([:positive])}"
    sup_name = :"inv_dist_monitor_local_sup_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({WorkerSupervisor, name: sup_name})

    result =
      WorkerSupervisor.spawn(
        sup_name,
        :test_author,
        "brief",
        "main",
        node: remote_node,
        registry: registry_name,
        repo_dir: "/tmp/unused",
        agent_bin: "/usr/bin/true"
      )

    assert result == {:error, :use_oban_for_remote_workers},
           "INV-DIST-MONITOR-LOCAL: spawn/5 must refuse off-node spawn with " <>
             "{:error, :use_oban_for_remote_workers}; raw Process.monitor is unsafe " <>
             "for remote pids. Got: #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # B. Liveness authority classification
  # ---------------------------------------------------------------------------

  @tag :inv_dist_monitor_local
  test "INV-DIST-MONITOR-LOCAL: liveness_authority/1 returns :local_process_monitor for node()" do
    assert WorkerSupervisor.liveness_authority(node()) == :local_process_monitor,
           "INV-DIST-MONITOR-LOCAL: liveness_authority/1 must return :local_process_monitor " <>
             "for the local node. Function does not exist or returns wrong value."
  end

  @tag :inv_dist_monitor_local
  test "INV-DIST-MONITOR-LOCAL: liveness_authority/1 returns :oban_queue for any remote node" do
    remote_node = :"remote@127.0.0.2"

    assert WorkerSupervisor.liveness_authority(remote_node) == :oban_queue,
           "INV-DIST-MONITOR-LOCAL: liveness_authority/1 must return :oban_queue for a " <>
             "remote node atom. Off-node liveness MUST use the Oban job lease/heartbeat, " <>
             "not a raw Process.monitor. Function does not exist or returns wrong value."
  end
end
