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

# Validation: Close tau-permissions property-coverage holes via four parallelisable PRs

## Overview

The root solution synthesises four leaf solutions into a four-PR program that
together claims to satisfy the root acceptance criterion (property coverage of
every invariant-bearing function in `tau-permissions` plus `Loader.merge/2`,
elimination of the `PathPrefix` impurity, and structural separation of
evaluator mode-dispatch from rule-set precedence). This validation enumerates
six cross-cutting claims, runs full Toulmin on each, and applies a named
falsification strategy per claim. Strategies used: integration check
(PRs touch real existing code at cited file/line), edge-case enumeration
(parent-AC conjunction; rebase storm under concurrent merge), dependency
check (D-NNN slot availability against the MISSION registry), counter-example
construction (PathPrefix purification under untouched call sites),
prior-art counter-case (factory-loop's own §Parallel execution clauses
applied as the public-case test). One claim (claim 5 — D-NNN slot) is
**partially falsified**: the literal range cited (D-090..D-099) is exhausted
per `docs/MISSION.md`, but the solution's own Open Question requires a grep
audit at PR-filing time, so the narrowed qualifier — "the next free slot in
the SPEC-PERMISSION-PROMPTS block, which is D-174..D-179 in the PR-B TUI sub-
range, not D-090..D-099" — survives and triggers no revision. All other claims
withstood. Five outstanding doubts remain (listed at end).

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found unguided Toulmin output
varies greatly even on identical content
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
Each field below adds independent information; no field restates the claim.

### Claim 1: The four PRs are parallelisable per the factory-loop conflict check; spawning PR-A, PR-B, PR-C, PR-D concurrently is the recommended factory batch.

- **Claim (C):** "The four PRs are parallelisable per the conflict check in
  `.claude/rules/factory-loop.md` §Parallel execution. […] All five clauses
  clear. The recommended factory batch is to spawn PR-A, PR-B, PR-C, PR-D
  concurrently as four implementer agents, each `isolation: worktree`, each
  with its own draft PR opened first per the factory-loop cycle." (solution.md
  Migration sketch, l. 163–186)
- **Grounds (G):** PR-A modifies only `lib/tau/permissions/matchers.ex`
  (`PathPrefix.match?/4` at matchers.ex:79–88) and creates
  `test/tau/permissions/matchers_test.exs`. PR-B modifies only
  `test/tau/permissions/mode_test.exs`. PR-C creates
  `lib/tau/permissions/mode_policy.ex`, modifies one defp in
  `lib/tau/permissions/evaluator.ex` (`default_for_mode/3`, evaluator.ex:91–119),
  creates `test/tau/permissions/mode_policy_test.exs`, and adds one D-NNN entry
  to `docs/spec/SPEC-PERMISSION-PROMPTS.md`. PR-D creates
  `test/tau/settings/loader_property_test.exs`. The four file sets share no
  file path.
- **Warrant (W):** factory-loop.md's §Parallel execution five clauses license
  concurrent spawn when (1) no dependency, (2) disjoint files, (3) disjoint
  codepoints, (4) no shared SPEC/D-NNN block, (5) shared-resource isolation
  possible. A PR set that clears all five MAY spawn concurrently.
- **Qualifier (Q):** Holds for the file-disjointness and codepoint-disjointness
  clauses as written. Holds for shared-SPEC clause only if PR-C's D-NNN lands
  in a block none of PR-A/PR-B/PR-D touches (true — PR-A and PR-B touch no
  SPEC; PR-D touches no SPEC). Holds for dependency clause only if PR-C's SPEC
  amendment is not a prerequisite for PR-A/PR-B/PR-D's gating tests to land —
  true, because the SPEC entry pins enforcement but the property tests stand
  alone.
- **Rebuttal (R):** A concurrent run that exceeds the coordinator's ability to
  manage four simultaneous freshness re-checks (cycle step 8a fires once per
  merge for every other in-flight branch — three re-checks across the batch's
  lifetime) may force serialisation into two batches; the solution itself
  flags this and offers PR-A+PR-B / PR-C+PR-D as the fallback grouping.
- **Backing (B):** `.claude/rules/factory-loop.md` §Parallel execution +
  §Conflict check (lines on the in-repo rule file; quoted verbatim by the
  solution at l. 163–164).

#### Falsification attempt for claim 1

