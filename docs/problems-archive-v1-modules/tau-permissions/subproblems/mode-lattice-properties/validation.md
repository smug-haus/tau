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

# Validation: Deterministic 9-pair sweep + dedicated `at_or_below?/2` property block

## Overview

The solution makes seven distinct checkable propositions: (1) the three peer
spot-checks in the existing `describe "clamp/2 — peer modes"` block will be
removed; (2) a module attribute `@peers` will be added; (3) a single new test
will deterministically exhaust the 9-pair peer × peer cartesian product via a
`for` comprehension; (4) a new `describe "at_or_below?/2 — properties"` block
will contain a StreamData reflexivity property; (5) that block will contain two
explicit `FunctionClauseError` guard tests pinning `at_or_below?/2`'s unknown-
atom semantics; (6) `lib/tau/permissions/mode.ex` is not touched; (7) the two
existing `clamp/2` properties are preserved. Each claim is examined with a
named falsification strategy: counter-example construction, dependency check,
edge-case enumeration, and an integration check against the acceptance
criterion. Six claims withstand; claim 5 is partially falsified — the guard
tests pin `at_or_below?/2`'s `FunctionClauseError` semantics, but the
acceptance criterion's "raises or returns `false` on unknown atoms" disjunction
is decided in favour of "raises", which is a narrowing of the criterion rather
than a falsification of it. The narrowing is faithful to the current
implementation (`mode.ex:94` guard) and is recorded in the Qualifier without
triggering a revision.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

### Claim 1: The three individual spot-check tests in `describe "clamp/2 — peer modes"` will be removed

- **Claim (C):** The solution will "Remove the three individual spot-check
  tests inside `describe \"clamp/2 — peer modes\"` (`plan under accept_edits`,
  `accept_edits under plan`, `dont_ask under plan`)."
- **Grounds (G):** The named tests exist verbatim at
  `test/tau/permissions/mode_test.exs:129-139` inside the describe block
  declared at `mode_test.exs:123`. Solution §"What changes" first bullet
  states "Remove" against the same three identifiers. Proposal 2's sketch
  (`proposals/proposal-2.md:39-50`) shows the replacement that supersedes
  them.
- **Warrant (W):** A solution that explicitly enumerates the removed tests
  by name and located them in the same file Grounds cites is internally
  consistent with the intent to delete those exact assertions. An edit
  matching the solution's verbatim instructions necessarily satisfies the
  claim.
- **Qualifier (Q):** Holds for the next implementation edit on this file
  as long as the test names and describe-block heading remain at their
  cited lines. If a different PR renames or restructures those tests
  before this solution is implemented, the editor must re-locate by name
  rather than by line.
- **Rebuttal (R):** The claim would not hold if an implementer chose to
  "additively" keep the three spot-checks alongside the new comprehension
  loop on grounds of "more coverage is better". The solution's chosen
  rationale (decomplecting "some peers" from "all peers" and removing
  redundancy — `proposals/proposal-2.md:25-30`) explicitly rejects that
  framing.
