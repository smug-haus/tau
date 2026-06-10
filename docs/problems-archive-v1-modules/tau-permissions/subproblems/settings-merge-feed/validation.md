---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: withstood
revision_triggered: none
---

# Validation: Separate property test file loader_property_test.exs

## Overview

The solution proposes adding a single new test file —
`test/tau/settings/loader_property_test.exs` — containing three StreamData
properties (concat C1, identity C2, absent-key C3) covering the
`Tau.Settings.Loader.merge/2` permissions-array contract. No production
code changes. The acceptance criterion in `problem.md` mandates at least
two properties (concat + identity); the solution provides three. Five
distinct propositions are extracted and run through full Toulmin with an
explicit falsification strategy per claim. Outcome: all five **withstood**.
No revision triggered.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that participants
generated highly variable Toulmin structures from the same content
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
Each field below is filled independently with cited content; none is
merged or elided.

### Claim 1: The new file contains three properties — prefix-then-suffix concat (C1), right identity (C2), absent-key-as-empty-list (C3)

- **Claim (C):** "Add `test/tau/settings/loader_property_test.exs` … containing
  three properties: the prefix-then-suffix concatenation invariant for all
  three permissions keys simultaneously (C1), the right-identity invariant
  `merge(x, %{}) == x` (C2), and the absent-key-as-empty-list invariant (C3)."
  (solution.md §Recommendation, lines 14–20.)
- **Grounds (G):** Proposal 2's sketch (`proposals/proposal-2.md` lines
  40–105) literally defines three `property "..."` blocks named
  "prefix-then-suffix concat", "merge(x, %{}) == x", and "absent
  permissions key … treated as empty list, not nil". The solution
  explicitly cites Proposal 2 as the synthesised source
  (`synthesised_from: [proposals/proposal-2.md]`, frontmatter line 7) and
  the recommendation maps token-for-token to the three blocks.
- **Warrant (W):** A solution that selects exactly one proposal and is
  marked `selection_method: single` (frontmatter line 8) inherits the
  proposal's concrete sketch as its specification; what the proposal
  sketches is what gets implemented.
- **Qualifier (Q):** Holds as long as the implementer follows Proposal 2's
  sketch (lines 40–105) without subsetting. The solution does not loosen
  the three-property contract anywhere in §What changes (lines 55–60).
- **Rebuttal (R):** An implementer could legitimately ship only two
  properties and still satisfy the acceptance criterion in `problem.md`
  (which requires "at least two"). In that case the solution's three-
  property claim would over-promise relative to what the implementer
  delivered — but that is an implementation-fidelity question, not a
  solution-design defect.
- **Backing (B):** Polya-audit selection-method semantics
  (`templates/solution.md` frontmatter: `selection_method: single` ⇒
  recommendation is the chosen proposal's sketch). Proposal 2 lines 40–105.

#### Falsification attempt for claim 1

- **Strategy:** Counter-example construction — try to find a property in
  the claim that is absent from the proposal's sketch, or a property in
  the sketch that is absent from the claim.
- **Attempt:** Enumerated the three `property` blocks in proposal-2.md
  (lines 69, 84, 90); matched each against the three named C1/C2/C3
  invariants in the solution's Recommendation. C1 ↔ "prefix-then-suffix
  concat for each key" (proposal-2.md:69). C2 ↔ "merge(x, %{}) == x"
  (proposal-2.md:84). C3 ↔ "absent permissions key in layer b treated as
  empty list, not nil" (proposal-2.md:90). All three present in both.
- **Outcome:** withstood.
- **Action:** none.

### Claim 2: The new file uses `fixed_map/1`-based named local generator helpers

- **Claim (C):** "Use `fixed_map/1`-based named generator helpers local
  to the file." (solution.md §Recommendation, line 19). Reinforced in
  §What changes: "named local generator helpers (`permission_list/0`,
  `permissions_layer/0`, `settings_with_permissions/0`)" (lines 57–59).
- **Grounds (G):** Proposal 2 sketch defines `permission_list/0`
  (proposal-2.md:53), `permissions_layer/0` using `fixed_map/1`
  (proposal-2.md:55–61), `settings_with_permissions/0` using
  `fixed_map/1` (proposal-2.md:63–65). `StreamData.fixed_map/1` exists
  and accepts a map of generators (proposal-2.md:163 cites
  `https://hexdocs.pm/stream_data/StreamData.html#fixed_map/1`).
  `mix.exs` line 129 confirms `{:stream_data, "~> 1.1"}` is already
  declared `only: [:test, :dev]`.
