---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Explicit MergeContract module encoding invariants as callable guards

## Approach

Extract the three merge invariants into a new production module
`Tau.Settings.MergeContract` that exposes one function per invariant
(`assert_concat_order/3`, `assert_identity/1`, `assert_absent_as_empty/3`).
Each function takes merged-settings inputs and returns `:ok | {:error, reason}`.
Add a single property test file `test/tau/settings/loader_property_test.exs`
that drives `Loader.merge/2` and then calls `MergeContract` assertion functions
to check correctness — decoupling the "what did merge return" from "does the
return satisfy the contract." The `MergeContract` module ships in `lib/` (not
`test/`) so it is usable in runtime diagnostics or integration smoke tests.

## Rationale

The problem identifies an invisible coupling: `Evaluator`'s first-match-wins
semantics depend on `Loader.merge/2`'s concat order, but this contract lives
only in comments and example tests. Making the contract a first-class module
(`MergeContract`) means the coupling becomes discoverable by anyone reading
`lib/tau/settings/`. A runtime consumer (e.g. a debug endpoint, a CI smoke)
can call `MergeContract.assert_concat_order/3` directly against a live merged
settings map without setting up a full property-test harness. The property
tests then verify that `Loader.merge/2` satisfies `MergeContract` for arbitrary
inputs — rather than encoding the invariant logic inside the test itself, which
is where the current example tests fail (the invariant is expressed in the
assertion, not named and composed). This is an interface-change axis: the
contract becomes an explicit boundary, not an implicit assumption.

## Sketch

```
lib/tau/settings/
  loader.ex                 # unchanged
  merge_contract.ex         # new — contract module in lib/
test/tau/settings/
  loader_test.exs           # unchanged
  loader_property_test.exs  # new — uses MergeContract
```

```elixir
# lib/tau/settings/merge_contract.ex

defmodule Tau.Settings.MergeContract do
  @moduledoc """
  Named invariants for `Tau.Settings.Loader.merge/2`.

  Each function returns `:ok` or `{:error, {key, expected, actual}}`.
  Usable in property tests, runtime diagnostics, and smoke tests.

  Invariants:
    C1 — permissions arrays are prefix-then-suffix concatenations.
    C2 — merge(x, %{}) == x  (right-identity).
    C3 — absent permissions key in a layer is treated as [], not nil.
  """

  @perm_keys [:allow, :deny, :ask]

  @doc """
  C1: assert that each permissions key in `merged` equals
  `a_perms[key] ++ b_perms[key]` for all three permission keys.
  """
  @spec assert_concat_order(map(), map(), map()) ::
          :ok | {:error, {atom(), list(), list()}}
  def assert_concat_order(a, b, merged) do
    Enum.reduce_while(@perm_keys, :ok, fn key, :ok ->
      expected = (get_in(a, [:permissions, key]) || []) ++
                 (get_in(b, [:permissions, key]) || [])
      actual   = get_in(merged, [:permissions, key]) || []

      if actual == expected do
        {:cont, :ok}
      else
        {:halt, {:error, {key, expected, actual}}}
      end
    end)
  end

  @doc """
  C2: assert merge(x, %{}) == x.
  """
  @spec assert_identity(map()) :: :ok | {:error, {map(), map()}}
  def assert_identity(x) do
    merged = Tau.Settings.Loader.merge(x, %{})
    if merged == x, do: :ok, else: {:error, {x, merged}}
  end

  @doc """
  C3: assert absent key in b is treated as [], not nil.
  Returns :ok when merged[:permissions][key] is a list.
  """
  @spec assert_absent_as_empty(map(), map(), atom()) ::
          :ok | {:error, {:nil_result, atom()}}
  def assert_absent_as_empty(a, b, key) do
    merged = Tau.Settings.Loader.merge(a, b)

    case get_in(merged, [:permissions, key]) do
      nil  -> {:error, {:nil_result, key}}
      list when is_list(list) -> :ok
    end
  end
end
```

