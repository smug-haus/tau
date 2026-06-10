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

# Validation: tau-infrastructure cross-cutting correctness — four-PR sequenced fix

## Overview

The root solution makes one composite recommendation (land four child PRs
serially in the order #1 telemetry → #2 circuit breaker → #3 supervision
startup → #4 global names) and packages five cross-cutting claims that the
non-leaf synthesis must defend in addition to per-child claims (which are
validated at the child nodes). This validation extracts six checkable
propositions from the root `solution.md` Recommendation and Composition
rationale, focusing on: (a) the conjunction's coverage of the parent
acceptance criterion, (b) the disjoint-region claim for `Application.start/2`
between PRs 3 and 4, (c) the conjecture that no PR introduces sibling-boundary
defects, (d) the additive-overlap claim for `Store`/`Tracker` between PRs 2/1
and PR 4, (e) the ordering claim ("lowest blast radius first"), and (f) the
sibling-independence claim ("no PR has a prerequisite from a sibling beyond
ordering"). Falsification strategies are mixed: integration check, dependency
check, edge-case enumeration, and counter-example construction. Five claims
withstood; one (Claim 3, ordering rationale) is partially falsified — the
qualifier needs narrowing because "lowest blast radius first" is post-hoc
rather than load-bearing on correctness, but the narrowed claim survives.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly to counter that variance.

### Claim 1: The four child PRs together resolve all four sub-problems and therefore satisfy the parent acceptance criterion

- **Claim (C):** "The combined effect restores four invariants in
  `Tau.Application` and its cross-cutting subsystems — asymmetric crash-safety
  in cost telemetry handlers, post-/pre-increment coupling between
  `CircuitBreaker.Store` and the façade, unmonitored CLI task and dual OTel
  enable-disable policy in `start/2`, and hard-coded global atom names blocking
  multi-instance deployment — without introducing new defects at sibling
  boundaries." (root solution.md, Recommendation, lines 23-32).
- **Grounds (G):** The parent problem.md (lines 78-89) lists exactly four
  sub-problems by short-name: `supervision-tree-startup`,
  `telemetry-handler-coupling`, `circuit-breaker-invariant-split`,
  `global-name-collision`. The root solution's `synthesised_from` frontmatter
  (lines 6-10) names exactly four child solution paths matching these four
  short-names. The "What changes" section (lines 99-176) enumerates one PR per
  child, each addressing one sub-problem. Cross-checked: every concrete defect
  cited in problem.md's Context section (lines 25-46) — `cost/tracker.ex:118`
  rescue gap, `telemetry/supervisor.ex:17-22` strategy, `circuit_breaker.ex:124`
  `new_count - 1` adjustment, `state.ex:64` `@default_cooldown_ms`,
  `application.ex:113` dual OTel policy, `application.ex:185` unmonitored Task,
  `application.ex:68` `Tau.PubSub` hard-coded — appears in exactly one PR's
  change list.
- **Warrant (W):** The parent acceptance criterion (problem.md line 93-95)
  reads "All four sub-problems are resolved: each has a validated proposal
  that names the change, the affected file(s) and line(s), and the invariant
  it restores." This is a **conjunction**: `P1 ∧ P2 ∧ P3 ∧ P4`. By Hickey's
  decomposition discipline (MECE along the concern axis, problem.md lines
  64-75), a partition has no overlap and no gap; resolving each part
  independently resolves the whole. The conjunction is satisfied iff every
  conjunct is satisfied and the conjuncts cover the original problem.
- **Qualifier (Q):** Holds **only if** each child sub-problem's solution is
  itself validated. Child validation lives in
  `subproblems/<name>/validation.md` — the root validator cannot re-validate
  child solutions, only their composition. Also requires that the partition
  in problem.md §Decomposition strategy is genuinely MECE (no concern
  straddles a boundary); root validator inherits this from the decomposer's
  output without re-deriving it.
- **Rebuttal (R):** If a defect listed in problem.md's Context section is NOT
  addressed by any of the four child PRs, the conjunction fails to cover the
  acceptance criterion. Concretely, the "without introducing new defects at
  sibling boundaries" sub-clause is the load-bearing risk — addressed
  separately in Claim 2 (the disjoint-region claim) and Claim 5 (the additive-
  overlap claim).
- **Backing (B):** Hickey, "Simple Made Easy" (2011) — concerns that are
  woven together must be teased apart on the concern axis, not on the
  artefact axis, to avoid hidden coupling. Tau's `.claude/rules/spec-before-
  code.md` and OTP non-negotiable #2 (extensibility seams as behaviours)
  codify the same discipline for this codebase.

#### Falsification attempt for claim 1

- **Strategy:** Edge-case enumeration over the defect inventory in
  problem.md's Context section + dependency check that each child PR's change
  list addresses the cited file/line.
- **Attempt:** Walked each of the eight concrete defect citations in
  problem.md (lines 27-46) and traced them to a specific PR change in the
  root solution's "What changes" section (lines 99-176):
  - `lib/tau/cost/tracker.ex:118-138` rescue gap → PR 1 first bullet (line
    105) ✓
  - `lib/tau/telemetry/supervisor.ex:17-22` `:one_for_one` → PR 1 second
    bullet (line 109) ✓
  - `lib/tau/circuit_breaker.ex:124-145` `new_count - 1` → PR 2 second
    bullet (line 121) ✓
  - `lib/tau/circuit_breaker/state.ex:64` `@default_cooldown_ms` →
    PR 2 third bullet (line 124) ✓
  - `lib/tau/application.ex:185` unmonitored Task → PR 3 first/third bullets
    (lines 137, 142-144) ✓
  - `lib/tau/application.ex:113` dual OTel policy → PR 3 second bullet (line
    140) ✓
  - `lib/tau/application.ex:68` hard-coded `Tau.PubSub` → PR 4 second/sixth
    bullets (lines 158, 172) ✓
  - Other hard-coded names (`Tau.Providers.Finch`,
    `Tau.CircuitBreaker.Store`, `Tau.Sessions.Supervisor`) → PR 4 sweep
    bullet (lines 172-173) ✓
  Independently verified all citations are real via grep of the live tree:
  `Tau.Providers.Finch` appears in `application.ex:78`, `mcp/transport/http.ex:28`,
  `providers/copilot/auth.ex:132`, `providers/shared/finch_stream.ex:76`,
  `mcp/transport/sse.ex:36/66` — consistent with the "~30 call sites"
  estimate in PR 4. `Tau.PubSub` appears in `permissions/rule_set.ex:32`,
  `settings/cache.ex:50`, `tui/event_bridge.ex:60`, `session.ex:178`/`1367`,
  `commands/builtin/export.ex:71`, `tools/builtin/agent.ex` (5 sites),
  `session/slash_command.ex:361`, `providers/rate_limiter*.ex` (2 sites),
  `cli.ex:315` — same.
- **Outcome:** Withstood. Every defect in the parent's Context list maps to
  exactly one child PR. No defect is orphaned; no defect is double-assigned.
- **Action:** None.

### Claim 2: PRs 3 and 4 touch `Application.start/2` at disjoint regions and rebase cleanly

- **Claim (C):** "These overlap in the same function; ordering #3 before #4
  means the `spawn_monitor` + `receive` block and the `OtelReporter`
  unconditional entry are present in `start/2` when #4 then adds the
  `Tau.Names.compute/1` / `:persistent_term.put/2` lines and rewrites the
  child specs to thread `names.*` fields. The two patches touch the same
  function but at clearly separable points (CLI dispatch block and OtelReporter
  spec list vs name resolution and child opts) — a textbook rebase-rather-
  than-conflict situation." (root solution.md, Composition rationale, lines
  68-77).
- **Grounds (G):** Live `lib/tau/application.ex` (read at validation time):
  - PR 3's regions: `maybe_dispatch_cli/0` body at lines 179-195;
    `otel_reporter_spec/0` definition at lines 113-119 and its child-spec
    invocation at line 67; the `opts = [...]` line at 93; the `{:ok, pid}`
    branch at lines 96-103.
  - PR 4's regions: the `children = List.flatten([...])` list at lines 60-91
    (each child-spec entry needs `names.*` threading); a new `start/2` head
    block that reads `instance_id`, calls `Tau.Names.compute/1`, and writes
    `:persistent_term`. The natural placement is before `children =`, i.e.
    before line 60.
  - Overlap analysis: PR 3 deletes line 67 (`otel_reporter_spec()`),
    replacing it with literal `Tau.OtelReporter`; deletes the function
    bodies at 113-119 and 179-195; rewrites the `opts` keyword at 93; inserts
    a `spawn_monitor` block on the success branch at 96-103. PR 4 inserts
    new code at the head of `start/2` (before line 60) and modifies entries
    inside the `children = [...]` list (lines 60-91) to add `name:`/`names.*`
    opts. The literal line ranges PR 3 modifies (67, 93, 96-103, 113-119,
    179-195) and the line ranges PR 4 modifies (head of `start/2`, body of
    `children` list entries) intersect ONLY at "inside `start/2` body" —
    not at any common line.
- **Warrant (W):** Git's three-way merge resolves edits that touch disjoint
  hunks of the same file without conflict (rebase succeeds). For a single
  function, disjoint *line ranges* is the operative criterion — two patches
  to different statements of the same `def` body do not conflict.
- **Qualifier (Q):** Holds **provided** PR 4's `Tau.Names.compute/1` call is
  placed at the head of `start/2`, before the child list is constructed.
  Solution's "Open questions" section (lines 236-245) explicitly flags this
  ordering ambiguity and identifies the recovery: "moving the
  `Tau.Names.compute/1` + `:persistent_term.put/2` call to the very start of
  `start/2`, before any child spec list is constructed." Also holds only if
  PR 4's child-spec rewrites in `children = [...]` (which restructure entries
  like `{Phoenix.PubSub, name: Tau.PubSub}` into name-threaded forms) do not
  collide with PR 3's deletion of `otel_reporter_spec()` from that same list
  — they do not, because PR 3 *substitutes* the literal `Tau.OtelReporter`
  for the function call at the same list position, and PR 4 then *modifies*
  that entry by adding the `names.*` opt (additive).
- **Rebuttal (R):** If PR 3's `spawn_monitor` block in the `{:ok, pid}`
  branch (lines 96-103) ends up needing access to `Tau.Names.get()` (e.g.
  because the CLI dispatch path reads a name), the ordering inverts: PR 4
  must land first, OR the implementer must shift the
  `:persistent_term.put/2` to before the `Supervisor.start_link` call.
  Solution's open question 1 (lines 236-243) names exactly this risk and
  marks it as PR-4-implementation-time work.
- **Backing (B):** Git documentation: `git-merge-file(1)` resolves
  disjoint-hunk edits without operator intervention; conflict requires
  overlapping line ranges. Tau's `.claude/rules/factory-loop.md` "Parallel
  execution" §"The conflict check" clause 3 ("disjoint codepoints") permits
  same-function edits at "clearly separate, stable regions" — exactly the
  configuration here.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — try to construct a concrete
  ordering of edits that produces a git conflict given the live file state.
- **Attempt:** Simulated PR 3 first against current `application.ex`:
  - delete `otel_reporter_spec()` from line 67, replace with
    `Tau.OtelReporter` ⇒ line 67 mutates.
  - rewrite `opts` at line 93 ⇒ line 93 mutates.
  - insert `spawn_monitor` block between current lines 96-103 ⇒ lines
    96-103 mutate / expand.
  - delete `otel_reporter_spec/0` at lines 113-119 ⇒ block removed.
  - delete `maybe_dispatch_cli/0` and its call site at line 101, body at
    179-195 ⇒ block removed.
  Then simulated PR 4 layered on top: inserts ~3-5 lines at the head of
  `start/2` (before the current line-60 `children =`), and modifies each
  `children` list entry to add a `names.*` opt. The line-60 head is BEFORE
  every line PR 3 touched (67, 93, post-93 success branch, 113+, 179+).
  The `children` entries PR 4 modifies are each one-line additions of a
  keyword (`{Phoenix.PubSub, name: ...}` already has `name:`; PR 4 adds
  `name: Tau.Names.get().pubsub` or similar). These are intra-list-element
  edits — PR 3's deletion of `otel_reporter_spec()` and its replacement
  with `Tau.OtelReporter` leaves a list slot PR 4 must then thread an opt
  into. The slot replacement happens at the SAME line PR 3 produced (so
  PR 4 reads PR-3-state, not original state). No physical line conflict
  could be constructed.
  Counter-attempted by attempting to construct a name-resolution-ordering
  hazard: could PR 3's `spawn_monitor` body read `Tau.Names.get()` and
  thereby need the `:persistent_term` write to land BEFORE
  `Supervisor.start_link`? In the current PR 3 design, the spawn_monitor
  body calls `Tau.CLI.main(argv)`, which under PR 4 would resolve names
  via `Tau.Names.get()` at call time. PR 4 places its
  `:persistent_term.put/2` at the head of `start/2`, which is BEFORE
  `Supervisor.start_link` and therefore BEFORE the `{:ok, pid}` branch
  spawn_monitor — so the read sees the write. No name-resolution hazard.
- **Outcome:** Withstood. No conflict can be constructed under the open-
  question-1 placement (which is the prescribed placement).
- **Action:** None for this validator; the open question is correctly held
  open in the root solution for PR-4 implementation time.

### Claim 3: The chosen ordering (#1 → #2 → #3 → #4) minimises blast radius by putting the smallest patches first

- **Claim (C):** "ordering is chosen to put the smallest, lowest-blast-radius
  patches first and the broadest call-site sweep last." (root solution.md,
  Recommendation, lines 21-23).
- **Grounds (G):** Counting changed files / sweep scope from "What changes":
  PR 1 = 2 files + 1 test (rescue + supervisor strategy);
  PR 2 = 4 files + SPEC amendment (counter convention + cooldown opt + façade
  simplification + spec text);
  PR 3 = 1 file (`application.ex` body rewrite);
  PR 4 = 1 new file + 4 edited files + ~30 call-site sweep + 1 regression
  property test.
  Numerically the ordering is `2 < 4 ≤ 1 < 5` files-only, but if "blast
  radius" includes call-site sweep, PR 4's `~30 call sites` strictly
  dominates PRs 1-3 each.
- **Warrant (W):** Smaller patches are easier to gate (per Tau's
  `factory-loop.md` "Gateability ceiling": "MUST stay reviewable by `critic`
  and `reviewer` in a single pass"). The factory loop's per-PR gate is
  stateless, so cumulative blast risk grows with the size of each individual
  PR rather than with cumulative size — early-and-small reduces the
  probability of a gate failure in the high-friction PR (#4) holding up
  earlier wins.
- **Qualifier (Q):** "Smallest first" is true for PR 1 (2 files) vs PR 4
  (~35 files counting the sweep) but **NOT strictly true for the middle**:
  PR 2 (4 files + SPEC) is broader than PR 3 (1 file). The ordering claim
  is therefore not "monotonically increasing blast radius" but "PR 4 last,
  others arranged for conflict-minimisation." Narrow the qualifier
  accordingly.
- **Rebuttal (R):** Solution itself supplies a *different* ordering
  rationale earlier in the same Migration sketch (lines 200-204): "Land the
  four PRs serially in the order above. Each PR is small enough to gate
  independently … none has a prerequisite from a sibling beyond the ordering
  chosen here for conflict-minimisation." This second rationale is
  *conflict-minimisation*, not blast-radius — and is the load-bearing one
  (PR 3 must precede PR 4 to give PR 4 a base to rebase on; PRs 1 and 2
  could in principle merge in any order). The "lowest blast radius first"
  framing in the Recommendation is post-hoc colour, not a correctness
  constraint.
- **Backing (B):** Tau `factory-loop.md` "PR scope guards" + "Gateability
  ceiling" + "Conflict check" clauses. None of these axiomatise "smallest
  first"; they axiomatise "small enough to gate" and "no merge conflicts."

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction — find an ordering that
  contradicts "smallest first" while still satisfying the load-bearing
  constraints.
- **Attempt:** Consider ordering `#3 → #1 → #2 → #4`. PR 3 (1 file) is
  smaller than PR 1 (2 files + 1 test) on the file count. PR 3 has no
  sibling prerequisite. PR 4 still lands last. This ordering also satisfies
  the conflict-minimisation invariant (only same-function overlap is
  3 ∩ 4, and PR 4 still lands after PR 3). Yet the solution chose `#1 → #2
  → #3 → #4`. Therefore "smallest first" is NOT the operative criterion;
  conflict-minimisation + PR 4 last is.
- **Outcome:** Partially falsified. The literal text "smallest first" does
  not hold; "PR 4 last + conflict-minimisation between the others" does.
- **Action:** Narrow the qualifier in place — the ordering is correct on the
  load-bearing criterion (conflict-minimisation); the "smallest first"
  framing is descriptive colour, not a constraint. No solution.md revision
  required (the Migration sketch already states the correct rationale; only
  the Recommendation paragraph's gloss is loose). Logged as an outstanding
  doubt for the parent's parent validator to consider — the gloss could
  mislead a future implementer into reordering on a "smaller first" basis
  and breaking the actual constraint.

### Claim 4: No PR has a prerequisite from a sibling beyond the chosen ordering

- **Claim (C):** "none has a prerequisite from a sibling beyond the ordering
  chosen here for conflict-minimisation." (root solution.md, Migration
  sketch, lines 203-204).
- **Grounds (G):** Cross-referencing each PR's "What changes" against the
  others:
  - PR 1 modifies `cost/tracker.ex` (rescue) and
    `telemetry/supervisor.ex` (strategy). Neither file is touched by PR 2
    or PR 3. PR 4 modifies `cost/tracker.ex` but only to add a `name:` opt
    to `start_link/1` — additive on top of PR 1's rescue.
  - PR 2 modifies `circuit_breaker.ex`, `circuit_breaker/store.ex`,
    `circuit_breaker/state.ex`, and `SPEC-CIRCUIT-BREAKER.md`. PR 4
    modifies `circuit_breaker/store.ex` only in `start_link/1` / `init/1`
    (accepting `name:`/`table:` opts) — solution explicitly states (lines
    62-65) the regions are different from PR 2's `bump_*/1` edits and
    `do_transition/3` is untouched.
  - PR 3 modifies `application.ex` only. PR 4 also modifies
    `application.ex` — see Claim 2.
  - PR 4 modifies one new file + 4 edited files + ~30 call-site sweep.
- **Warrant (W):** Tau `factory-loop.md` "Conflict check" clause 2 (disjoint
  files) and clause 3 (disjoint codepoints): two PRs may safely merge in
  serial order if their file/codepoint sets are disjoint or additive at
  separate functions. No PR pair here violates this when serialized as
  prescribed.
- **Qualifier (Q):** Holds under the prescribed merge order (1 → 2 → 3 → 4).
  Holds **only if** PR 1's `Cost.Tracker` rescue block survives PR 4's
  additive `name:` opt edit (which it does, per solution lines 81-83:
  "preserves PR 1's rescue block verbatim") and PR 2's `Store.bump_*/1`
  pre-increment semantics survive PR 4's additive `name:`/`table:` opt
  edit (which they do, per solution lines 79-81: "preserves PR 2's
  pre-increment semantics"). These are unverifiable until each PR's diff
  exists; the validator can only check that the solution's claim is
  internally consistent.
- **Rebuttal (R):** If a future PR (outside this module's scope) lands
  between two of these four PRs and modifies one of the overlap surfaces
  (e.g. another change to `circuit_breaker/store.ex` `start_link/1`
  signature), then PR 4 must rebase against the intermediate. The
  solution's open question 2 (lines 246-251) flags this for the SPEC
  amendment; the same applies to source files in principle.
- **Backing (B):** `factory-loop.md` §"Conflict check" + §"When to
  serialize"; `spec-before-code.md` for the SPEC-amendment rebase pattern.

#### Falsification attempt for claim 4

- **Strategy:** Dependency check — for each child PR, verify that nothing it
  needs at merge time is produced by a later child PR in the ordering.
- **Attempt:** Walked each PR for backward references:
  - PR 1 references nothing from PRs 2/3/4. ✓
  - PR 2 references nothing from PRs 3/4. (The pre-increment convention is a
    change to `Store`, but it does not require PR 4's `name:` opt.) ✓
  - PR 3 references nothing from PR 4. (The `Tau.OtelReporter` always-in-
    tree change does not require PR 4's name resolution; `OtelReporter` is
    started by literal module atom.) ✓
  - PR 4 explicitly assumes PRs 1, 2, 3 are merged (per solution lines
    220-223: "Rebases on top of PR 3's `start/2` body"). Forward
    dependency only — consistent with last-in-order.
  Counter-attempt: is there any reverse dependency, e.g., does PR 2's
  `check/3` cooldown opt need to be threaded through `Tau.Names` somehow?
  No — `cooldown_ms` is a per-call keyword opt to a pure function, not a
  process name. Independent.
- **Outcome:** Withstood. No backward dependency among the four.
- **Action:** None.

### Claim 5: PR 4's edits to `Cost.Tracker` and `CircuitBreaker.Store` are additive and preserve PRs 1 and 2's semantics verbatim

- **Claim (C):** "Modifying `Cost.Tracker` and `CircuitBreaker.Store` here
  is purely additive (accept `name:`, `table:` opts with defaults equal to
  current atoms), so the rescue block from #1 and the multi-op
  `update_counter` from #2 are preserved verbatim." (root solution.md,
  Composition rationale, lines 81-85).
- **Grounds (G):** Solution's PR 4 specification, lines 162-167: "`name:`
  and `table:` opts (defaults `__MODULE__` and `:tau_circuit_breakers`).
  Additive — preserves PR 2's pre-increment semantics." Lines 166-167:
  "same pattern (`name:` opt). Additive — preserves PR 1's rescue block
  verbatim." The defaults specified match the current atoms exactly
  (`__MODULE__` for `Store`, `:tau_circuit_breakers` for the ETS table,
  `Tau.Cost.Tracker` implicitly for `Tracker`'s `__MODULE__` name).
- **Warrant (W):** Adding a keyword opt with a default that equals the
  previous hard-coded value is a *backward-compatible refinement*: every
  caller that does not supply the opt observes pre-change behaviour
  exactly; the new behaviour is opt-in. This is the standard contract-
  preserving extension pattern (OTP non-negotiable #2 — extensibility seams
  as behaviours, here as keyword opts).
- **Qualifier (Q):** Holds **only if** the default truly equals the
  current atom AND the only added code paths are the opt-reading sites;
  any edit to the *body* of `handle_event/4` (PR 1's rescue) or the
  *body* of `bump_failure_count/1`/`bump_success_count/1` (PR 2's
  multi-op) would violate "preserved verbatim."
- **Rebuttal (R):** If PR 4's implementer, when threading `name:` through
  `Cost.Tracker.start_link/1` and `init/1`, mistakenly also edits the
  `:telemetry.attach` block (lines 89-105 in current `tracker.ex`) — e.g.
  to make the handler_id parameterised by instance — that would mutate
  PR 1's rescue boundary and violate the verbatim-preservation claim.
  This is a real implementation hazard but not asserted by the solution
  text; the solution prescribes only `start_link/1` / `init/1` opt
  acceptance.
- **Backing (B):** Erlang/OTP convention for keyword-opt extension (cf.
  `:gen_server` callback opts, `:ets.new/2` opts list); OTP non-negotiable
  #2 in `.claude/rules/otp-non-negotiables.md`.

#### Falsification attempt for claim 5

- **Strategy:** Counter-example construction — find a code path in the live
  `tracker.ex` or `store.ex` where adding a `name:` opt requires editing
  PR-1 or PR-2 territory.
- **Attempt:** Read `lib/tau/cost/tracker.ex` end-to-end at validation time.
  `start_link/1` (line 73) calls `GenServer.start_link(__MODULE__, opts,
  name: __MODULE__)`. To make `name:` configurable, PR 4 needs to derive
  the name from opts and pass `name: derived_name` — purely opt-list
  manipulation, no body edits required. `init/1` (lines 80-108) references
  `:telemetry.attach` with literal handler IDs `@handler_id` /
  `@coding_agent_handler_id` — these would need parameterisation for
  multi-instance, since `:telemetry.attach` requires globally-unique IDs.
  This IS a body edit, not pure opt threading. **The solution does not
  mention handler-ID parameterisation.** This is a partial gap.
  However: the gap is in PR 4's *completeness for multi-instance handler
  attachment*, NOT in PR 4's *preservation of PR 1's rescue verbatim*. PR
  1's rescue lives inside `handle_coding_agent_cost/4` body — that body is
  not touched by handler-ID parameterisation (only the `:telemetry.attach`
  argument is). So Claim 5's "preserves verbatim" stands; the deeper PR 4
  question (will handler IDs collide across instances?) is a child-node
  concern routed to `subproblems/global-name-collision/validation.md`.
  For `CircuitBreaker.Store.bump_failure_count/1` (line 116, single
  `:ets.update_counter(@table, provider, {3, 1})` call), PR 4's `table:`
  opt makes `@table` parameter-driven — body edit, but PR 2's "multi-op"
  per the solution is `[{pos, 0}, {pos, 1}]`. The instruction in PR 2
  changes the *third argument* of `update_counter`, while PR 4 changes
  the *first* (the table). These do not overlap textually; PR 4's edit
  is `:ets.update_counter(table, provider, ...)` where `table` is the
  resolved opt. **PR 2's "multi-op" is preserved verbatim** — only the
  argument is now a variable instead of `@table`. The solution's
  "preserved verbatim" claim is intact under a reasonable reading: the
  multi-op *expression* is unchanged; only its surrounding scope is
  parameterised.
- **Outcome:** Withstood at the stated scope (PR-1 rescue body and PR-2
  multi-op expression). Surfaced a separate gap (handler-ID
  parameterisation) that is properly the child node's concern, not this
  claim's.
- **Action:** None for this claim. Logged as an outstanding doubt for
  parent inheritance.

### Claim 6: The four sub-problems are MECE along the Hickey concern axis

- **Claim (C):** "The four child recommendations are **directly composable**.
  The decomposition strategy in `problem.md` partitions defects along the
  Hickey *concern* axis (steady-state event handling vs lifecycle vs
  data-shape-across-a-layer vs deployment topology); no concern lives in
  two children, so no recommendation contradicts another." (root
  solution.md, Composition rationale, lines 42-46).
- **Grounds (G):** problem.md §Decomposition strategy (lines 64-75) names
  four classes (a)-(d) and asserts MECE explicitly. Cross-checked: each
  concrete defect cited in problem.md maps to exactly one class:
  - cost tracker rescue gap → (a) steady-state event handling
  - telemetry supervisor `:one_for_one` → (a) steady-state event handling
  - circuit-breaker counter leakage → (c) data-shape across layer
  - cooldown asymmetric configurability → (c) data-shape across layer
  - unmonitored CLI task → (b) lifecycle
  - dual OTel enable policy → (b) lifecycle
  - hard-coded global atom names → (d) deployment topology
- **Warrant (W):** Hickey's "Simple Made Easy" defines a *concern* as a
  single dimension of meaning; MECE-by-concern means the partition's
  equivalence classes are atomic-by-concern. A partition is composable
  iff its classes are independent (changes to one class do not require
  reading another), which is exactly MECE-by-concern.
- **Qualifier (Q):** Holds **provided** no later finding crosses a
  boundary. The classification of "cost tracker rescue gap" and "telemetry
  supervisor strategy" as the same class (a) is a judgement call — they
  could be argued as separate concerns (handler-internal vs supervisor-
  strategic). But child solution at
  `subproblems/telemetry-handler-coupling/solution.md` packages them
  together, so the boundary is held.
- **Rebuttal (R):** If a defect surfaces that legitimately straddles two
  classes (e.g., a circuit-breaker concern that is also a deployment-topology
  concern), the partition is no longer MECE and the composition argument
  weakens. None such surfaced in the four child solutions; if one surfaces
  later, the root would need to re-validate.
- **Backing (B):** Hickey, "Simple Made Easy" (2011); Tau's
  `.claude/rules/spec-before-code.md` which encodes the same partition
  discipline at the SPEC level (one SPEC per concern, not per artefact).

#### Falsification attempt for claim 6

- **Strategy:** Edge-case enumeration — try to construct a defect that
  straddles two of the four classes.
- **Attempt:** Construct candidate cross-boundary defects:
  - "What if a circuit breaker is per-instance — does PR 4 (deployment
    topology) need PR 2 (counter convention)?" PR 4 makes the breaker
    table name configurable; the counter convention is still per-row.
    Different tables hold different rows; no cross-instance interference.
    The two are orthogonal — MECE holds.
  - "What if the cost tracker rescue (PR 1) needs to be aware of the
    handler ID being per-instance (PR 4 deployment topology)?" The rescue
    catches body raises regardless of handler ID; the two are orthogonal.
    MECE holds.
  - "What if the supervision-tree-startup change (PR 3) needs to know
    about PR 4 names because `Tau.OtelReporter` reads a name?" The
    `OtelReporter` is started by literal module atom in PR 3; PR 4's
    `names.*` threading would add a `name:` opt later. The two are
    serial-additive, not cross-cutting.
  No straddling defect could be constructed within the inventory.
- **Outcome:** Withstood. The MECE-by-concern partition holds for the
  defect set.
- **Action:** None.

## Cross-claim consistency

Internally consistent. The six claims fit together as: Claims 1 + 6 establish
that the conjunction `P1 ∧ P2 ∧ P3 ∧ P4` covers the parent acceptance criterion;
Claims 2 + 4 + 5 establish that the conjunction's *operationalisation* (the
serial four-PR merge) does not destroy independence; Claim 3 explains the
order. Claim 3's partial falsification narrows the *gloss* on ordering rationale
without contradicting any other claim — the load-bearing constraint
(conflict-minimisation + PR 4 last) is stated in the Migration sketch and is
unaffected.

One latent tension worth noting: Claim 5 ("preserves verbatim") and Claim 2
("same function, disjoint regions") both assert that PR 4's additive edits
do not damage prior PRs' semantics. They reinforce each other rather than
conflict; neither weakens the other.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Four PRs cover parent acceptance criterion | Edge-case enumeration + dependency check | withstood | none |
| 2 | PRs 3 ∩ 4 in `start/2` are disjoint regions | Counter-example construction | withstood | none |
| 3 | Ordering puts smallest blast radius first | Counter-example construction | partially falsified | narrow qualifier — load-bearing criterion is conflict-min + PR 4 last, not "smallest first" |
| 4 | No sibling prerequisite beyond ordering | Dependency check | withstood | none |
| 5 | PR 4 edits to Tracker/Store preserve PR 1/2 verbatim | Counter-example construction | withstood | none |
| 6 | Decomposition is MECE-by-concern | Edge-case enumeration | withstood | none |

## Revision required

No solution.md or problem.md revision triggered. Claim 3's partial
falsification narrows the *qualifier* on the ordering rationale in place;
the prescribed ordering itself is unchanged, and the Migration sketch
already states the load-bearing rationale (conflict-minimisation + PR 4
last) correctly. The Recommendation paragraph's "lowest blast radius first"
gloss is descriptive rather than prescriptive — flagged as an outstanding
doubt rather than triggering revision.

- **Target file:** n/a
- **Revision kind:** n/a
- **Rationale:** Per `validate.md` §5, partial falsification → narrow
  qualifier in place; no revision needed. Revision is reserved for
  falsified claims (none here) or solution-invalidating tensions (none
  here).

## Outstanding doubts

- **D1** (from Claim 3): The Recommendation's "smallest patches first"
  framing is post-hoc and could mislead a future implementer into
  reordering on a size basis (e.g., #3 before #1) and inadvertently
  breaking the conflict-minimisation invariant. Mitigation: the Migration
  sketch already states the load-bearing rationale; future implementers
  should read both sections. Parent-level validator should consider
  whether to amend the Recommendation to surface the operative criterion
  explicitly.
- **D2** (from Claim 5 counter-attempt): PR 4's `name:` opt threading on
  `Cost.Tracker.init/1` raises a question the solution does not address —
  `:telemetry.attach` requires globally-unique handler IDs, so a
  multi-instance Tau would need handler-ID parameterisation as well. This
  is properly the concern of
  `subproblems/global-name-collision/validation.md`, but flagged here in
  case the child validator missed it.
- **D3** (from Claim 4): The "preserves verbatim" guarantees in PR 4 are
  unverifiable until each PR's diff exists; the solution's internal
  consistency is verified, but implementation drift is a real risk gated
  only by the per-PR `critic` + `reviewer` cycle. Flagged for the
  factory-loop's per-PR gate rather than for this validation.
- **D4** (from Claim 6): The classification of "cost tracker rescue" and
  "telemetry supervisor strategy" as a single concern class (a) is a
  judgement call; an alternative decomposition could split them. Both
  the parent and the child currently bundle them; this validation accepts
  the bundling. If a later defect surfaces that ties the two more tightly,
  re-validate.
