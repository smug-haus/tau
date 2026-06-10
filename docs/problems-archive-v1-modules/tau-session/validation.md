---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/5
revision_triggered: none
---

# Validation: Complete the session decomposition by distributing the four residual concerns to their owning modules

## Overview

The root solution synthesises four validated child solutions into a single
four-PR sequence (1 cross-cutting-data → 2 fsm-facade-helpers → 3
cancellation-teardown [3A/3B/3C] → 4 user-message-routing) that collectively
reduces `lib/tau/session.ex` to a thin `:gen_statem` façade. This validation
treats the root as a non-leaf node: its claims are the *integration* claims
that bind the four child solutions, not the per-child mechanics (already
validated downstream). Six integration claims emerge: (1) composition-by-
direct-addition with no signature conflict on `Data`; (2) `fsm-facade-helpers`
BEFORE `user-message-routing` resolves the `emit_user_message_telemetry`
coupling; (3) `cross-cutting-data` BEFORE `cancellation-teardown` makes
`reset_for_cancel/1` available when the cancel clause bodies are rewritten;
(4) each PR ends green with no broken intermediate state and is independently
revertible; (5) the post-PR-4 state satisfies the parent acceptance criterion
in its four conjuncts; (6) parent MECE holds — disjoint line-clusters across
the four children. Each claim is exercised with an explicit falsification
strategy. Five withstood; one (claim 5, AC conjunction) is partially
falsified — the qualifier narrows on the `finish_cancel/2` placement open
question and the (implicit) `cascade_to_children/2` exception. No revision
of the solution or problem is triggered; outstanding doubts are recorded.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that unguided generation
produces highly variable output; per-field prompts in the template counter
that. All six fields are filled below; none are merged.

### Claim 1: The four child recommendations compose by direct addition; each owns a disjoint cluster of `session.ex` lines and a disjoint set of new/extended sub-module surfaces, with `Data` as the only merge point and three reconciliation points all resolvable in favour of the child solutions as written.

- **Claim (C):** "The four child recommendations compose by direct addition;
  each owns a disjoint cluster of `session.ex` lines and a disjoint set of
  new/extended sub-module surfaces. Three composition points need explicit
  reconciliation, all resolvable in favour of the child solutions as
  written." (solution.md §"Selected from" / "Composition rationale")
- **Grounds (G):** Three independent inspections:
  (i) **`Data` surface additions are signature-disjoint.** `cross-cutting-data`
  adds `get_queue/2`, `put_queue/3`, `replace_field/3`, `reset_for_cancel/1`;
  `fsm-facade-helpers` adds `append_message/2`, `generate_event_id/0`,
  `current_run?/2`. All seven names differ from each other AND from the
  existing public surface on `lib/tau/session/data.ex` (verified by `grep -n
  'def\|defstruct\|@type t'` on `data.ex`: only `new/1`, `validate/1`,
  `defstruct` at line 96, `@type t` at line 41 are present today). No
  collision.
  (ii) **`session.ex` line-clusters are disjoint.** `cancellation-teardown`
  owns lines 842–961 (`:awaiting_permission` cancel) + 963–1083
  (cross-cutting cancel), confirmed by inspecting the actual file:
  `def handle_event(:cast, :cancel, :awaiting_permission, data)` at line 842
  and `def handle_event(:cast, :cancel, _state, data)` at line 963.
  `user-message-routing` owns the three `{:user_message, ...}` clauses at
  lines 563, 572, 613 (also confirmed by direct grep). `fsm-facade-helpers`
  owns the eight `@doc false` defs at lines 1292/1295/1299/1310/1344/1347/
  1365/1387/1403 (confirmed by `grep -n "@doc false"`). `cross-cutting-data`
  owns no `session.ex` lines — only sub-module struct-match heads. Zero
  overlap.
  (iii) **No two children create the same new file.** Only
  `cancellation-teardown` creates `cancellable.ex`; only `fsm-facade-helpers`
  creates `telemetry.ex` and `hooks.ex`. The four children's "new file" sets
  are pairwise disjoint.
