# ADR-0013: Skill activation lives on the session FSM, scoped to one turn

- **Status:** Accepted
- **Date:** 2026-05-01
- **Deciders:** the agent loop, with no objection from @smug-haus
- **Related:**
  - Issues: #16, #3
  - Code: `lib/tau/session.ex` (`init/1`, `dispatch_tools/2`,
    `finalize_assistant/2`, `handle_event(:cast, :cancel, …)`),
    `lib/tau/permissions/evaluator.ex`
  - Prior ADRs: ADR-0005 (skills are read-only consumed from a pure
    loader), ADR-0009 (turns are the FSM's natural transaction
    boundary)

## Context

Issue #16 requires that when a skill is "active" — typically because the
user invoked it via slash command or a future `pre_tool_use` hook
selected it — every tool call dispatched during that activation be
checked against the skill's `allowed-tools` whitelist before the regular
permissions rule set runs. Tool calls outside the whitelist must fail
synthetically (an `is_error: true` `ToolResult`), exactly like a
permissions evaluator `:deny`.

This raises three coupled questions: **where does activation live**,
**when does it end**, and **who sets it**. Answering them shapes the
public surface for the rest of the M-series milestones.

The constraints in play:

- ADR-0005 says skills are read-only consumed by sessions; sessions do
  not register or mutate skill data.
- Non-negotiable #1 forbids a long-lived "Manager" GenServer for
  shared mutable state. A registry keyed by `session_id → active_skill`
  would be exactly that.
- ADR-0009 establishes the turn (`user_message → … → :end_turn`) as the
  unit of work the FSM cleanly bounds. Mid-turn invariants (postponed
  user messages, in-flight tool dispatcher, fallback chain remaining)
  all live on `data` and are cleared on turn boundaries or cancel.
- The model itself decides when a skill's task is complete by emitting
  `stop_reason: :end_turn`. There is no out-of-band signal we should
  rely on for "skill task done".

## Decision

Skill activation is a single optional field on the session FSM's `data`
map: `data.active_skill :: %Tau.Skill{} | nil`, defaulting to `nil`.

- **Lifetime is per-turn.** `finalize_assistant/2` clears
  `data.active_skill` when the assembled assistant message has
  `stop_reason == :end_turn`. Tool-call turns (`stop_reason == :tool_use`)
  keep the activation so the following tool-result → next-assistant turn
  is still gated by the same whitelist.
- **`:cancel` clears it.** The cancel handler resets `active_skill: nil`
  alongside `provider_task`, `tools_in_flight`, `tool_dispatcher`,
  `assembler`, and `command_task`. Cancel ends the current turn; the
  activation goes with it.
- **Stop drops it.** `:stop` terminates the FSM, so `data` is GC'd
  along with the activation. No extra handling needed.
- **No cross-session activation.** Activation lives strictly on this
  FSM's `data`. There is no global registry, no `Application` env
  fallback, and no PubSub topic that lets one session affect another's
  skill state.
- **Permissions enforcement is positional.** `Tau.Permissions.Evaluator.evaluate/5`
  reads `ctx.active_skill`. When it is set and `allowed_tools` is a
  non-empty list, a tool name not on the list returns `:deny` *after*
  the deny-rule pass but *before* the allow / ask / mode-default
  pipeline. Admin-level deny rules still win first; the skill whitelist
  is necessary, not sufficient.
- **The "set" path is intentionally minimal.** This ADR fixes the
  *enforcement plumbing*; today's slash-command parser does not yet
  resolve into an `active_skill` set. A future PR (or a `pre_tool_use`
  hook) will set the field via a session helper. The plumbing exists so
  that work plugs in without re-litigating the scoping question.

## Consequences

- A skill with `allowed-tools: Bash(npm test) Read` lets the model run
  exactly those operations during its activation. The first
  `:end_turn` clears the gate; subsequent turns operate under the
  global rule set only.
- The synthetic `ToolResult` for a whitelist violation reads
  `Tool '<name>' not on active skill '<skill_name>' allowed_tools
  whitelist`, distinct from the rule-set message
  (`Permission denied: <name> blocked by deny rule`). The model can
  tell the two apart and adapt.
- No new process, ETS table, or `:persistent_term` slot enters the
  supervision tree.
- `Tau.Session.snapshot/1`'s contract is unchanged. (Adding
  `:active_skill` to the snapshot map would be additive and safe per
  the snapshot contract; we defer that until a caller needs it.)
- Setting the activation in the future is a pure `data` update from
  inside an FSM handler. There is no public API for an external caller
  to set someone else's session's active skill, by design.

## Alternatives considered

- **Session-sticky activation (`activate` / `deactivate` slash commands
  toggling a session-wide flag).** Rejected. A model decides mid-stream
  to stop using a skill by emitting `:end_turn`; a session-sticky flag
  would mask that decision and keep the gate up across unrelated user
  turns. It also encourages users to forget the deactivation and
  invent confusion about why later tool calls are denied.
- **Registry-tracked activation (`Tau.Skills.ActiveRegistry` keyed by
  `session_id`).** Rejected. Re-introduces a "Manager" GenServer for
  cross-session bookkeeping that violates non-negotiable #1, and earns
  nothing the FSM-data approach doesn't already provide. Skill state is
  one-to-one with a session; pinning it on the session is the OTP
  shape.
- **Putting activation on `data.metadata`.** Rejected. `metadata` is
  user-supplied, JSON-encodable, and forwarded to hooks and tools (see
  the `Tau.Session.Meta` doc). Skill activation is FSM-internal and
  carries a `%Tau.Skill{}` struct (which is *not* round-tripped through
  JSON via persistence today). Keeping it as a first-class `data` field
  also makes the `:end_turn` clear unambiguous.

## Notes

If a future TUI panel needs "show currently-active skill", it can read
`Tau.Session.snapshot/1` after we add the field there. Until then,
operators introspecting a stuck session can use `:sys.get_state/1` —
same as for any other internal `data` slot.

The "set" path is being scoped out separately. The candidates are
(a) extending the slash-command parser to resolve `/foo` against
`Tau.Skills.Loader` and casting an `:activate_skill` event into the
FSM, or (b) letting a `pre_tool_use` hook return `{:cont, %{... ,
active_skill: skill}}`. Both are local to the FSM — neither requires
revisiting this ADR.
