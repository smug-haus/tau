---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/6
revision_triggered: none
---

# Validation: Three orthogonal, file-disjoint corrections to `Tau.Settings` landed as independent commits

## Overview

The parent solution is a non-leaf synthesis of three already-validated
child solutions (`subproblems/merge-invariant-properties/`,
`subproblems/schema-exception-as-flow/`,
`subproblems/watcher-exit-catch/`). Its `selection_method` is
`synthesis`: the parent does NOT pick one child over others; it
arranges all three children's `What changes` sections into a single PR
with ordered, file-disjoint commits.

This validation deliberately scopes to the **cross-cutting integration
claims** the parent adds on top of the children: composition order,
file/test/dependency disjointness, conjunction of child changes
satisfying the parent acceptance criterion, preservation of existing
test behaviour, and the no-shared-support-module discipline. The
intra-child claims (e.g. "associativity is a sound invariant",
"`Process.monitor/1` is OTP-compliant for runtime crashes") have
already been adjudicated in the children's `validation.md` files;
their `partially_falsified` outcomes are inherited as outstanding
qualifiers on the parent claim that names them.

Seven claims are extracted. Falsification strategies used: dependency
check (claims 1, 3, 4, 7), counter-example construction (claims 2, 6),
integration check (claim 5). Outcome: six claims withstood; claim 6
partially falsified (the parent's "no behaviour change visible to
existing callers and zero regressions in the existing test suite" is
conditional on the implementer respecting an inherited qualifier from
the `merge-invariant-properties` child — idempotency was partially
falsified there, and the new property test MUST be written as
left-identity or scalar-restricted to avoid a spurious regression).
No revision required: the qualifier already lives in the child
validation and the parent solution explicitly inherits open questions.

---

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

---

### Claim 1: The three child solutions are file-disjoint at the production-code level (schema.ex, watcher.ex, loader.ex have no overlapping callsites)

- **Claim (C):** "each child names a distinct production file
  (`schema.ex`, `watcher.ex`, `loader.ex`) with no overlapping
  callsites" (parent solution.md, §Selected from / Composition
  rationale). Concretely, Commit 1 touches only `lib/tau/settings/schema.ex`;
  Commit 2 touches only `lib/tau/settings/watcher.ex`; Commit 3 touches
  only `lib/tau/settings/loader.ex` and adds one new test file. No
  production file is edited by more than one commit.
- **Grounds (G):** Per child solutions: schema-exception-as-flow
  solution.md:66-69 names only `lib/tau/settings/schema.ex` in its
  `What changes`; watcher-exit-catch solution.md:71-86 names only
  `lib/tau/settings/watcher.ex`; merge-invariant-properties
  solution.md:78-86 names only `lib/tau/settings/loader.ex` (plus a
  new test file at `test/tau/settings/loader_property_test.exs`).
  Cross-inspection of `lib/tau/settings/` shows the three modules
  share no module attributes, no `import`/`alias` lines into one
  another's namespace, and no callsites — `Schema` does not call
  `Loader.merge/2`, `Watcher` does not reference `Schema`, `Loader`
  does not reference `Watcher`. The only inter-module link is
  `Tau.Settings.Watcher.handle_info(:reload, …) -> Tau.Settings.Cache.reload/0`
  (`watcher.ex:99-102`), and `Cache` is out of scope for all three
  commits (parent solution.md §What does not change).
- **Warrant (W):** Two commits whose diff hunks edit disjoint files
  cannot conflict at the textual level — `git apply` and `git merge`
  are file-scoped at the hunk level. Beyond textual disjointness,
  disjointness at the call-graph level (no module calls another in the
  set) means commit-A's runtime behaviour does not enter commit-B's
  edited region, so semantic conflict is also ruled out.
- **Qualifier (Q):** Holds at HEAD as of validation time. Holds for
  the three production files named. The new test file
  `test/tau/settings/loader_property_test.exs` is new (no existing
  file to collide with), and the existing example test
  `test/tau/settings/loader_test.exs` is explicitly preserved
  untouched (parent solution.md §What does not change).
- **Rebuttal (R):** A concurrent unrelated PR that touches one of the
  three files would create a merge conflict, but that is a
  parallel-PR concern, not a property of the three-commit
  decomposition itself. The factory-loop's conflict check
  (`.claude/rules/factory-loop.md` §The conflict check, clause 2) is
  the appropriate guard for that scenario.