- **Warrant (W):** When two refactor units (i) touch pairwise-disjoint lines
  in the shared source file, (ii) add pairwise-disjoint names to a shared
  module's public surface, and (iii) create pairwise-disjoint new files,
  their composition is the *union* of their diffs and does not require a
  joint redesign; any residual cross-reference is a sequencing concern,
  not a content conflict. (This is the textbook definition of "additive
  composition" for code changes.)
- **Qualifier (Q):** Holds for the four children as written today (revision 0
  of each child solution). If a child is revised to widen its surface, the
  disjoint-name check must be re-run. The `cascade_to_children/2` helper
  remains in `session.ex` (solution.md "What does not change") — this is
  flagged as a deliberate exception to "no inline teardown" (see claim 5).
- **Rebuttal (R):** Would fail if a child solution silently added a name
  already exported by another child. Re-inspection of all seven `Data`
  additions (above) and the three new modules confirms none does.
- **Backing (B):** The four child `validation.md` files all report
  `falsification_outcome: partially_falsified — claim/N` with
  `revision_triggered: none` — each child's claims survive at the level of
  the *child's* qualifier. The MITRE Toulmin study
  (https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument)
  motivates the explicit per-field check rather than gestalt review of
  composition.

#### Falsification attempt for claim 1

- **Strategy:** Counter-example construction (try to find two children whose
  surfaces collide).
- **Attempt:** Cross-referenced the seven new `Data` `def`s named across
  `cross-cutting-data` and `fsm-facade-helpers` against (i) each other, (ii)
  the existing `Data` API (`grep -n 'def ' lib/tau/session/data.ex`), and
  (iii) the existing `Tau.Session` cross-module callsites (`grep -n
  'Tau.Session.broadcast\|Tau.Session.hook_payload\|Tau.Session.append_message
  \|Tau.Session.current_run\|Tau.Session.emit_user_message_telemetry\|
  Tau.Session.process_user_message\|Tau.Session.generate_event_id'
  lib/tau/session/*.ex`). The eight cross-module callsites are concentrated
  in `provider_turn.ex`, `tool_dispatch.ex`, `slash_command.ex`, `queue.ex`,
  `compaction.ex`, `coding_agent_turn.ex`, `model_swap.ex`, `data.ex`,
  `skill_activation.ex` — all are receivers of moves, not additional sources
  of conflict. Also checked: does `cancellation-teardown` need a `Data`
  field `cross-cutting-data` doesn't already preserve? Per the synthesis
  (composition point 3), `Data.reset_for_cancel/1` is owned by
  `cross-cutting-data` and consumed by `cancellation-teardown`; the scope
  list is identical between the two children.
- **Outcome:** withstood — no signature, file, or line collision found.
- **Action:** none.

### Claim 2: Sequencing `fsm-facade-helpers` BEFORE `user-message-routing` resolves the `emit_user_message_telemetry` coupling that `user-message-routing` would otherwise leave in place.

- **Claim (C):** "The synthesis sequences `fsm-facade-helpers` BEFORE
  `user-message-routing` so the new `dispatch_idle/2`,
  `Queue.handle_enqueue/4`, and `Queue.handle_postpone/2` call the new
  `Tau.Session.Telemetry.emit_user_message/3` directly. The acknowledged
  coupling in `user-message-routing`'s solution is resolved at sequence
  time, not as a residual debt." (solution.md §"Selected from" /
  "Composition rationale" point 2)
- **Grounds (G):** (i) `user-message-routing`'s Open Questions explicitly
  flags the coupling — its `dispatch_idle/2` would otherwise call the
  FSM-resident `Tau.Session.emit_user_message_telemetry/3`. (ii) Today's
  callers of `Tau.Session.emit_user_message_telemetry/3` are precisely
  `lib/tau/session/queue.ex:97,116,128` and the three soon-to-be-replaced
  inline clauses in `session.ex:565,605,614` (verified by grep). (iii)
  `fsm-facade-helpers` (PR 2) creates `Tau.Session.Telemetry` with
  `emit_user_message/3` and updates ALL callsites to the new module before
  deleting the FSM-resident `@doc false def`. PR 4 (user-message-routing)
  is therefore writing its new `SlashCommand.dispatch_idle/2` against a
  world where `Tau.Session.Telemetry.emit_user_message/3` already exists.