```elixir
# test/tau/settings/loader_property_test.exs

defmodule Tau.Settings.LoaderPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Settings.{Loader, MergeContract}

  defp perm_list, do: list_of(string(:alphanumeric, min_length: 1))

  defp perms_map do
    fixed_map(%{allow: perm_list(), deny: perm_list(), ask: perm_list()})
  end

  defp settings_with_perms do
    fixed_map(%{permissions: perms_map()})
  end

  property "C1: concat order invariant holds for arbitrary permissions layers" do
    check all(a <- settings_with_perms(), b <- settings_with_perms()) do
      merged = Loader.merge(a, b)
      assert MergeContract.assert_concat_order(a, b, merged) == :ok
    end
  end

  property "C2: right-identity invariant holds for arbitrary settings maps" do
    check all(x <- settings_with_perms()) do
      assert MergeContract.assert_identity(x) == :ok
    end
  end

  property "C3: absent permissions key treated as empty list, not nil" do
    check all(
              a    <- settings_with_perms(),
              key  <- member_of([:allow, :deny, :ask])
            ) do
      b = %{permissions: Map.delete(%{allow: [], deny: [], ask: []}, key)}
      assert MergeContract.assert_absent_as_empty(a, b, key) == :ok
    end
  end
end
```

The `MergeContract` module ships under `lib/` so it is compiled into the
release and reachable from `iex -S mix`, runtime diagnostics, and integration
tests without requiring `ExUnit` to be running.

## Tradeoffs

### Strengths

- The merge contract becomes a named, versioned, first-class module — the
  coupling between `Evaluator`'s first-match semantics and `Loader.merge/2`'s
  concat order is now visible in `lib/`, not only in test assertions.
- `MergeContract` functions return tagged tuples, making them usable in runtime
  diagnostics (e.g. `mix tau.settings.check`), not just in property tests.
- Invariant identifiers (C1, C2, C3) create stable references in PRs,
  error messages, and documentation — easier to cite in ADRs and spec amendments.
- The property tests are shorter and more readable because the assertion logic
  lives in `MergeContract`, not inline in `check all` blocks.

### Weaknesses

- Adding a production module (`MergeContract`) to close a test-coverage gap
  is overkill for this problem's stated scope. The problem is a missing
  property test; the fix is a property test. A new `lib/` module is a
  structural change whose cost exceeds the problem's severity.
- `MergeContract.assert_identity/1` calls `Loader.merge/2` internally, which
  means the contract module is tightly coupled to the module it validates —
  an inside-out dependency that inverts the usual test-subject relationship.
  This makes `MergeContract` unsuitable as an independent oracle.
- The `:error` return tuple shapes differ across the three invariant functions,
  making programmatic consumers harder to write uniformly.
- Shipping contract code in `lib/` means it enters the release binary and
  Dialyzer type-checking scope, adding non-zero maintenance overhead for code
  whose primary consumer is the test suite.
- A release reviewer using `code-review-patterns` may flag the `lib/`
  production module as a violation of "no GenServer wrapping stateless logic"
  (this is pure functions, not a GenServer, but the reasoning for not
  shipping test helpers to production applies).

### Costs

- Two new files (~70 + ~55 lines): one in `lib/`, one in `test/`.
- No existing file changes required.
- `MergeContract` enters Dialyzer scope — requires valid `@spec` annotations
  (sketched above) and will fail `mix dialyzer` if specs are missing or wrong.
- CI: identical property runtime to Proposals 2 and 3 (~3 runs × 100 iters).
- Knowledge cost: contributors must understand that `MergeContract` is both
  a test oracle and a runtime utility — a dual role that requires active
  documentation.

## Dependencies

- `{:stream_data, "~> 1.1"}` already present.
- Dialyzer must pass on `MergeContract`'s `@spec` annotations — verify with
  `mix dialyzer` before PR.
- No other production changes required.

## Confidence

low — The structural approach is sound in principle (named contracts as first-
class modules is a well-established pattern), but the cost-benefit ratio for
this specific problem is unfavorable. The problem is a two-property test gap,
not an architectural contract-encoding gap. This proposal would raise its own
confidence with a prototype showing `MergeContract` functions used in a live
`iex` session or runtime diagnostic, but that use case is speculative. The
selector should prefer Proposals 2 or 3 unless a runtime diagnostics use case
for `MergeContract` is confirmed.

## Prior art / references

- Bertrand Meyer, "Design by Contract" — named precondition/postcondition
  functions as explicit contract modules; the PEGS framework referenced in
  `CLAUDE.md`.
- Elixir `NimbleOptions` — ships validation logic as a separate composable
  module callable independently of the schema definition.
- `Tau.CircuitBreaker.State` in `lib/tau/circuit_breaker/state.ex` — precedent
  for extracting state-machine invariants into a dedicated module.
