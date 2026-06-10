---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Inline property block in loader_test.exs

## Approach

Add a `property "merge invariants"` block directly into the existing
`test/tau/settings/loader_test.exs`, immediately after the four example
tests. The block uses `StreamData` generators to exercise three contractual
properties of `Loader.merge/2`: (a) associativity of three-layer merge,
(b) list-key concatenation under arbitrary list inputs, and (c) scalar
override (later layer wins). No new file is created; the test module
gains `use ExUnitProperties` and three `property/2` blocks.

## Rationale

The complecting hypothesis is that the invariants are documented only via
coincidental examples. Extending the existing test file with `property/2`
blocks directly specifies the contractual properties beside their example
counterparts, making the distinction between "contractual" and "incidental"
explicit without requiring the reader to cross file boundaries. The
approach is the smallest possible intervention: it adds signal (property
coverage) without moving, renaming, or splitting anything. It satisfies
OTP NN #6 at the minimal scope the rule requires.

## Sketch

```elixir
# test/tau/settings/loader_test.exs  (additions only)
defmodule Tau.Settings.LoaderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties                       # <-- add

  alias Tau.Settings.Loader

  # ... existing describe "merge/2" block unchanged ...

  describe "merge/2 properties" do
    @describetag :property

    # Generator: a settings map with atom keys and scalar/list/map values.
    # Keeps generators simple; structural complexity is exercised by
    # the associativity check.
    defp settings_gen do
      scalar = StreamData.one_of([
        StreamData.string(:alphanumeric, max_length: 8),
        StreamData.integer()
      ])
      list_val = StreamData.list_of(StreamData.string(:alphanumeric, max_length: 4),
                                    max_length: 4)
      key_gen = StreamData.member_of([:model, :theme, :hooks, :allow, :deny])

      StreamData.fixed_map(%{
        optional_key: StreamData.boolean()
      })
      |> StreamData.bind(fn _ ->
        StreamData.map(
          StreamData.list_of(
            StreamData.tuple({key_gen, StreamData.one_of([scalar, list_val])}),
            max_length: 5
          ),
          &Map.new/1
        )
      end)
    end

    property "associativity: merge(merge(a, b), c) == merge(a, merge(b, c))" do
      check all(
        a <- settings_gen(),
        b <- settings_gen(),
        c <- settings_gen()
      ) do
        assert Loader.merge(Loader.merge(a, b), c) ==
                 Loader.merge(a, Loader.merge(b, c))
      end
    end

    property "idempotency: merge(a, a) == a" do
      check all(a <- settings_gen()) do
        assert Loader.merge(a, a) == a
      end
    end

    property "list-key concatenation: length grows additively" do
      list_key = StreamData.member_of([:hooks, :allow, :deny, :extensions,
                                       :mcp, :ask, :permissions])
      check all(
        k    <- list_key,
        xs   <- StreamData.list_of(StreamData.integer(), max_length: 8),
        ys   <- StreamData.list_of(StreamData.integer(), max_length: 8)
      ) do
        merged = Loader.merge(%{k => xs}, %{k => ys})
        assert merged[k] == xs ++ ys
      end
    end

    property "scalar override: non-list, non-map values always take later layer" do
      non_list_scalar = StreamData.one_of([
        StreamData.string(:alphanumeric, max_length: 8),
        StreamData.integer(),
        StreamData.boolean()
      ])
      check all(
        k  <- StreamData.atom(:alphanumeric),
        v1 <- non_list_scalar,
        v2 <- non_list_scalar
      ) do
        assert Loader.merge(%{k => v1}, %{k => v2}) == %{k => v2}
      end
    end
  end
end
```

Key notes:
- `settings_gen/0` produces maps with a mix of list-keys and scalar keys,
  deliberately including keys from `list_keys/0` so the associativity check
  exercises both branches of `merge_value/3`.
- The `@describetag :property` tag means `mix test --only property` runs
  exactly these blocks and nothing else, matching the acceptance criterion.
- No new module. No behaviour change. No file move.

## Tradeoffs

### Strengths

- Minimal footprint: one file modified, zero new files.
- `mix test --only property` works immediately with the existing
  `ExUnitProperties` dependency already in `mix.exs`.
- Properties live adjacent to their example counterparts — a reader sees
  both the "what" (examples) and the "always" (properties) in one file.
- Idempotency property catches a subtle class of bug (a merge that
  doubles list-key values when merging identical layers) not covered by
  any current example.

### Weaknesses

- The `settings_gen/0` generator is ad-hoc and lives in the test module,
  not a shared support module — if a sibling problem needs similar
  generators they would be duplicated.
- Associativity of `merge/2` holds only when the value types are
  consistent across layers (map-map-map or list-list-list at the same
  key); the generator must be careful not to produce type conflicts at
  the same key that would make associativity vacuously false. The sketch
  above uses independent generators per key, which can produce type
  mismatches. A production version needs a generator that produces
  structurally coherent triples.
- Does not separate the property specification from the test file — the
  contractual documentation is still interleaved with tests rather than
  being a standalone spec artefact.

### Costs

- ~80 lines of new test code. No production code changes.
- Generator correctness requires care (see Weaknesses above); a first
  draft will likely need one or two refinement passes under `mix test`.
- `ExUnitProperties` is already a dev dependency; zero new deps.

## Dependencies

- `ExUnitProperties` and `StreamData` already present in `mix.exs`
  (confirmed by `test/tau/settings/vault/env_test.exs` using them).
- No production code changes; `Loader.merge/2` is already public.

## Confidence

Medium. The approach is straightforward and the tooling is in place.
Confidence would rise to high after a prototype run confirming the
generator produces structurally coherent inputs (the main risk).

## Prior art / references

- `test/tau/settings/vault/env_test.exs` — project-local precedent for
  `use ExUnitProperties` pattern and `@describetag :property` convention.
- OTP NN #6 in `CLAUDE.md` — explicit mandate naming `Settings.Loader`.
- Hickey "Simple Made Easy" — complecting specification with coincidental
  examples is a form of accidental complexity.
