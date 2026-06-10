---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Additive property block directly in mode_test.exs

## Approach

Add two new `property` blocks to the existing `test/tau/permissions/mode_test.exs`
file — one for the peer-rank exhaustion and one for `at_or_below?/2`'s reflexivity
and guard behaviour — without touching any other file or introducing new helpers.
The peer-rank property generates `{requested, parent}` from
`StreamData.member_of([:accept_edits, :dont_ask, :plan])` and asserts
`clamp(requested, parent) == requested`. The `at_or_below?/2` property generates
from `StreamData.member_of(@modes)` and asserts reflexivity (`at_or_below?(m, m)`)
plus a separate example block for the guard-raises path.

## Rationale

The acceptance criterion is purely additive — the existing two properties are
correct and need no change. The gap is a missing 9-pair sweep of the peer tier
and a missing independent test of `at_or_below?/2`. Adding two `property` blocks
to the existing file is the smallest possible change: no new module, no new
support infrastructure, no behaviour change. The peer-rank invariant
("all three peers share rank 3, so clamp leaves requested standing") is directly
expressible as a StreamData property over a three-element `member_of` generator.

## Sketch

```elixir
# Addition to test/tau/permissions/mode_test.exs — inside the @moduletag :property section

@peers [:accept_edits, :dont_ask, :plan]

property "clamp/2 preserves requested for all peer × peer combinations" do
  check all(
    requested <- StreamData.member_of(@peers),
    parent    <- StreamData.member_of(@peers)
  ) do
    assert Mode.clamp(requested, parent) == requested
  end
end

property "at_or_below?/2 is reflexive for all known modes" do
  check all(m <- StreamData.member_of(@modes)) do
    assert Mode.at_or_below?(m, m)
  end
end

# Example test (not a property) clarifying guard semantics for external callers:
describe "at_or_below?/2 — guard semantics on unknown atoms" do
  test "raises FunctionClauseError for unknown child" do
    assert_raise FunctionClauseError, fn -> Mode.at_or_below?(:nope, :default) end
  end

  test "raises FunctionClauseError for unknown parent" do
    assert_raise FunctionClauseError, fn -> Mode.at_or_below?(:plan, :nope) end
  end
end
```

No new files. No new modules. The `@peers` module attribute is defined at the
top of the property section. The guard-semantics block uses example tests (not
a property) because the space of "unknown atoms" is infinite and the interesting
claim is just that the guard fires, not a distribution over unknowns.

## Tradeoffs

### Strengths

- Minimal diff: two `property` blocks and one `describe` block in one file.
- Immediately satisfies the acceptance criterion in full: 9 pairs swept (the
  `check all` generator over a 3-element set is exhaustive under StreamData's
  default run count, but more importantly is *structurally* exhaustive — the
  cartesian product is the generator), reflexivity covered, guard semantics
  documented.
- No risk of touching production code, new modules, or supervision trees.
- `@peers` attribute makes the intent explicit at the top of the property
  section; a future rank-4 mode addition requires updating `@peers` explicitly,
  making the invariant visible.

### Weaknesses

- `@peers` is a test-local constant, not tied to `Mode.@ranks`; if a new rank-3
  mode is added to production code, the test will not automatically include it.
  The author must remember to update `@peers`.
- StreamData's `check all` over a 3-element set does not guarantee all 9 pairs
  are generated in any single run; it exhausts them probabilistically. A
  deterministic exhaustion would require `for req <- @peers, par <- @peers` in
  an example test. This proposal accepts the probabilistic coverage.
- The `FunctionClauseError` example tests hard-code two specific unknown atoms;
  a property over `StreamData.atom(:alphanumeric)` filtered against `@modes`
  would be stronger but is not required by the acceptance criterion.

### Costs

- One file changed: `test/tau/permissions/mode_test.exs`.
- ~25 lines added.
- No new dependency; `StreamData` is already in use.
- Zero production-code risk.

## Dependencies

- None. The production module `Tau.Permissions.Mode` is unchanged.
- `ExUnitProperties` already `use`d in the existing test module.

## Confidence

medium. The sketch is concrete and maps directly to the acceptance criterion.
Confidence is not `high` because the probabilistic vs deterministic question
(StreamData exhaustion over a 3-element set) has not been prototyped; a
5-minute `mix test` run would raise it to `high`.

## Prior art / references

- Existing `property "clamp/2 returns requested when requested is a mode at-or-below parent"` in `mode_test.exs` — direct structural predecessor.
- StreamData `member_of/1` docs: a generator over a finite list naturally
  produces the cartesian product given sufficient runs.
- ADR-0015 (ceiling clamp for sub-agent spawn) — the peer-rank invariant is the
  operational foundation of the ADR.
