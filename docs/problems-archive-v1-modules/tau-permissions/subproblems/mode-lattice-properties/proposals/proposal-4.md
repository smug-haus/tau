---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Split at_or_below?/2 into guarded and total variants, then test both

## Approach

Refactor `at_or_below?/2` in `lib/tau/permissions/mode.ex` into two functions:
`at_or_below?/2` (kept as the guarded function, unchanged contract, raises on
unknown atoms) and a new `at_or_below_safe?/2` (total function, returns
`{:ok, boolean()} | {:error, :unknown_mode}`). Tests cover both:
`at_or_below?/2` gets a reflexivity property over known modes and explicit
raise-assertions for unknown atoms; `at_or_below_safe?/2` gets a property
that it never returns `:error` for known modes and always returns `:error`
for unknown atoms. `clamp/2` continues to call `at_or_below?/2` (no callers
change). The peer-sweep property for `clamp/2` is added as in Proposal 1.

## Rationale

The problem statement identifies two distinct issues: (a) peer-rank not
property-swept, and (b) `at_or_below?/2`'s guard clause is "dead code for
`clamp/2`'s callers, but external callers could pass unknown atoms and receive
a FunctionClauseError." The acceptance criterion asks for a property that
"raises or returns false on unknown atoms — clarifying the guard semantics."
The phrase "clarifying" implies the current semantics are ambiguous. Proposal 4
resolves the ambiguity by making the two behaviours explicit: the guarded
function raises (contract: caller must ensure valid modes), the safe function
returns a tagged tuple (contract: caller handles unknown atoms). This is a
behaviour-correcting refactor on `at_or_below?/2`'s external API — not on
`clamp/2`, which calls the guarded variant after `mode?/1` validation.

## Sketch

```elixir
# lib/tau/permissions/mode.ex — add alongside existing at_or_below?/2

@doc """
Total variant of `at_or_below?/2`. Returns `{:ok, boolean()}` for known
modes, `{:error, :unknown_mode}` when either argument is not a recognised
mode atom. Never raises.

Prefer this when callers cannot guarantee their inputs are valid modes
(e.g. values from user config, network payloads). Use `at_or_below?/2`
directly only when calling code has already validated both arguments
(as `clamp/2` does via `mode?/1`).
"""
@spec at_or_below_safe?(term(), term()) :: {:ok, boolean()} | {:error, :unknown_mode}
def at_or_below_safe?(child, parent) do
  if mode?(child) and mode?(parent) do
    {:ok, at_or_below?(child, parent)}
  else
    {:error, :unknown_mode}
  end
end
```

```elixir
# test/tau/permissions/mode_test.exs — additions

@peers [:accept_edits, :dont_ask, :plan]

# Peer-rank sweep (same as Proposal 1, included for completeness):
property "clamp/2 preserves requested for all peer × peer combinations" do
  check all(
    requested <- StreamData.member_of(@peers),
    parent    <- StreamData.member_of(@peers)
  ) do
    assert Mode.clamp(requested, parent) == requested
  end
end

# Guarded at_or_below?/2 properties:
property "at_or_below?/2 is reflexive for all known modes" do
  check all(m <- StreamData.member_of(@modes)) do
    assert Mode.at_or_below?(m, m)
  end
end

describe "at_or_below?/2 — guard raises for unknown atoms" do
  test "unknown child raises" do
    assert_raise FunctionClauseError, fn -> Mode.at_or_below?(:nope, :plan) end
  end
  test "unknown parent raises" do
    assert_raise FunctionClauseError, fn -> Mode.at_or_below?(:plan, :nope) end
  end
end

# Safe total variant properties:
property "at_or_below_safe?/2 returns {:ok, _} for all known-mode pairs" do
  check all(
    child  <- StreamData.member_of(@modes),
    parent <- StreamData.member_of(@modes)
  ) do
    assert {:ok, _} = Mode.at_or_below_safe?(child, parent)
  end
end

property "at_or_below_safe?/2 returns {:error, :unknown_mode} for any unknown atom" do
  check all(
    child  <- StreamData.one_of([StreamData.constant(:nope), StreamData.member_of(@modes)]),
    parent <- StreamData.one_of([StreamData.constant(:nope), StreamData.member_of(@modes)]),
    child == :nope or parent == :nope
  ) do
    assert Mode.at_or_below_safe?(child, parent) == {:error, :unknown_mode}
  end
end
```

File changes:
- `lib/tau/permissions/mode.ex`: add `at_or_below_safe?/2` (+12 lines).
- `test/tau/permissions/mode_test.exs`: add 4 properties + 1 describe block (+~40 lines).

## Tradeoffs

### Strengths

- Directly resolves the stated ambiguity in the guard semantics: the two
  behaviours (raise vs return-false) are now separate functions with distinct
  type signatures.
- Test coverage is broader: the safe variant is fully property-swept over both
  valid and invalid inputs; the guarded variant's raises are documented and
  tested.
- Future callers that need fault-tolerant mode comparison have a clear API path
  (`at_or_below_safe?/2`) without needing to wrap `at_or_below?/2` in `try/rescue`.
- Adheres to the OTP non-negotiable "do not swallow errors, use tagged tuples."

### Weaknesses

- Adds production API surface beyond what the acceptance criterion requires; the
  criterion says "clarify guard semantics," not "add a total variant."
- `at_or_below_safe?/2` is unlikely to have callers in the current codebase;
  it may be dead code added speculatively.
- The proposal is the largest diff of the four: it touches both production and
  test files, adds two new properties for the safe variant, and the filter-based
  StreamData generator for the "any unknown" property is non-trivial to write
  correctly (the `check all` filter approach shown above may need tuning for
  shrinkability).
- Overloads the single-problem scope slightly: the acceptance criterion is about
  test coverage, not API design.

### Costs

- Two files changed: `lib/tau/permissions/mode.ex` (+~12 lines),
  `test/tau/permissions/mode_test.exs` (+~40 lines).
- New `@spec` and `@doc` required on the safe variant.
- Dialyzer coverage extended to the new function.
- Review cost is higher than Proposals 1 or 2 due to the production code change.

## Dependencies

- None. Production module change is purely additive; no callers change.
- `StreamData` already in use.

## Confidence

low. The proposal is sound, but the production API addition goes beyond the
acceptance criterion, and the StreamData filter-based generator for
"at least one unknown atom" requires careful construction to avoid `assume/1`
exhaustion. Confidence would rise to `medium` with a working prototype of the
safe-variant property, and to `high` with a reviewer endorsement that
`at_or_below_safe?/2` is wanted.

## Prior art / references

- Elixir convention: `foo!/1` raises, `foo/1` returns `{:ok, _} | {:error, _}` — this proposal inverts the naming (keeping `?` suffix), but follows the tagged-tuple pattern.
- `StreamData.filter/2` vs `StreamData.unshrinkable/1` tradeoff documented in StreamData docs — relevant to the "any unknown" property's generator design.
- ADR-0015: the guard clause in `at_or_below?/2` is documented as "dead code for `clamp/2`'s callers" — this proposal gives it a documented external caller contract instead.