- **Strategy:** prior-art counter-case applied internally — walk the
  factory-loop's own five clauses against the PR file-sets to look for a
  hidden overlap that would defeat the disjointness claim.
- **Attempt:** Enumerated every file path in each PR's What-changes list and
  set-intersected the four sets pairwise. PR-A: `{matchers.ex,
  matchers_test.exs}`. PR-B: `{mode_test.exs}`. PR-C:
  `{mode_policy.ex, evaluator.ex, mode_policy_test.exs,
  SPEC-PERMISSION-PROMPTS.md}`. PR-D: `{loader_property_test.exs}`. All six
  pairwise intersections are empty. Codepoints: PR-A's only production edit
  is `PathPrefix.match?/4` (matchers.ex:79–88, verified by Read); PR-C's only
  production edit is `default_for_mode/3` (evaluator.ex:91–119, verified by
  Read). No codepoint overlap. Dependencies: PR-A's `PathPrefix` purification
  does not depend on PR-C's `ModePolicy` extraction (different module); PR-D's
  loader properties do not depend on either (different subsystem); PR-B's mode
  property block is test-only in `Tau.Permissions.Mode`, independent of all
  three production-code modules.
- **Outcome:** withstood. The five clauses all clear under verbatim inspection.
- **Action:** None. The Migration sketch correctly notes the fall-back to two
  batches if coordinator cannot gate four simultaneously; that is a capacity
  qualifier, not a correctness rebuttal.

### Claim 2: The four PRs together close all four coverage gaps named in the root problem statement.

- **Claim (C):** "Together [the four PRs] satisfy the root acceptance criterion
  [...]. After all four land, every invariant-bearing function in
  `tau-permissions` and `Settings.Loader.merge/2` has at least one property
  test, the `PathPrefix` impurity is eliminated rather than merely documented,
  and the evaluator's per-mode allow-set is structurally separated from
  rule-set precedence and pinned by a spec-gated D-NNN." (solution.md
  Recommendation, l. 19–36)
- **Grounds (G):** The root problem.md names four gaps explicitly (matchers
  zero property tests at problem.md l. 76–79; mode peer-rank not
  property-swept at l. 80–82; `default_for_mode/3` complecting at l. 83–86;
  `Loader.merge/2` no property tests at l. 87–89). PR-A covers gap 1 (new
  `matchers_test.exs` with two-or-more properties per matcher); PR-B covers
  gap 2 (9-pair sweep + `at_or_below?/2` properties in `mode_test.exs`); PR-C
  covers gap 3 (extract `ModePolicy`, delegate `default_for_mode/3`); PR-D
  covers gap 4 (new `loader_property_test.exs` with three invariants).
- **Warrant (W):** Conjunction satisfaction: if the parent AC is a conjunction
  of independently-satisfiable clauses and each clause has at least one PR
  whose deliverable provably satisfies it, the AC is satisfied iff every
  contributing PR lands. The four PRs partition by concern layer exactly as
  the problem's Decomposition strategy specifies (l. 65–71).
- **Qualifier (Q):** Holds *iff* all four PRs land. If any PR is dropped or
  fails the gate beyond N=3 + pivot, the residual gap re-opens.
- **Rebuttal (R):** AC3 ("structurally separated") is stronger than what
  PR-C's delegation pattern delivers: the delegation puts the data structure
  in a separate module but `evaluate/5` still holds a `cond` branch that calls
  `default_for_mode/3` as the fall-through. A reader could argue that
  delegation is not "structural separation" because the call site survives.
  The solution itself acknowledges this — Open question "Deferred deeper
  structural fix" (l. 220–224) explicitly defers Proposal 3's fold-into-
  rule-set approach to a future milestone.
- **Backing (B):** `docs/MISSION.md` D-NNN registry (per-spec partitioning);
  CLAUDE.md OTP non-negotiable #6 (invariant-bearing modules require
  properties before examples); ADR-0014/ADR-0015 (mode ceiling and sub-agent
  clamp, cited at problem.md l. 44–45).

#### Falsification attempt for claim 2

- **Strategy:** edge-case enumeration — list every clause of the parent AC,
  pair each to the PR claimed to satisfy it, and check for a clause with no
  satisfying PR or a PR whose deliverable falls short.
