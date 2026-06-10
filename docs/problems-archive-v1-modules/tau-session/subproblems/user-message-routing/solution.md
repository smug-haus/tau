---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-2.md, proposals/proposal-1.md]
selection_method: hybrid
revision: 0
---

# Solution: Extract `dispatch_idle/2` into SlashCommand; extract `dispatch/2` dispatch table into SlashCommand

## Recommendation

Move the idle-dispatch clause body verbatim into `Tau.Session.SlashCommand.dispatch_idle/2`, and split out the six classify arms into a new `Tau.Session.SlashCommand.dispatch/2` function (called by `dispatch_idle/2`). The two non-idle clauses already have `Queue.handle_postpone/2` and `Queue.handle_enqueue/4` as delegation targets — update `session.ex` to call them. The result: three `handle_event` clauses each ≤3 lines, no inline `case` branching or telemetry emission in `session.ex`, no new inter-module dependencies, and the classifier + dispatch table co-located in `SlashCommand`.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-2.md` (primary) + `proposals/proposal-1.md` (dispatch table extraction)
- **Why chosen:** Proposal 2 satisfies the acceptance criterion with minimum surface change — one new function, two delegation line changes — and is a verbatim extraction that provably preserves behaviour. Its sole weakness is that `dispatch_idle/2` remains a 40-LOC monolith with an inline `case`. Proposal 1's `SlashCommand.dispatch/2` closes that weakness by separating the classify step from the six dispatch arms, making each individually testable and named. The combination (Proposal 2's extraction method + Proposal 1's dispatch table split) gives a slightly smaller `dispatch_idle/2` body (classify → dispatch, 3 lines) and six independently readable dispatch clauses, without the `Queue → SlashCommand` cross-dependency that Proposal 1's `Queue.route/3` would introduce. Proposals 3 and 4 were rejected: Proposal 3 introduces two new modules and a behaviour for a three-branch routing decision of bounded scope (the behaviour's single callback is not warranted — see OTP non-negotiable §3 analogue: no over-abstraction for stateless logic); Proposal 4 introduces a `%UserMessageDecision{}` struct that adds a naming layer without compressing logic, and whose `decide/4 → execute_decision/2` pipeline does not reduce complexity below Proposal 2's simpler extraction.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|---|---|---|---|---|
| 1 | Yes | Substantial | Low | Low | Easy |
| 2 | Yes | Substantial | Low | Low | Easy |
| 3 | Yes | Deep | Medium | Medium | Easy |
| 4 | Yes | Substantial | Medium | Low-Medium | Easy |

Proposals 1 and 2 tie on raw score; the tiebreaker is dependency direction. Proposal 1 routes through `Queue.route/3` which calls `SlashCommand.classify_slash_command/4`, creating a new `Queue → SlashCommand` coupling. Proposal 2 avoids this entirely. The hybrid takes Proposal 2's extraction structure and Proposal 1's dispatch table split, which is strictly compositional: `dispatch_idle/2` calls `classify_slash_command/4` then `dispatch/2`, both already in `SlashCommand`. No new inter-module edges.

## What changes

- **`lib/tau/session/slash_command.ex`**: Add `dispatch_idle/2` (verbatim extraction of the idle-dispatch clause body, refactored to call `dispatch/2`). Add `dispatch/2` with six pattern-match clauses for the classify result (`:builtin`, `:async`, `:skill_activation`, `:model_command` empty, `:model_command` non-empty, `:unknown_command`, `:sync`). Both functions are public with `@spec`.
- **`lib/tau/session.ex`**: The three `handle_event` clauses become:
  1. `Queue.handle_postpone(data, state)` (postpone guard — already correct in structure, update to call Queue function).
  2. `Queue.handle_enqueue(msg, tier, state, data)` (tier-routing clause — call existing Queue function).
  3. `SlashCommand.dispatch_idle(msg, data)` (idle clause — single delegation, 1 line).
  No inline `case`, no `emit_user_message_telemetry` call, in `session.ex`.
- **`lib/tau/session/queue.ex`**: No changes required (functions already present).

## What does not change

- `Tau.Session.Queue` — no new functions, no signature changes.
- `Tau.Session.SlashCommand.classify_slash_command/4` — signature and logic unchanged.
- `Queue.handle_postpone/2` and `Queue.handle_enqueue/4` — unchanged.
- `Tau.Session.emit_user_message_telemetry/3` — remains `@doc false` public; `dispatch_idle/2` calls it, as `Queue.drain_steering_queue_one/1` already does.
- All six arm targets: `SkillActivation.activate_skill_via_slash/2`, `ModelSwap.handle_slash_model_swap/2`, `Tau.Session.broadcast/2`, `process_user_message/2` — unchanged.
- D-077, D-078, D-083 queue cap contract and invariants — untouched.
- All existing tests: the delegation is transparent — no test calling through `handle_event` needs updating.

## Migration sketch

Single PR, no migration. Step 1: add `SlashCommand.dispatch/2` with the six clauses (pure addition, no callers yet). Step 2: add `SlashCommand.dispatch_idle/2` that calls `classify_slash_command/4` then `dispatch/2`, with `emit_user_message_telemetry` call moved inside. Step 3: update the three `handle_event` clauses in `session.ex` to delegate — the idle clause to `dispatch_idle/2`, the non-idle clauses to the existing `Queue` functions they were already shadowing. Step 4: run `mix test` — no tests should fail since all paths are preserved. The three steps can land in one commit; no two-phase migration is needed.

## Open questions

- `emit_user_message_telemetry(:delivered, …)` moves from `session.ex` into `SlashCommand.dispatch_idle/2`. The `:enqueued` and `:postponed` telemetry events remain in `Queue.handle_enqueue/4` and `Queue.handle_postpone/2` respectively. This is consistent with `Queue.drain_steering_queue_one/1` calling `emit_user_message_telemetry` already; but a reviewer should confirm this is intentional rather than a side-effect of the extraction.
- `SlashCommand` will hold a call to `Tau.Session.emit_user_message_telemetry/3`, which is a `@doc false` internal on the FSM module. This is existing practice (Queue already does it), but the coupling is noted. A follow-on could move `emit_user_message_telemetry` to a dedicated telemetry module; that is out of scope here.
- The `dispatch_idle` name encodes FSM state. If a future path invokes idle dispatch from a non-idle state, the name becomes misleading. Alternative: `dispatch_message/2`. Naming choice left to the implementer; the validator should flag if either name choice would fail the acceptance criterion.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — `Queue.route/3` returns a discriminated action; `SlashCommand.dispatch/2` (this proposal's `dispatch/2` is taken from here, minus `Queue.route/3`)
- `proposals/proposal-2.md` — `SlashCommand.dispatch_idle/2` absorbs the full idle clause (primary source; extraction method and module placement)
- `proposals/proposal-3.md` — `UserMessageRouter` behaviour + `MessageRouter` module (rejected: over-abstracts a bounded routing decision into a two-module behaviour)
- `proposals/proposal-4.md` — `%UserMessageDecision{}` struct + `Queue.decide/4` (rejected: adds struct indirection without compressing logic; struct's `:enqueue` branch has a `msg` threading awkwardness)

## Revision history

- (revision 0 — initial)
