---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Mode lattice peer-rank contract is only spot-checked, not property-swept

## Statement

`Tau.Permissions.Mode` has example tests and two properties in
`test/tau/permissions/mode_test.exs`, but the peer-rank invariant — that
`:accept_edits`, `:dont_ask`, and `:plan` all share rank 3 and therefore
`clamp/2` treats any peer as "already restricted enough" against any other
peer — is verified by three discrete example tests rather than a property that
exhausts all peer × peer combinations. Additionally, `at_or_below?/2` is not
covered by a property; it is exercised only through `clamp/2`'s implementation
path, so a regression in `at_or_below?/2`'s guard clause (which only accepts
known modes) would not be caught independently.

## Context

- `lib/tau/permissions/mode.ex`:
  - `@ranks` map: `bypass: 0, auto: 1, default: 2, accept_edits: 3,
    dont_ask: 3, plan: 3`.
  - `at_or_below?/2` — guarded with `when is_map_key(@ranks, child) and
    is_map_key(@ranks, parent)`; raises `FunctionClauseError` on unknown atoms.
  - `clamp/2` calls `at_or_below?/2` only after `mode?(requested)` is true;
    the guard in `at_or_below?/2` is therefore dead code for `clamp/2`'s
    callers, but external callers (e.g. tests, future code) could pass unknown
    atoms and receive a `FunctionClauseError`.
- `test/tau/permissions/mode_test.exs`: two properties present — `"clamp/2
  result never more permissive than parent"` and `"clamp/2 returns requested
  when requested is a mode at-or-below parent"`. These are strong. The
  peer-rank section has three spot-checks (`plan under accept_edits`,
  `accept_edits under plan`, `dont_ask under plan`) but does not sweep all
  nine peer × peer combinations.
- ADR-0015: ceiling clamp for sub-agent spawn relies on these rank invariants.

## Complecting hypothesis

The peer-rank contract of `clamp/2` is complected with the representation
choice (`@ranks` map assigning the same integer to three atoms) because the
correctness of the "peer modes are interchangeable" behaviour depends on an
unstated invariant — that all three share the same rank — which is not
separately tested as a property. A future edit adding a rank-4 mode or
changing a peer's rank would not surface a failing test.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

A property test exhausts all combinations of the three peer modes under
`clamp/2` (9 pairs: requested × parent in `{:accept_edits, :dont_ask, :plan}²`)
asserting that the result equals `requested` in all cases; and a separate
property asserts `at_or_below?/2`'s reflexivity (`∀ m: at_or_below?(m, m)`)
and that it raises or returns `false` on unknown atoms (clarifying the guard
semantics for external callers).

## Out of scope

- The existing two `clamp/2` properties in `mode_test.exs` — these are
  correct; the gap is additive, not corrective.
- Matcher unit tests — covered by `matcher-unit-contracts`.
- Evaluator mode dispatch — covered by `evaluator-mode-complecting`.
- `Settings.Loader.merge/2` — covered by `settings-merge-feed`.

## Amendment log

- (none yet)