- **Attempt:** Parent AC has three conjuncts (problem.md l. 92–99): (a) every
  invariant-bearing function in `tau-permissions` and `Loader.merge/2` has at
  least one property; (b) `PathPrefix` impurity is documented as known
  deviation; (c) `default_for_mode/3` allow-lists are structurally separated
  from rule-set precedence. PR mapping: (a) ← PR-A+PR-B+PR-C+PR-D; (b) ← PR-A
  (eliminates rather than documents, strictly stronger per the synthesis
  rationale l. 56–60); (c) ← PR-C. Every clause has a satisfying PR. The
  "structurally separated" reading risk in (c) is the rebuttal's territory,
  not an outright clause-without-PR.
- **Outcome:** withstood. All three AC clauses are addressed.
- **Action:** None. The rebuttal narrows the qualifier under which (c) is
  fully satisfied (structural-separation reading), but the solution itself
  flags this in Open questions; no further narrowing needed.

### Claim 3: The PathPrefix purification (PR-A's 3-line change) is safe under the existing call-site contract because every Evaluator.evaluate/5 caller propagates :cwd in the context map.

- **Claim (C):** "[PR-A is a] 3-line `PathPrefix.match?/4` fail-closed
  purification [...]. **Pre-PR audit** (no file change): grep all
  `Evaluator.evaluate/5` call sites to confirm `:cwd` is in the ctx map; any
  gap fixes land in the same PR." (solution.md What changes, l. 73–86)
- **Grounds (G):** Today, `PathPrefix.match?/4` at matchers.ex:79–88 reads
  `cwd = ctx[:cwd] || File.cwd!()`. The fallback to `File.cwd!()` masks
  any caller that omits `:cwd` — the function silently uses the BEAM
  process's `cwd`. After the change, the same code path returns `false`
  when `:cwd` is `nil`, which is a fail-closed semantic shift.
- **Warrant (W):** A pure function that returns `false` on absent context is
  safer than one that consults process-global state, *provided* every existing
  caller already supplied the context (no behavioural change for compliant
  callers). The OTP non-negotiable #8 (pure functions are the default) makes
  this trade strictly correct.
- **Qualifier (Q):** Safe iff every `Evaluator.evaluate/5` call site populates
  `ctx[:cwd]`, OR the call site is path-rule-free (no `PathPrefix` rule in the
  active rule-set). Holds conditionally on the PR-A pre-PR audit succeeding;
  the solution explicitly conditions the change on the audit (l. 86) and
  scopes any audit-found gap into the same PR.
- **Rebuttal (R):** A `PathPrefix` rule in a rule-set evaluated against a
  call site that doesn't pass `:cwd` will silently shift from "matches
  against process-cwd" (potentially true) to "returns `false`" (always)
  after PR-A. If `lib/tau/session.ex` or `lib/tau/tui/app.ex` calls
  `Evaluator.evaluate/5` without `:cwd`, the change is a user-visible
  permission semantic change. The Open question "Call-site audit scope for
  PR-A" (l. 202–205) explicitly names `Tau.Session` as the call site to
  audit; if the audit surfaces a gap, PR-A's scope widens.
- **Backing (B):** OTP non-negotiable #8 (`CLAUDE.md` / `TAU.md` §OTP
  non-negotiables — pure functions are the default; processes are the
  exception); the matchers.ex source itself (verified by Read l. 74–89).

#### Falsification attempt for claim 3

- **Strategy:** counter-example construction — try to construct a
  `(Evaluator.evaluate/5 caller, rule-set, ctx)` triple where the PR-A change
  flips a previously-true match into `false` without compensating audit fix.
- **Attempt:** A call site that omits `:cwd` and evaluates against a rule-set
  containing a `PathPrefix` rule with a relative prefix (e.g.
  `Read(./src/**)`) currently uses `File.cwd!()` to expand both `path` and
  `prefix`. After PR-A, the call returns `false` always. If
  `lib/tau/session.ex` or `lib/tau/tui/app.ex` calls `evaluate/5` with a
  context map that lacks `:cwd`, this counter-example is realised. I have
  *not* exhaustively read those files in this validation — the solution's
  Open question explicitly requires the implementer to do so before filing
  PR-A and to fix any gap in the same PR. Treating that requirement as a
  pre-condition rather than a defect: the *claim as scoped* (safe **subject
  to** the audit-and-fix) survives. Treating it as unconditional: counter-
  example is plausible but unconstructed in this validation.
- **Outcome:** withstood under the qualifier as scoped. The solution's own
  audit-and-fix-in-same-PR clause is the answer to the counter-example
  attempt.