- **Warrant (W):** A test file `use ExUnitProperties` exposes the
  imported `StreamData` namespace; `fixed_map/1` is a public function
  in `stream_data ~> 1.1`. Therefore the sketch is buildable in this
  project without dependency changes.
- **Qualifier (Q):** Holds for `stream_data` 1.x. If the dependency
  were downgraded to 0.x where the function signature differs, the
  sketch would need adjustment.
- **Rebuttal (R):** None known — `fixed_map/1` is present in
  `stream_data` 0.5 onward; the codebase already uses property tests
  in 20+ files (e.g. `test/tau/permissions/property_test.exs`,
  `test/tau/circuit_breaker/store_property_test.exs`), confirming the
  pattern works.
- **Backing (B):** `mix.exs:129` (`stream_data ~> 1.1`); existing
  property-test files enumerated by `grep -rn 'use ExUnitProperties'
  test/` (≥ 20 hits).

#### Falsification attempt for claim 2

- **Strategy:** Dependency check — verify `stream_data` is present at a
  version where `fixed_map/1`, `list_of/1`, `member_of/1`, and
  `string/2` are all available with the signatures the sketch uses.
- **Attempt:** Read `mix.exs:129` → `stream_data ~> 1.1` is declared
  for `:test, :dev`. The sketch calls `fixed_map/1` (1-arity, map
  argument), `list_of/1` (1-arity, generator), `string(:alphanumeric,
  min_length: 1)` (2-arity with keyword), and `member_of/1`. All four
  have stable signatures in `stream_data` 1.x (well-established public
  API). The codebase has 20+ existing files using these primitives.
- **Outcome:** withstood.
- **Action:** none.

### Claim 3: `test/tau/settings/loader_test.exs` is untouched and continues to pass

- **Claim (C):** "Leave `loader_test.exs` untouched" (solution.md line 20)
  / "`test/tau/settings/loader_test.exs` — untouched; all existing example
  tests continue to pass." (line 63).
- **Grounds (G):** §What changes (lines 55–60) lists exactly one item:
  the new file. §What does not change (lines 62–67) explicitly names
  `loader_test.exs`, `lib/tau/settings/loader.ex`, and `mix.exs` as
  untouched. The migration sketch (lines 70–76) consists of "Single PR:
  create `test/tau/settings/loader_property_test.exs`" — a creation, not
  a modification, of any existing file.
- **Warrant (W):** Creating a new test file in the `test/` tree does not
  affect compilation or execution of existing test files when they
  reside in distinct modules; ExUnit discovers test files independently.
  `Tau.Settings.LoaderPropertyTest` (proposal-2.md:43) and
  `Tau.Settings.LoaderTest` (loader_test.exs:1) are distinct modules.
- **Qualifier (Q):** Holds as long as the new file does not change
  `lib/tau/settings/loader.ex` or any of its compile-time dependencies.
  The solution explicitly forbids any production change (line 65).
- **Rebuttal (R):** If the new property test reveals a real bug in
  `merge/2`, the implementer might be tempted to fix `merge/2` in the
  same PR — which would then risk breaking `loader_test.exs`'s existing
  assertions. The solution's §Open questions (lines 79–86) acknowledges
  this: "If the property fails on the real implementation, the
  implementer must fix `Loader.merge/2` or narrow the property … and
  file a follow-up." This is correctly scoped as an out-of-PR
  contingency, not a defect of the claim.
- **Backing (B):** ExUnit module-discovery semantics (each file is an
  independent test module); the solution's explicit fence in §What
  does not change.

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction — try to construct a way
  in which adding only a new test file at a new module path could
  break `loader_test.exs`.
- **Attempt:** Considered (a) module-name collision: the proposed
  module is `Tau.Settings.LoaderPropertyTest` vs existing
  `Tau.Settings.LoaderTest` (no collision). (b) Helper imports: the
  new file defines its generators as private `defp` and does not
  inject anything into the existing file's namespace. (c) Shared
  fixtures: no test/support module is added (solution.md line 67
  explicitly: "no new support modules added"). (d) Compile-time
  dependency: `loader_property_test.exs` would `alias Tau.Settings.Loader`
  but does not modify that module.
- **Outcome:** withstood.
- **Action:** none.

### Claim 4: The selected proposal directly satisfies the acceptance criterion (both mandated properties)

- **Claim (C):** "Proposal 2 directly satisfies the acceptance criterion
  (both mandated properties) while also covering C3 (the third named
  invariant in the problem statement)" (solution.md §Why chosen, lines
  26–29).
