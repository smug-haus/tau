---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Add `cancel_permission_round/1` to ToolDispatch and `cancel/1` to each cluster sub-module

## Approach

Add a `cancel_permission_round/1` function to `Tau.Session.ToolDispatch` that
mirrors `finish_permission_round/1`'s emit loop but synthesises error
`ToolResult`s for still-pending `:ask` calls and resets the permission cluster's
data fields. Add a `cancel/1` (or `teardown_for_cancel/1`) function to
`Tau.Session.Compaction` that demonitors and exits the compaction worker and
clears its fields, and a `cancel/1` to `Tau.Session.CodingAgentTurn` that guards
and calls `CodingAgent.Dispatcher.cancel/1` and clears the coding-agent fields.
`Tau.Session.ProviderTurn` already has `cancel_provider_task/1`; extend it or
add a `teardown_for_cancel/1` that also clears provider-cluster fields
(`provider_task`, `cancel_flag`, `stream_ref`, `provider_span_ref`, `assembler`).
The two `:cancel` clause bodies in `session.ex` become shallow call sequences
over these delegates plus the unchanged `cascade_to_children/2` call and the
existing `Journal.persist/3` call.

## Rationale

The complecting hypothesis names two distinct complections: the permission
teardown is complected with the FSM clause because `ToolDispatch` has no cancel
counterpart to `finish_permission_round/1`; the multi-cluster teardown is
complected because no sub-module exposes a cluster-scoped teardown function. This
proposal resolves both by adding the missing cancel-path functions precisely where
the happy-path functions already live. Each sub-module then owns both directions
of its cluster lifecycle. The decomplecting move is minimal: add the absent
functions, update the callsites — no module boundaries change, no new modules
are created.

## Sketch

```elixir
# lib/tau/session/tool_dispatch.ex — new public function (mirrors finish_permission_round/1)
@spec cancel_permission_round(Data.t()) :: Data.t()
def cancel_permission_round(data) do
  # Emit accumulated deny-once results (same reduce loop as finish_permission_round/1).
  data =
    Enum.reduce(
      Enum.reverse(data.permission_pending_results),
      data,
      fn {call_id, result_msg}, acc ->
        {_lookup, rest} = Map.pop(acc.tool_loop_call_lookups, call_id)
        acc =
          acc
          |> Tau.Session.append_message(result_msg)
          |> Tau.Session.Journal.persist("tool_result",
               Tau.Session.Journal.tool_result_to_data(result_msg))
          |> Map.put(:tool_loop_call_lookups, rest)
        Tau.Session.broadcast(acc.id, %Events.ToolEnd{
          session_id: acc.id, tool_call_id: call_id, result: result_msg})
        acc
      end)

  # Synthesise error ToolResults for still-pending :ask calls.
  data =
    Enum.reduce(
      data.pending_permission_requests,
      data,
      fn {tool_call_id, %{name: name}}, acc ->
        result = ToolResult.new(
          tool_call_id: tool_call_id, tool_name: name,
          content: "Session cancelled while awaiting permission for #{name}.",
          is_error: true)
        {_lookup, rest} = Map.pop(acc.tool_loop_call_lookups, tool_call_id)
        acc =
          acc
          |> Tau.Session.append_message(result)
          |> Tau.Session.Journal.persist("tool_result",
               Tau.Session.Journal.tool_result_to_data(result))
          |> Map.put(:tool_loop_call_lookups, rest)
        Tau.Session.broadcast(acc.id, %Events.ToolEnd{
          session_id: acc.id, tool_call_id: tool_call_id, result: result})
        acc
      end)

  %{data |
    pending_permission_requests: %{},
    permission_dispatch_batch: [],
    permission_pending_results: [],
    tools_in_flight: %{},
    tool_dispatcher: nil}
end

# lib/tau/session/compaction.ex — new public function
@spec cancel(Data.t()) :: Data.t()
def cancel(data) do
  if data.compaction_monitor, do: Process.demonitor(data.compaction_monitor, [:flush])
  if data.compaction_task && Process.alive?(data.compaction_task),
    do: Process.exit(data.compaction_task, :brutal_kill)
  %{data | compaction_task: nil, compaction_monitor: nil}
  # compaction_failures intentionally NOT reset
end

# lib/tau/session/coding_agent_turn.ex — new public function
@spec cancel(Data.t()) :: Data.t()
def cancel(data) do
  if data.coding_agent_dispatcher && Process.alive?(data.coding_agent_dispatcher),
    do: Tau.CodingAgent.Dispatcher.cancel(data.coding_agent_dispatcher)
  %{data |
    coding_agent_dispatcher: nil,
    coding_agent_pending: nil,
    coding_agent_blocks: []}
end

# lib/tau/session/provider_turn.ex — extend or add alongside cancel_provider_task/1
@spec teardown_for_cancel(Data.t()) :: {atom(), Data.t()}
def teardown_for_cancel(data) do
  mechanism = cancel_provider_task(data)
  {mechanism, %{data |
    provider_task: nil, cancel_flag: nil,
    stream_ref: nil, provider_span_ref: nil, assembler: nil}}
end
```

