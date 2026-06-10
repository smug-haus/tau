---
template_version: 1
template_name: solution
parent_problem: ../../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-2.md]
selection_method: single
revision: 0
---

# Solution: Deterministic 9-pair sweep via `for` comprehension + dedicated `at_or_below?/2` property block

## Recommendation

Replace the three spot-check tests in `describe "clamp/2 — peer modes"` with
a single example test that iterates all 9 peer × peer combinations via a `for`
comprehension, and add a dedicated `describe "at_or_below?/2 — properties"`
block containing a StreamData reflexivity property over all known modes and two
explicit `FunctionClauseError` guard tests. Both changes land in
`test/tau/permissions/mode_test.exs` only; no production code is touched.

## Selected from

- **Chosen:** `proposals/proposal-2.md`
- **Why chosen:** The acceptance criterion requires a test that "exhausts all
  combinations" of the nine peer × peer pairs. Proposal 2 satisfies this
  literally and provably: `for req <- @peers, par <- @peers` generates exactly
  9 assertions per run by definition of cartesian-product comprehension. Proposal
  1 also satisfies the criterion but relies on StreamData's probabilistic
  sampling over a 3-element set — statistically sound but structurally weaker
  than a deterministic loop, and confidence is explicitly rated medium for that
  reason. Proposals 3 and 4 both touch production code beyond what the criterion
  requires (new public API functions on `Mode`), introducing review cost and API
  surface that is out of scope. Proposal 2 dominates on fit and determinism with
  the same low risk and easy reversibility as Proposal 1, and the same-file
  migration cost is the lowest of any proposal that touches production.

## What changes

- `test/tau/permissions/mode_test.exs`:
  - **Remove** the three individual spot-check tests inside `describe "clamp/2 —
    peer modes"` (`plan under accept_edits`, `accept_edits under plan`,
    `dont_ask under plan`).
  - **Add** module attribute `@peers [:accept_edits, :dont_ask, :plan]` at the
    top of the property section.
  - **Add** `describe "clamp/2 — peer modes (exhaustive 9-pair sweep)"` containing
    one `test` with `for req <- @peers, par <- @peers` asserting
    `Mode.clamp(req, par) == req` with an interpolated error message.
  - **Add** `describe "at_or_below?/2 — properties"` containing:
    - `property "at_or_below?/2 is reflexive for all known modes"` using
      `StreamData.member_of(@modes)`.
    - `test "guard raises FunctionClauseError on unknown child"`.
    - `test "guard raises FunctionClauseError on unknown parent"`.

## What does not change

- `lib/tau/permissions/mode.ex` — no production code change.
- The two existing `clamp/2` properties (`"clamp/2 result never more permissive
  than parent"` and `"clamp/2 returns requested when requested is a mode
  at-or-below parent"`) — these are correct and are not touched.
- All other test modules and support files.
- ADR-0015 — no contract change; this PR only adds test coverage for an
  already-specified invariant.

## Migration sketch

One PR: open `test/tau/permissions/mode_test.exs`, delete the three
spot-check tests from the peer-modes describe block, add `@peers`, add the
comprehension test, add the `at_or_below?/2` describe block. Run
`mix test test/tau/permissions/mode_test.exs` to confirm net count and that
all new assertions pass. No compile step, no supervisor changes, no migration
ordering concern.

## Open questions

- Whether the existing `@modes` test-local attribute should be replaced by
  `Mode.modes()` (as Proposal 3 suggests) is a separate decision; this solution
  does not depend on it either way.
- The comprehension test fires all 9 assertions inside a single `test` block;
  if a pair fails, the error message must carry enough context to identify the
  failing pair. The sketch in Proposal 2 includes `inspect` interpolation — this
  must be confirmed in the actual edit.
- StreamData's reflexivity property over `@modes` (6 elements) samples
  probabilistically; it covers the full space in practice but is not provably
  exhaustive per run. This is acceptable because reflexivity is a weaker claim
  than peer-rank exhaustion and the set is small.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Additive property block directly in mode_test.exs; probabilistic StreamData sweep over peers; test-local `@peers` hardcoded. Not chosen: probabilistic rather than deterministic exhaustion; confidence medium.
- `proposals/proposal-2.md` — Deterministic exhaustion via `for` comprehension; replaces three spot-checks; adds `at_or_below?/2` property block. **Chosen.**
- `proposals/proposal-3.md` — Adds `peer_modes/0` and `modes/0` to production mode.ex; tests derive peer set from module. Not chosen: touches production code beyond the acceptance criterion; API surface addition out of scope.
- `proposals/proposal-4.md` — Splits `at_or_below?/2` into guarded + safe total variant; adds four new properties. Not chosen: production API addition out of scope; low proposer confidence; filter-based StreamData generator risk.

## Revision history

- (revision 0 — initial)