- **Warrant (W):** If a successor PR's required API is created and
  callsite-migrated by its predecessor PR — and the predecessor PR ends
  green — then the successor PR's new code can call the new API directly
  without inheriting the prior coupling. (This is the standard "land
  substrate then build on it" sequencing rule for incremental refactors.)
- **Qualifier (Q):** Holds provided PR 2 completes its step 6 ("update all
  callsites … to the new module-qualified names") AND step 7 ("delete the
  eight `@doc false` defs") in the same PR, per the solution's PR-2
  migration sketch. If those steps split across two PRs, PR 4 may
  transiently call a still-existing FSM helper.
- **Rebuttal (R):** Would fail if `user-message-routing`'s child solution
  hard-codes a call to `Tau.Session.emit_user_message_telemetry/3` (not the
  new `Tau.Session.Telemetry.emit_user_message/3`). Per the synthesis text,
  the call in `dispatch_idle/2` is to the *new* module name; the solution
  text is unambiguous on this.
- **Backing (B):** The `fsm-facade-helpers` child `validation.md`
  (frontmatter `falsification_outcome: partially_falsified — claim/4,
  revision_triggered: none`) endorses the migration as written. The Pike /
  Hickey principle "do one thing well, then compose" via additive +
  substitutive steps backs the predecessor-substrate-then-successor
  sequencing.

#### Falsification attempt for claim 2

- **Strategy:** Dependency check (verify PR 4's substrate exists at PR-2
  end-of-merge time, not later).
- **Attempt:** Walked PR 2's migration sketch step list — steps 1–5 add new
  surfaces (additive), steps 6–7 substitute callsites and delete the old
  helpers ("land together"). At PR 2's end-of-merge, `Tau.Session.Telemetry`
  exists, all existing callers are migrated, and the FSM-resident helper is
  gone. PR 4 therefore cannot inherit the coupling — there is no helper to
  inherit. Cross-checked against `lib/tau/session/queue.ex:97,116,128`: PR 2
  rewrites these three callsites; PR 4 introduces three more (in
  `SlashCommand.dispatch_idle/2` plus the two non-idle clauses, per the
  synthesis), all to the new module.
- **Outcome:** withstood.
- **Action:** none.

### Claim 3: Sequencing `cross-cutting-data` BEFORE `cancellation-teardown` means `Data.reset_for_cancel/1` exists when the `:cancel` clause bodies are rewritten to call it; no content reconciliation is required.

- **Claim (C):** "`Data.reset_for_cancel/1` is owned by `cross-cutting-data`
  and consumed by `cancellation-teardown`. … Sequencing `cross-cutting-data`
  before `cancellation-teardown` means the function exists when the
  `:cancel` clause bodies are rewritten to call it. No content
  reconciliation is required." (solution.md §"Selected from" /
  "Composition rationale" point 3)
- **Grounds (G):** (i) The two children name the same function with the same
  cross-cutting field scope (`active_skill`, `tool_iterations`,
  `tool_loop_state`, `provider_retry_state`, `steering_queue`) — verified by
  cross-reading both child solution.md files. (ii)
  `cancellation-teardown`'s migration sketch sub-PR 3B explicitly calls
  `Data.reset_for_cancel/1` from `finish_cancel/2`; sub-PR 3A precedes 3B
  but does not need the function (3A only adds the behaviour and the
  four cluster implementations). (iii) PR 1 (cross-cutting-data) lands
  `reset_for_cancel/1` as part of step "(1) add accessors" plus the
  reset-scope addition — solution.md PR 1 enumeration is explicit:
  "`reset_for_cancel/1` lands here too so `cancellation-teardown` (PR 3) can
  call it immediately."
- **Warrant (W):** If a function is added by a predecessor PR and consumed
  only by code introduced in a successor PR, then at the successor PR's
  open-edit time the function is defined and callable; no symbol-not-found
  failure can occur. (Compile-time dependency = strict happens-before; PR
  sequencing satisfies it.)
- **Qualifier (Q):** Holds provided the field-scope of
  `reset_for_cancel/1` is *exactly* what `cancellation-teardown`'s
  `finish_cancel/2` requires. The solution explicitly excludes
  `tool_loop_call_lookups` from the cross-cutting scope (owned by
  `ToolDispatch.cancel_cluster/2`); both children agree.
- **Rebuttal (R):** Would fail if `cancellation-teardown` discovers at
  implementation time a field that *must* be in `reset_for_cancel/1` and
  *isn't*. The synthesis pre-commits both children to the same five-field
  list; any divergence at implementation time is a child-level revision,
  not a root-level one.
- **Backing (B):** OTP non-negotiable #2 ("extensibility seams MUST be
  behaviours") is satisfied because `Tau.Session.Cancellable` is a behaviour;
  the predecessor-substrate sequencing complies with the standard
  refactor pattern for behaviour adoption (define helper data API,
  *then* implementations of the behaviour can depend on it).

#### Falsification attempt for claim 3

- **Strategy:** Dependency check (verify the scope-list invariant the
  warrant assumes).
- **Attempt:** Compared the field list in `cross-cutting-data`'s
  `reset_for_cancel/1` against the per-turn field resets in *today's*
  cross-cutting cancel clause body (lines 1037–1083 in `session.ex`,
  inspected above). The clause body explicitly resets `active_skill`,
  `tool_iterations`, `tool_loop_state`, `provider_retry_state`,
  `steering_queue`, plus also `tool_loop_call_lookups`,
  `pending_permission_requests` (only as `%{}`), `permission_dispatch_batch`,
  `permission_pending_results`, `tools_in_flight`, `tool_dispatcher`,
  `command_task`, `coding_agent_dispatcher`, `coding_agent_pending`,
  `coding_agent_blocks`, `compaction_task`, `compaction_monitor`, plus
  `provider_task`, `cancel_flag`, `stream_ref`, `provider_span_ref`,
  `assembler`. The synthesis assigns these via `@cancel_clusters`:
  `ProviderTurn.cancel_cluster/2` owns the provider-task / stream / assembler
  fields; `ToolDispatch.cancel_cluster/2` owns the permission / tools /
  dispatcher / call-lookups fields; `Compaction.cancel_cluster/2` owns the
  compaction worker fields; `CodingAgentTurn.cancel_cluster/2` owns the
  coding-agent fields. The five fields left for
  `Data.reset_for_cancel/1` match the synthesis's stated scope.
- **Outcome:** withstood.
- **Action:** none.

### Claim 4: Each of the four PRs ends green; no PR leaves an intermediate broken state; each PR is independently revertible.

- **Claim (C):** "The four PRs are ordered so each PR's new surface is the
  next PR's substrate; no PR introduces a broken intermediate state, and
  every PR is independently revertible." (solution.md §"Recommendation"
  closing sentence + §"Migration sketch" "Each PR ends with a green
  `mix test`; no PR leaves an intermediate broken state; each PR is
  independently revertible.")
- **Grounds (G):** (i) PR 1 is purely additive on `Data` plus a callsite
  micro-fix sweep — every existing test still hits the same data shape.
  (ii) PR 2's steps 1–5 are additive; step 6 substitutes callsites; step 7
  deletes the old `@doc false` defs — if 6 lands first, callsites no
  longer reference the old name, and step 7 is safe. (iii) PR 3A is
  declared "dead but tested" — the new behaviour implementations exist
  but `session.ex` doesn't yet call them, so they can't affect runtime
  behaviour. PR 3B is the only step that mutates `session.ex` clause
  bodies; the existing cancellation integration tests are the regression
  baseline (no test changes). PR 3C only removes orphaned private helpers.
  (iv) PR 4 replaces three `handle_event` bodies with one-line delegations;
  the existing slash-routing tests cover this.
- **Warrant (W):** A PR ends green if (a) it compiles, (b) all existing
  tests pass against the new state, and (c) no new test fails. Additive-
  only steps preserve (b) by construction; substitutive steps preserve
  (b) if they update *all* callsites in the same PR. Both conditions
  are explicit in the migration sketch.
- **Qualifier (Q):** Holds for `mix test`-green and `mix compile
  --warnings-as-errors`-green; does NOT formally claim
  `mix dialyzer`-green (PR 1's accessors tighten Dialyzer information,
  but the 101-head struct-match sweep changes type-inference surface and
  could surface latent warnings). Independent revertibility holds at the
  PR-as-merge-commit level; reverting PR 1 after PR 2 has merged would
  break PR 2's callsites (this is normal sequencing; the claim is "each PR
  is *revertible* (cleanly removed)", not "any subset is revertible in any
  order").
- **Rebuttal (R):** Would fail if PR 2's step 6 misses a callsite (silent
  compile success but runtime `UndefinedFunctionError` once step 7
  deletes the def). Mitigated by `mix compile --warnings-as-errors`
  catching the undefined-call as a warning.
