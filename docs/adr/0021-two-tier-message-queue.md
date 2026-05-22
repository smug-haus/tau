# ADR-0021: Two-tier message queue (steering / follow-up)

- **Status:** Accepted
- **Date:** 2026-05-22
- **Deciders:** @smug-haus
- **Related:**
  - Issue: #339
  - PR: #360
  - Prior ADRs: ADR-0009 (partially superseded — user-message-postpone path only), ADR-0008 (unchanged)
  - Spec: `docs/spec/SPEC-USER-TURN.md` §6 D-077..D-083

## Context

ADR-0009 introduced a single `:postpone` primitive for user messages that
arrive while the session FSM is busy (`:provider_streaming`, `:tool_executing`,
`:coding_agent_streaming`, etc.). `:postpone` tells `:gen_statem` to park the
cast in the process mailbox and re-deliver it verbatim on the next state
change.

This single-queue approach cannot express Pi's two-tier message model (#339):

- **Steering messages** (`Enter` while busy in Pi): injected at the
  *tool-round boundary* — after all pending tool results are collected,
  BEFORE the next provider call. This gives the user fine-grained control
  over the current turn without abandoning it entirely.
- **Follow-up messages** (`Alt+Enter` while busy in Pi): delivered at the
  *end of the current turn* — after the FSM returns to `:awaiting_user`.
  These queue up additional turns to run sequentially after the in-flight
  work completes.

ADR-0009's single postpone cannot distinguish the two tiers. Postponed
messages all re-deliver on the FIRST state change, which is not the correct
drain point for either tier in the general case.

Additional problems with `:postpone`:

1. **No introspection.** The `:gen_statem` postpone queue is opaque; no
   `snapshot/1` visibility, no cap enforcement, no drain control.
2. **No cancellation interaction.** On `:cancel`, postponed messages are
   silently lost because the FSM never re-enters the state they waited for.
   Pi restores steering messages to the editor (`%QueueRestored{}`); with
   `:postpone` this is impossible.
3. **No cap.** An unbounded postpone queue allows resource exhaustion.

ADR-0008 (slash-command-task postpone) is UNAFFECTED. The `command_task != nil`
guard that postpones user messages while a slash-command task is running is a
separate mechanism with different drain semantics (re-delivery is correct there
because slash-command tasks return the FSM to `:awaiting_user` immediately). This
ADR supersedes ADR-0009's user-message-postpone decision ONLY; ADR-0008 is
preserved byte-identical.

## Decision

Replace ADR-0009's `:postpone` (for the non-`command_task` path) with two
explicit OTP `:queue` FIFO fields on the session FSM data:

- `steering_queue` — holds messages routed via `Tau.steer/2` (`:steering` tier).
  Drained one-at-a-time at the tool-round boundary (`drain_steering_queue_one/1`).
- `followup_queue` — holds messages routed via `Tau.send/2` (`:followup` tier).
  Drained one-at-a-time on `:awaiting_user` entry via `:internal :drain_followups`.

Both queues are capped at 32 messages (D-083). Messages beyond the cap are
dropped silently (no crash, no wedge).

### Public API additions

- `Tau.steer/2` — routes to `:steering` tier (deliver at next tool-round boundary).
  Idle sessions: delivers immediately (same as `Tau.send/2`).
- `Tau.send/2` — unchanged signature; now routes to `:followup` tier when busy.
  Backward compatible: existing callers see the same delivery behavior (next turn
  after the current one completes).

### TUI changes

- `Enter` while busy → `Tau.steer/2`
- `Alt+Enter` while busy → `Tau.send/2`
- `Esc` while idle → clear input editor (NOT quit)
- `Esc` while busy → `Tau.cancel/1`
- Status-bar keybinding hints are state-aware (idle vs busy)

### Cancel interaction (D-082)

On `Tau.cancel/1`: steering messages are returned to the editor via
`%Tau.Session.Events.QueueRestored{messages: list}` and cleared from the queue.
Follow-up messages survive cancellation (they are preserved for the post-cancel
`:awaiting_user` turn).

### `:drain_followups` implementation note

The follow-up drain routes through `handle_event(:cast, {:user_message, msg, :followup}, :awaiting_user, data)` rather than `process_user_message/2` directly. This ensures `classify_slash_command/4` runs, so slash commands queued as follow-ups are correctly dispatched (D-042 compliance) rather than blindly sent to the provider as plain text.

## Consequences

**Good:**

- Two-tier queue matches Pi's interaction model.
- Steering and follow-up queues are introspectable via `snapshot/1`.
- Cancel correctly restores steering messages to the user.
- Hard cap prevents resource exhaustion.
- ADR-0008's slash-command-task postpone is fully preserved — no behavioral
  regression for `/compact`, `/reload`, or any other command task.

**Accepted tradeoffs:**

- Steering messages are held until a tool round occurs (pure-text turns do not
  drain the steering queue). This is the correct Pi semantics: steering is
  meaningful only at the tool-round boundary. Users who want immediate injection
  should cancel and re-send.
- The `:gen_statem` callback mode remains `[:state_enter, :handle_event_function]`
  without change; `:drain_followups` is an `:internal` event, not a `state_enter`
  action, so no module-wide `callback_mode` change is required.

## Implementation

`lib/tau/session.ex`, `lib/tau/session/events.ex`, `lib/tau.ex`,
`lib/tau/tui/app.ex`. Full source map in `docs/spec/SPEC-USER-TURN.md`
Appendix B (D-077..D-083 entry).
