---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Introduce a public `Schema.provider_from_string/1` with an explicit result type

## Approach

Extract the string-to-module resolution into a new **public** function
`Tau.Settings.Schema.provider_from_string/1` with a `@spec` that explicitly
declares `{:ok, module()} | {:error, {:unknown_provider, String.t()}}`. The
implementation uses a compile-time `@known_provider_names` map (same as proposal
1), but the change is API-breaking in that it moves this conversion from a
private implementation detail to a named, typed, testable public surface. The
existing binary clause of `to_known_module/1` becomes a one-line delegation to
`provider_from_string/1`. The `try/rescue` is removed.

## Rationale

The binary clause currently has two responsibilities: (a) converting a string to
a module reference and (b) doing so as part of the private `to_known_module`
validation pipeline. Extracting the string-to-module conversion into a public
function with an explicit `@spec` decomplects these responsibilities. Callers
that want to perform provider name resolution outside the settings validation
pipeline (e.g. CLI argument parsing, test helpers) get a clean, stable callsite.
The private clause becomes a delegation. The `rescue` disappears because the
named function's spec is a tagged tuple — the absence of a provider is a return
value, not an exception.

## Sketch

```elixir
# New public function:
@spec provider_from_string(String.t()) :: {:ok, module()} | {:error, {:unknown_provider, String.t()}}
def provider_from_string(str) when is_binary(str) do
  case Map.fetch(@known_provider_names, str) do
    {:ok, mod} -> {:ok, mod}
    :error     -> {:error, {:unknown_provider, str}}
  end
end

# Updated private clause (delegation, no logic):
defp to_known_module(str) when is_binary(str), do: provider_from_string(str)

# @known_provider_names module attribute (compile-time map, same as proposal 1):
@known_provider_names Map.new(@known_providers, fn mod ->
  {mod |> Atom.to_string() |> String.replace_prefix("Elixir.", ""), mod}
end)
```

New test entry in `schema_test.exs`:
```elixir
describe "provider_from_string/1" do
  test "returns {:ok, mod} for known provider string" do
    assert {:ok, Tau.Providers.Anthropic} =
             Tau.Settings.Schema.provider_from_string("Tau.Providers.Anthropic")
  end

  test "returns {:error, {:unknown_provider, str}} for unknown string" do
    assert {:error, {:unknown_provider, "NotAProvider"}} =
             Tau.Settings.Schema.provider_from_string("NotAProvider")
  end
end
```

## Tradeoffs

### Strengths

- Removes `try`/`rescue` from the private clause — acceptance criterion met.
- Promotes the string-to-module conversion to a first-class, typed public API.
  Other callers (CLI argument parsers, test helpers) can use it directly.
- The explicit `@spec` makes the contract machine-checkable by Dialyzer.
- The delegation clause (`defp to_known_module(str) ..., do: provider_from_string(str)`)
  is self-documenting: the private function names what it delegates to.
- Enables isolated unit tests for `provider_from_string/1` without going through
  the full `resolve_fallback_chains/1` pipeline.

### Weaknesses

- This is an API-extending change, not a purely internal refactor. It adds a
  public function to `Tau.Settings.Schema`'s surface. If the module is consumed
  by external code, this is extra surface to maintain.
- The `@known_provider_names` attribute and the key-derivation logic are
  duplicated from proposal 1 — the implementation detail is the same; only the
  function visibility changes. A reader might question whether public visibility
  is warranted solely to fix a rescue-as-flow issue.
- Adding a new public `Schema` function may trigger `spec-before-code.md`
  review questions if `Schema` is listed in a SPEC boundary (it is not currently
  listed in any SPEC's Appendix B, so this risk is low).
- Two new tests are suggested; the problem statement says the existing tests
  already pass — so these tests add coverage but are not required by the
  acceptance criterion.

### Costs

- ~10 lines added (public function + spec + module attribute).
- ~4 lines removed (private binary clause body).
- 2 new tests suggested (optional but recommended for the new public API).
- No consumer breakage — `to_known_module/1` remains private and unchanged in
  signature.

## Dependencies

- None beyond the existing module. `@known_providers` is already defined.

## Confidence

Medium. The implementation detail (compile-time map) is identical to proposal 1
and carries the same high-confidence correctness guarantee. The API-extension
decision is the uncertain part: it is beneficial if other callers exist or will
exist; it is unnecessary overhead if the conversion will always be internal to
`Schema`. The problem statement does not identify external callers, so the
benefit is speculative.

## Prior art / references

- Phoenix `Router.route_info/4`: private routing logic exposed as a public
  function for use by test helpers and tooling, decomplecting the public API from
  the internal pipeline.
- Ecto `Type.cast/2`: public typed conversion function delegated to by internal
  changeset pipeline, enabling standalone use.
- Elixir `@spec` + `@type` for tagged-result functions: standard pattern in
  Elixir core (`File.read/1`, `Jason.decode/1`) where the absence of a result
  is a return value, not an exception.
