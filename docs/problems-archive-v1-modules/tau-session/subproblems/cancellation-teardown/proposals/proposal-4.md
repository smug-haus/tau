---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: PubSub-driven teardown — emit `%Cancelling{}` and let cluster sub-modules self-clean via subscribed handlers

## Approach

Introduce a new internal event struct `%Tau.Session.Events.Cancelling{}` (not
the existing `%Cancelled{}` which is external-facing). When either `:cancel` FSM
clause fires, `session.ex` emits `%Cancelling{session_id: id, scope: :permission
| :cross_cutting}` on the session's PubSub topic before yielding. Each cluster
sub-module that needs teardown registers a `handle_cancelling/2` handler (called
by a thin dispatcher in `session.ex`) that receives the event and the current
`Data.t()`, performs its own kills and field resets, and returns `Data.t()`. The
FSM clause becomes: emit `%Cancelling{}`, call `Cancellation.dispatch(data, scope)` 
— a new thin function in `Tau.Session.Cancellation` that folds registered handlers — 
then broadcast `%Cancelled{}` and return `{:next_state, :awaiting_user, data, actions}`.
The handler registry is a compile-time list (not a runtime subscription) to avoid
the supervision complexity of PubSub at the cancel path.

## Rationale

The root complecting is that the FSM clause knows the ordered side-effect
sequence for each cluster. If instead each cluster publishes what it needs on a
`%Cancelling{}` event and implements `handle_cancelling/2`, the FSM clause
reduces to "announce and collect." The interface-change axis: teardown becomes an
internal event protocol rather than a sequence of direct calls. This mirrors how
the TUI and dashboard react to `%Cancelled{}` (external), but applies the same
pub-sub inversion internally for the teardown phase itself. The `handle_cancelling/2`
protocol is more API-stable than `cancel_cluster/1` (Proposal 3) because it
receives the event struct, giving each handler access to `scope` and any future
metadata without changing the signature.

## Sketch

```elixir
# lib/tau/session/events.ex — add internal event struct
defmodule Tau.Session.Events.Cancelling do
  @moduledoc "Internal event emitted before teardown begins; not broadcast externally."
  @enforce_keys [:session_id, :scope]
  defstruct [:session_id, :scope]
  @type scope :: :permission | :cross_cutting
  @type t :: %__MODULE__{session_id: String.t(), scope: scope()}
end

# lib/tau/session/cancellation.ex — new thin dispatcher module
defmodule Tau.Session.Cancellation do
  @moduledoc """
  Dispatches the internal `%Cancelling{}` event to registered cluster handlers,
  returning the updated `Data.t()`.

  Handlers are registered at compile time. Order is significant:
  ProviderTurn → ToolDispatch → Compaction → CodingAgentTurn.
  """

  alias Tau.Session.Events.Cancelling
  alias Tau.Session.Data

  # Compile-time registry — not a runtime subscription.
  @handlers [
    Tau.Session.ProviderTurn,
    Tau.Session.ToolDispatch,
    Tau.Session.Compaction,
    Tau.Session.CodingAgentTurn
  ]

  @spec dispatch(Data.t(), Cancelling.scope()) :: {atom(), Data.t()}
  def dispatch(data, scope) do
    event = %Cancelling{session_id: data.id, scope: scope}
    # Returns {mechanism_atom, Data.t()} — mechanism is threaded for ADR-0017 journal.
    Enum.reduce(@handlers, {:noop, data}, fn handler, {_mech, acc} ->
      handler.handle_cancelling(event, acc)
    end)
  end
end

# Cluster modules — implement handle_cancelling/2 (example: ProviderTurn)
defmodule Tau.Session.ProviderTurn do
  # ... existing code ...

  @spec handle_cancelling(Events.Cancelling.t(), Data.t()) :: {:cooperative | :brutal_kill | :noop, Data.t()}
  def handle_cancelling(%Events.Cancelling{}, data) do
    mechanism = cancel_provider_task(data)
    {mechanism, %{data | provider_task: nil, cancel_flag: nil,
                         stream_ref: nil, provider_span_ref: nil, assembler: nil}}
  end
end

defmodule Tau.Session.ToolDispatch do
  @spec handle_cancelling(Events.Cancelling.t(), Data.t()) :: {:noop, Data.t()}
  def handle_cancelling(%Events.Cancelling{scope: scope}, data) do
    data = case scope do
      :permission -> cancel_permission_round_fields(data)   # emit loop + synthesis
      :cross_cutting -> kill_tool_and_command(data)
    end
    {:noop, data}
  end
end

defmodule Tau.Session.Compaction do
  @spec handle_cancelling(Events.Cancelling.t(), Data.t()) :: {:noop, Data.t()}
  def handle_cancelling(%Events.Cancelling{}, data) do
    if data.compaction_monitor, do: Process.demonitor(data.compaction_monitor, [:flush])
    if data.compaction_task && Process.alive?(data.compaction_task),
      do: Process.exit(data.compaction_task, :brutal_kill)
    {:noop, %{data | compaction_task: nil, compaction_monitor: nil}}
  end
end

defmodule Tau.Session.CodingAgentTurn do
  @spec handle_cancelling(Events.Cancelling.t(), Data.t()) :: {:noop, Data.t()}
  def handle_cancelling(%Events.Cancelling{}, data) do
    if data.coding_agent_dispatcher && Process.alive?(data.coding_agent_dispatcher),
      do: Tau.CodingAgent.Dispatcher.cancel(data.coding_agent_dispatcher)
    {:noop, %{data | coding_agent_dispatcher: nil, coding_agent_pending: nil,
                      coding_agent_blocks: []}}
  end
end
```

