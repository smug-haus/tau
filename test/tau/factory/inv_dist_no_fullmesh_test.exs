defmodule Tau.Factory.InvDistNoFullmeshTest do
  @moduledoc """
  Gating test for issue #593 — INV-DIST-NO-FULLMESH.

  ## The invariant

  INV-DIST-NO-FULLMESH: FSMs and large payloads (diffs, agent transcripts)
  MUST NOT be spread over distributed Erlang full-mesh; the execution tier
  scales via an explicit queue boundary (Oban over node-local SQLite), NOT
  raw distributed message passing.

  Rationale (`docs/arch/04-software-architecture/distribution-readiness.md` §4):

  > Spread the FSMs and large payloads over distributed Erlang full-mesh =>
  > full-mesh TCP, one TCP per node pair => head-of-line blocking on large
  > messages (diffs, agent transcripts); the cluster degrades under exactly
  > the payloads the factory sends.

  Mitigation (distribution-readiness.md §4, row "Spread the FSM population"):

  > Don't cluster the FSMs. W/G scale via a queue (Oban over the
  > node-local SQLite, served to executors via API), not raw distributed
  > message passing; large payloads go through durable storage, not the wire.

  ## Audit verdict

  NOT-YET-BUILT: neither the distributed-full-mesh violation nor the
  prescribed enforcement (Oban queue boundary declaration) exists in
  executable code. This test enforces the architectural wall that MUST be
  built to make the invariant machine-checkable.

  ## What is asserted

  ### A. Machine-checkable queue boundary declaration

  WorkerSupervisor.cross_node_routing_mechanism/0 MUST exist and return
  :oban_queue, declaring the prescribed cross-node routing boundary.

  This is the INV-DIST-NO-FULLMESH analogue of
  WorkerSupervisor.liveness_authority/1 (which enforces INV-DIST-MONITOR-LOCAL):
  it makes the architectural wall machine-checkable before any distributed
  routing path can be introduced. Without this declaration, a future PR could
  add raw distributed-Erlang routing without any gate firing.

  ### B. No distributed-Erlang constructs in WorkerSupervisor source

  The WorkerSupervisor module source MUST NOT contain any of the
  distributed-Erlang primitives that would route FSMs or large payloads over
  full-mesh TCP:
    - :net_kernel.connect_node — explicit cluster join
    - Node.spawn / Node.spawn_link — remote process spawn
    - :rpc.call / :rpc.cast — synchronous/asynchronous distributed RPC
    - :erpc.call / :erpc.cast — enhanced RPC (same full-mesh concern)

  Note: node() (local node identity) and :node (keyword option name used
  in spawn/5 for node routing) are NOT prohibited — the guard at spawn/5
  already converts off-node requests to {:error, :use_oban_for_remote_workers}.
  The prohibited set is restricted to constructs that *perform* distributed
  routing over full-mesh TCP rather than refuse or classify it.

  ### C. No distributed-Erlang constructs in Worker source

  The Tau.Factory.Worker module source MUST NOT contain the same set of
  prohibited distributed-Erlang primitives. Workers are node-local by design
  (worker-fleet.md §8); any of these calls would route a worker's actions
  over full-mesh TCP, violating INV-DIST-NO-FULLMESH.

  ## Entry point

  Test A exercises the real WorkerSupervisor.cross_node_routing_mechanism/0
  function — no hand-built structs, no injected seams. Tests B and C are
  structural assertions against the module source file (located via
  :code.get_object_code/1), asserting absence of prohibited patterns at
  the WorkerSupervisor and Worker boundaries.

  ## AC / invariant linkage
    - INV-DIST-NO-FULLMESH: all tests in this file (#593)
  """

  use ExUnit.Case, async: true

  @moduletag :inv_dist_no_fullmesh

  alias Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # A. Machine-checkable queue boundary declaration
  # ---------------------------------------------------------------------------

  @tag :inv_dist_no_fullmesh
  test "INV-DIST-NO-FULLMESH: WorkerSupervisor.cross_node_routing_mechanism/0 returns :oban_queue" do
    # This function must exist and return :oban_queue to make the prescribed
    # architectural boundary (Oban over node-local SQLite) machine-checkable.
    # The function does not yet exist — this test fails until it is added.
    assert WorkerSupervisor.cross_node_routing_mechanism() == :oban_queue,
           "INV-DIST-NO-FULLMESH: WorkerSupervisor.cross_node_routing_mechanism/0 must " <>
             "return :oban_queue, declaring that the Oban queue boundary is the ONLY " <>
             "permitted cross-node routing mechanism for the execution tier. " <>
             "Raw distributed Erlang full-mesh routing MUST NOT be used for FSMs or " <>
             "large payloads (diffs, agent transcripts). " <>
             "See distribution-readiness.md §3 and §4."
  end

  # ---------------------------------------------------------------------------
  # B. No distributed-Erlang constructs in WorkerSupervisor source
  # ---------------------------------------------------------------------------

  @tag :inv_dist_no_fullmesh
  test "INV-DIST-NO-FULLMESH: WorkerSupervisor source contains no distributed full-mesh routing primitives" do
    {_module, _beam, source_path} = :code.get_object_code(Tau.Factory.WorkerSupervisor)
    source = File.read!(to_string(source_path))

    prohibited_patterns = [
      {~r/\bNode\.spawn\b/, "Node.spawn (remote process spawn over full-mesh TCP)"},
      {~r/\bNode\.spawn_link\b/,
       "Node.spawn_link (remote linked process spawn over full-mesh TCP)"},
      {~r/:rpc\.call\b/, ":rpc.call (synchronous distributed RPC, large payload over wire)"},
      {~r/:rpc\.cast\b/, ":rpc.cast (asynchronous distributed RPC over wire)"},
      {~r/:erpc\.call\b/,
       ":erpc.call (enhanced RPC, same full-mesh concern as :rpc.call)"},
      {~r/:erpc\.cast\b/, ":erpc.cast (enhanced RPC cast over wire)"},
      {~r/:net_kernel\.connect_node\b/, ":net_kernel.connect_node (explicit cluster join)"}
    ]

    violations =
      prohibited_patterns
      |> Enum.filter(fn {pattern, _label} -> Regex.match?(pattern, source) end)
      |> Enum.map(fn {_pattern, label} -> label end)

    assert violations == [],
           "INV-DIST-NO-FULLMESH: WorkerSupervisor source contains prohibited " <>
             "distributed-Erlang full-mesh routing primitives. " <>
             "These route FSMs or large payloads over full-mesh TCP, violating the " <>
             "Oban-queue-boundary requirement (distribution-readiness.md §4). " <>
             "Prohibited constructs found:\n" <>
             Enum.map_join(violations, "\n", &"  - #{&1}")
  end

  # ---------------------------------------------------------------------------
  # C. No distributed-Erlang constructs in Worker source
  # ---------------------------------------------------------------------------

  @tag :inv_dist_no_fullmesh
  test "INV-DIST-NO-FULLMESH: Worker source contains no distributed full-mesh routing primitives" do
    {_module, _beam, source_path} = :code.get_object_code(Tau.Factory.Worker)
    source = File.read!(to_string(source_path))

    prohibited_patterns = [
      {~r/\bNode\.spawn\b/, "Node.spawn (remote process spawn over full-mesh TCP)"},
      {~r/\bNode\.spawn_link\b/,
       "Node.spawn_link (remote linked process spawn over full-mesh TCP)"},
      {~r/:rpc\.call\b/, ":rpc.call (synchronous distributed RPC, large payload over wire)"},
      {~r/:rpc\.cast\b/, ":rpc.cast (asynchronous distributed RPC over wire)"},
      {~r/:erpc\.call\b/,
       ":erpc.call (enhanced RPC, same full-mesh concern as :rpc.call)"},
      {~r/:erpc\.cast\b/, ":erpc.cast (enhanced RPC cast over wire)"}
    ]

    violations =
      prohibited_patterns
      |> Enum.filter(fn {pattern, _label} -> Regex.match?(pattern, source) end)
      |> Enum.map(fn {_pattern, label} -> label end)

    assert violations == [],
           "INV-DIST-NO-FULLMESH: Worker source contains prohibited " <>
             "distributed-Erlang full-mesh routing primitives. " <>
             "Workers are node-local by design (worker-fleet.md §8); " <>
             "any distributed routing primitive violates INV-DIST-NO-FULLMESH. " <>
             "Prohibited constructs found:\n" <>
             Enum.map_join(violations, "\n", &"  - #{&1}")
  end
end