After these additions, the two `:cancel` clauses in `session.ex` reduce to:

```elixir
# :awaiting_permission clause (~5 lines)
def handle_event(:cast, :cancel, :awaiting_permission, data) do
  data = ToolDispatch.cancel_permission_round(data)
  broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})
  data = drain_steering_and_reset(data, "awaiting_permission")
  {:next_state, :awaiting_user, data, followup_actions(data)}
end

# cross-cutting clause (~5 lines)
def handle_event(:cast, :cancel, _state, data) do
  cascade_to_children(data, :cancel)
  {mechanism, data} = ProviderTurn.teardown_for_cancel(data)
  data = data |> ToolDispatch.cancel_tool_cluster() |> Compaction.cancel() |> CodingAgentTurn.cancel()
  broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})
  data = drain_steering_and_reset(data, Atom.to_string(mechanism))
  {:next_state, :awaiting_user, data, followup_actions(data)}
end
```

where `drain_steering_and_reset/2` (a private helper in `session.ex`) handles
`Journal.persist/3`, the steering-queue drain + `%QueueRestored{}` broadcast,
remaining per-turn field resets (`active_skill`, `tool_iterations`,
`tool_loop_state`, `tool_loop_call_lookups`, `provider_retry_state`,
`steering_queue`), and is shared between both clauses.

## Tradeoffs

### Strengths

- Satisfies the acceptance criterion directly: both clause bodies reduce to ≤5 lines by delegating to the functions that own each cluster.
- Minimal blast radius: no new modules, no structural reorganisation — only new public functions added to modules that already own the relevant fields.
- `cancel_permission_round/1` is the obvious symmetric companion to `finish_permission_round/1`; any reader of `ToolDispatch` will immediately understand the pairing.
- `Compaction.cancel/1` can be called from any future cancel path without referencing `session.ex`.
- Incremental: each delegate function can be extracted and tested independently before wiring.

### Weaknesses

- The shared `drain_steering_and_reset/2` helper remains in `session.ex`; it is still a private FSM helper rather than a delegate, meaning queue-drain logic has two homes (SPEC-USER-TURN §6, D-082 constraint stays visible but not resolved).
- `ProviderTurn.teardown_for_cancel/1` combines a side-effectful kill with a data-shape return; the mixed signature (`{atom(), Data.t()}`) is unidiomatic relative to the existing `cancel_provider_task/1 :: atom()` that does not return data.
- Does not address the `tool_dispatcher` and `command_task` kills (lines 984–990) — these inline guards have no obvious sub-module home (`ToolDispatch` dispatches tools but does not own the process handle lifecycle for the raw pid); they may remain in `session.ex` or require a further `ToolDispatch.cancel_dispatcher/1` extension.
- Adding `cancel/1` to `Compaction` and `CodingAgentTurn` grows each module's public API; callers outside `session.ex` could misuse the cancel path.

### Costs

- 4 new public functions across 4 modules; ~60 LOC total new code (mostly moved from the cancel clauses).
- `session.ex` loses ~200 LOC from the cancel clause bodies; gains ~30 LOC in delegates.
- Unit tests for `cancel_permission_round/1`, `Compaction.cancel/1`, `CodingAgentTurn.cancel/1`, and `ProviderTurn.teardown_for_cancel/1` are new — ~4 new test modules or ~80–100 new test lines.
- Low disruption: no existing callers of any affected module change.

## Dependencies

- `Tau.Session.Data` must be a typed struct (the `cross-cutting-data` sub-problem's acceptance criterion); without it, the field-reset maps in the new functions are unguarded. This proposal can land before that refactor but will benefit from it.
- No library upgrades required.

## Confidence

Medium. The pattern (add a cancel-path sibling to the happy-path function) is
well-established; `finish_permission_round/1` already shows the exact shape.
Confidence would be raised by a prototype confirming that the `tool_dispatcher`
/ `command_task` kill guards fit naturally in a `ToolDispatch.cancel_dispatcher/1`
without requiring the raw pids to be passed in separately.

## Prior art / references

- `finish_permission_round/1` in `lib/tau/session/tool_dispatch.ex` (lines 294–): the happy-path pattern this proposal mirrors for the cancel path.
- `cancel_provider_task/1` in `lib/tau/session/provider_turn.ex` (lines 95–130): existing cancel delegate; this proposal extends the same pattern to the other clusters.
- Erlang/OTP `gen_statem` convention: FSM callbacks delegate to domain modules; the FSM holds only wiring.
