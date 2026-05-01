# ADR-0009: User messages queue (postpone) during an active turn

- **Status:** Accepted
- **Date:** 2026-05-01
- **Deciders:** the agent loop, with no objection from @smug-haus
- **Related:**
  - Issue: #64
  - Code: `lib/tau/session.ex` (`handle_event(:cast, {:user_message, _}, …)`)
  - Prior: ADR-0008 (user code never runs synchronously inside the FSM)

## Context

`Tau.Session` is a `:gen_statem` with four user-visible states:
`:awaiting_user`, `:provider_streaming`, `:tool_executing`, and the
implicit `:stopped` (gen_statem terminates immediately on `:stop`).

Until this ADR, the user-message handler matched any state:

```elixir
def handle_event(:cast, {:user_message, msg}, _state, data) do
  case classify_slash_command(msg) do
    {:async, mod, args, msg} -> spawn_command_task(mod, args, msg, data)
    {:sync, msg}             -> process_user_message(msg, data)
  end
end
```

A user cast that arrived during `:provider_streaming` or
`:tool_executing` would append to `data.messages`, persist a
`"user_message"` event, and call `start_provider` again — racing with
the still-live `provider_task` and the `:provider_event` /
`:tool_done` traffic already in the mailbox (#64). Even when no race
manifested, the second user message could land mid-tool-call and end
up adjacent to a `tool_call` block in the transcript without its
matching `tool_result`, which providers reject.

ADR-0008 already established that follow-up user messages **must
queue, not drop**: a user typing while a slash-command worker is in
flight has their input postponed. We need the same guarantee
covering provider-streaming and tool-executing — not just slash
commands.

## Decision

The session FSM accepts `{:user_message, _}` casts only in
`:awaiting_user`. In every other state (and while
`data.command_task != nil`, per ADR-0008) the cast is **postponed**
via gen_statem's built-in `:postpone` action; gen_statem re-delivers
postponed events on the next state transition, so the message lands
naturally on entry into `:awaiting_user` without the FSM maintaining
its own queue.

Specifics:

- Two clauses fire on `{:cast, {:user_message, _}}`:

  1. A guard clause matching anything other than `:awaiting_user`
     (or `:awaiting_user` while `command_task != nil`) returns
     `{:keep_state_and_data, [{:postpone, true}]}` and emits
     `[:tau, :session, :user_message, :enqueued]` telemetry.
  2. The existing accept clause matches only `:awaiting_user` (and
     `command_task == nil`) and proceeds with `classify_slash_command`
     + dispatch as before, emitting
     `[:tau, :session, :user_message, :delivered]` telemetry.

- Telemetry pairs but **does not span**: there is no monotonic
  `duration` measurement linking enqueue to delivery, because
  postponed events are re-delivered through the gen_statem mailbox
  and not labeled. Each event carries `session_id`, `from_state`
  (the state we postponed in / delivered in), and the canonical
  `system_time` measurement.

- Cancellation interaction: postponed events **survive** a `:cancel`
  cast. The existing cancel handler returns
  `{:next_state, :awaiting_user, …}`, which triggers gen_statem's
  postpone-redelivery. The user's queued follow-up runs immediately
  after cancel, on a clean turn. This matches user intent: cancel
  ends *this* turn, not all queued input.

- Stopped-state interaction: `:stop` returns `{:stop, :normal, _}`,
  terminating the process and dropping the mailbox (including any
  postponed events). This is correct — stopping ends the session.

- Snapshot interaction: `Tau.Session.snapshot/1` does not expose
  postponed messages. Postponed events live in the gen_statem's
  internal queue, not in `data`, and there is no public API to
  introspect them. If a future TUI panel needs "show pending input",
  we'll switch to an explicit queue field at that time.

## Consequences

- A `{:user_message, _}` cast in flight during a tool call or
  provider stream lands in order on the next return to
  `:awaiting_user`. No race on the provider task, no orphaned
  `tool_call` blocks.
- Per-source FIFO is preserved: gen_statem postpones reorder nothing
  — events come back in arrival order on the next transition.
- The session's `data` struct gains nothing new — no
  `pending_user_messages` field to keep in sync with the mailbox.
- No callers see a behavioural break. The cast contract is unchanged
  (`:gen_statem.cast/2` returns `:ok` regardless of whether delivery
  is immediate or postponed).
- The runtime cost is one extra clause-match per user_message cast
  arriving in a non-idle state. Postponed events sit in the
  gen_statem internal queue and are O(n) on the next state-change
  scan; bounded by the user's typing rate, this is unmeasurable.
- Postponed events are not visible to `:sys.get_status/1` callers
  outside of the postpone-internal queue. Operators debugging a
  stuck session will see them via `erlang:process_info(pid,
  :messages)`.

## Alternatives considered

- **Explicit `pending_user_messages` queue field on `data`,
  drained on entry into `:awaiting_user`.** This is what the
  status-report draft proposed. It works, but reimplements what
  gen_statem already does for free — and it diverges from
  ADR-0008's `:postpone` pattern that's already in this module
  for the slash-command-task case, which would be confusing to
  read. The only thing this approach buys us is introspectability
  via `snapshot/1`, which no caller needs today.

- **Drop or error the cast when busy.** A drop loses user input
  silently; a synchronous error tuple is incompatible with
  `:gen_statem.cast/2`'s fire-and-forget contract. Both punt the
  ordering problem onto callers who shouldn't have to know the
  FSM's current state.

- **Block the sender (turn the cast into a `call`).** Couples the
  caller's lifecycle to the session and re-introduces every
  problem ADR-0008 was written to solve (a slow provider stream
  blocks the API caller).

## Notes

The same shape ports cleanly to other "owner-private" cast events
that should respect turn boundaries — e.g. compaction-trigger casts,
should we ever expose them. The pattern is: only accept in
`:awaiting_user`; postpone elsewhere.

The `[:tau, :session, :user_message, :delivered]` event fires on the
clause that previously had no telemetry; it's the canonical hook for
"a user turn began" and supersedes ad-hoc inferences from
`[:tau, :session, :transition]` with `to: :provider_streaming`.
