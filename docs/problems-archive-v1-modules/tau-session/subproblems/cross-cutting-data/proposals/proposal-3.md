---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Split Data into typed sub-structs by concern cluster

## Approach

Replace the single flat 69-field `Tau.Session.Data` struct with a nested
struct whose top-level fields are typed sub-structs, one per concern cluster.
`Data.new/1` returns `{:ok, %Tau.Session.Data{}}` as today, but the struct
now composes:

- `%Data.ProviderState{}` — `provider_task`, `stream_ref`, `provider_span_ref`,
  `cancel_flag`, `assembler`, `fallback_chain_remaining`, `provider_retry_state`,
  `provider_retry_max`, `provider_retry_base_delay_ms`
- `%Data.ToolState{}` — `tools_in_flight`, `tool_dispatcher`, `tool_iterations`,
  `max_tool_iterations`, `tool_loop_state`, `tool_loop_brake_threshold`,
  `tool_loop_call_lookups`
- `%Data.CodingAgentState{}` — all `coding_agent_*` fields (9 fields)
- `%Data.CompactionState{}` — `compaction_task`, `compaction_monitor`,
  `compaction_failures`
- `%Data.QueueState{}` — `steering_queue`, `followup_queue`
- `%Data.PermissionState{}` — `interactive?`, `pending_permission_requests`,
  `permission_dispatch_batch`, `permission_pending_results`

The top-level `%Data{}` retains session-identity fields (`id`, `cwd`,
`provider`, `model`, etc.) as first-class fields. Sub-modules receive the
relevant sub-struct as an argument where they previously received the full
`data`; `session.ex` extracts and re-embeds sub-structs at the FSM clause
boundary.

## Rationale

The flat 69-field struct is itself a mild complecting: all concern clusters
share a single namespace and update path. Sub-modules that own a cluster (e.g.
`ProviderTurn`, `ToolDispatch`, `CodingAgentTurn`) currently receive the entire
`data` and touch only their slice; the dependency on the full struct is wider
than necessary. Typed sub-structs give each cluster a `defstruct`/`@type t`
of its own, allowing Dialyzer to verify that `ToolDispatch` never reads
`compaction_task` and that `CompactionTurn` never reads `tools_in_flight`. The
dynamic-key queue dispatch in `queue.ex` disappears because `QueueState` has
only two fields and both are named; the `case tier` branch is a natural
pattern match on a two-field struct with no dynamic dispatch needed. Defensive
`Map.get` calls on the outer struct are structurally impossible — sub-modules
receive typed sub-structs, not maps.

## Sketch

```elixir
# lib/tau/session/data/queue_state.ex
defmodule Tau.Session.Data.QueueState do
  @enforce_keys [:steering_queue, :followup_queue]
  defstruct [:steering_queue, :followup_queue]
  @type t :: %__MODULE__{
          steering_queue: :queue.queue(),
          followup_queue: :queue.queue()
        }
end

# lib/tau/session/data/provider_state.ex
defmodule Tau.Session.Data.ProviderState do
  defstruct [provider_task: nil, stream_ref: nil, provider_span_ref: nil,
             cancel_flag: nil, assembler: nil, fallback_chain_remaining: [],
             provider_retry_state: %{count: 0}, provider_retry_max: 3,
             provider_retry_base_delay_ms: 1000]
  @type t :: %__MODULE__{...}
end

# lib/tau/session/data.ex — top-level struct composes sub-structs
defstruct [
  :id, :cwd, :provider, :original_provider, :model,
  :persistence, :persist_handle,
  metadata: %{},
  provider_ctx: %{},
  messages: [],
  skills: [],
  prompt_templates: [],
  command_task: nil,
  active_skill: nil,
  persona_lifetime: :turn,
  tools_whitelist: :all,
  child_session_ids: nil,
  provider:   %Tau.Session.Data.ProviderState{},
  tools:      %Tau.Session.Data.ToolState{},
  coding_agent: %Tau.Session.Data.CodingAgentState{},
  compaction: %Tau.Session.Data.CompactionState{},
  queues:     %Tau.Session.Data.QueueState{...},
  permissions: %Tau.Session.Data.PermissionState{}
]

# queue.ex — no dynamic dispatch needed
@spec enqueue(Tau.Session.Data.t(), Tau.Message.t(), :steering | :followup, atom()) ::
        Tau.Session.Data.fsm_result()
def enqueue(%Tau.Session.Data{queues: %QueueState{} = qs} = data, msg, tier, from_state) do
  {queue, update_fn} =
    case tier do
      :steering -> {qs.steering_queue, &%{qs | steering_queue: &1}}
      _         -> {qs.followup_queue, &%{qs | followup_queue: &1}}
    end
  # ... cap check ...
  new_qs = update_fn.(:queue.in(msg, queue))
  {:keep_state, %{data | queues: new_qs}}
end
```

File touches: new files `lib/tau/session/data/provider_state.ex`,
`tool_state.ex`, `coding_agent_state.ex`, `compaction_state.ex`,
`queue_state.ex`, `permission_state.ex`; revised `lib/tau/session/data.ex`;
revised `lib/tau/session/queue.ex`, `provider_turn.ex`, `tool_dispatch.ex`,
`coding_agent_turn.ex`, `compaction.ex`, `session.ex`.

## Tradeoffs

### Strengths

- Every concern cluster has its own typed struct; Dialyzer coverage is
  maximised — cross-cluster field access becomes a compile-time type error.
- Dynamic `Map.get(data, queue_field)` is eliminated structurally, not by
  adding branches.
- Sub-modules can specify narrower argument types (e.g.
  `Tau.Session.Data.ToolState.t()` rather than `Tau.Session.Data.t()`),
  making their dependencies explicit at the spec level.
- The `coding_agent_state` nested map (`Map.get(data.coding_agent_state, :session_id)`)
  disappears because `CodingAgentState` has named fields.

### Weaknesses

- Large scope: ~10 files touched, ~200 lines changed or added. Well outside
  the "minimal surgical edit" risk profile.
- The FSM cancel clauses in `session.ex` now reconstruct multiple nested
  structs instead of one flat map update — verbosity increases.
- `session.ex` and all sub-modules must be updated simultaneously; no
  incremental path unless field renaming is done in multiple PRs. This is an
  API-breaking change to every sub-module's public signatures.
- Naming collision risk: `data.provider` (a module) and
  `data.provider` (the sub-struct) would need to be disambiguated — requires
  renaming one of them (e.g. `data.provider_state`).
- Review surface is large; the gate must compare a diff touching 10+ files;
  risk of subtle merge ordering errors.

### Costs

- Estimated diff: ~250–300 lines across 10+ files.
- Must update all tests that build `Data` structs or access fields directly.
- Dialyzer PLT rebuild required; first-run PLT analysis on new struct hierarchy
  can surface false warnings that need suppression annotations.

## Dependencies

- Must be a single atomic PR (no partial delivery is safe).
- Requires that the sibling `cancellation-teardown` sub-problem NOT be in
  flight simultaneously — both touch the cancel clauses in `session.ex`.

## Confidence

Medium. The approach is correct in principle; the implementation scope is
large and the naming collision on `provider` requires careful resolution. A
prototype of the `QueueState` extraction alone would raise confidence.

## Prior art / references

- Erlang/OTP `:gen_statem` `data` field nesting pattern — state records with
  typed sub-records per concern cluster are idiomatic in complex state machines.
- `Tau.Session.Meta` — already a typed struct for session metadata returned to
  callers; the same principle applied to internal FSM state.
- Elixir forum: "Nested structs for large GenServer state" — community consensus
  favours nested structs for state machines with >30 fields.