- **Backing (B):** Factory-loop rule `.claude/rules/factory-loop.md` §
  "Stop / escalate conditions" requires `mix compile
  --warnings-as-errors` + `mix test` post-merge — the gate that enforces
  this claim at land time. OTP non-negotiable #7 ("let it crash") does
  NOT relax test-greenness.

#### Falsification attempt for claim 4

- **Strategy:** Edge-case enumeration (intermediate-state failure modes).
- **Attempt:** Enumerated the post-merge state after PR 1, PR 2, PR 3A,
  PR 3B, PR 3C, PR 4 in turn. Looked for symbols referenced by old code
  but not yet defined / no longer defined:
  - **Post PR 1:** `session.ex` still has all eight `@doc false` defs;
    nothing references the new `Data.reset_for_cancel/1` yet (it is
    defined but unused). `mix test` green.
  - **Post PR 2:** All `@doc false` defs deleted; all callsites
    (in `session.ex` AND the seven sub-modules) updated to the new
    module-qualified names *in the same PR*. `dispatch_idle/2` is not
    yet introduced (PR 4); `session.ex`'s inline `:awaiting_user` clause
    still does its own classify-and-dispatch but now calls
    `Tau.Session.Telemetry.emit_user_message/3` (was the deleted
    `Tau.Session.emit_user_message_telemetry/3`). Cross-module callers of
    helpers (e.g. `Queue.handle_enqueue/4` at `queue.ex:97,116,128`) are
    similarly updated. `mix test` green.
  - **Post PR 3A:** Four new `cancel_cluster/2` implementations exist with
    new unit tests; `session.ex` cancel clauses are unchanged. `mix test`
    green; new tests pass.
  - **Post PR 3B:** Cancel clauses now ≤5-line folds. Existing cancellation
    integration tests + TUI cancel smoke pass (regression baseline). `mix
    test` green.
  - **Post PR 3C:** Orphan private helpers removed. `mix test` green (nothing
    references the removed helpers, by construction of "orphan").
  - **Post PR 4:** Three `handle_event` clauses become one-line delegations;
    `SlashCommand.dispatch_idle/2` and `dispatch/2` are introduced. Existing
    slash-routing tests are the regression baseline. `mix test` green.
  - One residual risk: PR 4 changes the *path* `:drain_followups` takes (via
    `handle_event` re-routing) — see `lib/tau/session.ex:661–681`. The
    re-route relies on `handle_event(:cast, {:user_message, …})` calling the
    new `SlashCommand.dispatch_idle/2`; if PR 4's clause rewrite doesn't
    preserve this entry path, the follow-up drain breaks. This is an
    integration check the implementer must perform; the synthesis does not
    explicitly call it out.
