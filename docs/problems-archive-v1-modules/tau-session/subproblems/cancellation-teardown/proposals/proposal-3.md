---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Data-shape teardown — `Data.reset_for_cancel/2` + per-cluster `cancel_cluster/1` callbacks on a `Cancellable` behaviour

## Approach

Define a `Tau.Session.Cancellable` behaviour with a single callback
`cancel_cluster(Data.t()) :: Data.t()`. Implement it in
`Tau.Session.ProviderTurn`, `Tau.Session.ToolDispatch`, `Tau.Session.Compaction`,
and `Tau.Session.CodingAgentTurn` — each module declares `@behaviour
Tau.Session.Cancellable` and implements `cancel_cluster/1` to kill its own
processes and clear its own fields. Add `Data.reset_for_cancel/1` in
`Tau.Session.Data` to reset the cross-cutting per-turn fields that belong to no
single cluster (`active_skill`, `tool_iterations`, `tool_loop_state`,
`tool_loop_call_lookups`, `provider_retry_state`, `steering_queue`). Both
`:cancel` clause bodies in `session.ex` become a fold over a hardcoded list of
cluster modules plus a `Data.reset_for_cancel/1` call.

## Rationale

The deepest complection is the one between the FSM clause and the data-field
reset maps: the clause must know every field of every cluster in order to zero
them out. By placing `cancel_cluster/1` on each cluster module and
`reset_for_cancel/1` on `Data`, each module is responsible for the fields it
declared — the FSM need only enumerate the cluster modules and let each clean up
after itself. This is the data-shape axis: the change is primarily about who
owns the reset map, not just who contains the kill logic. The `Cancellable`
behaviour makes the contract explicit and compiler-checkable: a new cluster
sub-module that forgets to implement `cancel_cluster/1` produces a compile-time
warning, not a silent cancel gap.

## Sketch

```elixir
# lib/tau/session/cancellable.ex — new behaviour (3 lines)
defmodule Tau.Session.Cancellable do
  @callback cancel_cluster(Tau.Session.Data.t()) :: Tau.Session.Data.t()
end

# lib/tau/session/provider_turn.ex — add behaviour + implement callback
@behaviour Tau.Session.Cancellable

@impl Tau.Session.Cancellable
@spec cancel_cluster(Data.t()) :: Data.t()
def cancel_cluster(data) do
  _mechanism = cancel_provider_task(data)   # existing function; mechanism recorded elsewhere
  %{data | provider_task: nil, cancel_flag: nil,
           stream_ref: nil, provider_span_ref: nil, assembler: nil}
end

# lib/tau/session/tool_dispatch.ex — add behaviour + implement callback
@behaviour Tau.Session.Cancellable

@impl Tau.Session.Cancellable
@spec cancel_cluster(Data.t()) :: Data.t()
def cancel_cluster(data) do
  if data.tool_dispatcher && Process.alive?(data.tool_dispatcher),
    do: Process.exit(data.tool_dispatcher, :brutal_kill)
  if data.command_task && Process.alive?(data.command_task),
    do: Process.exit(data.command_task, :brutal_kill)
  data
  |> emit_and_close_pending_permissions_on_cancel()  # mirror of finish_permission_round paths
  |> Map.merge(%{
    tools_in_flight: %{}, tool_dispatcher: nil, command_task: nil,
    pending_permission_requests: %{}, permission_dispatch_batch: [],
    permission_pending_results: [], tool_loop_call_lookups: %{}})
end

# lib/tau/session/compaction.ex — add behaviour + implement callback
@behaviour Tau.Session.Cancellable

@impl Tau.Session.Cancellable
@spec cancel_cluster(Data.t()) :: Data.t()
def cancel_cluster(data) do
  if data.compaction_monitor, do: Process.demonitor(data.compaction_monitor, [:flush])
  if data.compaction_task && Process.alive?(data.compaction_task),
    do: Process.exit(data.compaction_task, :brutal_kill)
  %{data | compaction_task: nil, compaction_monitor: nil}
  # compaction_failures intentionally NOT reset
end

# lib/tau/session/coding_agent_turn.ex — add behaviour + implement callback
@behaviour Tau.Session.Cancellable

@impl Tau.Session.Cancellable
@spec cancel_cluster(Data.t()) :: Data.t()
def cancel_cluster(data) do
  if data.coding_agent_dispatcher && Process.alive?(data.coding_agent_dispatcher),
    do: Tau.CodingAgent.Dispatcher.cancel(data.coding_agent_dispatcher)
  %{data | coding_agent_dispatcher: nil, coding_agent_pending: nil, coding_agent_blocks: []}
end

# lib/tau/session/data.ex — new function
@spec reset_for_cancel(t()) :: t()
def reset_for_cancel(data) do
  %{data |
    active_skill: nil,
    tool_iterations: 0,
    tool_loop_state: %{},
    provider_retry_state: %{count: 0},
    steering_queue: :queue.new()}
end
```

The two `session.ex` cancel clauses become:

