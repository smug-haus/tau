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

# Validation: tau-cli four-PR module-wide correctness pass (root synthesis)

## Overview

This is the root validation of `docs/problems/tau-cli/solution.md`, a
non-leaf synthesis of four child solutions (error-swallowing-rescues,
run-loop-raw-receive, wizard-data-fidelity, reflective-module-dispatch).
Validation here does NOT re-validate the four children's internal
correctness — each has its own withstood-or-partially-falsified
`validation.md` already on file. The validator's job at the root is
**cross-cutting integration**: the synthesis-level claims about PR
sequencing, parallelisability, conjunction satisfaction of the parent
acceptance criterion, and absence of inter-child contradictions.

Six distinct propositions were extracted from the Recommendation and
What-changes sections. Falsification per claim used **integration check**,
**dependency check**, and **edge-case enumeration**; one external
**counter-example construction** was attempted for the PR-4
parallelisability claim. Five claims withstood the attempt; one (Claim 3
— PR-2 / PR-3 serialisation rationale) was partially falsified and the
qualifier is narrowed in place. No revision is triggered.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

### Claim 1: PR-0 (NN #7 carve-out amendment) MUST land before PR-1

- **Claim (C):** "the NN #7 amendment must land first because the rescues
  PR depends on it being in effect" (solution.md Recommendation, lines
  23–24). The doc-only PR-0 amends
  `.claude/rules/otp-non-negotiables.md` rule #7 to permit a targeted
  `catch :exit, {:noproc, _}` at a CLI/TUI command boundary; PR-1 then
  uses that carve-out in `Tau.CLI.Extensions` / `Tau.CLI.MCP`.
- **Grounds (G):** The text of NN #7 today is unconditional: "MUST NOT
  `try/rescue` across process boundaries. MUST NOT catch `:exit`"
  (`.claude/rules/otp-non-negotiables.md:26–27`). PR-1's per the child
  solution `subproblems/error-swallowing-rescues/solution.md`
  Recommendation introduces `catch :exit, {:noproc, _}` arms — literally
  the forbidden construct. The critic/reviewer gate is mandatory and reads
  these rules (`.claude/rules/factory-loop.md` "The gate"); a PR that
  imports a forbidden construct without the rule already amended would
  fail the gate.
- **Warrant (W):** A PR that violates an OTP non-negotiable cannot pass
  the mandatory critic/reviewer gate unless the rule already permits the
  construct at the moment the gate runs. The gate is stateless across
  PRs — it reads the rule file as it stands on the PR's branch.
  Therefore a code PR that depends on a rule amendment MUST follow the
  doc PR in merge order; the two-PR split avoids conflating rule change
  with code change (the factory-loop "PR scope guards" prefer one
  coherent shippable increment per PR).
- **Qualifier (Q):** Holds when PR-1 ships the targeted-catch form as
  proposed. If PR-1 chose the documented fallback ("pure deletion +
  top-level `Tau.CLI.main/1` rescue" — solution.md Open questions §1),
  the dependence on PR-0 vanishes and PR-1 could land standalone. The
  primary recommendation is the targeted-catch form, so Q is the
  expected branch.
- **Rebuttal (R):** Two corner conditions break the dependence: (a) the
  rule itself already contains an implicit carve-out via the
  rate-limiter precedent — but precedent does not amend rule text, so
  the gate's literal reading still rejects new uses; (b) the rescues PR
  could ship the rule amendment in-PR rather than as a separate PR-0 —
  the spec-before-code rule allows in-PR amendments — but the synthesis
  chose to split to honour the "one coherent shippable increment" guard.
- **Backing (B):** `.claude/rules/factory-loop.md` "The gate" section
  (mandatory, no override, no skipping); `.claude/rules/otp-non-negotiables.md:26–27`
  (current rule text); `.claude/rules/spec-before-code.md` (rule
  amendment in-PR vs separate PR is acceptable but scope guards prefer
  separation); precedent `lib/tau/providers/rate_limiter.ex:84–86`
  (targeted `catch :exit, {:noproc, _}` already in tree; cited in
  solution.md PR-0 bullet).

#### Falsification attempt for claim 1

- **Strategy:** dependency check (verify the prior state of the
  codebase and rulebook holds today).
- **Attempt:** Read `.claude/rules/otp-non-negotiables.md` at HEAD and
  searched for any existing carve-out language permitting targeted
  `catch :exit`. None present — rule #7 is unconditional. Confirmed
  rate-limiter precedent exists at
  `lib/tau/providers/rate_limiter.ex:84–86` but is precedent, not rule
  text. Verified the critic persona at
  `.claude/agents/critic.md` would read the rule file as text.
- **Outcome:** withstood — PR-0 dependency is real; PR-1 in its primary
  form would fail the gate without PR-0 first.
- **Action:** none.

### Claim 2: PR-4 is parallelisable with PR-1 and PR-2 once PR-0 has landed

- **Claim (C):** "**PR-4** (wizard `Catalog` extraction +
  `enabled_providers` schema key) parallelisable against PR-1 and PR-2
  once PR-0 has landed" (solution.md Recommendation, lines 30–32).
