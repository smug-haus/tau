---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Data-shape restructuring — explicit MergeRule type + table-driven merge

## Approach

Replace the implicit branching in `merge_value/3` with an explicit
`MergeRule` type and a table-driven dispatch. `list_keys/0` becomes a
`@list_key_rules` module attribute of type `%{atom() => :concat}`;
a new private `%MergeRule{}` struct captures `:concat | :override |
:deep_merge` per-key decisions; `merge_value/3` is rewritten as a
single pattern-match against the rule looked up from the table. Property
tests are then written against the rule table itself (not just the
function), asserting that every declared `:concat` rule produces
concatenation and every `:override` rule produces override — making the
contract mechanical and table-verifiable rather than logic-verifiable.

## Rationale

The complecting hypothesis is that the invariants are embedded in
implementation code in a way that makes it impossible to tell which
properties are contractual vs incidental. The current `merge_value/3`
uses a `if k in list_keys()` guard that requires reading the guard,
the body, and `list_keys/0` to reconstruct the contract. A rule-table
approach makes the contract data: the table IS the specification, and
the property tests verify that the dispatch function honours the table.
This is a data-shape change (not a control-flow change), and it means
the invariant is no longer embedded in logic — it is declared in data
and verified by testing that data.

## Sketch

```elixir
# lib/tau/settings/loader.ex  (rewrite of merge_value/3 and list_keys/0)
defmodule Tau.Settings.Loader do

  # The merge rule table IS the contract.
  # :concat  — lists concatenate (earlier-first)
  # (all other keys default to :override for scalars, :deep_merge for maps)
  @merge_rules %{
    hooks:       :concat,
    extensions:  :concat,
    mcp:         :concat,
    allow:       :concat,
    deny:        :concat,
    ask:         :concat,
    permissions: :concat
  }

  @doc "The merge rule table. Used by property tests to verify dispatch."
  @spec merge_rules() :: %{atom() => :concat}
  def merge_rules, do: @merge_rules

  @doc "Pure deep-merge of two settings maps."
  @spec merge(map(), map()) :: map()
  def merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn k, v1, v2 -> merge_value(k, v1, v2) end)
  end

  defp merge_value(_k, v1, v2) when is_map(v1) and is_map(v2),
    do: merge(v1, v2)

  defp merge_value(k, v1, v2) when is_list(v1) and is_list(v2) do
    case Map.get(@merge_rules, k, :override) do
      :concat   -> v1 ++ v2
      :override -> v2
    end
  end

  defp merge_value(_k, _v1, v2), do: v2

  # list_keys/0 is now derived from the rule table (no divergence possible)
  @doc false
  def list_keys, do: Map.keys(@merge_rules)

  # ... rest of load/1, paths/1, etc. unchanged ...
end
```

```elixir
# test/tau/settings/loader_property_test.exs  (new file)
defmodule Tau.Settings.LoaderPropertyTest do
  @moduledoc """
  Property tests for Tau.Settings.Loader.merge/2.

  Two verification layers:

  1. **Rule-table tests** — for each key declared in merge_rules/0,
     verify the dispatch function honours the declared rule. These tests
     are derived mechanically from the table, not from the implementation.

  2. **Algebraic-law tests** — associativity, idempotency, scalar
     override across arbitrary inputs.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Settings.Loader

  @moduletag :property

  describe "rule-table contract" do
    property "every :concat-rule key produces v1 ++ v2" do
      concat_keys = for {k, :concat} <- Loader.merge_rules(), do: k

      check all(
        k  <- StreamData.member_of(concat_keys),
        xs <- StreamData.list_of(StreamData.integer(), max_length: 6),
        ys <- StreamData.list_of(StreamData.integer(), max_length: 6)
      ) do
        assert Loader.merge(%{k => xs}, %{k => ys})[k] == xs ++ ys
      end
    end
  end

  describe "algebraic laws" do
    # Coherent-triple generator: same key always has same type in a, b, c.
    defp coherent_triple do
      StreamData.bind(
        StreamData.list_of(
          StreamData.tuple({
            StreamData.atom(:alphanumeric),
            StreamData.member_of([:scalar, :list])
          }),
          max_length: 5
        ),
        fn schema_list ->
          schema = Map.new(schema_list)
          StreamData.fixed_map(
            Map.new(schema, fn
              {k, :scalar} ->
                {k, StreamData.tuple({
                  StreamData.string(:alphanumeric, max_length: 6),
                  StreamData.string(:alphanumeric, max_length: 6),
                  StreamData.string(:alphanumeric, max_length: 6)
                })}
              {k, :list} ->
                {k, StreamData.tuple({
                  StreamData.list_of(StreamData.integer(0..20), max_length: 4),
                  StreamData.list_of(StreamData.integer(0..20), max_length: 4),
                  StreamData.list_of(StreamData.integer(0..20), max_length: 4)
                })}
            end)
          )
          |> StreamData.map(fn kv ->
            {
              Map.new(kv, fn {k, {v1, _, _}} -> {k, v1} end),
              Map.new(kv, fn {k, {_, v2, _}} -> {k, v2} end),
              Map.new(kv, fn {k, {_, _, v3}} -> {k, v3} end)
            }
          end)
        end
      )
    end

    property "associativity for type-coherent triples" do
      check all({a, b, c} <- coherent_triple()) do
        lhs = Loader.merge(Loader.merge(a, b), c)
        rhs = Loader.merge(a, Loader.merge(b, c))
        assert lhs == rhs
      end
    end

    property "idempotency: merge(a, a) == a" do
      check all({a, _b, _c} <- coherent_triple()) do
        assert Loader.merge(a, a) == a
      end
    end

    property "scalar override: later layer wins" do
      scalar = StreamData.one_of([
        StreamData.string(:alphanumeric, max_length: 8),
        StreamData.integer(),
        StreamData.boolean()
      ])
      check all(k <- StreamData.atom(:alphanumeric), v1 <- scalar, v2 <- scalar) do
        assert Loader.merge(%{k => v1}, %{k => v2}) == %{k => v2}
      end
    end
  end
end
```

