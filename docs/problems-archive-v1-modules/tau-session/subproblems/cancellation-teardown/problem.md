---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: cancel clause bodies inline multi-cluster teardown instead of delegating

## Statement

`session.ex` contains two `:cancel` `handle_event/4` clause bodies — one
specific to `:awaiting_permission` (~120 LOC, lines 842–961) and one
cross-cutting (~121 LOC, lines 963–1083) — each of which directly emits
`%ToolEnd{}` events, drains queues, demonitors processes, kills tasks,
resets dozens of data fields, and posts `%QueueRestored{}` broadcasts,
rather than delegating each of those operations to the sub-module that owns
the corresponding cluster. A developer changing teardown behaviour for
`ProviderTurn` must read and edit `session.ex`, not `provider_turn.ex`.

## Context

- `session.ex` lines 842–961: `:awaiting_permission`-specific cancel — emits
  `%ToolEnd{}` for `permission_pending_results`, synthesises error
  `ToolResult`s for `pending_permission_requests`, broadcasts `%Cancelled{}`,
  persists a `"cancellation"` journal entry, drains `steering_queue` to
  `%QueueRestored{}`, then resets 14 data fields.
- `session.ex` lines 963–1083: cross-cutting cancel — calls
  `cascade_to_children/2`, calls `ProviderTurn.cancel_provider_task/1`,
  kills `tool_dispatcher`, `command_task`, and `compaction_task`, calls
  `CodingAgent.Dispatcher.cancel/1`, broadcasts `%Cancelled{}`, persists
  a `"cancellation"` journal entry, drains `steering_queue`, then resets
  16 data fields.
- `Tau.Session.ToolDispatch` (`lib/tau/session/tool_dispatch.ex`, 1,060 LOC)
  owns permission-round logic (`handle_permission_allow_once/2`,
  `handle_permission_deny_once/2`) — the inline emit sequence in the
  permission-cancel clause duplicates the pattern from `finish_permission_round/1`.
- `Tau.Session.ProviderTurn` (`lib/tau/session/provider_turn.ex`, 872 LOC)
  owns `cancel_provider_task/1` and provider lifecycle; the compaction and
  coding-agent kills inline in the cross-cutting cancel have no equivalent
  delegates in `Tau.Session.Compaction` or `Tau.Session.CodingAgentTurn`.
- `Tau.Session.Journal.persist/3` is already a clean delegation; only the
  cancel-specific field-reset map is new.
- SPEC-USER-TURN §6, D-080, D-082: queue-drain contracts that both cancel
  clauses must satisfy regardless of where the logic lives.

## Complecting hypothesis

The teardown sequence for permissions is complected with the `:cancel` FSM
clause because `finish_permission_round/1` in `ToolDispatch` covers the
happy-path drain but has no `cancel_permission_round/1` counterpart, so the
cancel path duplicates the emit loop inline.

The multi-cluster resource teardown (provider task + tool dispatcher +
command task + compaction worker + coding-agent dispatcher) is complected
with the `:cancel` FSM clause because no sub-module exposes a
`teardown/1`-style function that resets its own cluster's data fields and
kills its own processes — the FSM clause must orchestrate each cluster
directly.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

Both `:cancel` clause bodies in `session.ex` are reduced to ≤5 lines each:
one delegation to `ToolDispatch.cancel_permission_round/1` (for the
`:awaiting_permission` clause) and one delegation to a shared teardown
coordinator (for the cross-cutting clause), with the data-field reset map
and queue-drain logic living in the owning sub-modules.

## Out of scope

- Queue drain ordering or D-080/D-082 contract changes — behavioural, not structural.
- The `cascade_to_children/2` helper itself — it is already a correctly
  sized private function; its call site may stay in the cancel clause body.
- `try/rescue` removal in any cancel-adjacent code.
- Sibling sub-problems: fsm-facade-helpers, user-message-routing,
  cross-cutting-data.

## Amendment log

- (none yet)
