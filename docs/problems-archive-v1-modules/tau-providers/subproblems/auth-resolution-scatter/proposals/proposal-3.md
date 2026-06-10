---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Auth.Spec data-shape contract + compile-time assertion

## Approach

Define a `Tau.Providers.Auth.Spec` struct that each adapter declares as a
module attribute, encoding the adapter's credential layout as data (which vault
names map to which resolved fields, and which env vars are the fallbacks). A
`Tau.Providers.Auth.Resolver.resolve/2` function takes an `Auth.Spec` and an
opts map and applies the standard chain. Adapters that fit the standard shape
declare `@auth_spec` and call `Resolver.resolve(@auth_spec, opts)` from
`stream/3`; they contain no credential logic. A compile-time `@on_definition`
hook (or a Mix task `mix tau.check_auth_specs`) asserts that every module
claiming `@behaviour Tau.Provider` either declares `@auth_spec` or implements
a documented override marker `@auth_custom true` — making the gap between
"has a spec" and "silently missing vault" observable without running code.

## Rationale

This proposal addresses the complecting hypothesis at the **data level** rather
than the control-flow level. Today the credential chain is encoded as procedure
(a sequence of function calls). This proposal encodes it as data (a struct that
says "my vault name is X, my env fallback is Y, my app-env key is :api_key").
The `Auth.Spec` struct makes the priority chain a first-class value: it can be
inspected, tested independently of any adapter, and emitted as telemetry metadata.
The compile-time assertion closes the silent-inconsistency hole: an adapter that
forgets vault coverage fails the assertion rather than silently ignoring vault at
runtime. The acceptance criterion (predictable, observable vault honoring) is
met because the spec is the single declaration that an operator or tooling can
inspect to determine coverage.

## Sketch

```elixir
defmodule Tau.Providers.Auth.Spec do
  @moduledoc """
  Declarative credential layout for a provider adapter.

  Encodes the app_env → vault → system_env priority chain as data.
  Adapters with non-standard shapes (Anthropic OAuth, Bedrock SigV4)
  set custom?: true and manage resolution themselves.
  """

  @enforce_keys [:vault_name, :env_var]
  defstruct [
    :vault_name,       # String — vault credential name, e.g. "MISTRAL_API_KEY"
    :env_var,          # String — System.get_env fallback
    :app_env_key,      # atom — Application.get_env key (default: :api_key)
    custom?: false     # true = adapter manages resolution; spec is documentation only
  ]

  @type t :: %__MODULE__{
    vault_name:   String.t() | nil,
    env_var:      String.t() | nil,
    app_env_key:  atom(),
    custom?:      boolean()
  }
end
```

```elixir
defmodule Tau.Providers.Auth.Resolver do
  @moduledoc "Applies a Tau.Providers.Auth.Spec to an opts map."

  alias Tau.Providers.Auth.Spec

  @spec resolve(Spec.t(), module(), map()) ::
          {:ok, String.t()} | {:error, :missing_api_key}
  def resolve(%Spec{custom?: true}, _adapter, _opts) do
    {:error, :custom_auth_required}
  end

  def resolve(%Spec{} = spec, adapter, opts) do
    key =
      Map.get(opts, spec.app_env_key || :api_key) ||
        Application.get_env(:tau, adapter, [])[spec.app_env_key || :api_key] ||
        Tau.Settings.Vault.resolve({:vault, spec.vault_name}) ||
        System.get_env(spec.env_var)

    case key do
      nil -> {:error, :missing_api_key}
      ""  -> {:error, :missing_api_key}
      k   -> {:ok, k}
    end
  end
end
```

**Adapter declaration (Mistral):**
```elixir
defmodule Tau.Providers.Mistral do
  @behaviour Tau.Provider

  @auth_spec %Tau.Providers.Auth.Spec{
    vault_name: "MISTRAL_API_KEY",
    env_var: "MISTRAL_API_KEY"
  }

  @impl true
  def stream(messages, opts, ctx) do
    with {:ok, api_key} <- Tau.Providers.Auth.Resolver.resolve(@auth_spec, __MODULE__, opts) do
      ...
    end
  end
  # private api_key/0 and vault_key/0 deleted
end
```

**Anthropic (custom shape):**
```elixir
@auth_spec %Tau.Providers.Auth.Spec{vault_name: nil, env_var: nil, custom?: true}
# Anthropic.Auth.resolve/1 still handles OAuth chain; @auth_spec is declarative metadata
```