- **Outcome:** withstood, with one noted integration check (the
  `:drain_followups` re-entry path) the implementer must explicitly verify
  in PR 4. Recorded as Outstanding Doubt #1; does not warrant qualifier
  narrowing because the existing test suite (`test/tau/session/` follow-up
  drain tests) will catch a regression.
- **Action:** none beyond surfacing the integration check.

### Claim 5: After PR 4, `lib/tau/session.ex` satisfies the parent acceptance criterion in all four conjuncts: no inline teardown, no `@doc false` cross-module utility functions, no multi-branch routing bodies, no anonymous-map data init; every `handle_event/4` body is a one-line delegation or three-line FSM return; `Tau.Session.Data` exports a typed struct that all sub-modules pattern-match against.

- **Claim (C):** "After PR 4: `lib/tau/session.ex` satisfies the parent
  acceptance criterion — no inline teardown, no `@doc false` cross-module
  utility functions, no multi-branch routing bodies, no anonymous-map data
  init; every `handle_event/4` body is a one-line delegation or a three-line
  FSM return; `Tau.Session.Data` exports a typed struct that all
  sub-modules pattern-match against." (solution.md §"Migration sketch"
  closing paragraph)
- **Grounds (G):** Per-conjunct check against the migration sketch:
  (i) **No inline teardown.** PR 3B replaces both `:cancel` clause bodies
  with ≤5-line folds over `@cancel_clusters`. The four cluster modules
  own teardown; `Data.reset_for_cancel/1` owns the cross-cutting field
  reset.
  (ii) **No `@doc false` cross-module utility functions.** PR 2 deletes all
  eight `@doc false` defs.
  (iii) **No multi-branch routing bodies.** PR 4 replaces the three
  `{:user_message}` clause bodies with one-line delegations to `Queue` /
  `SlashCommand`.
  (iv) **No anonymous-map data init.** PR 1 makes the FSM data shape a
  `%Data{}` struct (the struct already exists in `data.ex` line 96; the
  101-head sweep makes every sub-module pattern-match on it; per the
  synthesis "What does not change" `Data.new/1` keeps `{:ok,
  %Tau.Session.Data{}}` shape).
