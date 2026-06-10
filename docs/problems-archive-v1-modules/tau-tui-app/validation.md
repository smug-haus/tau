---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/3
revision_triggered: none
---

# Validation: Module-wide decomplecting of `Tau.TUI.App` sub-modules

## Overview

The parent solution synthesises four child solutions into one sequenced
plan. Per the synthesis brief, this validation does NOT re-litigate each
child's intra-scope claims (each child has its own validation.md with
withstood / partially_falsified outcomes already recorded). Instead the
focus is on the cross-cutting integration claims that only appear at the
parent level: the prescribed ordering of the four steps, the
independence (or otherwise) of the four children, the disjointness of
their primary surfaces, the partial-coverage admission for the
Permission concern, and whether the conjunction of the four children
satisfies the parent acceptance criterion. Six claims are enumerated
below; five withstand falsification (counter-example construction,
dependency check, integration check) and one (Claim 3 — disjoint
primary surfaces) is partially falsified, narrowing the qualifier
without triggering revision.

---

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly to counter that
variance.

---

### Claim 1: The four children compose without internal contradiction; each child's "What does not change" excludes every surface another child modifies.

- **Claim (C):** "No tension between child recommendations. Each child
  solution's 'What does not change' section explicitly excludes the
  surfaces the other children modify, and each child's 'What changes'
  list is internally consistent with every other child's exclusion
  list."
