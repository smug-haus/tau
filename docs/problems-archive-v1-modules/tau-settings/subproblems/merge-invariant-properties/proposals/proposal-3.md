---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Extract merge contract to a typespec + property-verified behaviour

## Approach

Promote `merge/2` and `merge_value/3` to a formal `@behaviour`-driven
contract by (a) introducing a `Tau.Settings.MergeBehaviour` behaviour
module with a single `@callback merge(map(), map()) :: map()` and a
`@doc` that states the algebraic laws, and (b) making
`Tau.Settings.Loader` `@impl true` its `merge/2` against that behaviour.
A companion `test/tau/settings/merge_behaviour_test.exs` uses the
behaviour's declared laws to generate shared property tests that any
`MergeBehaviour` implementation must pass — invoked once for
`Tau.Settings.Loader`. The existing four example tests in
`loader_test.exs` are left unchanged.

## Rationale

The complecting hypothesis is that the invariants are embedded in
implementation code and documented only via coincidental examples. A
`@behaviour` with a `@doc` stating the algebraic laws separates the
*specification* (what merge must always do) from the *implementation*
(how `Loader` does it), which is the canonical Elixir/OTP decomplecting
move for extensibility seams (OTP NN #2). The property test file derives
directly from the behaviour's declared contract, not from an informal
reading of the implementation — making the relationship between
specification and verification explicit and machine-checkable.

## Sketch

```elixir
# lib/tau/settings/merge_behaviour.ex  (new file)
defmodule Tau.Settings.MergeBehaviour do
  @moduledoc """
  Contract for deep cascade-merge of settings maps.

  Implementations MUST satisfy the following algebraic laws:

  - **Associativity** (for type-coherent inputs):
      merge(merge(a, b), c) == merge(a, merge(b, c))

  - **Scalar override**: for any non-list, non-map value v1, v2 at key k:
      merge(%{k => v1}, %{k => v2})[k] == v2

  - **List-key concatenation** (for keys in list_keys/0):
      merge(%{k => xs}, %{k => ys})[k] == xs ++ ys

  - **Idempotency of identical layers**:
      merge(a, a) == a

  Commutativity is NOT required: merge(a, b) != merge(b, a) in general.
  Later-layer wins for scalars; earlier-layer-first for list concatenation.
  """

  @doc """
  Deep-merge two settings maps. The second argument (b) is the "later
  layer" — its scalar values override a's; its list values at known
  list-keys are appended to a's.
  """
  @callback merge(map(), map()) :: map()
end
```

```elixir
# lib/tau/settings/loader.ex  (modifications only)
defmodule Tau.Settings.Loader do
  @behaviour Tau.Settings.MergeBehaviour   # <-- add

  # ...

  @impl Tau.Settings.MergeBehaviour         # <-- add
  @spec merge(map(), map()) :: map()
  def merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn k, v1, v2 -> merge_value(k, v1, v2) end)
  end

  # ... rest unchanged ...
end
```

```elixir
# test/tau/settings/merge_behaviour_test.exs  (new file)
defmodule Tau.Settings.MergeBehaviourTest do
  @moduledoc """
  Property verification of the Tau.Settings.MergeBehaviour contract.

  Each implementation under test must be listed in @implementations.
  The properties are derived directly from the @callback @doc in
  Tau.Settings.MergeBehaviour.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  @implementations [Tau.Settings.Loader]

  @list_keys [:hooks, :extensions, :mcp, :allow, :deny, :ask, :permissions]

  # Simple coherent-schema generator: generates a pair {a, b} where
  # each key has the same type in both maps.
  defp coherent_pair do
    StreamData.bind(
      StreamData.list_of(
        StreamData.tuple({
          StreamData.atom(:alphanumeric),
          StreamData.member_of([:scalar, :list])
        }),
        min_length: 0, max_length: 5
      ),
      fn schema_list ->
        schema = Map.new(schema_list)
        entries_gen =
          Enum.map(schema, fn
            {k, :scalar} ->
              {k, StreamData.string(:alphanumeric, max_length: 6)}
            {k, :list} ->
              {k, StreamData.list_of(StreamData.integer(0..20), max_length: 4)}
          end)

        # Generate three independent value bindings per key
        StreamData.fixed_map(
          Map.new(entries_gen, fn {k, gen} ->
            {k, StreamData.tuple({gen, gen, gen})}
          end)
        )
        |> StreamData.map(fn kv_triples ->
          {
            Map.new(kv_triples, fn {k, {v1, _v2, _v3}} -> {k, v1} end),
            Map.new(kv_triples, fn {k, {_v1, v2, _v3}} -> {k, v2} end),
            Map.new(kv_triples, fn {k, {_v1, _v2, v3}} -> {k, v3} end)
          }
        end)
      end
    )
  end

  for impl <- @implementations do
    @impl_mod impl

    describe "#{inspect(impl)} satisfies MergeBehaviour contract" do
      property "associativity" do
        check all({a, b, c} <- coherent_pair()) do
          lhs = @impl_mod.merge(@impl_mod.merge(a, b), c)
          rhs = @impl_mod.merge(a, @impl_mod.merge(b, c))
          assert lhs == rhs
        end
      end

      property "idempotency of identical layers" do
        check all({a, _b, _c} <- coherent_pair()) do
          assert @impl_mod.merge(a, a) == a
        end
      end

      property "list-key concatenation" do
        check all(
          k  <- StreamData.member_of(@list_keys),
          xs <- StreamData.list_of(StreamData.integer(), max_length: 6),
          ys <- StreamData.list_of(StreamData.integer(), max_length: 6)
        ) do
          assert @impl_mod.merge(%{k => xs}, %{k => ys})[k] == xs ++ ys
        end
      end

      property "scalar override" do
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
          assert @impl_mod.merge(%{k => v1}, %{k => v2}) == %{k => v2}
        end
      end
    end
  end
end
```

File summary:
- `lib/tau/settings/merge_behaviour.ex` — new (behaviour + law docs)
- `lib/tau/settings/loader.ex` — add `@behaviour` + `@impl` annotations
- `test/tau/settings/merge_behaviour_test.exs` — new (property tests keyed
  to `@implementations` list)

## Tradeoffs

### Strengths

- The `@behaviour` declaration makes the contract machine-verifiable by
  the Elixir compiler (`@impl true` raises a warning if the callback
  signature is wrong) and by Dialyzer.
- The `@moduledoc` on `MergeBehaviour` is the canonical location for the
  contract prose — the invariants are no longer coincidental, they are
  the official spec.
- The `@implementations` list in the test makes it trivial to add a
  second implementation (e.g., a test-double or a stricter merge
  strategy) and immediately have it verified against the same contract.
- Directly addresses OTP NN #2 ("extensibility seams MUST be
  behaviours") in addition to OTP NN #6.

### Weaknesses

- Introduces a `@behaviour` for a function that currently has exactly
  one implementation and no near-term plan for a second — this is
  speculative extensibility, which Hickey would call premature
  complexity.
- `lib/tau/settings/merge_behaviour.ex` is a new production module that
  must be maintained forever; if `merge/2` ever changes signature, the
  behaviour must change too.
- The `for impl <- @implementations` + `@impl_mod` compile-time
  macro pattern is unusual and may surprise readers unfamiliar with
  it; the generated describe-block name helps but the mechanism is
  non-obvious.
- Adding `@behaviour` to `Loader` changes its public API surface
  (it now claims to implement a behaviour), which could confuse readers
  expecting `Loader` to be a purely functional module with no
  polymorphism.

### Costs

- One new production file (`merge_behaviour.ex`), one new test file,
  two lines changed in `loader.ex`.
- Dialyzer must be re-run after merging to confirm no spec regressions.
- Team must decide: is `MergeBehaviour` the right abstraction boundary?
  If not, the behaviour is dead weight.

## Dependencies

- No library changes.
- Elixir 1.18.1 `@behaviour` / `@impl` are fully supported.
- The `coherent_pair/0` generator in the sketch uses `StreamData.fixed_map/1`
  with a map of generators — verify this API is available in the project's
  pinned `stream_data` version before committing.

## Confidence

Low-to-medium. The property tests are the right move; the `@behaviour`
is justifiable but adds scope beyond the acceptance criterion. Confidence
would rise to medium if the team confirms a second implementation is on the
roadmap (making the behaviour non-speculative).

## Prior art / references

- Elixir `Collectable` and `Enumerable` behaviours as precedent for
  algebraic-law-bearing callbacks.
- OTP NN #2 in `CLAUDE.md`: "extensibility seams MUST be behaviours;
  pattern match on atoms and structs."
- `Tau.Provider` behaviour in `lib/tau/provider.ex` — the project already
  uses this pattern for provider extensibility.