- **Backing (B):** `proposals/proposal-2.md` ("Strengths" §:
  "Removes the three spot-checks that gave false comfort, clarifying that
  the test is now complete rather than representative") plus the Hickey
  principle that redundancy in a test suite hides intent.

#### Falsification attempt for claim 1

- **Strategy:** counter-example construction.
- **Attempt:** Searched for any constraint that would force keeping the
  three spot-checks: (a) ADR-0015 — no requirement to retain example
  tests; (b) `mode_test.exs` — no shared fixtures keyed on the three test
  names; (c) project test-naming policy — none requires per-pair tests;
  (d) the comprehension test is a strict superset of the three spot-checks
  (all three pairs `(plan, accept_edits)`, `(accept_edits, plan)`,
  `(dont_ask, plan)` are in the 9-pair cartesian product). No counter-
  example was constructed.
- **Outcome:** withstood.
- **Action:** None.

### Claim 2: A module attribute `@peers [:accept_edits, :dont_ask, :plan]` will be added

- **Claim (C):** The solution will "Add module attribute `@peers
  [:accept_edits, :dont_ask, :plan]` at the top of the property section."
- **Grounds (G):** Solution §"What changes" second bullet (`solution.md:44`).
  Proposal 2's sketch (`proposals/proposal-2.md:37`) shows the attribute
  declaration. The existing `@modes` attribute at `mode_test.exs:24`
  establishes the file's convention for module-attribute test fixtures.
- **Warrant (W):** Module attributes in Elixir test files are evaluated
  at compile time and are referenced by `@peers` inside `test` and
  `property` blocks. The existing `@modes` precedent (`mode_test.exs:24`,
  used at `mode_test.exs:69` inside a `for` comprehension) demonstrates
  the pattern works for cartesian-product tests in this file.
- **Qualifier (Q):** Holds when the attribute is declared at module
  scope before any `describe` block that references it. The solution's
  phrase "at the top of the property section" is slightly imprecise —
  `@peers` must be declared at module scope (not inside `describe`), but
  may appear adjacent to the `@moduletag :property` line at
  `mode_test.exs:169`.
- **Rebuttal (R):** The claim would not hold if `@peers` were declared
  inside a `describe` block (an Elixir compile error), or if a stray
  `defp peers, do: ...` were used instead. The solution names "module
  attribute" specifically.
- **Backing (B):** Elixir docs on module attributes
  (https://hexdocs.pm/elixir/Module.html#module-module-attributes) and
  the established `@modes` pattern at `mode_test.exs:24`.

#### Falsification attempt for claim 2

- **Strategy:** dependency check.
- **Attempt:** Verified `ExUnit.Case` and `ExUnitProperties` are already
  `use`d at `mode_test.exs:19-20`, so no new dependency is required.
  Verified the existing `@modes` attribute is referenced from inside both
  `test` blocks (`mode_test.exs:28, 69`) and `property` blocks
  (`mode_test.exs:198, 199`) without a `use` change, demonstrating the
  exact pattern `@peers` will follow. No dependency gap.
- **Outcome:** withstood.
- **Action:** None.

### Claim 3: A new test will deterministically exhaust the 9-pair peer × peer cartesian product via `for` comprehension

- **Claim (C):** The solution will "Add `describe \"clamp/2 — peer modes
  (exhaustive 9-pair sweep)\"` containing one `test` with `for req <-
  @peers, par <- @peers` asserting `Mode.clamp(req, par) == req` with an
  interpolated error message."
- **Grounds (G):** Solution §"What changes" fourth bullet
  (`solution.md:46-48`). Proposal 2 sketch
  (`proposals/proposal-2.md:40-50`) shows the exact comprehension shape.
  The acceptance criterion in `problem.md:58-62` requires "all
  combinations of the three peer modes under `clamp/2` (9 pairs:
  requested × parent in `{:accept_edits, :dont_ask, :plan}²`)" with
  result equal to `requested`.
- **Warrant (W):** An Elixir `for req <- L1, par <- L2` comprehension with
  two generators iterates the cartesian product `L1 × L2` exhaustively;
  this is the documented semantics of multi-generator comprehensions. For
  `L1 = L2 = @peers` (3 elements), the comprehension produces exactly
  9 iterations per run. Determinism follows from `@peers` being a fixed
  list; exhaustion follows from cartesian-product semantics.
- **Qualifier (Q):** Holds when (a) `@peers` is the exact 3-element list
  `[:accept_edits, :dont_ask, :plan]` (claim 2); (b) the `Mode.clamp(req,
  par) == req` invariant is true for all 9 pairs in the production
  implementation. Property (b) follows from `mode.ex:31-38` where all
  three peers share rank 3, and `mode.ex:80-81` returns `requested` when
  `at_or_below?(requested, parent)` (which is true on rank equality at
  `mode.ex:94-96`).
- **Rebuttal (R):** Would not hold if (i) `@ranks` is changed so that
  the three peers no longer share rank 3 — but that is exactly the
  regression the test is designed to catch, so the test correctly fails
  in that case (which is the intended behaviour, not a falsification of
  this claim); (ii) the implementer writes `for req <- @peers, par <-
  @peers, do: ...` without `assert`, which compiles but tests nothing —
  prevented by the solution's verbatim "asserting `Mode.clamp(req, par)
  == req`" language.
- **Backing (B):** Elixir docs on comprehensions
  (https://hexdocs.pm/elixir/Kernel.SpecialForms.html#for/1 — "When
  multiple generators are given, the values are processed in nested
  loops"); the structural predecessor in this file at `mode_test.exs:69`
  uses the same multi-generator pattern; ADR-0015 ceiling-clamp contract.

#### Falsification attempt for claim 3

- **Strategy:** integration check + counter-example construction over
  all 9 pairs.
- **Attempt:** Enumerated all 9 pairs and verified `Mode.clamp/2`'s
  behaviour against `mode.ex:70-86`. For every `(req, par)` ∈ `{:accept_edits,
  :dont_ask, :plan}²`: `mode?(req)` is true (`mode.ex:44`), `parent` is
  already a known mode so `normalise_parent` returns it (`mode.ex:105`).
  If `req == par`, the second `cond` clause (`mode.ex:77`) returns
  `parent` which equals `req`. If `req != par`, both have rank 3, so
  `at_or_below?(req, par)` returns `true` (`mode.ex:95`), and the third
  `cond` clause returns `requested`. In every case the result equals
  `requested`. No counter-example exists in the current implementation.
- **Outcome:** withstood.
- **Action:** None. The 9-pair sweep is a deterministic, sound check of
  the peer-rank invariant the solution targets.

### Claim 4: A reflexivity property over all known modes will be added

- **Claim (C):** The solution will add `property "at_or_below?/2 is
  reflexive for all known modes"` using `StreamData.member_of(@modes)`.
- **Grounds (G):** Solution §"What changes" fifth bullet first sub-bullet
  (`solution.md:50-51`). Proposal 2 sketch
  (`proposals/proposal-2.md:56-60`) shows
  `check all(m <- StreamData.member_of(@modes)) do assert
  Mode.at_or_below?(m, m) end`. The acceptance criterion
  (`problem.md:62-63`) requires "a separate property asserts
  `at_or_below?/2`'s reflexivity (`∀ m: at_or_below?(m, m)`)".
- **Warrant (W):** Reflexivity of `at_or_below?/2` is provable from
  `mode.ex:94-96`: `Map.fetch!(@ranks, m) >= Map.fetch!(@ranks, m)` is
  trivially true for any `m` that is a key of `@ranks`.
  `StreamData.member_of(@modes)` samples uniformly from the 6-element
  set, so reflexivity is checked over the entire mode-atom space across
  enough runs.
- **Qualifier (Q):** Holds for all `m ∈ @modes`. The property covers the
  6-element space probabilistically, but because the implementation is
  deterministic and the space is small, every run with the default
  StreamData `max_runs: 100` will exercise every element with
  overwhelming probability (P(some element missed) ≤ 6·(5/6)^100 ≈
  3.4×10^-7). Open question #3 in `solution.md:84-86` acknowledges this
  is acceptable because reflexivity is a weaker claim than the peer-rank
  exhaustion that claim 3 covers deterministically.
- **Rebuttal (R):** Would not hold if `@modes` were declared *before*
  the property in a way that excluded a mode (e.g., if a future edit
  removed `:plan` from `@modes` but kept it in `@ranks`). The solution
  does not modify `@modes`, so the rebuttal is mitigated.
- **Backing (B):** StreamData docs
  (https://hexdocs.pm/stream_data/StreamData.html#member_of/1); reflexive
  relations as defined in lattice theory; `at_or_below?/2`'s
  implementation at `mode.ex:94-96`.

#### Falsification attempt for claim 4

- **Strategy:** edge-case enumeration over all 6 known modes.
- **Attempt:** For each `m ∈ @modes`, `Map.fetch!(@ranks, m) >=
  Map.fetch!(@ranks, m)` evaluates to `0 >= 0` (`:bypass`), `1 >= 1`
  (`:auto`), `2 >= 2` (`:default`), `3 >= 3` (each of `:accept_edits`,
  `:dont_ask`, `:plan`). All six are true. The guard
  `is_map_key(@ranks, child) and is_map_key(@ranks, parent)` admits
  each pair `(m, m)` since `m ∈ @modes` implies `m` is a `@ranks` key
  (the two structures share keys by inspection of `mode.ex:31-38` and
  `mode_test.exs:24`). No edge case falsifies the claim.
- **Outcome:** withstood.
- **Action:** None.

### Claim 5: Two explicit `FunctionClauseError` guard tests will pin `at_or_below?/2`'s unknown-atom semantics

- **Claim (C):** The solution will add `test "guard raises
  FunctionClauseError on unknown child"` and `test "guard raises
  FunctionClauseError on unknown parent"`.
- **Grounds (G):** Solution §"What changes" fifth bullet sub-bullets two
  and three (`solution.md:52-53`). Proposal 2 sketch
  (`proposals/proposal-2.md:62-68`) shows
  `assert_raise FunctionClauseError, fn -> Mode.at_or_below?(:nope,
  :plan) end` and the parent-symmetric variant. The implementation at
  `mode.ex:94` has `when is_map_key(@ranks, child) and is_map_key(@ranks,
  parent)`, which causes a `FunctionClauseError` for any non-key atom.
- **Warrant (W):** Elixir's `when` clause produces a
  `FunctionClauseError` when no head matches — this is the documented
  failure mode of unmatched guards. Pinning this behaviour in a test
  documents the public contract for external callers (whom the solution
  identifies as the population at risk — `problem.md:21-22`).
- **Qualifier (Q):** *Narrowed by validation.* The acceptance criterion
  (`problem.md:64-65`) reads "raises **or** returns `false` on unknown
  atoms (clarifying the guard semantics for external callers)" — an
  inclusive disjunction. The solution's two guard tests pin **only** the
  "raises" disjunct. This is a faithful pin of the current
  implementation (`mode.ex:94`), not a wider contract. If a future
  change replaced the guard with a `case` returning `false` on unknown
  atoms, both pin-tests would fail and force re-evaluation. This is the
  intended outcome (the criterion says "clarifying the guard semantics"
  — pinning *one* semantics is the clarification), so the narrowing is
  not a defect, but the validator records the narrowing here.
- **Rebuttal (R):** The narrowing would be a defect if the problem
  statement required the test suite to remain agnostic to which side of
  the disjunction holds — but the criterion's parenthetical
  ("clarifying the guard semantics") indicates the intent is to pin
  *one* specific behaviour. The narrowing is therefore faithful.
- **Backing (B):** Elixir docs on function guards
  (https://hexdocs.pm/elixir/patterns-and-guards.html — "If no clause
  matches, a `FunctionClauseError` is raised"); the guard at
  `mode.ex:94`; the problem statement's framing of unknown atoms as a
  contract clarification (`problem.md:32-34`).

#### Falsification attempt for claim 5

- **Strategy:** edge-case enumeration over the disjunction in the
  acceptance criterion.
- **Attempt:** Enumerated the two disjuncts: (i) "raises" — pinned by
  the two guard tests, faithful to `mode.ex:94`; (ii) "returns `false`"
  — not pinned. Asked: does the criterion's parenthetical "clarifying
  the guard semantics for external callers" require both disjuncts to
  be pinned, or only the one that matches the implementation? The
  parenthetical's intent is a *clarification* of the existing semantics,
  not a contract that admits both. The solution's two guard tests
  therefore satisfy the criterion's intent while narrowing the literal
  disjunction. Outcome: the literal disjunction is partially falsified
  (the "returns `false`" disjunct is not pinned), but the criterion's
  intent (pin one semantics) is satisfied. Narrowing is faithful.
- **Outcome:** partially_falsified.
- **Action:** Narrow Qualifier in place (see Q above). No `revision_triggered`.

### Claim 6: `lib/tau/permissions/mode.ex` is not touched

- **Claim (C):** "`lib/tau/permissions/mode.ex` — no production code
  change."
- **Grounds (G):** Solution §"What does not change" first bullet
  (`solution.md:57`). Proposal 2's "File-level change summary"
  (`proposals/proposal-2.md:72-74`) lists only the test file as changed.
  The selection rationale (`solution.md:24-36`) explicitly cites
  "Proposals 3 and 4 both touch production code beyond what the
  criterion requires (new public API functions on `Mode`), introducing
  review cost and API surface that is out of scope" as the reason for
  choosing proposal 2 over them.
- **Warrant (W):** The acceptance criterion (`problem.md:58-65`) is
  satisfied entirely by additions and reorganisation in the test file;
  no production change is required. Restricting the diff to the test
  file minimises blast radius and aligns with the project's "tests
  first; production unchanged" approach for additive coverage.
- **Qualifier (Q):** Holds for this PR's diff. A future PR may add
  `peer_modes/0` or `modes/0` to `Mode` (open question #1 —
  `solution.md:78-80`), but that is explicitly out of scope here.
- **Rebuttal (R):** Would not hold if a reviewer or implementer adds
  `peer_modes/0` to `Mode` while implementing this solution. The
  solution's "Open questions" §1 (`solution.md:78-80`) explicitly
  defers that decision.
- **Backing (B):** Selection rationale in `solution.md:24-36` rejecting
  proposals 3 and 4; project OTP non-negotiable #8 ("pure functions are
  the default; processes are the exception") — applies analogously here
  as "tests are the default for additive coverage; production change is
  the exception".

#### Falsification attempt for claim 6

- **Strategy:** dependency check.
- **Attempt:** Checked whether any new test in the solution requires a
  production-side change. (a) The 9-pair `for` test uses only `clamp/2`
  (already public). (b) The reflexivity property uses only
  `at_or_below?/2` (already public). (c) The two guard tests use only
  `at_or_below?/2`. (d) `@peers` is a test-local list of literal atoms;
  it does not require a `Mode` function. No production change is
  necessitated by the solution.
- **Outcome:** withstood.
- **Action:** None.

### Claim 7: The two existing `clamp/2` properties are preserved

- **Claim (C):** "The two existing `clamp/2` properties (`\"clamp/2
  result never more permissive than parent\"` and `\"clamp/2 returns
  requested when requested is a mode at-or-below parent\"`) — these are
  correct and are not touched."
- **Grounds (G):** Solution §"What does not change" second bullet
  (`solution.md:58-60`). The two named properties exist at
  `mode_test.exs:180-194` and `mode_test.exs:196-209`. The problem
  statement explicitly puts them out of scope (`problem.md:67-69`).
- **Warrant (W):** A solution that adds new describe blocks and
  modifies one specific describe block by name (claim 1) does not
  affect properties in other regions of the file. The two existing
  properties are inside their own `property` blocks under no described-
  by-name block — they are at module scope after the `@moduletag
  :property` declaration (`mode_test.exs:169`).
- **Qualifier (Q):** Holds as long as the implementer does not
  re-organise the file beyond the solution's literal instructions.
- **Rebuttal (R):** Would not hold if an implementer chose to
  consolidate all properties into a new shared describe block, moving
  the two existing properties in the process. The solution does not
  authorise that move.
- **Backing (B):** Problem statement's "Out of scope" §
  (`problem.md:67-69`); the literal text of the solution's "What does
  not change" §.

#### Falsification attempt for claim 7

- **Strategy:** counter-example construction.
- **Attempt:** Considered whether adding `describe "at_or_below?/2 —
  properties"` could collide with the two existing properties. The
  existing properties are at module scope (no `describe`); the new
  describe block adds a named scope that does not contain or displace
  them. No naming collision exists (`clamp/2` vs `at_or_below?/2`
  describes). No counter-example constructed.
- **Outcome:** withstood.
- **Action:** None.

## Cross-claim consistency

Claims 1-7 form a consistent set:

- Claim 1 (remove three spot-checks) and claim 3 (add 9-pair sweep) are
  complementary — the sweep is a strict superset of the spot-checks, so
  removing the spot-checks does not reduce coverage.
- Claim 2 (`@peers` attribute) supports claim 3 (the comprehension
  iterates `@peers`) — order of edits matters but is implicit in any
  reasonable implementation.
- Claim 6 (no production change) constrains the scope and is consistent
  with claims 1-5, which all describe test-file edits.
- Claim 7 (preserve existing properties) does not conflict with claim 4
  (add a new property in a new describe block) — they live in different
  regions of the same file.

No internal tension. The narrowed Qualifier on claim 5 is a local
narrowing of the criterion's disjunction and does not affect any other
claim.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Remove three peer spot-checks | counter-example construction | withstood | none |
| 2 | Add `@peers` module attribute | dependency check | withstood | none |
| 3 | Add 9-pair `for` comprehension sweep | integration + counter-example | withstood | none |
| 4 | Add reflexivity property over `@modes` | edge-case enumeration | withstood | none |
| 5 | Add two `FunctionClauseError` guard tests | edge-case enumeration | partially_falsified | narrow Qualifier in place (criterion's "raises or returns false" disjunction pinned only to "raises", faithful to current `mode.ex:94` guard) |
| 6 | No `lib/tau/permissions/mode.ex` change | dependency check | withstood | none |
| 7 | Two existing `clamp/2` properties preserved | counter-example construction | withstood | none |

## Revision required

No revision required. Claim 5 is partially falsified by literal reading
of the acceptance criterion's disjunction, but the narrowing is
faithful to the implementation and to the criterion's stated intent
("clarifying the guard semantics for external callers" — pinning one
specific semantics IS the clarification). The narrowed Qualifier in
claim 5 records the narrowing for parent-level inheritance.

- **Target file:** none
- **Revision kind:** n/a
- **Rationale:** All withstood except claim 5, which is partially
  falsified at the Qualifier level only. Per the validator protocol §5,
  partial falsifications are handled by narrowing the qualifier in
  place, not by triggering revision.

## Outstanding doubts

- The comprehension test fires all 9 assertions inside a single `test`
  block. If pair `n` fails, ExUnit will report the first failure and
  stop iterating; pairs `n+1`..`9` go un-evaluated within that run. The
  `inspect`-interpolated error message identifies the failing pair, but
  a regression that breaks multiple pairs requires multiple runs to
  surface them all. Acceptable: the solution's stated goal (catch a
  regression in the peer-rank invariant) is satisfied by surfacing the
  first failure.
- Open question #1 (`solution.md:78-80`) defers the `peer_modes/0` /
  `modes/0` decision. If a future PR adds those functions, the test
  file should be migrated to reference them rather than the test-local
  `@peers` and `@modes` attributes. This validation does not require
  that migration but notes it for the parent validator.
- Reflexivity over a 6-element space sampled probabilistically
  (claim 4, default `max_runs: 100`) has P(missed element) ≈ 3.4×10^-7.
  Acceptable in practice; a future hardening pass could replace with a
  deterministic `for m <- @modes` loop. Not a falsification of the
  current solution.