- **Grounds (G):** `problem.md` §Acceptance criterion (lines 56–63)
  requires "at least two StreamData properties: one asserting that
  `merge(a, b)[:permissions][:deny]` is a prefix-then-suffix
  concatenation … for arbitrary list-valued permission arrays; and one
  asserting that merging any settings map with an empty map is an
  identity (`merge(x, %{}) == x`) …". Proposal 2's properties P1 (concat
  for all three keys, proposal-2.md:69) and P2 (`merge(x, %{}) == x`,
  proposal-2.md:84) match these two requirements element-for-element.
  P3 (proposal-2.md:90) adds the third invariant named in `problem.md`
  §Statement (line 22: "a permissions block absent from one layer is
  treated as an empty list not nil").
- **Warrant (W):** "Satisfies the acceptance criterion" means the
  artifact contains at least the minimum mandated assertions. P1 covers
  `:deny` concat (in fact also `:allow` and `:ask`); P2 covers identity.
  Both required properties are present, so the acceptance criterion is
  met.
- **Qualifier (Q):** "Satisfies" means satisfies on paper. The
  property *passing* against the real implementation is a separate
  question — see Claim 5.
- **Rebuttal (R):** An over-strict reading of the acceptance criterion
  might insist the concat property be specifically over `:deny` alone
  (matching the criterion's exact wording). P1 covers `:deny` and more
  — a strict superset, which still satisfies the criterion. No
  rebuttal warranted.
- **Backing (B):** `problem.md` lines 56–63 (acceptance criterion);
  proposal-2.md lines 69, 84, 90 (the three property bodies).

#### Falsification attempt for claim 4

- **Strategy:** Edge-case enumeration — enumerate the acceptance
  criterion's required assertions and verify each appears in P1 or P2.
- **Attempt:** AC requirement 1: "prefix-then-suffix concat for `:deny`,
  arbitrary list-valued permission arrays" — P1 asserts `merged
  [:permissions][:deny] == a[:permissions][:deny] ++ b[:permissions]
  [:deny]` under `check all a, b <- settings_with_permissions()`
  (proposal-2.md:74–81). Direct match. AC requirement 2: "merge(x, %{})
  == x for all map shapes that include a permissions block" — P2
  asserts exactly that under `check all x <- settings_with_permissions()`
  (proposal-2.md:84–88). Direct match. No AC requirement is missing
  from the proposal.
- **Outcome:** withstood.
- **Action:** none.

### Claim 5: Property failure on the real implementation is the intended outcome (the value of the test)

- **Claim (C):** "If any property fails, it is a signal that `Loader.merge/2`
  violates an invariant the problem statement assumed was already correct
  — that failure is itself the value." (solution.md §Migration sketch,
  lines 75–76; restated in §Open questions, lines 79–86.)
- **Grounds (G):** Inspection of `lib/tau/settings/loader.ex` (read
  in full) shows: `merge/2` uses `Map.merge(a, b, fn k, v1, v2 ->
  merge_value(k, v1, v2) end)`. `merge_value/3` recurses for nested
  maps (line 41), and for list-valued keys in `list_keys()`
  concatenates `v1 ++ v2` (lines 43–48). `list_keys/0` (lines 88–98)
  includes `:allow`, `:deny`, `:ask`, `:permissions`. Tracing P1:
  outer keys both `:permissions` (maps) → recurse; inner keys
  `:allow/:deny/:ask` (lists in `list_keys()`) → `v1 ++ v2`. P1
  should pass against the real implementation. Tracing P2:
  `Map.merge(x, %{}, fun)` returns `x` (the resolver is never
  invoked because there are no shared keys). P2 should pass. Tracing
  P3: when `b = %{permissions: %{}}`, the inner merge resolves
  `Map.merge(%{key => list}, %{}, fun)` → `%{key => list}`, so
  `merged[:permissions][key] == a_list`. P3 should pass.
- **Warrant (W):** Property-based tests are valuable precisely because
  a failure surfaces a real defect (Hughes, "QuickCheck: a lightweight
  tool for random testing of Haskell programs", ICFP'00; the founding
  rationale for the technique). A property whose expected outcome is
  "pass" can still be valuable if its failure mode is informative; the
  solution explicitly designs for both outcomes.
- **Qualifier (Q):** The "failure is value" framing presupposes the
  implementer treats failure as a defect signal — not as test noise to
  be silenced by narrowing the property. The solution's §Open
  questions (lines 79–86) explicitly notes the implementer must "fix
  `Loader.merge/2` or narrow the property to match actual behaviour
  and file a follow-up" — the second option must be paired with a
  follow-up issue, otherwise the narrowing hides the defect.
- **Rebuttal (R):** If the implementer narrows the property without
  filing a follow-up, the test becomes vacuous (per the validator
  protocol's "pre-emptive over-narrowing" anti-pattern). The solution
  text mentions follow-up filing but does not enforce it.
- **Backing (B):** Hughes, ICFP 2000. CLAUDE.md OTP NN #6 ("Invariant-
  bearing modules MUST have properties before examples"). Validate
  protocol `validate.md` §5 (revision options).

#### Falsification attempt for claim 5

- **Strategy:** Dependency check — verify the real implementation
  actually does what the three properties assert, so the "failure is
  the value" outcome is meaningful (a property that always passes
  trivially adds little signal; a property that fails reveals a real
  bug).
- **Attempt:** Read `lib/tau/settings/loader.ex` end-to-end (99
  lines). Traced each property's expected behaviour against the
  implementation:
  - P1 (concat): nested-map recursion + `v1 ++ v2` for list-keys →
    should pass. The concat is genuinely `a ++ b`, not `b ++ a` —
    confirmed at line 45.
  - P2 (identity): `Map.merge(x, %{}, _) == x` is a property of
    `Map.merge/3` itself — should pass.
  - P3 (absent key): `Map.merge(%{k => v}, %{}, _) == %{k => v}` —
    should pass for any key-value.
  None of the three properties is expected to fail on the current
  implementation. That is the *current* expectation; the value of
  encoding them as properties is they will fire on any future
  regression. The "failure is the value" framing remains true for
  the regression case.
- **Outcome:** withstood.
- **Action:** none. (Note: this claim does not require that properties
  fail today — it requires that *if* they fail, the failure is
  informative. That conditional is sound.)

## Cross-claim consistency

The five claims are mutually consistent:

- Claim 1 (three properties) and Claim 4 (acceptance criterion
  satisfied) cohere: AC mandates two, solution provides three including
  both mandated ones.
- Claim 2 (named generators with `fixed_map/1`) and Claim 1 (three
  specific properties) cohere: the generators serve the properties;
  same source (proposal-2.md).
- Claim 3 (existing file untouched) and Claim 5 (failure is value)
  cohere: a failure of the new property does not break the existing
  file; it surfaces a real defect that is handled by the §Open-
  questions contingency.
- Claim 4 (AC satisfied) and Claim 5 (failure is value) cohere: the
  AC is "the properties exist", which the solution satisfies on paper;
  the value of the properties is the regression-detection capability
  Claim 5 describes.

No internal tension identified.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Three properties C1/C2/C3 | Counter-example construction | withstood | none |
| 2 | `fixed_map/1`-based named helpers | Dependency check | withstood | none |
| 3 | `loader_test.exs` untouched & passing | Counter-example construction | withstood | none |
| 4 | AC satisfied by the chosen proposal | Edge-case enumeration | withstood | none |
| 5 | Property failure is the intended value | Dependency check | withstood | none |

## Revision required

None. All five claims withstood their falsification attempts.

- **Target file:** n/a
- **Revision kind:** n/a
- **Rationale:** The solution selects a single proposal whose sketch
  matches the recommendation token-for-token; the acceptance criterion
  is satisfied on paper (Claim 4) and the implementation under
  inspection should make the properties pass (Claim 5); no fence in
  §What does not change is violated (Claim 3); the dependency surface
  is already present (Claim 2).

## Outstanding doubts

- **Doubt 1 (residual, not falsifiable here):** Proposal 2's
  `settings_with_permissions/0` generator always produces maps with all
  three permission keys present. A real-world settings layer might
  contain only `{deny: [...]}` (no `:allow`, no `:ask`). P1 would not
  exercise that shape; only P3 partially covers it (and only over the
  three keys individually, not over all 2³ subset combinations). The
  solution's own §Open questions (lines 87–93) acknowledges this as an
  "acceptable residual given the acceptance criterion's scope; a future
  property extension is low-effort if needed." This is correctly
  qualified and not a falsification target at this node — it surfaces
  to the parent validator as a known scope-residual.
- **Doubt 2 (implementer-fidelity, out of scope):** The solution claims
  the implementer will deliver three properties. The acceptance
  criterion mandates only two. A literal-minded implementer could ship
  two and pass the gate. The solution-vs-implementation gap is the
  reviewer's responsibility, not the validator's; flagged here so the
  parent validator can carry it.