- **Backing (B):** Hickey, "Simple Made Easy" — disjoint concerns are
  composable iff the only shared surface is data, not call graph or
  shared mutable state. `.claude/rules/factory-loop.md` §Parallel
  execution / conflict check, clause 2: "Disjoint files — their
  expected changed-file sets do not overlap."

#### Falsification attempt for claim 1

- **Strategy:** Dependency check — grep for any production-code
  cross-reference among the three modules; grep for any indirect
  shared-state or shared-callsite surface they all touch.
- **Attempt:** Ran `grep -rn "Settings.Loader\|Settings.Schema\|Settings.Watcher"`
  over the three target files. Result: `loader.ex` references neither
  `Schema` nor `Watcher`; `schema.ex` references neither `Loader` nor
  `Watcher`; `watcher.ex` references `Tau.Settings.Cache` (out of
  scope) but neither `Loader` nor `Schema`. The only logical
  cross-reference is the `schema_test.exs:24-29` test that asserts
  the Loader's list-key set agrees with the Schema's array-type top-level
  keys — this is a test-level consistency check, NOT a runtime
  dependency, and it hard-codes the key strings rather than calling
  `Loader.list_keys/0` or `Loader.merge_rules/0`. The merge-invariant
  child's refactor preserves the same 7-key set (parent solution.md
  Commit 3, "covering the same 7 keys"), so this test continues to pass.
  No falsifying overlap found.
- **Outcome:** withstood — production files are disjoint at file,
  callsite, and call-graph levels.
- **Action:** none.

---

### Claim 2: Composition order (schema → watcher → loader) is recommended for blast-radius minimisation but is NOT load-bearing — the three commits could land in any order

- **Claim (C):** "The order schema → watcher → loader is chosen for
  blast-radius minimisation … The order is **not load-bearing** — the
  three commits are file-disjoint and could land in any order, but
  this order makes review easier and a mid-PR revert cleaner."
  (parent solution.md, §Migration sketch.)