- **Action:** None. Validator records the audit-and-fix-in-same-PR scope as
  a load-bearing pre-condition that the PR-A implementer MUST execute; the
  solution already names it.

### Claim 4: The four child solutions partition cleanly by concern layer and present no inter-PR conflict to resolve.

- **Claim (C):** "The four child solutions partition cleanly by concern
  layer; their `What changes` lists are file-disjoint […] and their failure
  modes are orthogonal. There is no conflict to resolve and no gap against
  the root acceptance criterion […]. No child's recommendation contradicts
  another." (solution.md Selected from > Composition rationale, l. 50–69)
- **Grounds (G):** The four leaf solutions' What-changes lists, as read from
  each `subproblems/*/solution.md`: matcher-unit-contracts touches
  `lib/tau/permissions/matchers.ex` + `test/tau/permissions/matchers_test.exs`;
  mode-lattice-properties touches `test/tau/permissions/mode_test.exs` only;
  evaluator-mode-complecting touches `lib/tau/permissions/evaluator.ex` +
  creates `lib/tau/permissions/mode_policy.ex` +
  `test/tau/permissions/mode_policy_test.exs` +
  `docs/spec/SPEC-PERMISSION-PROMPTS.md`; settings-merge-feed touches
  `test/tau/settings/loader_property_test.exs` only. Pairwise file
  intersections all empty (verified in Claim 1 falsification).
- **Warrant (W):** Independent partitioning: two PRs with disjoint files,
  disjoint codepoints, and no shared SPEC entry cannot conflict at merge time
  because the merge operation is a set-union of disjoint diffs.
- **Qualifier (Q):** Holds for the diffs as currently scoped. If any leaf
  scope widens in implementation (e.g. PR-A's audit reveals a `:cwd` gap in
  `lib/tau/session.ex` and the fix lands in PR-A, while PR-C's
  `ModePolicy` extraction simultaneously edits a nearby region of
  `evaluator.ex`), an indirect conflict might emerge. None projected today.
- **Rebuttal (R):** PR-C's `default_for_mode/3` extraction touches
  `evaluator.ex` near the `cond` block; if a `:cwd`-fix in PR-A also lands in
  `evaluator.ex` (the audit may surface this — `evaluate/5` is the entry
  point), git could surface a structural conflict even with line-disjoint
  edits. Probability is low but not zero.
- **Backing (B):** The four leaf solutions themselves, cross-referenced
  against the synthesis rationale at solution.md l. 50–69.

#### Falsification attempt for claim 4

- **Strategy:** integration check — verify by reading the four leaf
  solutions independently that no leaf includes a deliverable that the
  synthesis omitted or contradicted.
