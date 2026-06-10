---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: `Tau.Session.Cancel` — a dedicated cancellation coordinator module

## Approach

Extract both `:cancel` clause bodies into a new module `Tau.Session.Cancel`
(`lib/tau/session/cancel.ex`) that exposes two public functions:
`permission_round/1` (for the `:awaiting_permission` path) and `cross_cutting/1`
(for the `_state` path). Each function accepts the full `Data.t()`, performs all
teardown operations internally (emitting events, killing processes, resetting
fields), and returns `{Data.t(), actions}` — the exact pair the FSM clause needs
for `{:next_state, :awaiting_user, data, actions}`. The two `session.ex` clause
bodies become single-line delegations. The existing sub-module delegates
(`ProviderTurn.cancel_provider_task/1`, `CodingAgent.Dispatcher.cancel/1`) are
called from within `Tau.Session.Cancel`, not from `session.ex`.

## Rationale

The cancel path is a distinct lifecycle phase with its own ordering invariants
(children first, provider cooperative-first, then broadcast, then queue drain).
Grouping both cancel functions in one module makes the ordering contract readable
in one place — a developer tracing cancellation reads `Tau.Session.Cancel`, not
`session.ex`. Unlike Proposal 1 (which distributes cancel logic across each
cluster's sub-module), this proposal decomplects the FSM from teardown by
concentrating teardown in a single purpose-built module, paralleling how
`Tau.Session.ToolDispatch` and `Tau.Session.ProviderTurn` concentrate their own
lifecycle logic. The cancel module calls into the cluster sub-modules where
delegates already exist, and handles inline what has no delegate yet — making
the gap in cluster coverage visible in one file.

## Sketch

```elixir
# lib/tau/session/cancel.ex — new module
defmodule Tau.Session.Cancel do
  @moduledoc """
  Teardown coordinator for `Tau.Session` cancellation paths.

  Provides `permission_round/1` for the `:awaiting_permission`-specific cancel
  and `cross_cutting/1` for the general-state cancel. Both return
  `{Data.t(), [gen_statem_action]}` for direct use in `:next_state` returns.
  """

  alias Tau.Session.{Data, Events, Journal, ToolDispatch}
  alias Tau.Session.ProviderTurn
  alias Tau.Message.ToolResult

  @spec permission_round(Data.t()) :: {Data.t(), [term()]}
  def permission_round(data) do
    data =
      data
      |> emit_pending_results()
      |> synthesise_error_results()
    Tau.Session.broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})
    data = Journal.persist(data, "cancellation", %{cause: "user", reason: "awaiting_permission"})
    data = drain_steering_queue(data)
    data = reset_permission_cluster(data)
    data = reset_per_turn_fields(data)
    {data, followup_actions(data)}
  end

  @spec cross_cutting(Data.t()) :: {Data.t(), [term()]}
  def cross_cutting(data) do
    Tau.Session.cascade_to_children(data, :cancel)
    mechanism = ProviderTurn.cancel_provider_task(data)
    data = kill_tool_cluster(data)
    data = kill_compaction_cluster(data)
    data = cancel_coding_agent_cluster(data)
    Tau.Session.broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})
    data = Journal.persist(data, "cancellation", %{cause: "user", reason: Atom.to_string(mechanism)})
    data = drain_steering_queue(data)
    data = reset_cross_cutting_fields(data)
    data = reset_per_turn_fields(data)
    {data, followup_actions(data)}
  end

  # Private helpers -------------------------------------------------------

  defp emit_pending_results(data), do: # ... (reduce over permission_pending_results)

  defp synthesise_error_results(data), do: # ... (reduce over pending_permission_requests)

  defp kill_tool_cluster(data) do
    if data.tool_dispatcher && Process.alive?(data.tool_dispatcher),
      do: Process.exit(data.tool_dispatcher, :brutal_kill)
    if data.command_task && Process.alive?(data.command_task),
      do: Process.exit(data.command_task, :brutal_kill)
    %{data | tool_dispatcher: nil, command_task: nil}
  end

  defp kill_compaction_cluster(data) do
    if data.compaction_monitor, do: Process.demonitor(data.compaction_monitor, [:flush])
    if data.compaction_task && Process.alive?(data.compaction_task),
      do: Process.exit(data.compaction_task, :brutal_kill)
    %{data | compaction_task: nil, compaction_monitor: nil}
  end

  defp cancel_coding_agent_cluster(data) do
    if data.coding_agent_dispatcher && Process.alive?(data.coding_agent_dispatcher),
      do: Tau.CodingAgent.Dispatcher.cancel(data.coding_agent_dispatcher)
    %{data | coding_agent_dispatcher: nil, coding_agent_pending: nil, coding_agent_blocks: []}
  end

  defp drain_steering_queue(data) do
    msgs = :queue.to_list(data.steering_queue)
    if msgs != [],
      do: Tau.Session.broadcast(data.id, %Events.QueueRestored{session_id: data.id, messages: msgs})
    %{data | steering_queue: :queue.new()}
  end

  defp reset_permission_cluster(data) do
    %{data |
      pending_permission_requests: %{},
      permission_dispatch_batch: [],
      permission_pending_results: [],
      tools_in_flight: %{},
      tool_dispatcher: nil}
  end

  defp reset_cross_cutting_fields(data) do
    %{data |
      provider_task: nil, cancel_flag: nil,
      stream_ref: nil, provider_span_ref: nil,
      assembler: nil, tools_in_flight: %{}}
  end

  defp reset_per_turn_fields(data) do
    %{data |
      active_skill: nil, tool_iterations: 0,
      tool_loop_state: %{}, tool_loop_call_lookups: %{},
      provider_retry_state: %{count: 0}}
  end

  defp followup_actions(data) do
    if :queue.is_empty(data.followup_queue),
      do: [],
      else: [{:next_event, :internal, :drain_followups}]
  end
end
```

The two `session.ex` clauses reduce to:

```elixir
def handle_event(:cast, :cancel, :awaiting_permission, data) do
  {data, actions} = Tau.Session.Cancel.permission_round(data)
  {:next_state, :awaiting_user, data, actions}
end

def handle_event(:cast, :cancel, _state, data) do
  {data, actions} = Tau.Session.Cancel.cross_cutting(data)
  {:next_state, :awaiting_user, data, actions}
end
```

Note: `cascade_to_children/2` in `cross_cutting/1` calls
`Tau.Session.cascade_to_children/2` — this remains a private helper in
`session.ex` (it is in-scope as a call site) and is simply invoked from the
cancel module via the public API or made accessible via a `@doc false` package-
private pattern.

## Tradeoffs

### Strengths

- Both cancel clause bodies in `session.ex` become exactly 2 lines — the strictest possible compliance with the acceptance criterion.
- All cancellation ordering logic lives in one file; a developer reading cancel behaviour reads `cancel.ex`, period.
- The `cross_cutting/1` implementation immediately surfaces which clusters still lack a sub-module delegate (compaction, tool kill) — the gap is visible and localised.
- Symmetric with the existing sub-module extraction pattern: `ToolDispatch` owns tool dispatch, `Cancel` owns cancellation.
- `permission_round/1` and `cross_cutting/1` are independently unit-testable without the FSM.

### Weaknesses

- Introduces a new module that coordinates across cluster boundaries — it now knows about compaction, coding agent, provider, tool dispatcher simultaneously. If a cluster sub-module later gains its own cancel delegate, the `Cancel` module must be updated; the coupling is concentrated rather than eliminated.
- `cancel.ex` calls `Tau.Session.broadcast/2`, `Tau.Session.append_message/2`, and `Tau.Session.cascade_to_children/2` — functions that live on the FSM module. This creates a `cancel.ex → session.ex` import cycle risk unless those helpers are moved to a shared internal module first (the `fsm-facade-helpers` sub-problem). Without that, the module boundary is enforced only by discipline, not by the compiler.
- `cascade_to_children/2` is currently private in `session.ex`; exposing it to `cancel.ex` requires making it package-accessible or moving it — non-trivial.
- The `{Data.t(), [action]}` return type for `permission_round/1` and `cross_cutting/1` is not a standard Elixir pattern; callers must destructure, and Dialyzer typing requires the action list to be typed as `term()` or a new alias.

### Costs

- 1 new module (~130 LOC); `session.ex` loses ~240 LOC from the cancel bodies.
- `cascade_to_children/2` must be made accessible to `cancel.ex` — either a small refactor (move to `Data` or `Journal`) or a `@doc false` exposure; ~5–10 LOC change.
- Unit tests for `permission_round/1` and `cross_cutting/1`: ~2 new test files, ~100–120 test lines.
- Dependency ordering: the `fsm-facade-helpers` sub-problem (shared helpers module) should ideally precede this to avoid the import-cycle risk, or the proposal must ship a minimal shared-helpers extraction alongside it.

## Dependencies

- `cascade_to_children/2` must be accessible from outside `session.ex` — requires either exposing it or first landing the `fsm-facade-helpers` sub-problem's shared internal module.
- `Tau.Session.Data` typed struct (the `cross-cutting-data` sub-problem) is not strictly required but makes the field-reset maps in `reset_*` helpers type-safe.

## Confidence

Medium. The extraction pattern is well-established in this codebase (see prior
sub-module extractions). The import-cycle risk with `session.ex` helpers is the
main uncertainty — the `fsm-facade-helpers` dependency is real and may require
sequencing. Confidence would be raised by confirming `cascade_to_children/2`
can be exposed without exposing more FSM internals.

## Prior art / references

- `Tau.Session.ToolDispatch` extraction: the direct precedent for concentrating a lifecycle concern in a sub-module rather than distributing it.
- Erlang/OTP supervisor `terminate/2` pattern: lifecycle cleanup in a dedicated callback rather than inline in the event handler.
- Elixir `Phoenix.LiveView` `handle_event/3` delegation pattern: thin FSM clause that delegates to a concern module.