- **Grounds (G):** PR-4's owned files (solution.md What-changes,
  lines 130–149): NEW `lib/tau/providers/catalog.ex`, NEW
  `test/tau/providers/catalog_test.exs`, MODIFY `lib/tau/cli/init.ex`,
  `lib/tau/commands/builtin/logout.ex`,
  `lib/tau/settings/schema.ex`, `test/tau/cli/init_test.exs`. PR-1's
  owned files: `lib/tau/cli/extensions.ex` and `lib/tau/cli/mcp.ex`
  (solution.md PR-1 bullets, lines 86–95). PR-2's owned files:
  `lib/tau/session.ex` and `lib/tau/cli.ex` (solution.md PR-2 bullets,
  lines 97–116). The file sets are pairwise disjoint. PR-4 has no
  dependency on PR-0's rule amendment (PR-4 introduces no `rescue` or
  `catch :exit`).
- **Warrant (W):** The factory-loop conflict check
  (`.claude/rules/factory-loop.md` "The conflict check") permits
  concurrent execution of two PRs when they have (a) no dependency,
  (b) disjoint files, (c) disjoint codepoints, (d) no shared SPEC or
  D-NNN block, and (e) shared-resource isolation is possible. Disjoint
  file sets satisfy (b); absence of a code-level dependency satisfies
  (a) and (c); the four sub-problems live under distinct concerns
  (no shared SPEC entry — the root problem is not under a SPEC) so (d)
  holds; (e) is satisfied by per-worktree `XDG_DATA_HOME` per the
  worktree-discipline rule.
