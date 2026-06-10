---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: user-message handle_event clauses mix queue-gating with slash-command dispatch

## Statement

Three `handle_event` clauses for `{:user_message, msg, tier}` in
`session.ex` (lines 563–690) each contain multi-branch inline logic:
the postpone guard on `command_task != nil` (5 LOC), the tier-routing
and queue-cap clause (41 LOC), and the idle-dispatch clause (47 LOC)
that calls `SlashCommand.classify_slash_command/4` and then branches
on six match arms — all in the FSM façade rather than in
`Tau.Session.Queue`. A reader tracing how a user message flows through
the system must follow `session.ex → SlashCommand → session.ex` rather
than `session.ex → Queue → SlashCommand`.

## Context

- `session.ex` lines 563–570: postpone clause — `command_task != nil`, calls
  `emit_user_message_telemetry(:enqueued, ...)` and returns
  `{:keep_state_and_data, [{:postpone, true}]}`.
- `session.ex` lines 572–611: tier-routing clause — `state != :awaiting_user`;
  resolves `queue_field` from `tier`, enforces 32-message cap with
  `%Events.SystemNotice{}`, enqueues or drops, emits telemetry.
- `session.ex` lines 613–657: idle-dispatch clause — `state == :awaiting_user`,
  `command_task == nil`; calls `SlashCommand.classify_slash_command/4`,
  six `case` arms, calls `process_user_message/2` for `:sync` and
  `:skill_activation` arms.
- `Tau.Session.Queue` (`lib/tau/session/queue.ex`, 180 LOC) owns
  `drain_followups/1`, `drain_steering_queue/1`, queue predicates — it is the
  natural owner of the routing decision "is this a queueable state?".
- `Tau.Session.SlashCommand` (`lib/tau/session/slash_command.ex`, 373 LOC)
  owns `classify_slash_command/4` and command-spawning — the six `case` arms
  in the idle-dispatch clause are really a delegation table that belongs
  adjacent to the classifier.
- The six `case` arms include calls to `Tau.Session.SkillActivation`,
  `Tau.Session.ModelSwap`, and `process_user_message/2` (itself `@doc false`
  on the FSM) — the idle-dispatch clause is the last place that touches
  multiple sub-module concerns in a single FSM clause body.

## Complecting hypothesis

Queue-gating logic (postpone, tier routing, cap enforcement) is complected
with slash-command dispatch because both phases of message handling — "should
this message be queued?" and "if idle, what kind of message is this?" — are
resolved in the same `handle_event` clause file rather than separated into
`Queue.route/3` (returns `:enqueue | :drop | :deliver`) and
`SlashCommand.dispatch/2` (returns a `handle_event` action tuple).

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The three `{:user_message}` `handle_event` clauses in `session.ex` are each
reduced to ≤3 lines: one that delegates the postpone decision to
`Tau.Session.Queue`, one that delegates tier-routing and cap-enforcement to
`Tau.Session.Queue`, and one that delegates idle dispatch (including the six
classify arms) to `Tau.Session.Queue` or `Tau.Session.SlashCommand`, with no
inline `case` branching or telemetry emission in `session.ex`.

## Out of scope

- Queue cap value, drain ordering, or D-077/D-078/D-083 contract changes.
- The `drain_followups` and `drain_steering_queue` internal-event clauses
  (lines 659–690) — those are already short and delegate cleanly.
- Slash-command classification logic itself (classification is already in
  `SlashCommand`; this problem is about the dispatch table that calls it).
- Sibling sub-problems: cancellation-teardown, fsm-facade-helpers,
  cross-cutting-data.

## Amendment log

- (none yet)