Production change summary:
- `list_keys/0` becomes `def list_keys, do: Map.keys(@merge_rules)` — no
  divergence between the rule table and the list-key set is possible.
- `merge_rules/0` is a new public function (required for the rule-table tests).
- `merge_value/3` uses `Map.get(@merge_rules, k, :override)` instead of
  `if k in list_keys()`.
- All existing example tests continue to pass unchanged.

## Tradeoffs

### Strengths

- Eliminates the possibility of `list_keys/0` and the `:concat` dispatch
  diverging — they are now the same data structure.
- The rule-table property tests verify that the dispatch function respects
  the declared table without any implicit logic — this is the most direct
  test of the contract.
- Adding a new `:concat`-rule key in the future requires only one change
  (the `@merge_rules` map) rather than two (`list_keys/0` AND a branch in
  `merge_value/3`).
- `merge_rules/0` as a public function makes the contract inspectable at
  runtime without reading source code (useful for debugging and introspection).

### Weaknesses

- Changes production code (`merge_value/3` and `list_keys/0`) in addition
  to adding tests — this is a production refactor, not a test-only change.
  It carries more risk than proposals 1 or 2.
- The rule table currently has only one rule type (`:concat`). Adding
  `:override` as an explicit rule type and a `case` dispatch for it
  adds code volume to handle a case that is already the default — it's
  extra mechanism for no current benefit.
- `@merge_rules` as a module attribute compiles the table into the module
  bytecode; if the rule table ever grows large or needs to be dynamic, this
  approach must be revisited (though for the current 7-key table, this is
  a non-issue).
- The `merge_rules/0` public function expands the module's public API
  surface; if the rule table is considered an implementation detail, making
  it public is an API commitment.

### Costs

- Small production code change (~10 lines modified + 3 lines added in
  `loader.ex`).
- All four existing tests must be confirmed still passing after the
  `merge_value/3` rewrite.
- Dialyzer re-run recommended.
- ~80 lines of new test code.

## Dependencies

- No new libraries.
- The production change is entirely within `lib/tau/settings/loader.ex`.
- `merge_rules/0` must be added before the test can reference it.

## Confidence

Medium. The data-shape change is a clean decomplecting move, and the
rule-table tests are mechanically stronger than pure algebraic-law tests
(they verify dispatch, not just outcomes). Confidence would rise to high
after confirming `mix test test/tau/settings/` passes with the refactored
`merge_value/3`.

## Prior art / references

- Erlang `ets:match_spec/0` — rule-table dispatch as data rather than code.
- Clojure `merge-with` — explicit merge strategy passed as data/function,
  making the contract a first-class value.
- The `@merge_rules` module-attribute pattern is used elsewhere in the
  project (e.g., `Tau.Provider` dispatch tables) for similar static
  key-to-strategy mappings.