- **Qualifier (Q):** Parallelisable in the per-PR implementation
  phase; merge remains serialised (the factory loop's "Gate and merge
  under concurrency" explicitly forbids concurrent merges). After
  whichever of PR-1/PR-2/PR-4 merges first, the others trigger the
  cycle-step-8a freshness re-check.
- **Rebuttal (R):** A hidden shared dependency could materialise via
  `Tau.Settings.Schema` — PR-4 adds an `"enabled_providers"` key
  (solution.md line 144); if PR-2 or PR-1 happened to touch
  `lib/tau/settings/schema.ex` in some way the synthesis missed, the
  shared-file conflict-check clause would fire. Inspection of PR-1's
  and PR-2's owned-file list shows neither touches the schema —
  rebuttal does not materialise.
- **Backing (B):** `.claude/rules/factory-loop.md` "Parallel execution"
  and "The conflict check"; `.claude/rules/worktree-discipline.md`
  "Shared $HOME-namespace caches MUST be isolated per concurrent
  agent" (Burrito XDG_DATA_HOME isolation).

#### Falsification attempt for claim 2

- **Strategy:** counter-example construction over the union of PR-4's,
  PR-1's, and PR-2's declared file sets — try to find any file that
  appears in two PRs' modify-or-create lists.
- **Attempt:** Built the three sets from solution.md's What-changes
  bullets. PR-1: `{lib/tau/cli/extensions.ex, lib/tau/cli/mcp.ex}`.
  PR-2: `{lib/tau/session.ex, lib/tau/cli.ex}`. PR-4: `{lib/tau/providers/catalog.ex,
  test/tau/providers/catalog_test.exs, lib/tau/cli/init.ex,
  lib/tau/commands/builtin/logout.ex, lib/tau/settings/schema.ex,
  test/tau/cli/init_test.exs}`. Intersection pairwise: PR-1 ∩ PR-2 =
  ∅; PR-1 ∩ PR-4 = ∅; PR-2 ∩ PR-4 = ∅. Cross-checked grep for
  imports of `Tau.Providers.Catalog` in the PR-1/PR-2 target files —
  none (the module is new in PR-4 and the resolvers in PR-3, not PR-2,
  optionally consume it — see claim 6).
- **Outcome:** withstood — no shared file across the three concurrent
  PRs.
- **Action:** none.

### Claim 3: PR-2 and PR-3 MUST serialise because they both touch `lib/tau/cli.ex`

- **Claim (C):** "the run-loop and reflective-dispatch PRs both touch
  `lib/tau/cli.ex` and must serialize against each other to avoid
  mechanical merge conflicts" + "Land PR-2 first because its diff is
  larger and its rebase cost on a registry refactor is higher"
  (solution.md Recommendation lines 24–26 and Selected-from §Composition
  rationale, lines 61–64).
- **Grounds (G):** Verified by reading `lib/tau/cli.ex`. PR-2 targets
  `drain_run_loop/2` (lines 427–486) and `drain_session_end/2` (lines
  489–497). PR-3 targets `resolve_provider/1` (lines 792–814) and
  `resolve_coding_agent/1` (lines 781–790). The line-region distance is
  large (~290 lines apart) and the function definitions are stable. The
  factory-loop conflict check's clause 3 ("disjoint codepoints — they
  do not modify the same function") permits this case in principle —
  "the same file touched at clearly separate, stable regions MAY still
  parallelise" — but the solution.md author chose serialisation as the
  safer option.
- **Warrant (W):** The factory-loop conflict check sets the burden of
  proof on the conflict check itself ("when in doubt, serialize") —
  serialising at the same-file level is correctness-conservative even
  if not strictly mandated by the rule. The solution's choice to
  serialise rather than attempt parallel is the policy-conservative
  reading. Larger-diff-first as the rebase-cost minimiser is the
  ordering choice within the serialised pair.
- **Qualifier (Q):** Strict serialisation is sufficient (i.e. no merge
  conflict can arise); it is NOT strictly necessary by the conflict-check
  rule text. A parallel-edit attempt against well-separated regions
  would also be permitted, at the cost of a rebase on the second-merging
  PR.
- **Rebuttal (R):** If between gate authorship and merge a third party
  PR refactors `lib/tau/cli.ex` such that the line numbers cited
  (427–497, 781–814) shift, the "clearly separate, stable regions"
  proviso of the conflict check could be challenged. Today the file is
  818 lines and the regions are stable; this is a future-state risk,
  not a current falsifier.
- **Backing (B):** `.claude/rules/factory-loop.md` "The conflict check"
  clauses 2 ("disjoint files") and 3 ("disjoint codepoints");
  `lib/tau/cli.ex:427–497` and `lib/tau/cli.ex:781–814` for the actual
  line regions.

#### Falsification attempt for claim 3

- **Strategy:** edge-case enumeration — list the cases under which the
  "MUST serialise" statement is too strong, vs cases where the
  rationale ("avoid mechanical merge conflicts") is genuine.
- **Attempt:** (1) Two edits to the same file but to functions defined
  at well-separated line ranges and not sharing any helper — `git
  merge` typically resolves cleanly; only an `@spec` or `@doc` block
  edit at file head could collide. (2) Two edits that share a module
  attribute or `alias` clause at file head — would collide. PR-2's
  changes (`drain_run_loop` deletion, `classify_event/2` /
  `render_event/1` extraction) MAY add new `alias` clauses; PR-3's
  changes (`@provider_registry`, `@coding_agent_registry` module
  attributes) certainly add new module attributes at file head. Both
  PRs are likely to touch the file's head region (alias/attribute
  block), producing a real, even-if-trivial conflict on the second
  rebase.