**Compile-time assertion (Mix task):**
```elixir
defmodule Mix.Tasks.Tau.CheckAuthSpecs do
  @moduledoc "Assert every Tau.Provider adapter declares @auth_spec."
  use Mix.Task

  @impl true
  def run(_args) do
    providers = Tau.Provider.known_adapters()  # or discovered via :application.get_key

    missing =
      Enum.filter(providers, fn mod ->
        not Map.has_key?(mod.__info__(:attributes), :auth_spec)
      end)

    if missing != [] do
      Mix.shell().error("Missing @auth_spec on: #{inspect(missing)}")
      exit({:shutdown, 1})
    end
  end
end
```

**File changes:**
- `lib/tau/providers/auth/spec.ex` — new (~25 lines)
- `lib/tau/providers/auth/resolver.ex` — new (~40 lines)
- `lib/tau/providers/mistral.ex`, `deepseek.ex`, `groq.ex`, `azure_openai.ex`, `custom.ex`, `gemini.ex` — declare `@auth_spec`, remove private helpers
- `lib/tau/providers/anthropic.ex` — declare `@auth_spec` with `custom?: true`
- `lib/tau/providers/bedrock.ex` — declare `@auth_spec` with `custom?: true`
- `lib/mix/tasks/tau.check_auth_specs.ex` — new (~30 lines)
- `test/tau/providers/auth/resolver_test.exs` — unit + property tests

## Tradeoffs

### Strengths

- Data-first: the `Auth.Spec` struct is inspectable at runtime (telemetry, `tau doctor`, debug output) — operators can query which adapters have vault coverage without reading source.
- Compile-time assertion closes the "silently added adapter without vault" gap at the CI level, not just the code-review level.
- `custom?: true` provides an explicit escape hatch with an annotation trail — it is impossible to silently omit vault without marking `custom?: true`, which is itself visible and searchable.
- Orthogonal to Proposal 1 and 2: can co-exist with either; `Auth.Spec` is a description, not a replacement for `configure/1` or a utility function.

### Weaknesses

- Higher complexity than Proposal 1: three new artifacts (Spec struct, Resolver, Mix task) vs one utility module.
- The Mix task `mix tau.check_auth_specs` must be added to CI manually; it is not a compile-time error, only a CI gate — a developer who doesn't run it locally can still merge a missing-spec adapter.
- `@on_definition` compile-time hooks are possible in Elixir but fragile; the Mix task is more robust but requires discipline to wire into CI.
- `Tau.Provider.known_adapters/0` does not currently exist; the Mix task needs a registry or module discovery mechanism, which is itself new infrastructure.
- Struct-as-metadata adds a new dependency direction: `Tau.Providers.Auth.Spec` becomes a type that adapter modules depend on; any future changes to the struct require touching all adapters.
- Azure's `resolve_config/0` resolves three fields (api_key, endpoint, deployment) but Auth.Spec models only one primary credential field; multi-field adapters would need a spec extension.

### Costs

- 3 new files; 7 adapter files modified; CI wiring change.
- No breaking changes to `Tau.Provider` callback surface.
- `Tau.Provider.known_adapters/0` must be implemented or the Mix task must use `:application.get_key` discovery (fragile).

## Dependencies

- A mechanism to enumerate all `@behaviour Tau.Provider` implementations is needed for the Mix task; either a centrally-registered list in `Tau.Provider` or compile-time discovery.
- No library upgrades needed.

## Confidence

low-medium — The struct + resolver shape is clean and the Auth.Spec concept has
strong prior art in Ecto's schemaless changesets and Absinthe's type definitions.
Confidence is constrained by the unresolved adapter-discovery mechanism and the
Azure multi-field gap. A prototype of the Mix task and a proof that
`known_adapters/0` can be implemented without `:application.get_key` fragility
would raise confidence to medium.

## Prior art / references

- Ecto changeset schemas — credential layout as a declared data shape, not procedural validation.
- Absinthe `object/2` type declarations — making what was implicit (field presence) explicit and inspectable.
- `mix xref` as a precedent for compile-time cross-module assertions in Mix tasks.
- Hickey "Simple Made Easy" — data-shape axis: moving from "how" (procedure) to "what" (data declaration).
