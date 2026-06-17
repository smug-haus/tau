defmodule Tau.Factory.InvDistR8Test do
  @moduledoc """
  Gating test for issue #595 — INV-DIST-R8.

  ## The invariant

  INV-DIST-R8: The move to distributed execution (Stage a) touches ONLY
  WorkerSupervisor/GateTasks placement, an Oban queue, and optional PubSub
  adapter — no invariant, no FSM, no contract changes are required.

  Falsified by: finding an invariant or contract change required by Stage (a)
  §5 steps 1–6.

  Source: docs/arch/04-software-architecture/distribution-readiness.md §5
  and §6 (R8 row).

  ## Rationale

  D-S4's claim — "distribution is config, not rearchitecture" — holds for the
  W/G (worker/gate) tier because the isolation model is node-local and
  self-contained (worker-fleet.md §8):

  Moving a worker off-node therefore needs no change to the isolation model:
  the same init/1 allocation, the same :DOWN-monitor capture, and the same
  per-worker namespace apply unchanged on the remote node. Distribution is
  configuration plus an Oban queue, not a rearchitecture of W.

  R8 is a design-time readiness property (line 248: "each is a falsifiable
  check against the layer-04 design, not a vibe"). Its machine-checkable
  footprint is an explicit attestation function at the WorkerSupervisor
  boundary — the same pattern used for INV-DIST-NO-FULLMESH
  (cross_node_routing_mechanism/0) and INV-DIST-MONITOR-LOCAL
  (liveness_authority/1).

  ## Audit verdict (issue #595)

  GAP: no code path verifies that Stage (a) requires no contract/FSM/invariant
  change. WorkerSupervisor is a plain DynamicSupervisor; Worker.init/1
  performs node-local git worktree allocation. Neither contains an executable
  construct keyed to distribution-readiness or to detecting a Stage-(a)
  contract change. This test enforces the architectural wall.

  ## What is asserted

  ### A. Machine-checkable Stage-(a) attestation

  WorkerSupervisor.stage_a_placement_only/0 MUST exist and return :verified,
  declaring that the Stage (a) move to distributed execution requires ONLY
  WorkerSupervisor/GateTasks placement and Oban queue config — no invariant,
  FSM, or contract changes. This function does NOT yet exist; the test fails
  until it is added.

  This is the INV-DIST-R8 analogue of cross_node_routing_mechanism/0
  (INV-DIST-NO-FULLMESH) and liveness_authority/1 (INV-DIST-MONITOR-LOCAL):
  it makes the R8 architectural claim machine-checkable at the boundary where
  the placement change would be wired.

  ### B. WorkerSupervisor source contains no co-residency assumptions

  WorkerSupervisor source MUST NOT contain constructs that would require
  contract changes to move workers off-node:
    - :net_kernel.connect_node — explicit cluster join (control-plane coupling)
    - Node.connect — same concern
    - :global.register_name / :global.whereis_name — global naming couples
      the supervisor to a specific cluster topology (forbidden by OTP
      non-negotiable #4 and distribution-readiness.md §4)
    - :pg.join / :pg.get_members — process group constructs that couple
      process identity to a specific cluster topology

  Note: node() (local identity check in spawn/5) and :node (keyword option
  name) are NOT prohibited — they implement the correct refusal guard.
  The prohibited set is constructs that would make placement non-configurable.

  ### C. Worker.init/1 isolation model is self-contained (no co-residency assumption)

  Tau.Factory.Worker source MUST NOT contain constructs that would require
  an isolation-model change when a worker moves off-node:
    - :global.register_name / :global.whereis_name — global naming
    - Node.connect / :net_kernel.connect_node — explicit cluster join
    - :pg.join / :pg.get_members — process group topology coupling
    - Node.list() / Node.list(:visible) — enumeration of live nodes

  These would require contract changes at move-time, falsifying R8.

  ## Entry point

  Test A exercises the REAL WorkerSupervisor.stage_a_placement_only/0
  function. Tests B and C are structural assertions against the module source
  (located via :code.get_object_code/1), asserting absence of co-residency
  patterns at the WorkerSupervisor and Worker boundaries.

  ## AC / invariant linkage
    - INV-DIST-R8: all tests in this file (#595)
  """

  use ExUnit.Case, async: true

  @moduletag :inv_dist_r8

  alias Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # A. Machine-checkable Stage-(a) attestation
  # ---------------------------------------------------------------------------

  @tag :inv_dist_r8
  test "INV-DIST-R8: WorkerSupervisor.stage_a_placement_only/0 returns :verified" do
    # This function must exist and return :verified to make R8 machine-checkable:
    # it declares that Stage (a) distributed execution requires ONLY placement +
    # Oban queue config — no invariant, FSM, or contract changes.
    # The function does NOT yet exist — this test fails with UndefinedFunctionError
    # until it is added to WorkerSupervisor.
    assert WorkerSupervisor.stage_a_placement_only() == :verified,
           "INV-DIST-R8: WorkerSupervisor.stage_a_placement_only/0 must return :verified, " <>
             "declaring that the Stage (a) move to distributed execution requires ONLY " <>
             "WorkerSupervisor/GateTasks placement and an Oban queue — no invariant, " <>
             "FSM, or contract changes. " <>
             "This is the machine-checkable R8 attestation at the boundary where the " <>
             "placement change would be wired. " <>
             "See distribution-readiness.md S5 Stage (a) and S6 R8."
  end

  # ---------------------------------------------------------------------------
  # B. WorkerSupervisor source contains no co-residency assumptions
  # ---------------------------------------------------------------------------

  @tag :inv_dist_r8
  test "INV-DIST-R8: WorkerSupervisor source contains no co-residency assumptions that would require contract changes" do
    {_module, _beam, source_path} = :code.get_object_code(Tau.Factory.WorkerSupervisor)
    source = File.read!(to_string(source_path))

    # These constructs would couple the supervisor to a fixed cluster topology,
    # requiring a contract change to move workers off-node (falsifying R8).
    co_residency_patterns = [
      {~r/:net_kernel\.connect_node/,
       ":net_kernel.connect_node (explicit cluster join — couples supervisor to topology)"},
      {~r/Node\.connect/,
       "Node.connect (explicit cluster join — couples supervisor to topology)"},
      {~r/:global\.register_name/,
       ":global.register_name (global naming — forbidden by OTP non-negotiable #4; " <>
         "couples placement to a specific cluster)"},
      {~r/:global\.whereis_name/,
       ":global.whereis_name (global name lookup — forbidden by OTP non-negotiable #4)"},
      {~r/:pg\.join/,
       ":pg.join (process group — couples process identity to cluster topology)"},
      {~r/:pg\.get_members/,
       ":pg.get_members (process group membership lookup — topology coupling)"}
    ]

    violations =
      co_residency_patterns
      |> Enum.filter(fn {pattern, _label} -> Regex.match?(pattern, source) end)
      |> Enum.map(fn {_pattern, label} -> label end)

    assert violations == [],
           "INV-DIST-R8: WorkerSupervisor source contains co-residency assumptions that " <>
             "would require contract changes when workers move off-node, falsifying R8. " <>
             "Stage (a) MUST be purely a placement + Oban queue configuration change. " <>
             "See distribution-readiness.md S5 Stage (a), S6 R8. " <>
             "Prohibited constructs found:\n" <>
             Enum.map_join(violations, "\n", fn v -> "  - #{v}" end)
  end

  # ---------------------------------------------------------------------------
  # C. Worker.init/1 isolation model is self-contained (no co-residency assumption)
  # ---------------------------------------------------------------------------

  @tag :inv_dist_r8
  test "INV-DIST-R8: Worker source contains no co-residency assumptions that would require isolation-model changes" do
    {_module, _beam, source_path} = :code.get_object_code(Tau.Factory.Worker)
    source = File.read!(to_string(source_path))

    # These constructs would make worker isolation topology-dependent, requiring
    # an isolation-model change to move workers off-node (falsifying R8).
    # worker-fleet.md S8: "Moving a worker off-node needs no change to the
    # isolation model: same init/1 allocation, same :DOWN-monitor capture,
    # same per-worker namespace apply unchanged on the remote node."
    isolation_coupling_patterns = [
      {~r/:global\.register_name/,
       ":global.register_name (global naming — couples worker identity to cluster; " <>
         "forbidden by OTP non-negotiable #4)"},
      {~r/:global\.whereis_name/,
       ":global.whereis_name (global name lookup — forbidden by OTP non-negotiable #4)"},
      {~r/Node\.connect/,
       "Node.connect (explicit cluster join from within a worker — topology coupling)"},
      {~r/:net_kernel\.connect_node/,
       ":net_kernel.connect_node (explicit cluster join — topology coupling)"},
      {~r/:pg\.join/,
       ":pg.join (process group — couples worker identity to cluster topology)"},
      {~r/:pg\.get_members/,
       ":pg.get_members (process group membership — topology coupling)"},
      {~r/Node\.list/,
       "Node.list (live-cluster enumeration from within a worker — cross-node assumption)"}
    ]

    violations =
      isolation_coupling_patterns
      |> Enum.filter(fn {pattern, _label} -> Regex.match?(pattern, source) end)
      |> Enum.map(fn {_pattern, label} -> label end)

    assert violations == [],
           "INV-DIST-R8: Worker source contains co-residency assumptions that would " <>
             "require isolation-model changes when workers move off-node, falsifying R8. " <>
             "The isolation boundary MUST be node-local and self-contained " <>
             "(worker-fleet.md S8): same init/1 allocation, same :DOWN-monitor capture, " <>
             "same per-worker namespace apply unchanged on the remote node. " <>
             "See distribution-readiness.md S5 Stage (a), S6 R8. " <>
             "Prohibited constructs found:\n" <>
             Enum.map_join(violations, "\n", fn v -> "  - #{v}" end)
  end
end