- **Outcome:** partially falsified — the "MUST serialise" wording is
  stronger than the conflict-check rule itself ("when in doubt,
  serialise" is the rule's posture, not "MUST"). However, the
  rationale stands: both PRs are likely to touch the file's head
  region, so the conservative serialisation choice is well-founded.
- **Action:** narrow the qualifier in place — restate as "PR-2 and PR-3
  SHOULD serialise per the conflict-check's `when in doubt, serialise`
  posture; both PRs probably touch the file head (alias/module
  attribute block), so serialisation is conservative even though the
  conflict-check rule does not strictly mandate it for separate
  function regions." Ordering (PR-2 before PR-3, larger diff first) is
  unaffected. No revision to solution.md required — the narrower
  qualifier is recorded here for the implementer to honour.

### Claim 4: The four child ACs together satisfy the root AC's four clauses

- **Claim (C):** "The module-wide acceptance criterion is the
  conjunction of the four child ACs; no child weakens another, and no
  gap requires a new sub-problem" (solution.md Recommendation, lines
  37–38). Restated mechanically in Migration sketch (lines 195–203):
  - (a) crashed supervised callee → non-zero exit + stderr line (PR-1);
  - (b) headless run loop uses `stream_from`; unknown events log at
    `:debug` rather than being silently dropped (PR-2);
  - (c) `tau init` persists all selected providers under
    `"enabled_providers"`; init/logout Bedrock credential key derived
    from the same `Catalog` (PR-4);
  - (d) `resolve_provider/1` and `resolve_coding_agent/1` reject
    unknown strings without `Module.concat` / `String.to_atom` on user
    input (PR-3).
- **Grounds (G):** The root problem's acceptance criterion
  (`problem.md:97–104`) states four conjuncts: (a) crashed supervised
  callee surfaces as explicit error exit code rather than empty result;
  (b) headless run loop does not use raw `receive` and does not
  silently discard `Events.*`; (c) `tau init` persists all selected
  providers AND uses a consistent Bedrock credential key across init
  and logout; (d) `resolve_provider/1` and `resolve_coding_agent/1` do
  not create atoms from unconstrained user input. The four child
  solutions' ACs (visible in each `subproblems/*/solution.md`) target
  exactly conjuncts (a), (b), (c), (d) respectively. The mapping is
  bijective: each conjunct has exactly one owning child, and each child
  has exactly one root conjunct.
- **Warrant (W):** A logical conjunction (AC = a ∧ b ∧ c ∧ d) is
  satisfied iff every conjunct is satisfied. If each conjunct has an
  owning sub-solution that satisfies it (per its own
  withstood/partially-falsified validation), and the sub-solutions do
  not weaken each other in their interaction, then the conjunction
  holds. Decomposition along the concern (Hickey) axis — declared in
  `problem.md` "Decomposition strategy" — exhausts the named concerns,
  so the conjunction is closed.
- **Qualifier (Q):** Holds provided each child solution actually
  satisfies its individual AC at the implementer level. Child
  validation status (today): error-swallowing-rescues — withstood;
  run-loop-raw-receive — partially_falsified claim 3 (narrowed
  qualifier); wizard-data-fidelity — partially_falsified claim 4
  (narrowed); reflective-module-dispatch — partially_falsified claim 3
  (narrowed). No child is `falsified`. The narrowed qualifiers
  propagate up — see Outstanding doubts.
- **Rebuttal (R):** A gap could exist if (i) some defect named in the
  root problem statement falls outside all four conjuncts, or (ii) one
  child's fix accidentally re-introduces a defect another child's fix
  removes. Root problem's "Open questions" surfaces three additional
  concerns not closed here — async reload visibility (asynchronous
  cast in `Tau.Extensions.Loader.reload_all/0` and
  `Tau.MCP.Reconciler.reload/0`), top-level `main/1` safety net, and
  registry/catalog cross-derivation — but the root problem explicitly
  lists them as "Open questions" / out-of-scope for THIS solution.
  They are not part of the root AC. (ii) is checked by Composition
  rationale §No conflicts (solution.md lines 65–73); no child removes
  or contradicts another's contribution.
