---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Deterministic exhaustion via explicit cartesian-product example test

## Approach

Replace the three spot-check example tests in `describe "clamp/2 — peer modes"`
with a single example test that iterates all 9 peer × peer combinations using
a comprehension, and add a separate dedicated `describe "at_or_below?/2 —
properties"` block with a property for reflexivity and an explicit guard
documentation test. Unlike Proposal 1, this approach uses `for req <- @peers,
par <- @peers` (deterministic exhaustion) rather than a StreamData property,
and removes the three now-redundant spot-checks that it replaces. Production
code is not touched.

## Rationale

The acceptance criterion says "a property test exhausts all combinations." A
`for` comprehension over a 3-element list is provably exhaustive — it generates
exactly 9 assertions in every test run, without probabilistic sampling. The
existing three spot-checks are a strict subset of the 9 pairs; replacing them
with the comprehensive loop removes the gap and the redundancy simultaneously.
This directly decomplects "we checked some peers" from "we checked all peers":
the exhaustion is structural, not statistical. The description also tightens
the claim from "tests pass for some peers" to "tests pass for all peers."

## Sketch

```elixir
# In test/tau/permissions/mode_test.exs

@peers [:accept_edits, :dont_ask, :plan]

# REPLACE the existing three-test "clamp/2 — peer modes" describe block with:
describe "clamp/2 — peer modes (exhaustive 9-pair sweep)" do
  # The peer-rank invariant: all three share rank 3, so clamp leaves
  # requested standing in every peer × peer combination.
  # ADR-0015 ceiling clamp relies on this.
  test "all 9 peer × peer combinations: requested is returned unchanged" do
    for req <- @peers, par <- @peers do
      assert Mode.clamp(req, par) == req,
             "expected clamp(#{inspect(req)}, #{inspect(par)}) == #{inspect(req)}"
    end
  end
end

# ADD a new dedicated describe block (does not replace any existing block):
describe "at_or_below?/2 — properties" do
  @moduletag :property

  property "at_or_below?/2 is reflexive for all known modes" do
    check all(m <- StreamData.member_of(@modes)) do
      assert Mode.at_or_below?(m, m)
    end
  end

  test "guard raises FunctionClauseError on unknown child" do
    assert_raise FunctionClauseError, fn -> Mode.at_or_below?(:nope, :plan) end
  end

  test "guard raises FunctionClauseError on unknown parent" do
    assert_raise FunctionClauseError, fn -> Mode.at_or_below?(:plan, :nope) end
  end
end
```

File-level change summary:
- `test/tau/permissions/mode_test.exs`: remove 3 tests, add 1 test + 1 property + 2 tests.
- Net: +1 test, +1 property, -3 tests → test count decreases by 1 but coverage increases.

## Tradeoffs

### Strengths

- Deterministically exhaustive: every run exercises all 9 combinations; no
  statistical sampling risk.
- Self-documenting error message with `inspect` interpolation pinpoints exactly
  which `(req, par)` pair failed.
- Removes the three spot-checks that gave false comfort, clarifying that the
  test is now complete rather than representative.
- Aligns acceptance criterion language ("exhausts all combinations") with
  implementation language (a loop that literally iterates the cartesian product).

### Weaknesses

- Deletes existing tests, which may be seen as behaviour-correcting rather than
  purely additive. This requires reviewer attention to confirm the new loop is
  strictly a superset of the removed spot-checks.
- A `for` comprehension test is sometimes seen as "testing the test" rather than
  naming each case; if a case fails, the error message is harder to read in
  tree-view test reporters that don't show per-iteration context.
- The reflexivity property still uses StreamData; a reviewer expecting purely
  deterministic tests may question why StreamData is used for a 6-element space.

### Costs

- One file changed: `test/tau/permissions/mode_test.exs`.
- ~20 lines added, 10 lines removed (the three individual spot-check tests).
- Minor review cost: a reviewer must confirm the 3 removed tests are subsumed.

## Dependencies

- None. Production module unchanged.
- `ExUnitProperties` already `use`d.

## Confidence

high. The cartesian product over a 3-element list is a standard Elixir idiom;
the `for` comprehension approach is demonstrated in the existing `describe "clamp/2
— equal modes"` block (`for m <- @modes`). No new dependency or tooling needed.

## Prior art / references

- Existing `test "every mode clamped against itself returns itself"` uses `for m <- @modes` — direct structural predecessor for the exhaustion pattern.
- Elixir `for` comprehension with multiple `<-` generators produces the cartesian product by definition.
- ADR-0015: peer-rank invariant underpins the ceiling clamp contract.
