---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from:
  - proposals/proposal-2.md
  - proposals/proposal-3.md
selection_method: hybrid
revision: 0
---

# Solution: Distribute helpers by concern, with pure/effectful split guiding the two ambiguous placements

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 (`Helpers` grab-bag) | Yes | Surface | Low | Low | Easy |
| 2 (Distribute by concern) | Yes | Deep | Medium | Low | Easy |
| 3 (Util + Effects split) | Yes | Substantial | Low | Low | Easy |
| 4 (Consolidate into Data + inline) | Yes | Substantial | Medium | Medium | Medium |

Fit: all four proposals satisfy the literal acceptance criterion (no `@doc false` on `session.ex`).

Decomplecting depth differentiates them. Proposal 1 moves the grab-bag intact — the concern boundary stays "not session.ex", not a real responsibility. Proposal 4 consolidates into Data and inlines effects; the inlining trades one complecting (named wrappers on the FSM) for another (topic string duplication; telemetry boilerplate at every callsite). Proposal 3's pure/effectful split is principled and low-cost but leaves `hook_payload/3` awkwardly co-located with `append_message/2` in `Util`. Proposal 2 reaches the deepest decomplecting: each function lands in a module with a named, domain responsibility — but its placement of `transition/3` and `emit_user_message_telemetry/3` in `Journal` blurs Journal's scope.

Risk and reversibility: all proposals except 4 are low-risk, easy to reverse (verbatim moves, no logic changes). Proposal 4 introduces duplication risk with inline topic strings and is harder to reverse (inlined code does not have a single re-extraction point).

## Recommendation

Distribute the eight helpers by concern (Proposal 2's scheme), using Proposal 3's pure/effectful naming insight to resolve the one debatable placement: the two telemetry helpers (`transition/3`, `emit_user_message_telemetry/3`) go into a new `Tau.Session.Telemetry` module rather than into `Journal`. This keeps `Journal` scoped to persistence observability and gives the FSM-transition and user-message telemetry a clear home. Everything else follows Proposal 2 exactly: `append_message/2`, `generate_event_id/0`, `current_run?/2` into `Tau.Session.Data`; `broadcast/2` into `Tau.Session.Events`; `hook_payload/3` + `transcript_path/1` into a new `Tau.Session.Hooks`; `process_user_message/2` into `Tau.Session.Queue`. `process_user_message/2` retains its `handle_event/4` back-call — that coupling is the user-message-routing sub-problem's scope, not this one's.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-2.md` and `proposals/proposal-3.md`
- **Why chosen:** Proposal 2 achieves the deepest decomplecting by distributing to named-concern modules; it is the only proposal where a sub-module's import list becomes fully self-documenting. Its single weak point is placing transition and user-message telemetry in `Journal`, which Proposal 2 itself acknowledges as debatable. Proposal 3's pure/effectful split insight resolves this cleanly: separating the FSM-transition telemetry from the persistence concern of `Journal` is exactly the `Effects`/`Telemetry` distinction Proposal 3 names. The hybrid takes Proposal 2's concern taxonomy and replaces its `Journal` debatable placement with a new `Tau.Session.Telemetry` module — the minimum change that removes Proposal 2's acknowledged weakness.

Proposal 1 was rejected: `Helpers` is a surface-level move that recreates the grab-bag in a new file.  
Proposal 4 was rejected: inlining the three effectful wrappers trades named abstraction for topic-string duplication; the inline `"session:#{id}"` pattern scattered across sub-modules is more fragile than the named `broadcast/2` it replaces. The consolidation of pure helpers into `Data` is sound, but this proposal takes only the sound part (via Proposal 2's scheme).

## What changes

- `lib/tau/session/data.ex` — add `append_message/2`, `generate_event_id/0`, `current_run?/2` as public `def` with `@spec` typed against `Data.t()`
- `lib/tau/session/events.ex` — add `broadcast/2` as a public `def`; the PubSub topic string `"session:#{id}"` becomes a single point of definition here
- `lib/tau/session/telemetry.ex` — new file (~35 LOC); owns `emit_transition/2` and `emit_user_message/3`
- `lib/tau/session/hooks.ex` — new file (~35 LOC); owns `payload/3` (renamed from `hook_payload/3`) and private `transcript_path/1`
- `lib/tau/session/queue.ex` — add `process_user_message/2` (verbatim move; retains `handle_event/4` back-call)
- `lib/tau/session.ex` — remove all eight `@doc false` defs; update internal callsites to the new module-qualified names
- `lib/tau/session/slash_command.ex`, `provider_turn.ex`, `coding_agent_turn.ex`, `tool_dispatch.ex`, `compaction.ex`, `model_swap.ex` — update callsites; add `alias` lines for whichever of the four destination modules each sub-module needs

## What does not change

- The bodies of all eight functions — verbatim moves, no logic changes
- `generate_id/0` (public API, line 487 of `session.ex`) — untouched
- `Tau.Session.Journal` — no changes; it does not absorb the telemetry helpers
- The `:gen_statem` callbacks, FSM state machine logic, and supervision tree
- External callers of the public `Tau.Session` API — all moved functions were `@doc false`
- `append_message/2`'s O(n) list append — correctness is out of scope

## Migration sketch

1. Add the three functions to `Tau.Session.Data` (purely additive; no callsite breaks yet).
2. Add `broadcast/2` to `Tau.Session.Events`.
3. Create `lib/tau/session/telemetry.ex` with `emit_transition/2` and `emit_user_message/3`.
4. Create `lib/tau/session/hooks.ex` with `payload/3`.
5. Add `process_user_message/2` to `Tau.Session.Queue`.
6. Update all callsites in `session.ex` and the six sub-modules to the new module-qualified names.
7. Remove the eight `@doc false` defs from `session.ex`.

Steps 1–5 are additive and can land in any order; step 6 and 7 land together. The entire migration is one PR with no intermediate broken states — the old names still exist until step 7.

## Open questions

- `Tau.Session.Queue` — does `Queue` already exist as a module? If not, this proposal depends on the user-message-routing sub-problem having created it, or on this PR creating a stub. Verify before implementation.
- `emit_transition/2` signature: Proposal 2 drops the unused `_data` argument from `transition/3`; this should be confirmed against all callsites before the PR lands.
- `Tau.Session.Hooks.payload/3` vs `hook_payload/3`: the rename is minor but any external tooling referencing the old name (hook scripts, tests) must be updated. Confirm no test uses `Tau.Session.hook_payload/3` directly.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — `Tau.Session.Helpers` grab-bag (rejected: surface-level move, grab-bag stigma preserved)
- `proposals/proposal-2.md` — distribute by concern (primary source; concern taxonomy adopted wholesale except Journal telemetry placement)
- `proposals/proposal-3.md` — pure/effectful split (secondary source; naming insight used to resolve Proposal 2's Journal ambiguity via new `Telemetry` module)
- `proposals/proposal-4.md` — consolidate into Data + inline effects (rejected: inlining trades complecting for topic-string duplication; irreversible callsite expansion)

## Revision history

- (revision 0 — initial)