```elixir
@cancel_clusters [
  Tau.Session.ProviderTurn,
  Tau.Session.ToolDispatch,
  Tau.Session.Compaction,
  Tau.Session.CodingAgentTurn
]

def handle_event(:cast, :cancel, :awaiting_permission, data) do
  # ToolDispatch.cancel_cluster/1 handles permission-round emit + synthesis
  data = Enum.reduce(@cancel_clusters, data, & &1.cancel_cluster(&2))
  broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})
  data = finish_cancel(data, "awaiting_permission")
  {:next_state, :awaiting_user, data, followup_actions(data)}
end

def handle_event(:cast, :cancel, _state, data) do
  cascade_to_children(data, :cancel)
  data = Enum.reduce(@cancel_clusters, data, & &1.cancel_cluster(&2))
  broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})
  data = finish_cancel(data, "cross_cutting")
  {:next_state, :awaiting_user, data, followup_actions(data)}
end

# Private: journal + steering drain + Data.reset_for_cancel/1
defp finish_cancel(data, reason) do
  data
  |> Journal.persist("cancellation", %{cause: "user", reason: reason})
  |> tap(fn d ->
    msgs = :queue.to_list(d.steering_queue)
    if msgs != [], do: broadcast(d.id, %Events.QueueRestored{session_id: d.id, messages: msgs})
  end)
  |> Data.reset_for_cancel()
end
```

The `:awaiting_permission` clause uses the same `@cancel_clusters` fold;
`ToolDispatch.cancel_cluster/1` is written to handle both the permission-round
emit and the general-case (it detects which phase it is in from data fields).

## Tradeoffs

### Strengths

- Compiler-enforced contract: any new cluster sub-module that omits `cancel_cluster/1` produces a `@behaviour` warning at compile time — the coverage gap cannot be introduced silently.
- Field reset ownership is fully decomplected: each module declares which fields it resets; the FSM holds no field knowledge.
- The `@cancel_clusters` list in `session.ex` is the single enumeration of all clusters — adding a new cluster means adding one module and one list entry, not editing an inline teardown sequence.
- `Data.reset_for_cancel/1` is a natural addition to the `Data` module, consistent with OTP's convention of data-shape operations living on the data struct module.
- `finish_cancel/2` in `session.ex` remains a 4-line private helper — acceptable inline residual.

### Weaknesses

- The `ProviderTurn.cancel_cluster/1` implementation discards the `cancel_mechanism` atom (`:cooperative` vs `:brutal_kill`) that the cross-cutting cancel clause currently uses to journal the cancel reason. The journal entry loses ADR-0017's mechanism distinction unless `cancel_cluster/1` is extended to return `{mechanism, Data.t()}` — which breaks the behaviour signature's uniformity.
- A uniform fold `Enum.reduce(@cancel_clusters, data, & &1.cancel_cluster(&2))` assumes order-independence among clusters. The existing code has an ordering constraint: `cascade_to_children` before provider kill. The `:awaiting_permission` path currently does not kill the provider; by including `ProviderTurn` in the uniform fold for that path, it may run `cancel_provider_task/1` unnecessarily on a nil task (benign but wasteful).
- The behaviour is a thin wrapper over a single callback; some teams view single-callback behaviours as over-engineering compared to a plain function.
- `ToolDispatch.cancel_cluster/1` must handle both the permission-round emit (for the `:awaiting_permission` path) and the plain field-clear (for the cross-cutting path); the distinction between these two states leaks into the cluster module via data field inspection.

### Costs

- 1 new micro-module (`Tau.Session.Cancellable`, 3 LOC); 4 new `cancel_cluster/1` implementations across existing modules (~60 LOC total); `Data.reset_for_cancel/1` (~10 LOC).
- `session.ex` loses ~230 LOC from the cancel bodies; gains ~20 LOC (`@cancel_clusters`, `finish_cancel/2`, 2 simplified clauses).
- ADR-0017 journal mechanism distinction requires either relaxing the journal entry or adding a separate pre-fold step to capture the mechanism atom before the fold.
- Unit tests: `cancel_cluster/1` for each module + `Data.reset_for_cancel/1` — ~5 new test modules, ~80–100 test lines.

## Dependencies

- `Tau.Session.Data` must be an accessible struct (not `map()`) for `Data.reset_for_cancel/1` to be type-safe — benefits from, but does not strictly require, the `cross-cutting-data` sub-problem landing first.
- No library upgrades required.

## Confidence

Medium-low. The behaviour pattern is standard OTP; the main uncertainty is
whether `ToolDispatch.cancel_cluster/1` can elegantly handle both cancel paths
without field inspection (phase disambiguation from `pending_permission_requests`
being non-empty vs empty is doable but couples the implementation to an implicit
convention). Confidence would be raised by confirming that ADR-0017's mechanism
atom can be captured outside the fold without additional complexity.

## Prior art / references

- OTP `gen_server` `terminate/2` callback: each module handles its own cleanup with a uniform callback signature.
- Elixir behaviour pattern used extensively in `Tau.Provider` callbacks: `stream/3`, `context_window/1` — same single-module-per-behaviour-callback pattern.
- `Tau.Session.Data.new/1`: precedent for initialisation logic living on the data struct module; `reset_for_cancel/1` is the cancellation-path counterpart.