- **Attempt:** Read all four `subproblems/*/solution.md`. Each leaf's
  Recommendation section maps directly to one PR in the synthesis:
  matcher-unit-contracts ↔ PR-A (verbatim: "Add
  `test/tau/permissions/matchers_test.exs` […] and simultaneously replace
  `PathPrefix.match?/4`'s `File.cwd!/0` fallback with fail-closed `false`");
  mode-lattice-properties ↔ PR-B (verbatim: "Replace the three spot-check
  tests in `describe "clamp/2 — peer modes"` with a single example test
  that iterates all 9 peer × peer combinations via a `for` comprehension,
  and add a dedicated `describe "at_or_below?/2 — properties"` block");
  evaluator-mode-complecting ↔ PR-C (verbatim: "Introduce
  `Tau.Permissions.ModePolicy` […] add a D-NNN invariant entry to
  `SPEC-PERMISSION-PROMPTS.md`"); settings-merge-feed ↔ PR-D (verbatim:
  "Add `test/tau/settings/loader_property_test.exs` […] containing three
  properties"). No leaf deliverable was dropped; no leaf contradicts
  another.
- **Outcome:** withstood. The synthesis preserves every leaf deliverable
  verbatim and the partition is clean.
- **Action:** None.

### Claim 5: PR-C's new D-NNN invariant lives in the D-090..D-099 block of SPEC-PERMISSION-PROMPTS.md.

- **Claim (C):** "**Modified** `docs/spec/SPEC-PERMISSION-PROMPTS.md` — add
  one D-NNN invariant entry (next free slot in D-090..D-099 — must be
  confirmed by `git log --all --grep` plus `grep -rn` over `lib test docs
  .claude` before filing)". (solution.md What changes > PR-C, l. 116–122)
- **Grounds (G):** `docs/MISSION.md` D-NNN registry (l. 75) allocates
  D-090..D-099 to SPEC-PERMISSION-PROMPTS for PR-A, and D-170..D-179 for
  PR-B (TUI surface). Grep of `lib test docs .claude` for `D-09[0-9]` returns
  every slot D-090 through D-099 already used in SPEC-PERMISSION-PROMPTS
  §7 invariants table (D-090..D-098 active, D-099 deferred). Grep of
  `D-17[0-9]` shows D-170..D-173 used (PR-B TUI invariants); D-174..D-179
  free.
- **Warrant (W):** The MISSION D-NNN registry is the authoritative partitioner
  of identifiers across specs; a SPEC may only allocate within its assigned
  blocks. A new D-NNN entry in SPEC-PERMISSION-PROMPTS must come from one of
  its two assigned blocks (D-090..D-099 OR D-170..D-179).
- **Qualifier (Q):** The literal range cited in PR-C's What-changes
  ("D-090..D-099") is **wrong** — that block is fully allocated. The
  narrowed claim that *survives* is: "PR-C adds one D-NNN entry to
  SPEC-PERMISSION-PROMPTS, in the next free slot within the spec's two
  assigned blocks (today: D-174..D-179)." The solution's Open question
  (l. 196–200) makes the slot-grep a PR-C precondition, which catches this
  at filing time.
- **Rebuttal (R):** None — the registry is unambiguous and grep evidence is
  decisive. The claim's literal scope is provably false; the narrowed claim
  is provably true.
- **Backing (B):** `docs/MISSION.md` l. 75 (registry); SPEC-PERMISSION-PROMPTS.md
  §7 invariants table (l. 366–375 — D-090..D-099); §7 invariants table PR-B
  block (l. 381–384 — D-170..D-173); grep results (this validation).

#### Falsification attempt for claim 5

- **Strategy:** dependency check against the MISSION registry — assume the
  claim, verify the dependency (free slot in D-090..D-099) holds today.
- **Attempt:** `grep -rn "D-09[0-9]"` over `lib test docs .claude`. Every
  slot D-090 through D-099 is present in
  `docs/spec/SPEC-PERMISSION-PROMPTS.md` §7 and referenced in
  `lib/tau/session.ex`, `lib/tau/tui/app/*`, and
  `test/tau/session/permission_prompts_test.exs`. D-099 is annotated as
  "deferred" but still occupies the slot. The literal "next free slot in
  D-090..D-099" does not exist. `D-17[0-9]` grep shows D-170..D-173
  allocated; D-174..D-179 free.
- **Outcome:** partially falsified. The literal range is exhausted; the
  narrowed range (D-174..D-179, within the spec's other assigned block) has
  free slots and the solution's own Open-question audit clause makes the
  grep mandatory at PR-filing time. The narrowed claim survives.
- **Action:** Narrow the qualifier in place to "the next free slot within the
  spec's MISSION-assigned blocks (D-090..D-099 OR D-170..D-179)". No
  revision triggered — the solution's Open question already mandates the
  grep audit; the implementer briefed against PR-C MUST consult the registry
  and allocate D-174 (or next free) rather than the as-written placeholder
  D-09x. The validator records this as a load-bearing implementer
  pre-condition; the synthesis text in solution.md l. 117 should be read as
  "the next free slot in the SPEC-PERMISSION-PROMPTS-assigned blocks per the
  MISSION registry", not the literal range it cites.

### Claim 6: After all four PRs land, the four-gap closure satisfies the root acceptance criterion's conjunction.

- **Claim (C):** "After all four land, every invariant-bearing function in
  `tau-permissions` and `Settings.Loader.merge/2` has at least one property
  test, the `PathPrefix` impurity is eliminated rather than merely
  documented, and the evaluator's per-mode allow-set is structurally
  separated from rule-set precedence and pinned by a spec-gated D-NNN."
  (solution.md Recommendation, l. 33–36)
- **Grounds (G):** The set of invariant-bearing functions in `tau-permissions`
  (per problem.md Context, l. 30–46) comprises: five matcher `match?/4`
  implementations (matchers.ex); `Mode.clamp/2` and `at_or_below?/2`
  (mode.ex); `Evaluator.evaluate/5` and its private `default_for_mode/3`
  (evaluator.ex); `Loader.merge/2` (settings/loader.ex, named in the parent
  AC). PR-A adds properties to the five matchers; PR-B adds the 9-pair
  sweep + `at_or_below?/2` properties; PR-C adds `ModePolicy.default/3`
  properties (which is the renamed-and-extracted form of the former
  `default_for_mode/3`) and preserves the existing `evaluator_test.exs`
  integration examples; PR-D adds three `Loader.merge/2` properties. The
  matcher modules' `match?/4` callbacks become property-tested directly for
  the first time; `Mode.clamp/2` and `at_or_below?/2` already have
  properties (per `mode_test.exs` l. 180–209) and PR-B extends them; the
  evaluator's pure mode-default logic moves into `ModePolicy.default/3`
  with its own properties; `Loader.merge/2`'s three array-merge invariants
  are pinned.
- **Warrant (W):** The parent AC is a logical conjunction over three
  clauses (a, b, c — enumerated in Claim 2). Each conjunct's satisfaction
  by a delivered PR is necessary and (in combination) sufficient for the
  conjunction. The four PRs are independently-shippable and their land-or-
  miss outcomes are uncorrelated under the factory loop's gate-per-PR
  discipline.
- **Qualifier (Q):** Satisfied iff all four PRs land AND their gating
  tests survive Gate 5.1/5.2/5.3 AND the post-merge `main` health check
  stays green across the four merges. Any PR that pivots beyond N=3 + pivot
  re-opens the gap it was meant to close.
- **Rebuttal (R):** Two AC-falsifying scenarios: (a) PR-D's C3
  "absent-key-as-empty-list" property may fail against the real
  `Loader.merge/2` — settings/loader.ex's `merge_value/3` only fires when
  both layers have the same key, so absent-in-one-layer leaves the key
  alone; whether the merged result has a list (truthy `[]`) or `nil` for
  the absent key depends on `Map.get(_, _, [])` discipline at the read
  site. If C3 fails, PR-D's scope widens (per Open question l. 215–218) or
  a follow-up issue is filed; the AC's "at least one property" is still
  satisfied by C1+C2 even if C3 narrows. (b) The "structurally separated"
  reading of AC clause (c) — Claim 2's rebuttal applies here too; delegation
  is a weaker reading of "structural separation" than full integration into
  the rule-set (Proposal 3, deferred).
- **Backing (B):** Root problem.md Acceptance criterion (l. 92–99); the
  four leaf solutions' What-changes sections (verified independently in
  Claim 4); the OTP non-negotiable #6 invariant-bearing rule (CLAUDE.md
  §OTP non-negotiables).

#### Falsification attempt for claim 6

- **Strategy:** edge-case enumeration over the parent AC's three conjuncts
  and the failure modes of each contributing PR.
- **Attempt:** Conjunct (a) "every invariant-bearing function has at least
  one property test": fails iff PR-A drops a matcher (none — all five named
  in `What changes`), OR PR-B drops a `Mode` function (none — both `clamp/2`
  and `at_or_below?/2` covered), OR PR-C drops `ModePolicy.default/3`
  coverage (no — four properties named), OR PR-D drops `Loader.merge/2`
  coverage (no — three properties named). Conjunct (b) "PathPrefix impurity
  eliminated": fails iff PR-A drops the 3-line purification (no — it's the
  P3 component of the hybrid). Conjunct (c) "structurally separated": fails
  iff PR-C ships only the property tests without the `ModePolicy`
  extraction (no — extraction is the P2 component). Each conjunct
  withstands its enumeration. The C3 rebuttal in Claim 6 itself narrows
  PR-D's scope but not the AC's "at least one property" bar.
