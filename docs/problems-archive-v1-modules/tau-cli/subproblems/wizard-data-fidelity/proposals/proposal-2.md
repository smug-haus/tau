---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Extract `Tau.Providers.Catalog` as single source of truth

## Approach

Introduce a new module `Tau.Providers.Catalog` that owns the complete,
authoritative mapping from provider key atom to `%{label, env_var,
string_key}`. Both `Tau.CLI.Init` and `Tau.Commands.Builtin.Logout` are
refactored to delegate all provider-identity lookups to this module.
`Init.@providers` and `Logout.@credential_map` are deleted; their values
become compile-time derivations of `Catalog`. The `List.first` truncation
is fixed in the same PR by changing `Init.drive_flow/1` to persist all
selected provider strings.

## Rationale

The complecting hypothesis is explicit: provider identity is split across
two modules with no shared source, so they drift. The structural fix is
extraction — move the fact ("Bedrock's vault credential is
`AWS_SECRET_ACCESS_KEY`") to a single module that both consumers import.
After this change, a future edit to a provider's credential key has one
and only one callsite; a compile-time `@credential_map` derived from
`Catalog` at `Logout` load time ensures the two are always identical
without runtime indirection. The `List.first` fix is a one-line change
once the surrounding data structures are stabilised.

## Sketch

### New module: `lib/tau/providers/catalog.ex`

```elixir
defmodule Tau.Providers.Catalog do
  @moduledoc """
  Compile-time registry of Tau's recognised providers.

  Each entry defines:
    * `:key`       — internal atom identifier
    * `:label`     — human-readable display name
    * `:env_var`   — vault credential name (key stored/retrieved by Vault)
    * `:string_key` — the string representation written to settings JSON
  """

  @entries [
    %{key: :anthropic,         label: "Anthropic",          env_var: "ANTHROPIC_API_KEY",    string_key: "anthropic"},
    %{key: :openai_chat,       label: "OpenAI Chat",         env_var: "OPENAI_API_KEY",       string_key: "openai_chat"},
    %{key: :openai_responses,  label: "OpenAI Responses",    env_var: "OPENAI_API_KEY",       string_key: "openai_responses"},
    %{key: :gemini,            label: "Gemini",              env_var: "GEMINI_API_KEY",       string_key: "gemini"},
    %{key: :bedrock,           label: "Bedrock",             env_var: "AWS_SECRET_ACCESS_KEY",string_key: "bedrock"}
  ]

  @doc "All registered provider entries."
  @spec all() :: [map()]
  def all, do: @entries

  @doc "Look up a provider entry by atom key. Returns `nil` if not found."
  @spec by_key(atom()) :: map() | nil
  def by_key(key), do: Enum.find(@entries, &(&1.key == key))

  @doc "Look up a provider entry by string key. Returns `nil` if not found."
  @spec by_string_key(String.t()) :: map() | nil
  def by_string_key(str), do: Enum.find(@entries, &(&1.string_key == str))

  @doc "Build the credential map `%{string_key => env_var}` for all providers."
  @spec credential_map() :: %{String.t() => String.t()}
  def credential_map do
    Map.new(@entries, &{&1.string_key, &1.env_var})
  end
end
```

### `Init` after refactor (relevant excerpts)

```elixir
# lib/tau/cli/init.ex — remove @providers module attribute, import Catalog

alias Tau.Providers.Catalog

# provider_selection/1 uses Catalog.all()
defp provider_selection(io) do
  io.puts("[1/5] Which providers do you want to enable?")
  Catalog.all()
  |> Enum.with_index(1)
  |> Enum.each(fn {p, i} -> io.puts("  [#{i}] #{p.label} (env: #{p.env_var})") end)
  # ... parse_provider_indices unchanged ...
end

# drive_flow — fix List.first truncation; persist all selected providers
new_settings =
  base_settings
  |> Map.put("permissions", merge_permissions(base_settings, perms_mode))
  |> Map.put("provider", providers |> List.first() |> then(&Catalog.by_key(&1).string_key))
  |> Map.put("providers", Enum.map(providers, &Catalog.by_key(&1).string_key))
```

### `Logout` after refactor

```elixir
# lib/tau/commands/builtin/logout.ex — remove @credential_map, derive from Catalog

alias Tau.Providers.Catalog

# At module level, derive at compile time:
@credential_map Catalog.credential_map()
```

Because `Catalog.credential_map/0` is a pure function returning a literal
map (no runtime state), `@credential_map Catalog.credential_map()` compiles
identically to the current hardcoded literal. The existing `run/2` body is
unchanged.

### File moves

```
(new)  lib/tau/providers/catalog.ex
(mod)  lib/tau/cli/init.ex        — remove @providers, alias Catalog
(mod)  lib/tau/commands/builtin/logout.ex — remove @credential_map literal, derive from Catalog
(new)  test/tau/providers/catalog_test.exs
```

## Tradeoffs

### Strengths

- Single source of truth: the Bedrock credential key lives in exactly one
  place; future drift is structurally impossible.
- Compile-time derivation: `Logout.@credential_map` is built at compile
  time from `Catalog`, not at runtime — no performance cost, no process
  dependency.
- The new module is pure data; it requires no GenServer, no supervision,
  no ETS — consistent with OTP NN #3 and #8.
- Makes the `List.first` fix easy: `Enum.map(providers, &Catalog.by_key(&1).string_key)`
  replaces the single-value path.
- Testable in isolation: `Tau.Providers.Catalog` can be property-tested
  for completeness (every entry has non-nil `:env_var`, unique `:key`
  and `:string_key`, etc.).

### Weaknesses

- Introduces a new module and file that future contributors must know
  about; slight discovery burden.
- Schema still stores `"provider"` as a single string; the
  `"providers"` list key must be added to `Tau.Settings.Schema` in the
  same PR to satisfy the "all N selections persisted" AC.
- `Catalog.by_key/1` returns `nil` on an unknown atom; callers must guard
  against this (easy but adds a nil-path in `drive_flow`).
- If a provider is added to `@known_providers` in `Settings.Schema` but
  not added to `Catalog`, the divergence reappears at a different level —
  though the type system cannot catch this unless a compile-time check is
  added.

### Costs

- 1 new file (`catalog.ex`, ~40 lines), 1 new test file.
- Refactor of `Init` and `Logout`: ~20 lines changed each.
- Schema amendment: +3 lines.
- Total: ~90 lines changed/added.
- Compile-time impact: nil (pure data module).

## Dependencies

- `"providers"` array key must be added to `Tau.Settings.Schema` in the
  same PR.
- No library upgrades or OTP changes required.

## Confidence

high — the pattern (compile-time credential registry derived from a
central catalog) is idiomatic Elixir, has a concrete sketch, and the
credential-key discrepancy is confirmed by code inspection.

## Prior art / references

- `lib/tau/settings/schema.ex:47–54` — `@known_providers` list is a
  precedent for compile-time provider registries in this codebase.
- Elixir idiom: module attributes evaluated at compile time to derive
  secondary data structures (e.g. `@credential_map Catalog.credential_map()`).
- `lib/tau/cli/init.ex:245–253` — `handle_credentials/3` already treats
  the `@providers` list as the single credential truth for the init path;
  the proposal extends that authority to the logout path.