- **Grounds (G):** Cross-read of each child's What-does-not-change:
  duplicated-bounded-append `solution.md:95-96` excludes the other
  three siblings by name; model-as-bag-of-maps `solution.md:39`
  identically excludes the other three; session-side-effects-in-pure-modules
  `solution.md:104` does the same; transcript-coupling
  `solution.md:74-75` likewise. Each child's primary axis differs:
  child 1 = helper extraction, child 2 = call syntax, child 3 = return
  shape + new module, child 4 = single-function body restructure (per
  the parent's table at `solution.md:46-50`). Live codebase confirms
  the four axes touch overlapping files (`events.ex`, `input.ex`,
  `keymap.ex`) but at different concerns: child 1 adds aliases and
  removes function definitions; child 2 rewrites callsite syntax;
  child 3 changes return shapes; child 4 reshapes one function body in
  `events.ex`.
- **Warrant (W):** Two refactors compose without conflict when their
  primary write-sets touch different syntactic regions of the same
  file at different levels of granularity (module-level definition vs.
  callsite-level syntax vs. function-signature vs. function-body
  reshape). The Elixir compiler treats these as orthogonal
  transformations; any unintended interaction surfaces as a compile
  error or test failure at integration time, not as silent semantic
  drift.
- **Qualifier (Q):** Holds for the listed primary surfaces. The
  parent acknowledges Permission's view-fragment / event-logic /
  key-routing concern-mix is only partially addressed (parent
  `solution.md:84-92`, `solution.md:250-257`) — this is acknowledged
  scope, not a contradiction between siblings.
- **Rebuttal (R):** Two children edit the same file (`events.ex`) at
  lines that are syntactically adjacent or even on the same line (live
  evidence: `events.ex:253` contains both a `Map.put(:transcript, ...)`
  call — child-2 territory — and a `bounded_append_many(...)` call —
  child-1 territory — within the same expression). The children's
  scopes do not contradict each other, but the same line of code is
  modified by both children. The parent addresses this through
  sequencing (Claim 2), not through scope disjointness.
- **Backing (B):** Each child's `solution.md` What-does-not-change
  section (verbatim references above). Parent solution's composition
  rationale at `solution.md:42-92`. Live codebase grep at
  `lib/tau/tui/app/events.ex:253` confirming the adjacency.

#### Falsification attempt for claim 1

- **Strategy:** Counter-example construction — find a surface modified
  by child A that another child's What-does-not-change list either
  fails to exclude or explicitly preserves in a contradictory way.
- **Attempt:** Cross-checked each pair of children:
  - (1, 2): child 1 modifies `bounded_append/2` definition; child 2
    explicitly preserves Model's struct shape and `new/1`. No
    overlap on definitions. They do co-edit lines in `events.ex`
    (e.g. line 253), but child 2 rewrites `Map.put` syntax while
    child 1 has already changed `bounded_append` to
    `Model.bounded_append`. No contradiction in what each preserves.
  - (1, 3): child 1 touches `Events`/`Input` function definitions;
    child 3 changes `Input` public function return shapes. Child 1
    preserves bodies exactly; child 3 changes signatures and bodies.
    No contradiction in preservation lists.
  - (1, 4): child 4 reshapes only `Events.on_message_end/2`; child 1
    adds/removes `bounded_append` definitions. `on_message_end/2`
    calls `bounded_append_many` at line 253, but child 1's call-
    rewrite is done before child 4's body-reshape (per sequencing).
  - (2, 3): child 2 rewrites `Map.get/put` callsite syntax in
    `Input`; child 3 rewrites `Input` function return shapes. Co-edit
    same files at different syntactic levels.
  - (2, 4): child 2 rewrites `Map.get/put` in `Events`; child 4
    reshapes `on_message_end/2` body. After child 2, the body uses
    struct syntax; child 4 then splits it.
  - (3, 4): child 3 touches `Input`/`Keymap` return shapes; child 4
    touches `Events.on_message_end/2`. No overlap.
  No contradictory preservation claim found.
- **Outcome:** Withstood.
- **Action:** None.

---

### Claim 2: The ordering (1) → (2) → (3) → (4) is the only sequencing that avoids inter-step rework.

- **Claim (C):** "(1) → (2) → (3) → (4) is the only ordering that
  avoids inter-step rework."
- **Grounds (G):** Parent solution at `solution.md:62-76` enumerates
  the inter-step constraints: (1) before (2) because `bounded_append`
  callsites at `events.ex:69,253,284,296,390` and `input.ex:41,103,
  145,174` (verified by grep) are inside the same function bodies
  that child 2 rewrites for `Map.get/put`; (2) before (3) because
  child 3's new return-shape authoring is easier against struct-typed
  models; (2) before (4) for the same reason; (3) and (4) independent
  of each other. The adjacency is concrete: `events.ex:253` —
  `|> Map.put(:transcript, bounded_append_many(model.transcript, ...))`
  — has both child-1 and child-2 edits on one line.
- **Warrant (W):** When two edits modify the same line of code, the
  later edit must be authored against the post-image of the earlier
  edit, otherwise the second author is rewriting a line that is about
  to change shape (wasted work and merge surface). When the later edit
  is easier to author against a cleaner substrate (e.g. struct syntax
  vs. `Map.get/put`), the rework is also strictly larger if reversed.
  This is a refactoring-sequencing principle, not an absolute rule.
- **Qualifier (Q):** Holds for the four-step plan as specified.
  "Only ordering" is the strongest form of the claim and requires
  that no permutation other than (1)(2)(3)(4) [or (1)(2)(4)(3),
  since 3 and 4 are independent] avoids rework. Weaker permutations
  exist with quantifiable rework cost.
- **Rebuttal (R):** "Only" is overstated. The parent itself notes (3)
  and (4) are independent of each other (parent `solution.md:74-76`),
  so there are at least two valid orderings: (1)(2)(3)(4) and
  (1)(2)(4)(3). The parent's "(3) before (4) is preferred because
  (3)'s scope is broader and its merge risk against `main` is higher"
  is a preference, not a necessity. The Qualifier should narrow
  "only" to "the only orderings (1)(2)(3)(4) or (1)(2)(4)(3)".
- **Backing (B):** Live codebase confirmation of the adjacency at
  `events.ex:253` and the multi-line `Map.put` chain at
  `events.ex:252-257` (a chain of six `Map.put` calls, one of which
  embeds `bounded_append_many`). Each child solution's own migration
  sketch implicitly assumes the substrate state the parent's ordering
  produces.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — attempt to construct
  a non-(1)(2)(3)(4) / non-(1)(2)(4)(3) ordering that produces zero
  rework, or construct a (1)(2)(3)(4)-permutation that produces
  unbounded rework.
- **Attempt:** Considered (2) → (1): child 2 would rewrite
  `Map.put(:transcript, bounded_append_many(...))` at `events.ex:253`
  to `%{model | transcript: bounded_append_many(...)}`; child 1 then
  rewrites the inner call to `Model.bounded_append_many(...)`. This
  is one extra edit on a line already touched by child 2 — small but
  non-zero rework. Considered (3) → (2): child 3 would rewrite
  `Input.submit/1` return shape while it still uses `Map.get/put`;
  child 2 would then rewrite the same lines that child 3 just
  authored. The rework is real but bounded. Considered (4) → (2):
  child 4 splits `on_message_end/2` body while it still uses
  `Map.get/put`; child 2 then rewrites those lines inside the now-
  split handlers. Bounded rework. No permutation other than
  (1)(2)(3)(4) or (1)(2)(4)(3) avoids all rework, but the rework
  in alternative permutations is bounded and survivable. The claim's
  "only" is correct in the strict sense (avoids ALL inter-step
  rework); permutation orderings are merely more expensive, not
  impossible.
- **Outcome:** Withstood (interpreting "only" as "only zero-rework").
  Qualifier slightly narrowed: there are two zero-rework orderings
  ((1)(2)(3)(4) and (1)(2)(4)(3)), not one.
- **Action:** Narrow Qualifier in place; no revision.

---

### Claim 3: The four children's primary file boundaries are orthogonal (Model API; callsite syntax; Input/Keymap return shape; one Events function body).

- **Claim (C):** "The four steps compose without conflict because
  their primary file boundaries are orthogonal (Model API; callsite
  syntax; Input/Keymap return shape; one Events function body)."
- **Grounds (G):** Parent solution table at `solution.md:46-50`
  lists the four axes. Live codebase confirms the surfaces touched:
  child 1 touches `Model` (additions) and removes definitions from
  `Events`/`Input`; child 2 touches `Map.get/put` callsite syntax
  across six files (`events.ex`, `view.ex`, `keymap.ex`,
  `permission.ex`, `input.ex`, and audits `completion.ex`/
  `history.ex`); child 3 touches `Input` and `Keymap` function
  return shapes and creates `Cmd`; child 4 touches one function body
  inside `events.ex`.
- **Warrant (W):** Two refactors with orthogonal primary surfaces
  can be applied in either order without cross-interference at the
  primary surface, even if they secondarily touch the same files.
  Sequencing (Claim 2) handles the secondary co-touches.
- **Qualifier (Q):** Holds at the primary-axis level. Does NOT
  hold for secondary file touches (the children share `events.ex`,
  `input.ex`, and `keymap.ex` at the file level even though their
  primary axes differ). The orthogonality is conceptual, not
  file-disjoint.
- **Rebuttal (R):** Child 3's signature change to
  `Keymap.handle_event/2` has a cross-file consumer at
  `events.ex:35` (verified by grep: `Keymap.handle_event(model,
  event)` is the sole external call from `events.ex` into
  `keymap.ex`). The parent's What-changes list for child 3 mentions
  only the façade `app.ex` gaining `run_input/2`; it does NOT
  mention `events.ex:35` needing a destructure update. This is a
  real integration gap inherited from child 3's validation
  (Outstanding doubt 1 of session-side-effects-in-pure-modules
  `validation.md:376-380`). The implementer will discover it at
  compile time, but the parent solution does not call it out.
- **Backing (B):** Live grep `events.ex:35`: `Keymap.handle_event(
  model, event)`. Child 3's validation Outstanding doubt 1 names
  this gap.

#### Falsification attempt for claim 3

- **Strategy:** Integration check — verify that the parent's What-
  changes list covers every callsite affected by the children's
  signature changes.
- **Attempt:** Grepped for callers of `Keymap.handle_event/2` and
  `Input.*` public functions. `Keymap.handle_event/2` is called from
  `events.ex:35` and nowhere else (grep result). After child 3,
  `Keymap.handle_event/2` returns `{model, [Cmd.t()]}`; the caller
  at `events.ex:35` currently uses the return value as `model`
  directly. The parent's What-changes for `events.ex` (lines
  110-132) does NOT mention destructuring `Keymap.handle_event/2`'s
  return value at line 35. It only covers child 1 (`bounded_append`
  removal), child 2 (`Map.get/put` rewrites), and child 4
  (`on_message_end/2` split). The integration point at
  `events.ex:35` is unlisted. The omission is a falsifying case for
  the "primary file boundaries are orthogonal" claim — `events.ex`
  is in BOTH child 3's secondary callsite set AND child 4's primary
  axis, AND child 1's removal set, AND child 2's rewrite set. The
  parent solution's plan covers (1)(2)(4) for `events.ex` but
  omits (3)'s ripple into `events.ex:35`.
