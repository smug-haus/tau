---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Standalone loader_property_test.exs with contract-first layout

## Approach

Create a new file `test/tau/settings/loader_property_test.exs` whose
entire content is property tests — no example tests. The file opens with
a module-level `@moduledoc` that states the three invariants of
`Loader.merge/2` in prose (the contract), followed immediately by the
`property/2` blocks that mechanically verify each one. The existing
`loader_test.exs` is left entirely unchanged. A shared generator
`test/support/settings_generators.ex` is also created, exporting
`settings_map/0` and `list_key_pair/0`, available to any future
settings property test.

## Rationale

The leaf problem's complecting hypothesis is that the invariants are
embedded in implementation code but documented only through coincidental
examples, making it impossible to tell what is contractual. A standalone
file whose name ends in `_property_test.exs` and whose opening `@moduledoc`
states the invariants as prose makes the contract explicit and locatable.
The separation also means a reviewer reading `loader_test.exs` sees examples
and a reviewer reading `loader_property_test.exs` sees specifications — the
two concerns are no longer woven together. The shared generator module pays
the per-test setup cost once and makes future property tests cheaper.

## Sketch

```
# New files:
#   test/tau/settings/loader_property_test.exs
#   test/support/settings_generators.ex
```

```elixir
# test/support/settings_generators.ex
defmodule Tau.Test.SettingsGenerators do
  @moduledoc """
  StreamData generators for Tau.Settings property tests.

  All generators produce structurally coherent inputs: a given key always
  has the same value type across independently generated maps (enforced by
  generating the key-type assignment first, then generating values).
  """
  use ExUnitProperties

  @list_keys [:hooks, :extensions, :mcp, :allow, :deny, :ask, :permissions]

  @doc """
  Generates a settings map whose list-keys always carry lists and whose
  non-list keys always carry scalars. A fixed key-type schema is generated
  first; values are then generated according to that schema. This ensures
  structural coherence across independently generated maps sharing the
  same schema — a requirement for associativity tests.
  """
  @spec settings_map_with_schema() :: StreamData.t({map(), map()})
  def settings_map_with_schema do
    # Generate a schema: which keys are present and are they list or scalar?
    key_schema_gen =
      StreamData.map(
        StreamData.list_of(
          StreamData.tuple({
            StreamData.atom(:alphanumeric),
            StreamData.member_of([:scalar, :list])
          }),
          min_length: 1, max_length: 6
        ),
        &Map.new/1
      )

    StreamData.bind(key_schema_gen, fn schema ->
      value_maps =
        schema
        |> Enum.map(fn {k, :scalar} ->
          {k, StreamData.one_of([
            StreamData.string(:alphanumeric, max_length: 8),
            StreamData.integer(0..100)
          ])}
          {k, :list} ->
          {k, StreamData.list_of(StreamData.integer(0..50), max_length: 5)}
        end)

      # Build three maps from the same schema (for associativity)
      {m1, m2, m3} =
        Enum.reduce(value_maps, {%{}, %{}, %{}}, fn {k, gen}, {a, b, c} ->
          StreamData.bind(gen, fn va ->
            StreamData.bind(gen, fn vb ->
              StreamData.bind(gen, fn vc ->
                {Map.put(a, k, va), Map.put(b, k, vb), Map.put(c, k, vc)}
              end)
            end)
          end)
        end)

      StreamData.constant({m1, m2, m3, schema})
    end)
  end

  @doc "Generates {list_key, xs, ys} triples for concatenation tests."
  @spec list_key_pair() :: StreamData.t({atom(), list(), list()})
  def list_key_pair do
    StreamData.tuple({
      StreamData.member_of(@list_keys),
      StreamData.list_of(StreamData.integer(), max_length: 8),
      StreamData.list_of(StreamData.integer(), max_length: 8)
    })
  end
end
```