- **Backing (B):** `docs/problems/tau-cli/problem.md:97–104`
  (acceptance criterion text); each `subproblems/*/validation.md`
  frontmatter (child outcomes); solution.md "Composition rationale"
  §"No conflicts" lines 65–73.

#### Falsification attempt for claim 4

- **Strategy:** integration check — verify each root-AC conjunct maps
  to exactly one child AC, and that the mapped child satisfies it
  (per its validation.md outcome).
- **Attempt:** Built the conjunct→child map: (a) → error-swallowing-rescues
  (withstood), (b) → run-loop-raw-receive (partially falsified claim 3,
  qualifier narrowed to acknowledge that `stream_from/3`'s setup
  contract is silent on malformed topic — does NOT weaken AC (b)),
  (c) → wizard-data-fidelity (partially falsified claim 4, qualifier
  narrowed to acknowledge schema's `"providers"` key continues to
  coexist with new `"enabled_providers"` — does NOT weaken AC (c)),
  (d) → reflective-module-dispatch (partially falsified claim 3,
  qualifier narrowed re: `String.to_atom` distinction — does NOT
  weaken AC (d)). All four conjuncts have a passing-or-narrowed
  child. No child's narrowed qualifier weakens its conjunct.
- **Outcome:** withstood — the conjunction holds; no gap requires a new
  sub-problem within the root AC's stated scope.
- **Action:** none. (The three out-of-scope concerns in Open questions
  are correctly excluded.)

### Claim 5: No child solution contradicts another (no conflicts)

- **Claim (C):** "No child solution proposes a change that another
  contradicts. No child requires data or interfaces that another
  removes" (solution.md Composition rationale §No conflicts, lines
  65–67).
- **Grounds (G):** From the four child solutions' recommendations:
  error-swallowing-rescues edits `lib/tau/cli/extensions.ex` and
  `lib/tau/cli/mcp.ex` only; run-loop-raw-receive edits
  `lib/tau/session.ex` (additive `stream_from/3`) and
  `lib/tau/cli.ex` (drain functions only); wizard-data-fidelity adds
  `lib/tau/providers/catalog.ex`, edits `lib/tau/cli/init.ex`,
  `lib/tau/commands/builtin/logout.ex`, `lib/tau/settings/schema.ex`;
  reflective-module-dispatch edits `lib/tau/cli.ex` (resolver
  functions only). Pairwise file disjointness confirmed in Claim 2.
  Interface preservation: run-loop child explicitly preserves
  `Tau.Session.stream/2` (solution.md "What does not change" line
  154); wizard child does NOT remove the singular `"provider"` schema
  key (solution.md "What does not change" lines 177–179); reflective
  child does NOT touch `Tau.Providers.Catalog` (solution.md
  Composition rationale §"No conflicts", lines 68–73).
- **Warrant (W):** Two solutions cannot contradict if they are
  disjoint in code ownership AND each preserves the interfaces the
  other reads. Disjoint ownership is verified by file-set
  intersection (Claim 2); interface preservation is verified by each
  child's "What does not change" section. Both hold ⇒ no contradiction.
- **Qualifier (Q):** Holds for the proposed implementations as
  written. A late-stage implementer change that, e.g., chose to make
  reflective-module-dispatch consume `Tau.Providers.Catalog` (the
  cross-derivation flagged in solution.md Open questions §4) would
  introduce a real ordering dependency. The synthesis explicitly
  flags this as out-of-scope and recommends a future cleanup PR.
- **Rebuttal (R):** A subtle interface dependency could lurk in
  shared test scaffolding (e.g., a test helper used by two children's
  test suites) — but the children's owned test paths are also
  disjoint (PR-1: extensions/mcp tests; PR-2: classify_event +
  stream_from tests; PR-3: registry tests; PR-4: catalog +
  init_test). No shared test-support file is named.
- **Backing (B):** Each `subproblems/*/solution.md` "What does not
  change" section; solution.md "What does not change" (lines 152–183);
  solution.md "Open questions" §"Cross-derivation of registries"
  (lines 223–231).

#### Falsification attempt for claim 5

- **Strategy:** dependency check on shared symbols — search for any
  symbol that one child introduces and another consumes (excluding the
  intentional `Tau.Session.stream/2` additive case).