The two `session.ex` cancel clauses become:

```elixir
def handle_event(:cast, :cancel, :awaiting_permission, data) do
  {_mechanism, data} = Tau.Session.Cancellation.dispatch(data, :permission)
  broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})
  data = finish_cancel(data, "awaiting_permission")
  {:next_state, :awaiting_user, data, followup_actions(data)}
end

def handle_event(:cast, :cancel, _state, data) do
  cascade_to_children(data, :cancel)
  {mechanism, data} = Tau.Session.Cancellation.dispatch(data, :cross_cutting)
  broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})
  data = finish_cancel(data, Atom.to_string(mechanism))
  {:next_state, :awaiting_user, data, followup_actions(data)}
end
```

`finish_cancel/2` handles journal, steering-queue drain, and per-turn field
resets (same as Proposals 2 and 3).

## Tradeoffs

### Strengths

- Handler signature `handle_cancelling/2` is forward-compatible: new metadata in `%Cancelling{}` (e.g. `reason`, `source`) is available to all handlers without changing the callback contract.
- ADR-0017's `mechanism` atom threads naturally through the reduce fold via the `{atom, Data.t()}` return — no separate pre-fold step needed.
- Scope (`%Cancelling{scope: :permission | :cross_cutting}`) flows into each handler, allowing `ToolDispatch` to branch on it without the ambiguity problem noted in Proposal 3.
- Adding a new cluster sub-module requires only: implement `handle_cancelling/2` and add the module to `@handlers` — no editing of the FSM clause bodies.
- The internal event struct `%Cancelling{}` can later be promoted to a real PubSub broadcast if external monitoring of the teardown phase is ever needed — the structural investment is not wasted.

### Weaknesses

- The `@handlers` compile-time list in `Tau.Session.Cancellation` is not enforced: a module that implements `handle_cancelling/2` but is not listed is silently skipped. Unlike Proposal 3's behaviour, there is no compiler warning for a missing registration.
- The `{atom(), Data.t()}` reduce accumulator for the mechanism atom is awkward: only `ProviderTurn` returns a meaningful mechanism; all other handlers return `{:noop, data}`. The fold's `{_mech, acc}` pattern discards intermediate mechanisms — if two handlers both returned non-`:noop` atoms, only the last would survive.
- `handle_cancelling/2` is a non-standard convention (not a `:gen_server` callback, not a `Phoenix.PubSub` subscription) — it will surprise contributors unfamiliar with this codebase's pattern.
- Introduces a new internal event struct, a new dispatcher module, and a new callback on 4 existing modules — the conceptual surface area is larger than Proposals 1 or 2 for the same outcome.
- The `%Cancelling{}` struct name could be confused with `%Cancelled{}` by readers; naming discipline is required.

### Costs

- 2 new files: `lib/tau/session/events/cancelling.ex` (struct, ~10 LOC) and `lib/tau/session/cancellation.ex` (dispatcher, ~30 LOC).
- 4 new `handle_cancelling/2` functions across existing modules (~60 LOC total).
- `session.ex` loses ~230 LOC; gains ~10 LOC.
- No new behaviour module; no compile-time enforcement requires discipline in `@handlers` maintenance.
- Unit tests for `Cancellation.dispatch/2` plus each `handle_cancelling/2`: ~3–4 test modules, ~100–120 test lines (the dispatch coordination is testable in isolation).

## Dependencies

- `%Tau.Session.Events.Cancelling{}` must be added to `lib/tau/session/events.ex` or its own file; this is a minor change to a shared events namespace.
- `Tau.Session.Data` typed struct is beneficial for type-safe field resets; same dependency as Proposals 1–3.
- No library upgrades required.

## Confidence

Low-medium. The interface-change approach is the highest abstraction level of
the four proposals — the mechanism is sound but the `%Cancelling{}` event
protocol is novel in this codebase. Confidence would be raised by confirming
that the `{atom(), Data.t()}` reduce accumulator handles the ADR-0017 mechanism
cleanly (prototype needed) and by checking that no test currently pattern-matches
on the `:cancel` clause body structure in a way that would break.

## Prior art / references

- `Phoenix.LiveView` internal `handle_info/2` event delegation: the pattern of routing a struct event through a dispatcher rather than branching inline.
- `Tau.Session.Events.Cancelled` (external) → `Tau.Session.Events.Cancelling` (internal): the naming mirrors the existing external event, making the internal/external distinction explicit.
- Erlang `:gen_event` manager pattern: multiple handlers for a single event type, each cleaning up its own state — the compile-time list replaces the runtime registration for determinism.