```elixir
# test/tau/settings/loader_property_test.exs
defmodule Tau.Settings.LoaderPropertyTest do
  @moduledoc """
  Contract specification for Tau.Settings.Loader.merge/2.

  The following invariants hold by design and MUST continue to hold:

  1. **Associativity**: merge(merge(a, b), c) == merge(a, merge(b, c))
     for any three settings maps that share a type-coherent schema
     (same key always has same value type across layers).

  2. **List-key concatenation**: for any key in list_keys/0 and any
     lists xs, ys: merge(%{k => xs}, %{k => ys})[k] == xs ++ ys.

  3. **Scalar override**: for any non-list, non-map value, the later
     layer always wins: merge(%{k => v1}, %{k => v2})[k] == v2.

  4. **Idempotency of identical layers**: merge(a, a) == a.

  Commutativity is NOT an invariant: later-layer wins for scalars and
  list-key ordering preserves earlier-first; merge(a, b) != merge(b, a)
  in general.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Settings.Loader
  alias Tau.Test.SettingsGenerators, as: Gen

  @moduletag :property

  property "associativity: merge(merge(a,b),c) == merge(a,merge(b,c))" do
    check all({a, b, c, schema} <- Gen.settings_map_with_schema()) do
      lhs = Loader.merge(Loader.merge(a, b), c)
      rhs = Loader.merge(a, Loader.merge(b, c))
      assert lhs == rhs,
             "Associativity failed for schema #{inspect(schema)}\n" <>
             "a=#{inspect(a)}\nb=#{inspect(b)}\nc=#{inspect(c)}"
    end
  end

  property "list-key concatenation under arbitrary list inputs" do
    check all({k, xs, ys} <- Gen.list_key_pair()) do
      merged = Loader.merge(%{k => xs}, %{k => ys})
      assert merged[k] == xs ++ ys,
             "Concatenation failed for key #{k}: " <>
             "expected #{inspect(xs ++ ys)}, got #{inspect(merged[k])}"
    end
  end

  property "scalar override: later layer wins for non-list non-map values" do
    scalar = StreamData.one_of([
      StreamData.string(:alphanumeric, max_length: 8),
      StreamData.integer(),
      StreamData.boolean()
    ])
    check all(
      k  <- StreamData.atom(:alphanumeric),
      v1 <- scalar,
      v2 <- scalar
    ) do
      assert Loader.merge(%{k => v1}, %{k => v2}) == %{k => v2}
    end
  end

  property "idempotency: merge(a, a) == a for any coherent settings map" do
    check all({a, _b, _c, _schema} <- Gen.settings_map_with_schema()) do
      assert Loader.merge(a, a) == a
    end
  end
end
```

File moves: none. New files: 2. Existing files changed: 0.

## Tradeoffs

### Strengths

- The `@moduledoc` in `loader_property_test.exs` is a self-contained,
  prose specification of the merge contract — addresses the complecting
  hypothesis directly by making the contract explicit and separate.
- Explicitly states that commutativity is NOT an invariant, which is
  as important as stating what is invariant.
- `SettingsGenerators` is reusable by sibling problem tests and any
  future settings property test.
- `@moduletag :property` means all tests in the file run under
  `mix test --only property` without per-`describe` tagging.
- The structural-coherence constraint on the generator (same key always
  has same type) is encoded in `settings_map_with_schema/0`, preventing
  the false-associativity-failure trap.

### Weaknesses

- Two new files instead of one edit — higher surface area for a
  reviewer to assess.
- `settings_map_with_schema/0` uses nested `StreamData.bind/2` chains
  that are more complex to read and debug than a simple generator;
  the sketch above has a structural bug (the `Enum.reduce` returning
  `StreamData.bind` calls inside a reducer doesn't compose correctly)
  and needs careful revision before it will compile.
- `test/support/settings_generators.ex` adds a shared test-support
  module that requires consensus on naming and placement conventions
  for the project's test-support tree.
- If the generator bug in the sketch (see Weaknesses above) propagates
  to the implementation, the `settings_map_with_schema/0` property
  may silently generate only trivial maps.

### Costs

- ~120 lines across two new files. Zero production code changes.
- The `SettingsGenerators` module must be added to `test/support/` and
  `mix.exs`'s `:test` compilation paths, which may require a
  `test_helper.exs` or `mix.exs` edit to ensure it compiles.
- One careful review of `settings_map_with_schema/0` for generator
  composition correctness before merge.

## Dependencies

- `ExUnitProperties` + `StreamData` already in dev deps.
- `test/support/` directory already exists (confirmed by
  `test/support/tui_pty_helper.ex`).
- No production code changes.

## Confidence

Medium. The two-file structure and prose contract are the right shape.
Confidence would rise to high once `settings_map_with_schema/0` is
prototyped and confirmed to generate structurally coherent triples.

## Prior art / references

- `test/tau/settings/vault/env_test.exs` — `@describetag :property` and
  `ExUnitProperties` conventions already established.
- Elm's `Fuzz` module pattern of documenting algebraic laws as `@moduledoc`
  prose above the property tests.
- The leaf problem's acceptance criterion explicitly names
  `loader_property_test.exs` as a valid alternative to extending
  `loader_test.exs`.