- **Warrant (W):** The acceptance criterion is a conjunction of four
  syntactic conditions on `session.ex` and one structural condition on
  sub-module pattern matching. If each conjunct is established by a named
  PR and the PRs land in the stated order, the criterion holds at the
  post-PR-4 state.
- **Qualifier (Q):** Holds *modulo two exceptions* the solution itself
  flags:
  - **(a) `finish_cancel/2` placement** (Open Question #1): the synthesis
    leaves a private `finish_cancel/2` (≤10 lines) in `session.ex`. A
    strict reading of "no inline teardown" excludes any teardown logic,
    even ≤10 lines. The synthesis defers the placement question to the
    validator. *Validator ruling*: keep it in `session.ex` if the body
    is a pure fold of (`Journal.persist`, queue-drain broadcast,
    `Data.reset_for_cancel/1`) with no other side effects; relocate it
    to `Tau.Session.Cancel.Finish` only if a future revision adds
    side-effects that don't belong in the FSM entry. The current 10-line
    body satisfies "three-line FSM return" if measured per-clause (the
    fold + finish_cancel + return is the clause body, not `finish_cancel`
    itself).
  - **(b) `cascade_to_children/2` remains in `session.ex`** ("What does
    not change"). This is an ADR-0014 helper that fires before the
    cluster cancels; it is teardown-adjacent but specifically a
    parent-process responsibility (children are not linked). A strict
    reading would flag it; a charitable reading exempts it as
    supervision wiring, not teardown.
- **Rebuttal (R):** Would be falsified if (a) the synthesis intended
  `finish_cancel/2` to live outside `session.ex` and the validator
  disagreed; or (b) `cascade_to_children/2` is genuinely "teardown
  logic" and the synthesis explicitly preserves it. Both are noted but
  judged within the spirit of the criterion (parent acceptance text:
  "every `handle_event/4` clause body is a one-line delegation or a
  three-line `:gen_statem` return" — `cascade_to_children/2` is invoked
  at the *start* of the clause body, not as the body itself; if the body
  is a one-line `finish_cancel/2` call, the criterion is met).
- **Backing (B):** Parent problem.md §"Acceptance criterion". The four
  conjuncts are explicit; the validator's task is to check each conjunct
  holds at post-PR-4 state, which the synthesis itself argues for.

#### Falsification attempt for claim 5

- **Strategy:** Edge-case enumeration over the four conjuncts and the two
  noted exceptions.
- **Attempt:** Per-conjunct:
  - (i) "No inline teardown" — post-PR-3B, each `:cancel` clause body is a
    ≤5-line fold + `finish_cancel/2` call. `finish_cancel/2` itself remains
    private in `session.ex`. **Partially falsified** if "inline teardown"
    is read strictly (any teardown logic in `session.ex`); withstood if
    read as "no inline teardown *clause bodies*". The acceptance criterion
    text is "no inline teardown logic" — the strict reading wins on
    literal text. Narrow the qualifier: post-PR-4 satisfies (i) *modulo
    the ≤10-line `finish_cancel/2` private helper, which is acceptable
    by the synthesis's open-question disposition*.
  - (ii) "No `@doc false` cross-module utility functions" — withstood (all
    eight deleted in PR 2).
  - (iii) "No multi-branch routing bodies" — withstood (the three
    `{:user_message}` clauses become one-line delegations in PR 4).
  - (iv) "No anonymous-map data init" — withstood (struct exists in
    `data.ex:96`; 101-head sweep enforces struct-match downstream).
  - "Every `handle_event/4` body is a one-line delegation or a three-line
    FSM return" — withstood for the bodies the four children modify.
    Bodies the children do NOT modify (the other 36 `handle_event/4`
    clauses, e.g. `:stop`, `:terminate`, `{:tool_done}`, `:provider_event`,
    etc.) are *not in scope of this synthesis*; problem.md frames the
    work as "the four inline-body residuals", not "every clause body in
    the FSM". The criterion as written is ambiguous between "every body
    the four children touch" and "every body in the FSM"; the synthesis
    addresses the first.
- **Outcome:** partially falsified — the qualifier on conjunct (i) needs
  narrowing to acknowledge the ≤10-line `finish_cancel/2` private helper,
  and the criterion-scope is narrowed to "every body the four children
  touch", not all 41 `handle_event/4` clauses in `session.ex`.
- **Action:** Narrow Claim 5's Qualifier to: "Holds for the four
  clause-body clusters problem.md names (cancellation, helpers, routing,
  data); satisfies the literal acceptance text modulo the synthesis-
  endorsed ≤10-line `finish_cancel/2` private helper and the ADR-0014
  `cascade_to_children/2` parent responsibility, both of which the
  synthesis flags explicitly." No revision of solution.md is required —
  the synthesis itself surfaces both exceptions in Open Questions and
  "What does not change".

### Claim 6: Parent MECE holds — each child maps to a distinct cluster of `session.ex` lines with no overlap.

- **Claim (C):** "No tension surfaced between the four children that
  demands a re-decomposition; the parent's MECE claim (each child maps to a
  distinct cluster of `session.ex` lines with no overlap) holds in
  practice." (solution.md §"Selected from" / "Composition rationale"
  closing sentence)