- **Outcome:** withstood. The conjunction satisfies under the qualified
  scope (all four PRs land + gating tests survive + post-merge main stays
  green).
- **Action:** None. The qualifier names the four required preconditions;
  the rebuttal cases are downgrades-not-falsifications under the AC's
  "at least one property" floor.

## Cross-claim consistency

The six claims partition cleanly:

- Claim 1 (parallelisability) and Claim 4 (no inter-PR conflict) reinforce
  each other — both rest on file/codepoint disjointness, independently
  verified.
- Claim 2 (coverage of four named gaps) and Claim 6 (parent AC conjunction
  satisfied) are nested: Claim 6 is the conjunction whose four conjuncts
  Claim 2 enumerates per-gap.
- Claim 3 (PathPrefix purification safe) is a constraint on PR-A's
  acceptable scope (audit-and-fix in same PR); it does not contradict
  Claim 1's file-disjointness because the in-scope audit fix would land in
  `lib/tau/session.ex` or `lib/tau/tui/app.ex` — files PR-B, PR-C, PR-D
  don't touch.
- Claim 5 (D-NNN slot) narrows PR-C's literal range cite; it does not
  contradict Claim 4's "no inter-PR conflict" because the corrected slot
  (D-174..D-179) still lies in a block none of PR-A/PR-B/PR-D touches.

