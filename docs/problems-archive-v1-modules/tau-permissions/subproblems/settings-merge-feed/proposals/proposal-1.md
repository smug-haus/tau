---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Add StreamData properties in-place to loader_test.exs

## Approach

Extend the existing `test/tau/settings/loader_test.exs` file with two new
`property` blocks inside the existing `describe "merge/2"` group. No new
files, no new modules. Add `use ExUnitProperties` and `import StreamData` at
the top of the module, then write the two properties the acceptance criterion
names: (1) the prefix-then-suffix concatenation invariant for all three
permissions arrays (`allow`, `deny`, `ask`), and (2) the identity invariant
for merging any settings map with an empty map.

## Rationale

The problem is a test-coverage gap, not a structural deficiency in the
production code. The simplest path to closing the gap is to add the
properties alongside the existing examples, keeping all tests for `merge/2`
co-located. This directly satisfies the acceptance criterion with the
minimum diff surface: two `property` blocks added to one file. It also
makes the pairing between example tests and property tests visible at a
glance — a reader sees both probes of the same function in one place.
The existing example on line 27–31 (deny concatenation) acts as a sanity
anchor for the new property.

## Sketch

```elixir
# test/tau/settings/loader_test.exs  — additions only

defmodule Tau.Settings.LoaderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties          # ← add

  alias Tau.Settings.Loader

  # --- existing describe block unchanged ---

  describe "merge/2 properties" do
    property "permissions arrays (allow/deny/ask) are prefix-then-suffix concatenation" do
      check all(
              a_list <- list_of(string(:alphanumeric, min_length: 1)),
              b_list <- list_of(string(:alphanumeric, min_length: 1)),
              key    <- member_of([:allow, :deny, :ask])
            ) do
        a = %{permissions: %{key => a_list}}
        b = %{permissions: %{key => b_list}}
        merged = Loader.merge(a, b)
        assert merged[:permissions][key] == a_list ++ b_list
      end
    end

    property "merging any settings map with empty map is identity" do
      check all(
              # Generate a map that may or may not contain a permissions block
              base <- map_of(
                        atom(:alphanumeric),
                        one_of([
                          string(:alphanumeric),
                          integer(),
                          list_of(string(:alphanumeric))
                        ])
                      )
            ) do
        assert Loader.merge(base, %{}) == base
      end
    end
  end
end
```

Both properties depend only on `StreamData`, which is already a test
dependency in `mix.exs`. No generator helpers are needed; inline generators
are sufficient.

## Tradeoffs

### Strengths

- Smallest possible diff: one file, two `property` blocks, one added `use`.
- Co-location — all `merge/2` coverage (examples + properties) lives in one
  test module, easy to find and reason about together.
- Zero new modules; zero new files; the change is atomic and reviewable in
  one scroll.
- Directly satisfies both acceptance-criterion properties with minimal risk
  of reviewer scope-creep concern.

### Weaknesses

- The property generator for the `merge(x, %{})` identity test uses
  `map_of(atom(:alphanumeric), ...)` which generates atom keys, not the
  mixed atom/string key shapes that real settings maps may use. A subtle
  generator mismatch could leave the identity property satisfied trivially
  for generated inputs but failing for real-world inputs with string keys.
- Inline generators make the test harder to reuse if other test modules in
  this problem set (e.g. `matcher_test.exs`) need similar settings shapes.
  Each module would re-invent generators from scratch.
- The `concat` property tests only the three named keys (`allow`/`deny`/`ask`)
  individually. It does not cover the multi-key case where all three are
  present simultaneously in both layers — a gap an adversary could exploit
  to introduce a cross-key ordering bug.
- No assertion that `merge/2`'s concat semantics for `:hooks` and
  `:extensions` (sibling list-keys) are preserved; the acceptance criterion
  doesn't require this, but in-file placement invites scope inflation later.

### Costs

- ~25 lines of new test code.
- No migration cost; no callsite changes; no new dependencies.
- CI impact: property tests run `check all` with 100 (default) iterations
  each; negligible wall-time addition (< 1 s in typical StreamData runs).

## Dependencies

- `{:stream_data, "~> 1.1", only: [:test, :dev]}` already present in
  `mix.exs` — no dependency change.
- No production code changes required.

## Confidence

medium — The approach is structurally straightforward and prior art
(existing property tests in `mode_test.exs`) demonstrates StreamData is used
in this project. Confidence is not `high` because the identity property's
generator shape needs verification that `Loader.merge/2` handles atom-keyed
generated maps correctly (the function takes `map()`, which includes both
atom and string keys, but real settings are always atom-keyed from
`Jason.decode(..., keys: :atoms)` — the generator matches reality).

## Prior art / references

- `test/tau/permissions/mode_test.exs` — existing StreamData property usage
  in this project; the `check all` + `member_of` pattern mirrors what is
  proposed here.
- `ExUnitProperties` docs: https://hexdocs.pm/stream_data/ExUnitProperties.html
- OTP NN #6: "Invariant-bearing modules MUST have properties before examples."