- **Grounds (G):** Direct line-cluster inspection (per Claim 1 grounds
  (ii)):
  - `cancellation-teardown`: lines 842–961 + 963–1083.
  - `fsm-facade-helpers`: lines 1292–1432 (the eight `@doc false` defs
    and their bodies).
  - `user-message-routing`: lines 563, 572, 613 (the three `{:user_message}`
    `handle_event` clauses).
  - `cross-cutting-data`: no `session.ex` lines (sub-module struct-match
    sweep only).
  No two ranges overlap; together they exhaust the residual inline-body
  surface problem.md names.
- **Warrant (W):** Mutual exclusion of line-ranges plus collective
  exhaustion of the problem.md-named residual surfaces equals MECE in the
  decomposition. (Standard MECE = mutually exclusive AND collectively
  exhaustive.)
- **Qualifier (Q):** Mutual-exclusion holds at line-range granularity;
  collective-exhaustion holds against problem.md's residual list (the four
  clusters problem.md names), not against every line of the 1,438-LOC
  `session.ex`. Out-of-scope code (per problem.md "Out of scope") remains
  untouched.
- **Rebuttal (R):** Would fail if two children both modified the *same*
  `session.ex` line. Inspection (above) shows they do not. Cross-module
  callsite updates in PR 2 do touch lines in `session.ex` (callsite
  substitutions) but those are within the `fsm-facade-helpers` cluster
  scope, not collisions with another child.
- **Backing (B):** problem.md §"Decomposition strategy" claims the
  concern-ownership axis yields MECE; this validation verifies the claim
  empirically against the actual file ranges.

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction (find a `session.ex` line two
  children both modify).
- **Attempt:** Walked the four children's `session.ex` line scopes
  (above). The only potential overlap candidate is lines 842–1083
  (cancellation-teardown) which is fully disjoint from 1292–1432
  (fsm-facade-helpers) and 563/572/613 (user-message-routing). PR 2
  (fsm-facade-helpers) also updates *callsites* of the eight helpers — a
  callsite-substitution could fall inside (say) lines 842–1083 if a cancel
  clause body uses `append_message`. Inspection of lines 858, 904, 1037
  shows: yes, the `:awaiting_permission` cancel body calls `append_message`
  at 858 and 904, and `broadcast` at 906, 938, 1014. PR 2 will rewrite
  those callsites to `Data.append_message/2` and `Events.broadcast/2`.
  PR 3B then replaces the entire clause body. The order matters: if PR 2
  lands first, PR 3B operates on bodies whose helper calls are already
  module-qualified; PR 3B's wholesale replacement makes the qualifier
  fix moot (the body is gone). The synthesis sequences 2 → 3, so this is
  consistent.
  Conclusion: there is callsite *temporal* co-location (PR 2 touches
  lines PR 3 later replaces) but no *content* conflict. MECE on the
  *final* surfaces holds.
- **Outcome:** withstood — narrowed reading: MECE at the line-range
  granularity of the *final* delta; temporal co-location of PR 2's
  callsite sweep and PR 3B's body replacement is normal sequencing, not
  a MECE violation.
- **Action:** none.

## Cross-claim consistency

The six claims are mutually consistent:

- Claim 1 (additive composition) is the structural premise of Claims 2–6
  (sequencing, AC conjunction, MECE).
- Claim 2 and Claim 3 (the two sequencing claims) name *different*
  predecessor-successor pairs (PR 2 → PR 4, PR 1 → PR 3) and resolve to
  different APIs (`Telemetry.emit_user_message/3`, `Data.reset_for_cancel/1`).
  No conflict.