No tension between claims. The internal consistency check passes.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Four PRs parallelisable per factory-loop | prior-art counter-case | withstood | none |
| 2 | Four PRs close all four named gaps | edge-case enumeration | withstood | none |
| 3 | PathPrefix purification safe under audit | counter-example construction | withstood (qualified) | none — audit is load-bearing PR-A pre-condition |
| 4 | Clean concern-layer partition, no conflict | integration check | withstood | none |
| 5 | New D-NNN in D-090..D-099 block | dependency check | partially falsified | narrow qualifier to D-174..D-179 (other assigned block); registry-grep audit already mandatory |
| 6 | Conjunction satisfaction of parent AC | edge-case enumeration | withstood | none |

## Revision required

No revision triggered. Claim 5 is partially falsified but the surviving
narrowed qualifier ("next free slot in the SPEC-PERMISSION-PROMPTS-assigned
blocks per MISSION registry") is already mandated by the solution's own Open
question requiring the grep audit at PR-filing time. The literal "D-090..D-099"
text in solution.md What-changes is misleading; the implementer briefed against
PR-C MUST consult the MISSION registry and grep before allocating. This is a
note-and-record outcome, not a solution rewrite.

- **Target file:** none
- **Revision kind:** none
- **Rationale:** Partial falsification of Claim 5 lands within the qualifier-
  narrowing path; the solution.md text needs a one-line clarification at most
  (replace "D-090..D-099" with "the SPEC-PERMISSION-PROMPTS-assigned blocks")
  but this falls below the revision threshold — the implementer's mandatory
  grep audit catches it deterministically.

## Outstanding doubts

- **Audit-found scope creep in PR-A.** If the `Evaluator.evaluate/5` call-site
  audit surfaces a `:cwd` gap in `lib/tau/session.ex` or `lib/tau/tui/app.ex`,
  PR-A's scope widens and the in-flight conflict check against PR-C (which
  also edits `evaluator.ex`) must be re-run by the coordinator at spawn time.
  Probability low but non-zero.
- **C3 property outcome in PR-D.** If `Loader.merge/2`'s absent-key handling
  fails the C3 property as a real bug rather than a property-shape issue,
  PR-D's scope widens to include a production fix in `lib/tau/settings/loader.ex`,
  or a follow-up issue is filed and C3 narrows. The Open question (l. 215–218)
  treats discovery as the property suite's value; either outcome is acceptable.
- **"Structurally separated" reading risk.** Claim 2's rebuttal and Claim 6's
  rebuttal both flag that PR-C's delegation pattern is a weaker structural
  separation than Proposal 3's deeper fold-into-rule-set approach. The parent
  AC text "structurally separated from the rule-set precedence logic" is
  ambiguous between the two readings. A future critic may flag the delegation
  as insufficient. The solution explicitly defers Proposal 3 to a future
  milestone (l. 220–224).
- **Slot allocation for PR-C's D-NNN.** Claim 5's narrowed qualifier (D-174..D-179)
  is correct *today* (this validation) but the PR-B TUI work could allocate
  D-174 before PR-C files. The implementer's grep-at-filing-time discipline is
  the only guard; the validator cannot pre-allocate.
- **Mutation check (Gate 5.3) for test-only PRs.** PR-B and PR-D are test-only
  (no production change). Gate 5.3's mutation check reverts non-gating-test
  paths to the merge-base — with no production code under test in those PRs,
  the mutation check has no mutation to detect. Per `factory-loop.md` Gate 5.3
  *"Runner crash"* discipline, this likely reports `:not_applicable` and exits
  0, but I have not verified this empirically. If Gate 5.3 hard-fails on the
  test-only PRs, the synthesis assumes a gate it cannot pass; PR-B and PR-D
  would need an alternate path. Worth confirming via `mix tau.gate.mutation`
  dry-run before spawning.