- **Attempt:** Read each child solution's What-changes. The only
  inter-child symbol coupling is the FLAGGED `Tau.Providers.Catalog`
  → `@provider_registry` cross-derivation, explicitly deferred to a
  future PR (Open questions §4). PR-3 as scoped does NOT consume
  `Catalog`; PR-4 as scoped does NOT consume `@provider_registry`.
  The wizard's new `"enabled_providers"` schema key is consumed by no
  other child. The run-loop child's new `Tau.Session.stream_from/3`
  is consumed only by `lib/tau/cli.ex`'s own drain replacement, not
  by any other child. No falsifying coupling found.
- **Outcome:** withstood — no inter-child contradiction or removed-
  interface dependency.
- **Action:** none.

### Claim 6: Ordering rationale is correct — PR-2 before PR-3 minimises rebase cost

- **Claim (C):** "Land PR-2 first because its diff is larger and its
  rebase cost on a registry refactor is higher" (solution.md
  Composition rationale, lines 63–64).
- **Grounds (G):** PR-2's diff per the child solution touches a
  whole-function deletion (`drain_run_loop/2` ≈ 60 lines,
  `drain_session_end/2` ≈ 10 lines), new helper functions
  (`classify_event/2`, `render_event/{1,2}`) and a rewritten
  `run_cmd/1` block. PR-3's diff per the child solution adds two
  module attributes (≈ 30 lines) and rewrites two small resolver
  function clauses (`resolve_provider/1`, `resolve_coding_agent/1`,
  ≈ 25 lines existing). PR-2's diff is substantially larger in line
  count and in the number of stable code regions it touches.
- **Warrant (W):** When two PRs serialise on the same file and one is
  larger, merging the larger one first reduces the EXPECTED cost of
  rebase: the second-mover only needs to rebase its smaller diff onto
  the larger settled state. The reverse (smaller first, larger
  second) forces the larger diff to rebase onto changes anywhere in
  the same file, including possible aliases/module attributes added
  by the smaller PR.
- **Qualifier (Q):** Heuristic, not absolute. If the smaller PR (PR-3)
  contained a refactor that fundamentally restructured the regions
  PR-2 touches, that would invert the calculus — but PR-3 only adds
  module attributes at file head and rewrites two stable resolver
  blocks, neither of which intersects PR-2's drain-function region.
- **Rebuttal (R):** If PR-2 added a new module attribute that
  conflicted with PR-3's `@provider_registry` / `@coding_agent_registry`
  at file head, the ordering choice would not matter — the conflict
  would surface to whichever PR rebases last. The risk is symmetric
  in that pathological case; the chosen ordering is still no worse
  than the alternative.
- **Backing (B):** Standard rebase-cost heuristic (no formal
  citation); both child solutions' What-changes line counts as
  observable proxy.

#### Falsification attempt for claim 6

- **Strategy:** counter-example construction — try to construct a
  scenario where PR-3 first would be cheaper.
- **Attempt:** Scenarios considered: (i) PR-3 includes a refactor of
  `run_cmd/1` that PR-2 must merge around — PR-3 child solution
  explicitly does NOT touch `run_cmd/1`. (ii) PR-3's module attribute
  block lives at the same file head where PR-2 might add aliases —
  this is a possible head-collision but it is symmetric (either
  ordering hits it). (iii) PR-2 deletions free up lines that PR-3
  would otherwise have to renumber around — but git's three-way
  merge doesn't care about line numbers per se, only about hunk
  context. No scenario produces a strict ordering preference for PR-3
  first.
- **Outcome:** withstood — PR-2-first ordering is at least as cheap
  as PR-3-first under all considered scenarios.
- **Action:** none.

## Cross-claim consistency

Six claims are mutually consistent. The serialisation/ordering claims
(3, 6) are about PRs that touch a shared file; they do not contradict
the parallelisation claim (2), which concerns PRs whose files are
disjoint. Claim 1 (PR-0 before PR-1) does not constrain PR-2, PR-3, or
PR-4 — PR-0 is doc-only, no test or code coupling. Claim 4 (conjunction
satisfaction) presupposes claim 5 (no inter-child conflict) and the
order of claims 1, 3, 6; consistency holds because the conjunction is
about end-state (post-PR-4) correctness, not about the intermediate
states after PR-0, PR-1, or PR-2.