- Claim 4 (each PR ends green) and Claim 5 (post-PR-4 AC satisfaction)
  reinforce each other: greenness is the per-PR invariant; AC
  satisfaction is the cumulative target.
- Claim 6 (MECE) underwrites Claim 1's "disjoint line-clusters" sub-claim.
- The only tension surfaced is the literal-vs-charitable reading of
  acceptance conjunct (i) in Claim 5: a strict reading is partially
  falsified (the ≤10-line `finish_cancel/2` private helper persists); a
  charitable reading is satisfied. The validator's ruling (narrow the
  qualifier; do not revise) is the explicit resolution.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Additive composition, signature-disjoint on `Data` | Counter-example construction | withstood | none |
| 2 | PR 2 BEFORE PR 4 resolves the telemetry coupling | Dependency check | withstood | none |
| 3 | PR 1 BEFORE PR 3 makes `reset_for_cancel/1` available | Dependency check | withstood | none |
| 4 | Each PR ends green; intermediate states never broken | Edge-case enumeration | withstood (one integration check noted) | surface as Outstanding Doubt #1 |
| 5 | Post-PR-4 satisfies the parent AC in all four conjuncts | Edge-case enumeration over conjuncts | partially_falsified | narrow Qualifier in place; no solution revision |
| 6 | Parent MECE holds: disjoint `session.ex` line-clusters | Counter-example construction | withstood | none |

## Revision required

None. Claim 5 is partially falsified; the qualifier narrowing is applied
in place (acknowledging the ≤10-line `finish_cancel/2` private helper as
synthesis-endorsed and the ADR-0014 `cascade_to_children/2` as a
deliberately preserved exception in "What does not change"). The synthesis
itself flags both exceptions, so no revision of solution.md or problem.md
is triggered.

- **Target file:** n/a
- **Revision kind:** n/a — qualifier narrowing recorded in this
  validation; the solution stands.
- **Rationale:** The parent AC is a conjunction of four conditions; the
  synthesis satisfies the literal text of three (helpers, routing, data
  shape) and the spirit (with two explicit exceptions) of the fourth
  (teardown). The exceptions are minimal, documented, and the synthesis's
  own Open Question on `finish_cancel/2` placement leaves the final
  ruling to this validator — which rules: keep it in `session.ex` as
  a private helper at the synthesis's discretion; the clause-body
  criterion is met when measured per-clause.

## Outstanding doubts

- **Doubt 1: `:drain_followups` re-entry path.** PR 4 changes the
  `{:user_message}` clauses to one-line delegations. The follow-up drain
  at `session.ex:661–681` re-invokes `handle_event(:cast, {:user_message,
  ...})`. The implementer must verify the new delegation preserves the
  re-entry semantics (a queued `/reload` must still classify and execute
  the builtin, not start a turn). Existing test coverage in
  `test/tau/session/` for follow-up drain + slash-command interaction
  should catch a regression, but the synthesis does not call this out
  explicitly.

- **Doubt 2: `Tau.Session.Hooks.payload/3` external-name break.**
  `fsm-facade-helpers` Open Question asks whether any external tooling
  references `Tau.Session.hook_payload/3` by name. The synthesis flags
  this as a PR-2 grep task; if any extension or hook script references
  the old name, the rename breaks them silently. The PR-2 implementer
  must run the grep and add a `@deprecated` shim if any caller is found
  outside the repo. Not a falsification of the synthesis — a
  process-discipline reminder.

- **Doubt 3: Mechanism-atom semantics under the cluster fold.** The
  synthesis flags (Open Question 2) that "last non-`:noop` wins" is
  currently equivalent to "provider's mechanism" because only provider
  returns a non-`:noop` mechanism today. If a future cluster begins
  returning a meaningful mechanism, the fold's tie-breaking rule needs
  revisiting. Carried forward; no current falsification.

- **Doubt 4: Dialyzer warnings from the 101-head struct-match sweep.**
  The qualifier on Claim 4 explicitly does not claim Dialyzer-green;
  tightening type inference at 101 entry points may surface latent
  warnings (e.g. patterns that previously matched `map()` but won't
  match `%Data{}` when a field is `nil`). The PR-1 implementer should
  run `mix dialyzer` and treat any new warning as in-scope for PR 1.

```
role: validator
node: docs/problems/tau-session/problem.md
status: validated
validation_path: docs/problems/tau-session/validation.md
toulmin_complete: true
falsification_outcome: partially_falsified
claims_count: 6
revision_target: none
outstanding_doubts_count: 4
```