- **Grounds (G):** From claim 1, the three commits are file-disjoint.
  No commit imports a symbol introduced by another commit
  (`@known_provider_names`, `watcher_mon`, `merge_rules/0` are all
  module-private to their respective files; the only exported new
  function is `Loader.merge_rules/0`, which no other commit calls).
  The acceptance criterion is a logical conjunction (parent
  problem.md §Acceptance criterion: "(a) eliminate the `catch :exit`
  site, (b) add property tests for `Loader.merge/2`, (c) replace the
  rescue-based control flow") — conjunctions are order-invariant.
- **Warrant (W):** A set of commits is order-independent iff every
  commit's pre-conditions are independent of every other commit's
  post-conditions. For these three commits: the schema commit's
  pre-condition is `@known_providers` (already in the file); the
  watcher commit's pre-condition is the existing `FileSystem.start_link/1`
  surface (unchanged across the PR); the loader commit's
  pre-conditions are `merge_value/3` and the existing example tests
  (untouched by the other commits). No commit creates a symbol the
  others read; no commit modifies state the others observe.
- **Qualifier (Q):** Holds as a property of the three commits' diffs.
  Holds when the PR has access to the test toolchain at the loader
  commit (so `mix test --only property` runs); the toolchain is
  available throughout (claim 7).
- **Rebuttal (R):** "Not load-bearing" understates one practical
  consideration: if the loader commit lands first and its new
  property test reveals a latent bug in `merge_value/3`, the bisect
  blame would land on the loader commit even though the bug pre-dates
  the PR. This is a workflow nuisance, not a correctness issue, and
  does not falsify the order-independence claim.
- **Backing (B):** Hickey, "Simple Made Easy" — disjoint concerns
  imply order-independent composition; OTP NN #8 ("pure functions are
  the default") — pure-function changes have no temporal coupling.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — try to construct an
  order in which one of the three commits cannot land on top of HEAD
  without one of the others having landed first.
- **Attempt:** Three orderings checked.
  - **loader → watcher → schema.** Loader commit lands on HEAD: edits
    only `loader.ex`, adds `test/tau/settings/loader_property_test.exs`.
    `mix test` passes (existing example tests preserved; new property
    test passes under the implementer's qualifier — see claim 6).
    Watcher commit lands next: edits only `watcher.ex`. `mix test`
    passes (existing watcher tests preserved; the existing degraded-mode
    test exercises the `dirs: []` short-circuit, which is unaffected by
    the `try` removal). Schema commit lands last: edits only
    `schema.ex`. `mix test` passes (existing schema tests preserved per
    child validation claim 3). No commit fails to land for ordering
    reasons.
  - **watcher → loader → schema** and **schema → loader → watcher.**
    Same outcome by symmetry; each commit's pre-conditions hold on
    HEAD regardless of which siblings have landed.
  - Counter-example sought: a symbol referenced in one commit and
    defined in another. None found — `merge_rules/0` is consumed only
    by the new property test file (which lands in the same commit);
    `@known_provider_names` is consumed only inside `to_known_module/1`
    (same commit); `watcher_mon` is only in `watcher.ex` (same commit).
- **Outcome:** withstood — no order falsifies the claim.
- **Action:** none.

---

### Claim 3: The three commits' production changes are file-disjoint from each commit's TEST changes (no shared `test/support/` module is introduced)

- **Claim (C):** "no shared support modules (the merge-invariant child
  explicitly rejects a shared `test/support/settings_generators.ex`)"
  (parent solution.md, §Selected from / Composition rationale); and
  "No shared `test/support/settings_generators.ex` module is added"
  (parent solution.md, §What does not change).
- **Grounds (G):** `ls /home/brentw/src/tau/test/support/` returns:
  `blocking_tool.ex`, `capturing_provider.ex`, `extensions`,
  `factory`, `multi_fixture_provider.ex`, `session_helper.ex`,
  `stub_embedder.ex`, `tui_pty_helper.ex`. No `settings_generators.ex`
  exists today. The merge-invariant child's solution.md:111 states
  the `coherent_triple/0` generator lives in the test module, not in
  shared support. The schema child's solution.md:73-78 names no
  support-module changes. The watcher child's solution.md:99-110
  names no support-module changes either; the `{:DOWN, …}` test
  hint (`send/2` synthetic message) is also in-module.
- **Warrant (W):** Test-support modules are a parallel-collision
  surface under the factory-loop's conflict check
  (`.claude/rules/factory-loop.md` §The conflict check, clause 2:
  "shared `test/support` collision surface"). Avoiding new shared
  support files keeps the three commits' test additions disjoint
  with each other AND with concurrent unrelated PRs.
- **Qualifier (Q):** Holds for the explicit support-module question.
  Does NOT extend to claim "no other test-side coupling exists" —
  see claim 4 for the indirect coupling through existing schema/loader
  test interaction (the `schema_test.exs:24-29` assertion about
  Loader's list-key set).
- **Rebuttal (R):** If the loader commit's implementer decides
  mid-implementation that `coherent_triple/0` would be cleaner as a
  shared generator (e.g. because other test files want to reuse it
  later), the discipline could slip. The merge-invariant child's
  rationale (solution.md:111, "shared module adds naming/placement
  overhead with no current payoff") is the codified guardrail; an
  implementer-side override would be a deviation from the validated
  solution that should re-enter validation.
- **Backing (B):** `.claude/rules/factory-loop.md` §The conflict
  check, clause 2 (shared test-support is a collision surface);
  merge-invariant-properties solution.md:111 (explicit rejection of
  shared support module); merge-invariant-properties solution.md:25-27
  (rationale: "self-contained and sufficient").

#### Falsification attempt for claim 3

- **Strategy:** Dependency check — list every new test artefact across
  the three commits and verify none is in `test/support/` or
  references a new shared helper.
- **Attempt:** Enumerated new test artefacts:
  - Commit 1 (Schema): zero new test files; existing
    `test/tau/settings/schema_test.exs` covers the changed path
    (schema child validation claim 3, withstood).
  - Commit 2 (Watcher): zero new test files; existing
    `test/tau/settings/watcher_test.exs` covers the `dirs: []` path;
    the `{:DOWN, ...}` handler test is filed as a follow-up
    (watcher child solution §Open questions and §Migration sketch).
  - Commit 3 (Loader): one new test file at
    `test/tau/settings/loader_property_test.exs`; per child solution.md:111
    no shared support module; `coherent_triple/0` is in-module.
  None of the three commits adds anything under `test/support/`.
- **Outcome:** withstood.
- **Action:** none.

---

### Claim 4: The conjunction of the three children's `What changes` sections yields the parent acceptance criterion (a)+(b)+(c) without breaking any currently-passing test

- **Claim (C):** "applying all three children's `What changes`
  sections yields the parent acceptance criterion as a logical
  conjunction — (a) the `catch :exit` site in Watcher is eliminated,
  (b) `Loader.merge/2` gains property coverage, and (c) Schema's
  rescue-based control flow is replaced with explicit conditional
  logic, all without breaking any currently-passing test." (parent
  solution.md, §Selected from / Composition rationale.)
- **Grounds (G):** Parent problem.md §Acceptance criterion enumerates
  exactly (a), (b), (c). Mapping to children:
  - (a) "eliminate the `catch :exit` site" ← watcher-exit-catch
    solution.md:72-74 "Delete the `try/rescue/catch` block …";
    watcher child validation claim 1, withstood.
  - (b) "add property tests for `Loader.merge/2`" ← merge-invariant
    solution.md:87-101 "test/tau/settings/loader_property_test.exs (new
    file): … property blocks"; merge-invariant child validation claims
    1, 2, 3, 7, all withstood; claims 4, 5 partially falsified with
    qualifier narrowing handled at implementation time.
  - (c) "replace the rescue-based control flow in `to_known_module/1`
    with explicit conditional logic" ← schema-exception-as-flow
    solution.md:66-69 "replace the binary clause body … with `case
    Map.fetch(@known_provider_names, str) …`"; schema child validation
    claim 1, withstood.
  "without breaking any currently-passing test" is asserted by each
  child individually (schema child validation claim 3, withstood;
  watcher child validation claim 2, withstood; merge-invariant child
  preserves `loader_test.exs` untouched per solution.md:104-106).
- **Warrant (W):** Conjunction-by-composition: if A, B, C are
  independent claims each satisfied by an isolated change, and the
  three changes are file-disjoint and callgraph-disjoint (claim 1),
  then applying all three satisfies A ∧ B ∧ C. The "no broken tests"
  property is also conjunctively preserved iff each child's change
  preserves the tests *it touches*; file-disjointness ensures no
  child touches another's tests.
- **Qualifier (Q):** Holds when the implementer respects the
  qualifier narrowing flagged by the merge-invariant child's
  validation (claim 5 there: idempotency must be reframed as
  left-identity or restricted to scalar-only maps). If the implementer
  writes the property test as unqualified idempotency, it will fail
  on non-empty list-key inputs and falsify the "no broken tests"
  conjunct — see claim 6 below. Also holds when the implementer
  respects the watcher child's restart-strategy open question (claim
  5 there): the supervision tree currently runs Watcher under
  `:rest_for_one` with the OTP-default `:permanent` restart, so a
  thrash-on-`FileSystem`-startup-exit is a live possibility — see
  outstanding doubts.
- **Rebuttal (R):** A child's `What changes` claim being individually
  validated does not guarantee the union is correct if the children
  inadvertently share an integration surface this validation missed.
  Claim 1's grep-based check rules out the most obvious surfaces
  (file overlap, callsite overlap, module attribute overlap), but
  cannot exclude every conceivable indirect coupling (e.g. shared
  compile-time atom-table interactions, supervision tree restart
  cascading). The most plausible residual: `:rest_for_one` means a
  Watcher init failure restarts every child after it — including
  `Tau.Memory.Supervisor` and `Tau.Sessions.Supervisor` — which is
  the existing behaviour with or without the watcher change, but is
  now more directly triggerable by a `FileSystem.start_link/1` exit
  (vs. swallowed by `catch :exit` today).
- **Backing (B):** Parent problem.md §Acceptance criterion (verbatim
  conjunction); `lib/tau/application.ex:60-93` (the `:rest_for_one`
  supervision tree with `Tau.Settings.Watcher` at position 4 of 16,
  permanent restart); the three child validations (each with
  falsification_attempted: true; partial falsifications already
  documented).

#### Falsification attempt for claim 4

- **Strategy:** Dependency check — verify each clause of the
  acceptance criterion is mechanically delivered by exactly one
  child, and no clause is delivered by more than one (so no
  redundancy obscures a gap).
- **Attempt:** Mapped each acceptance-criterion clause to its source
  child and to the child's `What changes` line numbers (above). All
  three map 1-to-1. Inspected the parent `What changes` section to
  verify it is the *union*, not a *subset*: parent solution.md
  lines 63-112 itemise each child's commit-1, commit-2, commit-3
  content verbatim (allowing for the parent's commit-ordering
  framing). Verified no clause is omitted — e.g. `emit_degraded_telemetry/1`
  extraction (watcher child §What changes) appears in parent's
  Commit 2 bullet 4 (parent solution.md:90-93). Inspected for parent
  additions beyond the children — none found that change behaviour
  (the only parent additions are ordering and PR-shape commentary).
- **Outcome:** withstood — the parent's `What changes` is exactly the
  union of the three children's, and each acceptance-criterion clause
  is delivered.
- **Action:** none.

---

### Claim 5: There is no interface between the children's recommendations and no conflict to resolve at synthesis time

- **Claim (C):** "There is no interface between the children's
  recommendations and no conflict to resolve." (parent solution.md,
  §Selected from / Composition rationale.)
- **Grounds (G):** From claim 1: file-, callsite-, and callgraph-
  disjoint at the production level. From claim 3: no shared
  test-support module. From claim 4: each child delivers exactly one
  clause of the acceptance criterion with no overlap. The children's
  prose contracts (the `@moduledoc` they each propose to add or
  modify) are scoped to their own modules. No child requires the
  others' artefacts to compile, to run its tests, or to satisfy its
  own acceptance criterion.
- **Warrant (W):** An "interface" between two design changes exists
  iff one change must observe, depend on, or assume the other's
  artefact. Negation: if you can apply change A to HEAD, then apply
  change B to HEAD independently, and the union of the two diffs is
  the same as the sequential application, there is no interface.
  Disjoint-file diffs with disjoint callgraph footprints satisfy
  this property by construction.
- **Qualifier (Q):** Holds at design level. At PR mechanics level,
  the three commits share the same PR description and the same
  reviewer pool, which is a *coordination* surface but not an
  *interface*. The PR description (parent solution.md §Migration
  sketch, step 4) explicitly cites the parent problem.md acceptance
  criterion, satisfying the documentation-level integration.
- **Rebuttal (R):** If the PR opted to land as three single-commit
  PRs (per the open question in parent solution.md §Open questions,
  parent-level "PR shape"), the three PRs would share no PR-level
  interface either, and the conflict-check (factory-loop §The
  conflict check) confirms parallelisability. So even the
  coordination surface is dissolvable; nothing forces synthesis.
- **Backing (B):** Hickey, "Simple Made Easy" — interface-free
  composition is the defining property of decomplecting; parent
  problem.md §Decomposition strategy: "they share no code paths and
  can be analysed and remediated independently."

#### Falsification attempt for claim 5

- **Strategy:** Integration check — try to construct an integration
  test the parent would need to add that depends on artefacts from
  more than one child.
- **Attempt:** Considered three candidate integration boundaries:
  (i) settings cascade end-to-end (Loader → Watcher → Cache) — this
  pre-exists in `test/tau/settings/cache_pubsub_test.exs` and is
  unaffected by any of the three commits (no commit changes
  `Cache.publish/reload` or the cascade contract); (ii) provider
  resolution end-to-end (Schema → `resolve_fallback_chains/1` →
  Loader merge of `providers.fallback_chains`) — `Loader.merge/2`
  treats the providers block as a map (deep-merged), and Schema's
  `resolve_fallback_chains/1` consumes the post-merge structure; the
  Schema change is to a *private* helper (`to_known_module/1`), not
  to the public `resolve_fallback_chains/1` contract, so no new
  integration test is required (schema child validation claim 6,
  public API unchanged, withstood); (iii) Watcher startup affecting
  Loader behaviour — no path: the Watcher triggers `Cache.reload`,
  which calls `Loader.load/1`, but neither the Watcher commit nor
  the Loader commit changes `Loader.load/1` itself (merge-invariant
  child solution.md:107 "out of scope"). No integration test crosses
  two of the three commits; no integration interface exists.
- **Outcome:** withstood.
- **Action:** none.

---

### Claim 6: No behaviour change is visible to existing callers, and zero regressions occur in the existing test suite

- **Claim (C):** "no behaviour change visible to any existing caller
  and zero regressions in the existing test suite" (parent
  solution.md §Recommendation, final sentence; restated in §What
  does not change).
- **Grounds (G):** Per-child substantiation:
  - Schema: child validation claim 3 (existing tests pass without
    modification) and claim 6 (public API unchanged), both
    withstood. Public callers see identical `{:ok, mod} | {:error,
    {:unknown_provider, str}}` returns from `resolve_fallback_chains/1`.
  - Watcher: child validation claim 2 (legitimate `{:error, reason}`
    still pattern-matched; degraded-mode telemetry still fires) and
    the existing `watcher_test.exs` tests use the `dirs: []`
    short-circuit, which fires before `FileSystem.start_link/1` is
    reached — so the `try`-block removal is invisible to that test.
  - Loader: parent solution.md §What does not change line 130-131
    "`test/tau/settings/loader_test.exs` — the four existing example
    tests remain untouched"; `Loader.list_keys/0` (private)
    behaviour preserved when derived from `@merge_rules` per
    merge-invariant child solution.md:108-109.
- **Warrant (W):** "No behaviour change visible to existing callers"
  is a stronger claim than "existing tests pass" only if existing
  tests fully exercise the observable surface; here both claims hold
  by the same evidence (each child's "What does not change" plus the
  validated public-API stability).
- **Qualifier (Q):** Holds when the merge-invariant child's
  implementation respects the validated qualifier narrowing on
  idempotency (child validation claim 5: idempotency must be reframed
  as left-identity `merge(%{}, a) == a` OR restricted to scalar-only
  maps). If the implementer writes the new property test as
  unqualified `forall a, merge(a, a) == a`, the property will FAIL
  for any test run that includes `:hooks` or other concat keys with
  non-empty lists — and the full-suite `mix test` would then fail,
  falsifying the "zero regressions" conjunct. Holds also when
  Watcher's restart strategy is confirmed appropriate (child
  validation claim 5: `:permanent` under `:rest_for_one` could
  thrash on `FileSystem` startup exits).
- **Rebuttal (R):** The "zero regressions" framing in the parent is
  unqualified, but the merge-invariant child's `validation.md`
  records the qualifier explicitly; the parent inherits that
  qualifier (per `validate.md` §Outputs that feed parent: "The
  parent therefore inherits any Outstanding doubts and
  partially-falsified qualifiers — they should appear in the
  parent's claim Qualifier fields"). The parent's open-questions
  list (solution.md:174-212) does enumerate inherited child opens
  including the loader idempotency open, so the qualifier is
  documented even if the headline claim text is unqualified.
- **Backing (B):** schema child validation.md claims 3, 6;
  watcher child validation.md claim 2; merge-invariant child
  validation.md claims 4, 5 (the qualifier source);
  validate.md §Outputs that feed parent (the inheritance rule).

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — try to construct an
  implementation that follows the parent solution.md's `What changes`
  literally and produces a failing `mix test`.
- **Attempt:** Constructed the following implementer trajectory
  consistent with parent solution.md but at odds with the inherited
  qualifier: the implementer reads parent solution.md §What changes,
  Commit 3, bullet 2 — which lists "associativity, idempotency,
  scalar override" as the three algebraic-law properties (parent
  solution.md:110) — and writes the idempotency property literally
  as `forall a, merge(a, a) == a` using the same coherent generator
  used for associativity. The generator produces maps that include
  the list-keys (`:hooks`, `:extensions`, etc.) with non-empty list
  values to make the associativity property non-vacuous. The
  idempotency check then FAILS on the first generated input with a
  non-empty list at a concat key (`merge(%{hooks: [%{e: 1}]}, %{hooks:
  [%{e: 1}]}) == %{hooks: [%{e: 1}, %{e: 1}]}` ≠ original) — see
  merge-invariant child validation.md §Falsification attempt for
  claim 5. `mix test` then fails. The parent's "zero regressions"
  conjunct is falsified for this trajectory.
- **Outcome:** partially falsified — the unqualified "zero
  regressions" headline is false for the worst-case literal reading
  of parent solution.md. The narrowed survivor: "zero regressions in
  the existing test suite when the implementer follows the
  merge-invariant child's validation.md narrowed-qualifier guidance
  (left-identity OR scalar-restricted idempotency)." The narrowed
  claim is consistent with the child validation and with parent
  solution.md §Open questions inheritance.
- **Action:** narrow Qualifier in place (done above). No revision to
  parent solution.md is triggered because: (a) the parent's open
  questions inherit from the child; (b) the qualifier is already
  recorded in `subproblems/merge-invariant-properties/validation.md`;
  (c) the implementer's brief will surface the child validation.md
  alongside the parent's. The corrective action is at implementation
  time, not at parent design time — consistent with the validate.md
  §Outputs that feed parent inheritance contract.

---

### Claim 7: `mix.exs` requires no changes; `ExUnitProperties` / `StreamData` are already available; `mix compile --warnings-as-errors` and `mix credo --strict` continue to pass

- **Claim (C):** "`mix.exs` — `ExUnitProperties` and `StreamData` are
  already available; no new dependency" (parent solution.md, §What
  does not change line 134-135). Implicit in the Migration sketch
  §4: `mix compile --warnings-as-errors` and `mix credo --strict`
  pass on the merged tree.
- **Grounds (G):** `mix.exs:129` — `{:stream_data, "~> 1.1",
  only: [:test, :dev]}`. `mix.lock` line 63 — `stream_data 1.3.0`
  resolved. Existing test files use `ExUnitProperties` and
  `StreamData.fixed_map/1` / `StreamData.tuple/1` —
  `test/tau/providers/rate_limiter/token_bucket_property_test.exs:23`,
  `test/tau/circuit_breaker/state_property_test.exs:45`,
  `test/tau/providers/shared/tool_spec_test.exs:160,168,177` (cited
  in merge-invariant child validation claim 3, withstood). For
  `--warnings-as-errors`: schema child validation claim 5 (withstood)
  covers the Schema commit; the Watcher commit introduces only
  standard OTP patterns (`Process.monitor/1`, `handle_info/2`); the
  Loader commit's `@merge_rules` map attribute is a literal map of
  `atom() => atom()` with `Map.get/3` dispatch — all standard
  patterns under the Elixir compiler.
- **Warrant (W):** A dependency declared in `mix.exs` and present in
  `mix.lock` is available at test time. `--warnings-as-errors`
  passes if no new pattern-match, unused-variable, or type-mismatch
  warning is introduced; the three commits use only standard stdlib
  patterns with exhaustive case branches.
- **Qualifier (Q):** Holds at the locked toolchain version (Elixir
  1.18.1 / OTP 27.2 per `.tool-versions`) and `stream_data 1.3.0`
  per `mix.lock`. Holds for the three commits as specified; does
  NOT extend to implementer additions beyond the validated spec
  (e.g. if the implementer adds an unused alias).
- **Rebuttal (R):** `mix credo --strict` could flag style issues
  (e.g. function complexity, alias ordering) that the validation
  cannot mentally simulate without running the tool. The schema
  change is a 4-line substitution; the watcher change is ~15 lines
  with one new helper function; the loader change is a literal
  attribute and a derived accessor — none of these are likely to
  cross Credo's strict thresholds, but unrunnable confidence is
  weaker than executed confidence.
- **Backing (B):** `mix.exs:129`; `mix.lock` line 63; `.tool-versions`;
  schema child validation.md claim 5 (compile-warnings-as-errors,
  withstood); merge-invariant child validation.md claim 3
  (dependencies confirmed at locked versions, withstood).

#### Falsification attempt for claim 7

- **Strategy:** Dependency check — verify the cited line numbers and
  versions; cross-check against the three commits' diff content.
- **Attempt:** Verified `mix.exs:129` reads
  `{:stream_data, "~> 1.1", only: [:test, :dev]}` ✓. Verified
  `mix.lock` line 63 resolves to `stream_data 1.3.0` ✓. Verified
  `test/tau/circuit_breaker/state_property_test.exs:45` uses
  `StreamData.tuple/1` ✓ (cited in merge-invariant child validation,
  by extension applicable here). Cross-checked the three commits'
  added symbols (`@known_provider_names`, `Process.monitor/1`,
  `watcher_mon`, `@merge_rules`, `merge_rules/0`,
  `emit_degraded_telemetry/1`): all use stdlib / OTP primitives
  with type-stable signatures. No new dependency required.
- **Outcome:** withstood.
- **Action:** none.

---

## Cross-claim consistency

The seven claims partition cleanly:

- **Claims 1, 2, 3** establish structural disjointness (file,
  ordering, test-support). They are mutually reinforcing: file
  disjointness (1) entails order independence (2), and the
  no-shared-test-support discipline (3) preserves the same property
  for test artefacts.
- **Claims 4, 5** establish that the disjoint pieces compose to the
  acceptance criterion without an integration surface. They are
  consistent with 1-3: composition without interface is possible
  precisely because of structural disjointness.
- **Claim 6** is the "no regression" headline; it is partially
  falsified under a worst-case implementer reading and inherits the
  merge-invariant child's qualifier narrowing. Consistent with
  claims 1-5 once the qualifier is applied: the partial falsification
  does not invalidate disjointness, order independence, or
  composition correctness — it only flags an implementer-side
  discipline requirement.
- **Claim 7** is the toolchain availability check; independent of
  the others and consistent with all of them.

One potential tension considered: claim 2 (order independence) and
the parent solution.md's explicit ordering recommendation
(schema → watcher → loader). The parent text reconciles this
explicitly ("The order is not load-bearing … but this order makes
review easier and a mid-PR revert cleaner") — order is a workflow
preference, not a correctness constraint. Consistent.

A second potential tension: claim 6 (no regressions) and the inherited
merge-invariant qualifier (idempotency partially falsified). The
parent solution.md's "What does not change" line 134-135 inherits
no-mix.exs-change cleanly but its `Recommendation` text uses the
unqualified "zero regressions" framing. The validation here narrows
the qualifier per `validate.md` §Outputs that feed parent; no
revision required because the child validation already records the
qualifier and the parent's open-questions list inherits the open
explicitly.

No unresolvable tensions.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Three children file-/callsite-/callgraph-disjoint | Dependency check | Withstood | None |
| 2 | Composition order recommended but not load-bearing | Counter-example construction | Withstood | None |
| 3 | No shared `test/support/` module introduced | Dependency check | Withstood | None |
| 4 | Conjunction of children's changes yields parent AC (a)+(b)+(c) | Dependency check | Withstood | None |
| 5 | No interface between children; no conflict to resolve | Integration check | Withstood | None |
| 6 | No behaviour change to existing callers; zero regressions | Counter-example construction | Partially falsified | Narrow qualifier — implementer must respect merge-invariant child's left-identity-or-scalar-restricted idempotency framing |
| 7 | `mix.exs` unchanged; toolchain unchanged; compile clean | Dependency check | Withstood | None |

---

## Revision required

No revision to `solution.md` or `problem.md` is triggered. The
partial falsification of claim 6 narrows the qualifier in place:

- **Target file:** (none — the qualifier is already recorded in
  `subproblems/merge-invariant-properties/validation.md` §Claims 4-5
  and inherited per `validate.md` §Outputs that feed parent.)
- **Revision kind:** qualifier narrowing (in place); no file edit
  required.
- **Rationale:** The merge-invariant child's validation.md already
  documents the idempotency narrowing (left-identity or
  scalar-restricted). The parent solution.md §Open questions list
  inherits open questions from the children explicitly. The
  implementer's brief at PR time will surface both the parent
  solution.md and the child validation.md; that is the appropriate
  locus for the implementer to apply the narrowed framing. Editing
  the parent solution.md to repeat the qualifier would duplicate
  the child's contract without adding information.

---

## Outstanding doubts

These are inherited from the children per `validate.md` §Outputs
that feed parent. They are properly the parent's qualifier surface,
not blocking issues:

1. **Idempotency framing (from merge-invariant child claims 4-5).**
   The new property test must be written as left-identity
   (`merge(%{}, a) == a`) OR with a generator restricted to maps
   with no non-empty concat-key list values. The parent solution.md
   §What changes line 110 lists "associativity, idempotency, scalar
   override" without this qualifier; the implementer must respect
   the qualifier from the child validation.md or the property test
   will fail and falsify claim 6.

2. **Watcher restart strategy (from watcher child claim 5).** The
   Watcher is supervised under `:rest_for_one` with the OTP-default
   `:permanent` restart (`lib/tau/application.ex:60-93`). Removing
   `catch :exit` means a `FileSystem.start_link/1` exit during
   `init/1` now propagates to the supervisor, which will restart
   the Watcher up to the max-restart threshold. Under `:rest_for_one`,
   a Watcher restart also restarts every child after it
   (`Tau.Memory.Supervisor`, `Tau.Permissions.RuleSet`, ...,
   `Tau.Sessions.Supervisor` — 12 children). The implementer should
   confirm (a) whether the Watcher's restart option should be
   changed to `:transient` or `:temporary`, and (b) whether the
   `:rest_for_one` cascade is the desired behaviour for a degraded
   filesystem watch. The parent solution.md §Open questions inherits
   this; the validation flags it as a live risk because the existing
   `try`/`catch :exit` was silently absorbing this scenario.

3. **`file_system` library `start_link` contract (from watcher child
   open question).** The `rescue e` arm is removed in the hybrid;
   the child judges this acceptable based on the library's
   documented return-value+exit contract. Not verified against the
   pinned version in `mix.lock`. A two-line grep of the pinned
   `file_system` source would close this doubt.

4. **External provider-name documentation (from schema child claim 4
   partial falsification).** The `@known_provider_names` map uses
   the `"Tau.Providers.X"` format. If external user-facing
   documentation (rendered README on Codeberg/GitHub) uses
   short-form names (e.g. `"Anthropic"`), users following that doc
   would silently get `{:error, {:unknown_provider, "Anthropic"}}`.
   This is the same behaviour as the current rescue-based
   implementation, so it is not a regression — but the
   key-derivation convention becomes load-bearing and should be
   commented in the attribute definition (covered in parent
   solution.md §Open questions inherited from the schema child).

5. **`{:DOWN, …}` handler test coverage (from watcher child open
   question).** Not required by the acceptance criterion; the
   watcher child recommends a follow-up issue. The parent solution.md
   inherits the open. The test can be written as a `send/2`-driven
   unit test in a later PR.

6. **PR shape (parent-level open).** Single PR with three commits
   vs. three single-commit PRs. The factory-loop conflict check
   confirms parallelisability either way. No correctness implication;
   workflow choice.