One latent tension: solution.md Open questions §3 ("`main/1` top-level
safety net") explicitly names a gap NOT covered by any of the four
children, surfaced to the root "for triage rather than expand any PR's
scope". This is correctly excluded from the root AC (the root AC
mentions only the four conjuncts (a)–(d)), so claim 4's conjunction
holds. The gap is flagged in Outstanding doubts for the parent (if any
parent exists) and for the next planning pass.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | PR-0 must precede PR-1 (NN #7 amendment) | dependency check | withstood | none |
| 2 | PR-4 parallelisable with PR-1 and PR-2 post-PR-0 | counter-example construction | withstood | none |
| 3 | PR-2 and PR-3 MUST serialise on `lib/tau/cli.ex` | edge-case enumeration | partially falsified | narrow qualifier in place: SHOULD-serialise per "when in doubt" posture, not strict MUST |
| 4 | Four child ACs satisfy the root AC's conjunction | integration check | withstood | none |
| 5 | No child contradicts another | dependency check | withstood | none |
| 6 | PR-2 before PR-3 minimises rebase cost | counter-example construction | withstood | none |

## Revision required

No revision triggered. The single partial falsification (claim 3) is
addressed by narrowing the qualifier in this validation document; the
implementer of PR-2 and PR-3 should treat the serialisation as
"strongly recommended per conflict-check `when in doubt, serialise`"
rather than as a literal MUST. The ordering (PR-2 before PR-3) is
unchanged and the rationale (rebase cost) is independently validated
(claim 6 withstood).

- **Target file:** none
- **Revision kind:** n/a — qualifier narrowed in place
- **Rationale:** the narrowed qualifier accurately reflects the
  conflict-check rule's actual posture and the practical risk of
  file-head collision; the PR ordering and parallelisation plan are
  unaffected.

## Outstanding doubts

The parent-level validator (if any parent ever exists) should inherit
these inherited / surfaced doubts. Each child also surfaces partial
falsifications whose narrowed qualifiers propagate up through this
validation:

- **Child-inherited narrowed qualifiers** (from each
  `subproblems/*/validation.md`): (a) run-loop-raw-receive claim 3 —
  `Tau.Session.stream_from/3`'s setup contract is silent on malformed
  topic; (b) wizard-data-fidelity claim 4 — coexistence of
  `"providers"` (object) and `"enabled_providers"` (array) schema keys
  is intentional and reviewable but adds a future-deprecation surface;
  (c) reflective-module-dispatch claim 3 — `String.to_atom` distinction
  in the resolver tail clauses.
- **Async reload failures invisible** (root problem Open questions §2)
  — both `Tau.Extensions.Loader.reload_all/0` and
  `Tau.MCP.Reconciler.reload/0` are `GenServer.cast`; the operator
  cannot tell whether the reload succeeded. NOT part of the root AC;
  flagged here for the next planning pass.
- **`main/1` top-level safety net** (root problem Open questions §3)
  — handlers outside the four CLI commands named in the four
  sub-problems remain exposed to raw BEAM crash dumps. NOT part of
  the root AC; flagged for triage.
- **Cross-derivation of registries** (root problem Open questions §4)
  — `@provider_registry`, `Tau.Providers.Catalog`, and
  `Schema.@known_providers` are three compile-time representations of
  related provider sets that can drift on coverage. Deliberately
  deferred; flagged so the divergence is intentional and reviewable.
- **`stream_from/3` setup contract visibility** (root problem Open
  questions §5) — a malformed topic causes a silent empty drain.
  Flagged for the PR-2 implementer.
- **Singular `"provider"` key deprecation** (root problem Open
  questions §6) — retained for backwards compatibility; future PR may
  rename to `"default_provider"`.
- **Claim-3 file-head collision** (validator's own observation,
  above) — PR-2 and PR-3 are highly likely to both touch the
  alias/module-attribute block at the head of `lib/tau/cli.ex`, so
  the serialisation choice is conservative even though the
  conflict-check rule does not strictly mandate it.