- **Outcome:** Partially falsified — primary axes are conceptually
  orthogonal, but child 3's ripple into `events.ex:35` is unlisted
  in the parent's What-changes for `events.ex`. The Qualifier must
  narrow: "primary axes are orthogonal; child 3's `Keymap.handle_
  event/2` signature change requires a one-line destructure update
  at `events.ex:35` that is not enumerated in the parent's What-
  changes list."
- **Action:** Narrow Qualifier in place. No solution revision
  required because (a) it is a compile-time error, not a silent
  regression; (b) the fix is mechanical (destructure `{model,
  cmds}` and dispatch via `Cmd.execute/1`); (c) the implementer
  brief should explicitly name `events.ex:35` as in-scope for
  child 3 to prevent the omission persisting into implementation.

---

### Claim 4: Each step preserves observable behaviour at the `Tau.TUI.App` public interface, so each PR is independently revertible and gateable.

- **Claim (C):** "Each PR is independently revertible because each
  preserves observable behaviour." (parent `solution.md:213-214`,
  `solution.md:243-246`).
- **Grounds (G):** Each child's validation confirms preservation:
  duplicated-bounded-append `validation.md:201-232` (Claim 5 —
  function bodies preserved exactly, withstood); model-as-bag-of-
  maps `validation.md:271-307` (Claim 7 — Model fields, Cost,
  StatusBar unchanged, withstood); session-side-effects-in-pure-
  modules `validation.md:270-330` (Claim 5 — Model.t() fields,
  Tau.* API, siblings unaffected, withstood); transcript-coupling
  `validation.md:298-341` (Claims 5 and 6 — public APIs and D-168/
  D-169 telemetry schema preserved, both withstood).
- **Warrant (W):** A refactor that preserves observable behaviour
  at every public callsite is by definition revertible — the post-
  refactor state and pre-refactor state are observationally
  equivalent, so reverting any PR returns to a known-good state
  from the perspective of external callers. Each PR being
  observationally equivalent at the public boundary also means
  each PR can be gated independently against the existing
  integration test suite.
- **Qualifier (Q):** Holds when "observable behaviour" is scoped
  to the `Tau.TUI.App` public interface. Internal observability
  (e.g. private helper invocation patterns visible in process
  traces) is not preserved — child 1 changes the module that owns
  `bounded_append`, child 3 changes return shapes of `Input`/
  `Keymap` private callers. These are not part of the public
  interface but are observable to a code reader.
- **Rebuttal (R):** Child 3's narrowed Qualifier (validation Claim
  4) notes that `Store.append/3` remains inside `Input.submit/1`;
  a test that wants pure functional testing requires either a temp
  dir or a Store stub. This is a residual side effect that pre-
  exists the refactor, not a regression — but the parent's claim
  that "all four child changes preserve observable behaviour at
  the `Tau.TUI.App` public interface" depends on `Store.append/3`
  behaviour being unchanged, which the child's validation confirms.
- **Backing (B):** Each child's validation Toulmin entries (cited
  above). Live evidence: no child modifies `Tau.TUI.App`'s public
  callbacks (Ratatouille `update/2`, `render/1`, `subscribe/1`);
  the façade gains only one private helper (`run_input/2`).

#### Falsification attempt for claim 4

- **Strategy:** Dependency check — verify no child silently
  changes a public callback or a documented telemetry schema.
- **Attempt:** Checked each child's What-changes against the
  parent's What-does-not-change list (parent `solution.md:189-209`):
  Ratatouille callbacks unchanged (no child modifies `update/2`
  or `render/1`); telemetry schema `[:tau, :tui, :status, :update]`
  preserved (child 4 explicitly preserves D-168/D-169 — confirmed
  in its validation Claim 6); `Cost.for_session/1` and the
  `try/rescue` site unchanged (child 4 explicit); `Tau.*` /
  `Tau.Session.*` API surface unchanged (child 3 explicit);
  `Model.t()` struct shape unchanged (children 1 and 2 explicit).
  No counter-case found. Independence of PRs requires that PR1
  not depend on PR2's state; verified — PR1 (child 1) only adds
  to `Model` and rewrites callsites in `Events`/`Input` to use
  the new Model function; it does not depend on any later step's
  output.
- **Outcome:** Withstood.
- **Action:** None.

---

### Claim 5: The conjunction of the four children advances the acceptance criterion to the extent claimed (each sub-problem solvable to a concrete proposal; module-wide decomplecting achieved at the listed axes).

- **Claim (C):** The parent acceptance criterion is "each sub-problem
  is described at sufficient resolution that a proposer can produce
  a concrete, independently-evaluable refactoring proposal without
  needing to re-read sibling sub-problems" (problem `:90-93`). The
  parent solution claims to advance this by delivering four concrete
  proposals, each solving its named axis, sequenced into one coherent
  plan.
- **Grounds (G):** Four child `solution.md` files exist
  (`subproblems/*/solution.md`); each has a validated `validation.md`
  with falsification outcomes (3 partially_falsified, 1 partially_
  falsified — none falsified outright; all withstood under narrowed
  qualifiers). Each child names a concrete artefact: child 1 — three
  function definitions moved; child 2 — callsite syntax across six
  files plus one accessor; child 3 — new `Cmd` module + return shape
  change; child 4 — one function split into three. The parent's
  composition table at `solution.md:46-50` shows orthogonal primary
  axes.
- **Warrant (W):** The acceptance criterion is about *description
  resolution*, not implementation completeness. Four independently
  evaluable proposals, each producing a concrete What-changes list
  with file:line citations, satisfies "sufficient resolution that a
  proposer can produce a concrete, independently-evaluable refactoring
  proposal". Conjunction of four concrete proposals is itself a
  concrete plan.
- **Qualifier (Q):** Holds for the four children listed in the parent
  solution. Does NOT hold for the Permission concern named in
  problem.md but substituted-out by the decomposer. Parent solution
  acknowledges this at `solution.md:84-92`: "the decomposer produced
  four sub-problems but substituted `transcript-coupling` for the
  listed `permission-module-concern-mix`. … The Permission concern-
  mix is therefore *partially* addressed by this synthesis."
- **Rebuttal (R):** A strict reading of `problem.md`'s acceptance
  criterion against the listed four sub-problems (problem `:76-87`
  enumerates `duplicated-bounded-append`, `model-as-bag-of-maps`,
  `session-side-effects-in-pure-modules`, `transcript-coupling`)
  matches the four children synthesised. But `problem.md`'s
  Complecting hypothesis (point 3, `:53-56`) and Decomposition
  strategy (`:65-67`) both name the Permission module's concern-mix
  as one of the four inherited concerns. The decomposer's
  substitution is acknowledged but not justified. A reviewer could
  fairly argue that the acceptance criterion is met *for the four
  enumerated sub-problems* but not *for the four inherited concerns
  in the hypothesis*. The parent's open question 1 routes this to a
  follow-up sub-problem rather than blocking.
- **Backing (B):** Each child's `validation.md` (cited above).
  `problem.md` acceptance criterion at lines 90-93. Parent
  acknowledgement at `solution.md:84-92` and Open question 1 at
  `solution.md:250-257`.

#### Falsification attempt for claim 5

- **Strategy:** Dependency check — verify that each child's
  solution.md is concrete enough that an implementer could begin
  work without re-reading sibling problems.
- **Attempt:** Each child's solution.md has a What-changes section
  with explicit `file:line` references (verified in all four).
  Each has a Migration sketch with step-by-step ordering. Each has
  Open questions section flagging implementer risks. The
  acceptance criterion does not require the four children to
  cover the original four inherited concerns; it requires they be
  described at sufficient resolution. The substituted child
  (transcript-coupling) is itself well-resolved. The strict-reading
  rebuttal above is a scope question, not a resolution-quality
  question.
- **Outcome:** Withstood for the four enumerated sub-problems.
  Partially open for the substituted-out Permission concern, but
  the parent explicitly defers it ("a follow-up sub-problem
  should decompose `Permission`…") and the acceptance criterion as
  written ("each sub-problem" — i.e. those enumerated) is met.
- **Action:** None. The deferral is documented; the implementer
  brief should preserve the Open Questions section so the
  follow-up surfaces in the next planning cycle.

---

### Claim 6: The plan satisfies OTP non-negotiables (no new GenServer-wrapped stateless logic; no `try/rescue` across process boundaries introduced; supervised processes for stateful subsystems).

- **Claim (C):** Implicit across the parent solution and inherited
  from each child's preservation list — the refactor does not
  introduce OTP non-negotiable violations. The one residual concern
  (parent open question 3, `solution.md:262-265`) is the `spawn/1`
  in `Cmd.execute/1` for `:stop_tui_supervisor`.
- **Grounds (G):** Parent's What-does-not-change (`solution.md:189-
  209`) preserves the `try/rescue` in `cost_for_session/1`
  (the only `try/rescue` site, per child 4 validation Claim 4 —
  confirmed by grep at `events.ex:262-269`). No new GenServer is
  introduced (parent solution adds one new module, `Cmd`, which is
  a pure dispatch helper with no state). The `spawn/1` for
  `:stop_tui_supervisor` is lifted from inline (`keymap.ex:288`)
  into one named location (`do_stop_tui_supervisor/0`) called only
  from `Cmd.execute/1`.
- **Warrant (W):** OTP non-negotiable #3 forbids wrapping stateless
  logic in a GenServer. `Cmd` is pure; it has no state. OTP non-
  negotiable #7 ("let it crash; supervise; restart") forbids
  `try/rescue` across process boundaries; the preserved
  `try/rescue` in `cost_for_session/1` is in-process (catches
  `ArgumentError` from local ETS access), not cross-process. OTP
  non-negotiable #1 requires stateful subsystems under supervisors;
  the `:stop_tui_supervisor` spawn is fire-and-forget shutdown of
  an existing supervised subsystem, not new state.
- **Qualifier (Q):** Holds as specified. The `spawn/1` in
  `Cmd.execute/1` is a known residual (open question 3); the
  parent solution requires the implementation PR to document the
  justification at the call site.
- **Rebuttal (R):** Child 3's validation Outstanding doubt 2
  raises the same concern. If a reviewer reads OTP non-negotiable
  #1 strictly ("Every stateful subsystem MUST run as supervised
  processes"), an unsupervised `spawn/1` for any purpose is
  borderline. The justification (fire-and-forget shutdown, must
  be async to avoid blocking the TUI event loop) is valid but
  must be explicit.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` (rules
  1, 3, 7). Child 4 validation Claim 4 (try/rescue site
  preserved). Child 3 validation Outstanding doubt 2 (spawn
  justification required).

#### Falsification attempt for claim 6

- **Strategy:** Dependency check — verify that no child introduces
  a new GenServer wrapping stateless logic, and that the
  preserved `try/rescue` is genuinely in-process.
- **Attempt:** Parent's "New files" list (`solution.md:98-102`)
  introduces only `Tau.TUI.App.Cmd` — a pure dispatch module with
  `Cmd.t()` tagged union and `execute/1`. No `use GenServer`, no
  `start_link`, no `init/1`. The preserved `try/rescue` at
  `events.ex:262-269` catches `ArgumentError` from local
  `Tau.Cost.for_session/1` — an ETS read in the same process, not
  across a process boundary. The `spawn/1` for
  `:stop_tui_supervisor` is the one borderline case, but it is
  shutdown-of-supervisor logic, not new stateful work. No
  falsifying case found.
- **Outcome:** Withstood, with the documented residual that the
  implementation PR must include the `spawn/1` justification
  comment per the open question.
- **Action:** None. Open question 3 in the parent solution
  already captures the residual.

---

## Cross-claim consistency

Claims 1-6 are internally consistent. Claims 1 (independent
preservation lists) and 3 (orthogonal primary axes) are
mutually reinforcing; Claim 3's partial falsification (the
`events.ex:35` ripple) tightens but does not undermine Claim 1.
Claim 2 (sequencing) is the operational consequence of Claims 1
and 3 — orthogonal axes that nonetheless co-touch files require
sequencing to avoid rework. Claim 4 (revertibility) depends on
Claims 1-3 holding; with their narrowed qualifiers, Claim 4
holds at the public-interface level. Claim 5 (acceptance
criterion satisfaction) is acknowledged-partial for the
Permission concern but withstood for the four enumerated
sub-problems; the parent's deferral is a scope choice, not a
contradiction. Claim 6 (OTP compliance) is orthogonal to the
others and withstands.

One area where the children's narrowed qualifiers propagate up:
child 3's `Store.append/3` residual (its validation Claim 4
partial falsification) and child 4's `@spec` documentary-vs-
compiler-structural narrowing (its validation Claim 3 partial
falsification) both surface in the parent's Open Questions
section but are NOT lifted into the parent's claim Qualifiers
above. They are noted as Outstanding doubts below for the
implementer brief.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Children's preservation lists do not contradict | Counter-example construction | Withstood | None |
| 2 | (1)(2)(3)(4) ordering avoids inter-step rework | Counter-example construction | Withstood (Q narrowed: also (1)(2)(4)(3)) | Narrow Q in place |
| 3 | Primary file boundaries are orthogonal | Integration check | Partially falsified — `events.ex:35` ripple unlisted | Narrow Q in place; brief implementer to include `events.ex:35` in child 3 scope |
| 4 | Each PR preserves observable behaviour, independently revertible | Dependency check | Withstood | None |
| 5 | Conjunction satisfies acceptance criterion for the four enumerated sub-problems | Dependency check | Withstood (Permission concern explicitly deferred) | Follow-up sub-problem for Permission |
| 6 | No OTP non-negotiable violation introduced | Dependency check | Withstood (residual spawn justification required) | Implementer PR comments justify `spawn/1` in `Cmd.execute/1` |

---

## Revision required

No revision triggered. Claims 2 and 3 are partially falsified;
both narrowed via Qualifier in place. The narrowed forms remain
faithful to the parent solution's intent and do not require
edits to either `solution.md` or `problem.md`.

The Claim 3 narrowing has an actionable implementer-brief
consequence: the implementer brief for PR3 (child 3) must
explicitly list `lib/tau/tui/app/events.ex:35` as a callsite
requiring a destructure update for `Keymap.handle_event/2`'s
new return shape. Without this, the implementer will discover
it as a compile error and may handle it ad hoc.

---

## Outstanding doubts

1. **`events.ex:35` destructure (Claim 3 fallout).** Parent
   What-changes for `events.ex` omits the line-35 destructure
   update required by child 3's signature change to
   `Keymap.handle_event/2`. Mechanical fix at compile time, but
   the implementer brief should pre-name it.

2. **Permission concern-mix deferral (Claim 5 acknowledged
   gap).** Parent solution defers the `Permission` view-
   fragment / event-logic / key-routing concern named in
   problem.md to a follow-up sub-problem. The follow-up must
   actually be filed; otherwise the original four-concern
   problem statement is silently reduced to three concerns
   addressed plus one shelved.

3. **`Store.append/3` in `Input.submit/1` (child 3 validation
   Claim 4 partial falsification).** Disk I/O remains inline
   in `Input.submit/1` after the command-pattern refactor. The
   parent's open question 2 confirms this is deferred. Tests of
   `submit/1` require either a temp dir or a Store stub.

4. **`@spec` is documentary, not compiler-structural (child 4
   validation Claim 3 partial falsification).** The two new
   `Events` handlers' field-ownership is enforced by code
   review against `@spec` annotations, not by the type system.
   A future author can re-couple them silently. Parent solution
   open question (`solution.md:276-278`) acknowledges this.

5. **Test fixture risk (child 2 validation Outstanding doubt 2).**
   `app_test.exs:22-39` constructs a bare-map fixture missing
   several mandatory fields; after the struct-access conversion
   in PR2, this fixture will raise `BadMapError`. The fixture
   must be converted to `Model.new/1` or a `%Model{...}`
   literal as part of PR2.

6. **`spawn/1` in `Cmd.execute/1` for `:stop_tui_supervisor`
   (Claim 6 residual, child 3 validation Outstanding doubt 2).**
   Implementation PR must document the justification (fire-and-
   forget shutdown, must be async to avoid blocking the TUI
   event loop) at the call site, with reference to OTP non-
   negotiable #1.

7. **`Keymap` private call chain cascade (child 3 validation
   Outstanding doubt 3).** Child 3's `{model, cmds}` propagation
   requires changing `handle_event_normal/2`, `handle_char/2`
   (and possibly `handle_key/3`, `handle_readline_key`) return
   types from `map()` to `{map(), [Cmd.t()]}`. The parent's
   migration sketch step 3 mentions "propagate through
   `handle/2`" but does not enumerate the private chain. The
   implementer brief for PR3 should include a grep-trace of
   `keymap.ex` private call graph.
