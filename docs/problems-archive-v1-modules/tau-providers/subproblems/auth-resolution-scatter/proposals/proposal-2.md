---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Promote configure/1 to a mandatory auth-resolution callback

## Approach

Promote the existing `configure/1` optional callback in `Tau.Provider` to the
mandatory auth-resolution seam: remove it from `@optional_callbacks`, document
its contract explicitly (returns `{:ok, resolved_config_map}` or
`{:error, reason}`), and add a behaviour-level compile-time enforcement
warning for adapters that do not implement it. Each adapter moves its private
credential-resolution logic into its own `configure/1` implementation. The
`Tau.Provider` behaviour adds a `resolve_config/1` default implementation
(via `defmacro __using__` or a default-impl module) that provides the
`app_env → vault → system_env` chain as a callable helper for simple adapters
to delegate to. The dead interface becomes the enforced seam; the scattered
private functions migrate under a contract that new adapter authors will see
and follow.

## Rationale

The second complecting hypothesis in the problem statement names the
`configure/1` optional callback as dead interface that misleads new adapter
authors. This proposal addresses both hypotheses simultaneously by making
`configure/1` alive and mandatory rather than extracting a new module. Instead
of adding a utility module (Proposal 1), this reshapes what the behaviour
already advertises. Decomplecting: credential resolution is no longer an
implicit implementation detail of `stream/3` embedded in private functions;
it becomes an explicit, named, testable behaviour step. The acceptance
criterion is met because `configure/1` is the single documented seam —
operators and authors can predict where vault honoring happens without reading
each adapter's `stream/3`.

## Sketch

**Behaviour change:**
```elixir
# lib/tau/provider.ex — before
@optional_callbacks [configure: 1, chat: 3, cache_regions: 2, context_window: 1]

# After: configure/1 is no longer optional
@callback configure(opts :: map()) :: {:ok, map()} | {:error, term()}
@optional_callbacks [chat: 3, cache_regions: 2, context_window: 1]
```

**Default-chain helper (via __using__ macro):**
```elixir
defmacro __using__(_opts) do
  quote do
    @doc """
    Default configure/1: applies the standard app_env → vault → system_env
    chain for :api_key. Override for custom credential shapes.
    """
    def configure(opts) do
      env = Application.get_env(:tau, __MODULE__, [])
      api_key =
        Map.get(opts, :api_key) ||
          env[:api_key] ||
          Tau.Settings.Vault.resolve({:vault, __MODULE__.vault_key_name()}) ||
          System.get_env(__MODULE__.env_var_name())

      case api_key do
        nil -> {:error, :missing_api_key}
        "" -> {:error, :missing_api_key}
        key -> {:ok, Map.put(opts, :api_key, key)}
      end
    end

    defoverridable configure: 1
  end
end
```

**Adapter declaration (Mistral example):**
```elixir
defmodule Tau.Providers.Mistral do
  use Tau.Provider

  # Declare the vault/env-var names consumed by the default configure/1
  @vault_key_name "MISTRAL_API_KEY"
  @env_var_name   "MISTRAL_API_KEY"
  def vault_key_name, do: @vault_key_name
  def env_var_name, do: @env_var_name

  # Private api_key/0 removed; stream/3 calls configure/1 instead
  @impl true
  def stream(messages, opts, ctx) do
    with {:ok, config} <- configure(opts) do
      ...build_request(config.api_key)...
    end
  end
end
```

**Anthropic override (keeps full OAuth logic):**
```elixir
defmodule Tau.Providers.Anthropic do
  use Tau.Provider

  @impl true
  def configure(opts) do
    # Delegates to the existing Tau.Providers.Anthropic.Auth.resolve/1
    case Tau.Providers.Anthropic.Auth.resolve(opts) do
      {:ok, auth} -> {:ok, Map.put(opts, :auth, auth)}
      {:error, _} = err -> err
    end
  end
end
```

