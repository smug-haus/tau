---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Direct string-match against module-name strings at compile time

## Approach

Build a compile-time map `@known_provider_names` from `@known_providers` by
extracting the string suffix that callers write in `.tau/settings.json` (e.g.
`"Tau.Providers.Anthropic"` → `"Anthropic"`; `"Tau.Providers.OpenAI.Chat"` →
`"OpenAI.Chat"`). Replace the `try/rescue` binary clause with a two-branch
`case` that pattern-matches on this map: found → `{:ok, mod}`, not found →
`{:error, {:unknown_provider, str}}`. No atom creation at runtime. No exception.

## Rationale

The `@known_providers` list is a compile-time constant of six modules. Their
string names (as written by users) are equally knowable at compile time.
Building a `string → module` map once with a module attribute eliminates the
need for `String.to_existing_atom/1` entirely — the "is this provider known?"
question is answered by a pure data lookup, decomplecting domain logic from the
VM atom-intern mechanism. The exception path is removed because no exception-
raising call is made.

## Sketch

```elixir
# At module attribute level (compile time):
@known_provider_names Map.new(@known_providers, fn mod ->
  # "Elixir.Tau.Providers.Anthropic" → strip "Elixir.Tau.Providers." prefix is wrong;
  # callers write the module name after "Elixir.", so the lookup key is
  # the bare inspect form minus the "Elixir." prefix.
  name = mod |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  {name, mod}
end)

# Replacement for the binary clause:
defp to_known_module(str) when is_binary(str) do
  case Map.fetch(@known_provider_names, str) do
    {:ok, mod} -> {:ok, mod}
    :error     -> {:error, {:unknown_provider, str}}
  end
end
```

The existing atom clause (`is_atom(mod)`) is unchanged. The map is zero-cost at
runtime: it is frozen into the compiled BEAM module as a literal. No atom
creation, no `try`, no `rescue`.

## Tradeoffs

### Strengths

- Completely eliminates `try`/`rescue` from the binary clause — the acceptance
  criterion is satisfied in the minimal possible change.
- `@known_provider_names` is computable at compile time and stored as a literal;
  lookup is O(1) map fetch with no side effects.
- The domain question "is this a known provider string?" is answered entirely by
  the module's own data, not the VM's atom table — clean decomplecting.
- No new runtime dependency; no library change.
- The existing `schema_test.exs` tests exercise this path and will continue to
  pass without modification.

### Weaknesses

- The map key convention (strip `"Elixir."` prefix) must match what callers
  actually write in `.tau/settings.json`. If any caller writes a partial name
  (e.g., `"Anthropic"` instead of `"Tau.Providers.Anthropic"`), the map will
  miss it. The existing rescue-based impl would also miss it (no atom would
  match `@known_providers` anyway), so behaviour is preserved — but the
  convention is now load-bearing and undocumented.
- Adding a new provider requires no code change (it already requires updating
  `@known_providers`), but the key-derivation logic for the name must be correct
  for every future module name. A module in a deeper namespace (e.g.
  `Tau.Providers.Foo.Bar`) produces the key `"Tau.Providers.Foo.Bar"`, which may
  not match user intuition.
- The compile-time map derivation is a one-liner but subtly couples the string
  serialisation of module atoms to the lookup convention. A comment is needed.

### Costs

- One module-attribute definition added (~5 lines).
- Binary clause body reduced from 6 lines to 4 lines.
- No test changes — existing tests cover the path.
- Migration cost: zero. One callsite, no API change, no consumer impact.

## Dependencies

- None. `@known_providers` already exists; `Map.new/2` and `Atom.to_string/1`
  are standard library.

## Confidence

High. The change is mechanical, the data is available at compile time, and the
pattern (`compile-time string map`) is idiomatic Elixir for closed enum lookups.
The only risk is key-convention mismatch, which is verifiable by running the
existing tests.

## Prior art / references

- Elixir module attribute as compile-time lookup table: idiomatic pattern in
  Phoenix's router, Ecto's type registry.
- `Map.fetch/2` as a no-exception alternative to atom coercion: documented in
  the Elixir guides under "Atoms" (warning: `String.to_existing_atom/1` is for
  atoms known to be interned; prefer map lookup for user-controlled strings).
- The atom clause of this same function already uses `cond` with `mod in
  @known_providers` — consistent with the map-lookup idiom proposed here.
