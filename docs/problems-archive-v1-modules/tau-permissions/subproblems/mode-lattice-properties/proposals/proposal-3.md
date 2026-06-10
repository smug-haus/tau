---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Expose peer-rank set from Mode module and derive tests from it

## Approach

Add a public `Mode.peer_modes/0` function (or a `@peer_modes` module attribute
exposed via a zero-arity function) to `lib/tau/permissions/mode.ex` that returns
the set of modes sharing the highest rank. Tests in `mode_test.exs` then derive
the peer set from the production module itself: the peer-rank property generates
from `StreamData.member_of(Mode.peer_modes())`, and the `at_or_below?/2` property
generates from `StreamData.member_of(Mode.modes())` (a new companion function
returning all known modes). This decomplects the test's knowledge of which modes
are peers from the test itself: the test no longer hard-codes `[:accept_edits,
:dont_ask, :plan]` but instead queries the module.

## Rationale

The existing acceptance criterion is a test-coverage gap, but its deeper
root is that the peer-rank invariant is unstated in the production code: the
fact that three atoms share rank 3 is embedded in `@ranks` and documented
in a moduledoc comment, but there is no machine-readable boundary a caller
or test can query. Exposing `peer_modes/0` moves the definition of "which modes
are peers" into the module that owns the lattice. Tests automatically track
lattice changes: if a new rank-3 mode is added to `@ranks`, `peer_modes/0`
returns it and the property includes it without a manual test update. This
is the data-shape axis: the fix is in the interface, not just in the tests.

## Sketch

```elixir
# Addition to lib/tau/permissions/mode.ex

@doc """
Returns the set of modes sharing the maximum (most-restrictive) rank.
These modes are unordered relative to each other; `clamp/2` treats any
peer as at-or-below any other peer.

Used by property tests and by callers that need to enumerate the peer
tier without hard-coding atoms.
"""
@spec peer_modes() :: [mode()]
def peer_modes do
  max_rank = @ranks |> Map.values() |> Enum.max()
  @ranks |> Enum.filter(fn {_m, r} -> r == max_rank end) |> Enum.map(&elem(&1, 0))
end

@doc """
Returns all recognised mode atoms. Equivalent to `Map.keys(@ranks)`.
"""
@spec modes() :: [mode()]
def modes, do: Map.keys(@ranks)
```

```elixir
# Additions to test/tau/permissions/mode_test.exs

@moduletag :property

property "clamp/2 preserves requested for all peer × peer combinations" do
  peers = Mode.peer_modes()
  check all(
    requested <- StreamData.member_of(peers),
    parent    <- StreamData.member_of(peers)
  ) do
    assert Mode.clamp(requested, parent) == requested
  end
end

property "at_or_below?/2 is reflexive for all known modes" do
  check all(m <- StreamData.member_of(Mode.modes())) do
    assert Mode.at_or_below?(m, m)
  end
end

describe "at_or_below?/2 — guard on unknown atoms" do
  test "raises for unknown child" do
    assert_raise FunctionClauseError, fn -> Mode.at_or_below?(:unknown, :plan) end
  end

  test "raises for unknown parent" do
    assert_raise FunctionClauseError, fn -> Mode.at_or_below?(:plan, :unknown) end
  end
end
```

File changes:
- `lib/tau/permissions/mode.ex`: add `peer_modes/0` and `modes/0` (pure, no side effects).
- `test/tau/permissions/mode_test.exs`: add two properties and one describe block.
  The existing `@modes` test-local attribute can be replaced by `Mode.modes()`.

## Tradeoffs

### Strengths

- Self-maintaining: adding a new rank-3 mode to `@ranks` automatically includes
  it in the peer-sweep property without touching the test.
- Decomplects the "which modes are peers" knowledge from the test into the
  module, which is where it belongs under the lattice's stated ownership contract.
- `modes/0` unifies the test-local `@modes` attribute with the production
  module — one source of truth.
- Tests use the module's own definition of its lattice, making them robust to
  lattice extension (the stated regression scenario in the problem).

### Weaknesses

- Touches production code (`mode.ex`) to fix a test-coverage gap. This may
  be seen as scope creep — the gap is a test gap, and a production API change
  to serve tests is a code-smell in some disciplines.
- `peer_modes/0` returns a list (order undefined by Elixir's `Map.keys`); tests
  that depend on it must not assume order, which is fine for StreamData but
  could surprise future example-test authors.
- Two new public functions add API surface to a module that otherwise has a
  compact public interface (`mode?`, `clamp`, `at_or_below?`, `rank`).
- The acceptance criterion names no requirement for a production API change;
  this proposal goes beyond the stated criterion.

### Costs

- Two files changed: `lib/tau/permissions/mode.ex` (+10 lines), `test/tau/permissions/mode_test.exs` (+~20 lines, optional removal of `@modes`).
- New public functions require `@spec` and `@doc` (included in sketch).
- Dialyzer will typecheck the new specs; no added risk.

## Dependencies

- None beyond the existing `Tau.Permissions.Mode` module.
- `StreamData` already in use.

## Confidence

medium. The production-code change is straightforward, but "touch production
to fix a test gap" is a non-obvious trade. Confidence would rise to `high`
with a reviewer sign-off that `peer_modes/0` and `modes/0` are desirable API
additions independent of the test motivation.

## Prior art / references

- Haskell `QuickCheck` idiom: derive generators from the data type's own
  constructors/reflection rather than hard-coding them in tests.
- Elixir `Ecto.Type` pattern: expose `cast/1` + `type/0` so tests can
  enumerate the type's values without hard-coding.
- ADR-0015: the peer tier is semantically distinct; exposing it as
  `peer_modes/0` makes ADR-0015's "peer" concept machine-readable.