**Compile-time enforcement option** (adapter omitting `configure/1` gets a
dialyzer warning from the mandatory callback; no runtime penalty):
```elixir
# Any adapter NOT implementing configure/1 will emit:
# warning: module Tau.Providers.Foo does not implement required callback configure/1
```

**File changes:**
- `lib/tau/provider.ex` — remove configure/1 from @optional_callbacks; add `__using__` macro with default impl and defoverridable
- `lib/tau/providers/mistral.ex`, `deepseek.ex`, `groq.ex`, `azure_openai.ex`, `custom.ex`, `gemini.ex`, `bedrock.ex` — add `vault_key_name/0` and `env_var_name/0`; replace private chain functions; call `configure/1` from `stream/3`
- `lib/tau/providers/anthropic.ex` — add `@impl true` on `configure/1`, delegate to `Anthropic.Auth`
- `test/tau/providers/*_test.exs` — add `configure/1` tests per adapter

## Tradeoffs

### Strengths

- Directly resolves the second complecting hypothesis (dead interface) — `configure/1` goes from misleading ghost to the canonical auth seam.
- Compile-time enforcement: dialyzer flags any new adapter that forgets to implement it, making the contract self-documenting.
- Default implementation via `__using__` means simple adapters get vault honoring for free without any logic in their module body.
- `stream/3` becomes cleaner: it calls `configure/1` and pattern-matches the result; no private helper chain inline.

### Weaknesses

- Making `configure/1` mandatory is an API-breaking change to the `Tau.Provider` behaviour. Any external code (plugins, test doubles, the Replay adapter) that implements the behaviour but not `configure/1` will now get a dialyzer warning or compile failure.
- The `defoverridable` + `vault_key_name/0` / `env_var_name/0` module attribute pattern is an awkward inversion: the default implementation calls module-level functions that the adapter must define, which is more implicit than Proposal 1's explicit parameter passing.
- Bedrock's credential shape (AWS key triple, not a single API key) does not fit the `{:ok, %{api_key: ...}}` default; Bedrock must fully override `configure/1` with a bespoke implementation — no sharing gained there.
- The `__using__` macro adds a hidden dependency between `Tau.Provider` and `Tau.Settings.Vault` at compile time; modules that `use Tau.Provider` will now pull in `Tau.Settings.Vault` even if they don't need it (e.g. the Replay adapter).
- `stream/3` calling `configure/1` changes the call-graph timing: today, configuration errors surface inside private functions called from `stream/3`; after the change, they surface from `configure/1` before `stream/3` body runs, which may change error tuple shapes visible to callers.

### Costs

- Moderate: all eleven adapter modules require changes (not just the five with vault guards).
- The Replay adapter must either implement a no-op `configure/1` or be special-cased in the `__using__` macro.
- Any existing call sites that pass `configure/1`-shaped opts may need updating.
- Dialyzer baseline must be rebuilt after the callback change.

## Dependencies

- No library upgrades needed.
- The Replay adapter's test-harness contract must be audited before making configure/1 mandatory — if Replay intentionally omits it, a `defoverridable` default must handle the no-op case gracefully.
- `mix dialyzer` must be re-run to establish clean PLT after the callback promotion.

## Confidence

medium — The `defoverridable` + `__using__` pattern is idiomatic Elixir and used elsewhere in the OTP/Phoenix ecosystem. Confidence constrained to medium because the API breakage surface (external adapter authors, test doubles) is wider than Proposal 1's; a spike to audit all `@behaviour Tau.Provider` implementations in test/ would raise it.

## Prior art / references

- Elixir `__using__` macro with `defoverridable` for default behaviour implementations: used in Phoenix (`Phoenix.Controller`, `Phoenix.LiveView`).
- `Tau.Provider.@optional_callbacks` existing pattern — inverse of this proposal.
- Hickey "Simple Made Easy" — interface axis: "complecting" the auth seam with `stream/3`'s body is the problem; making configure/1 a hard contract separates the concerns at the interface level.
