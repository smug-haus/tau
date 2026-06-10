---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Behaviour-based registry — providers and coding agents self-register, resolution via `String.to_existing_atom`

## Approach

Introduce a `Tau.Provider` behaviour callback `short_name/0 :: String.t()` (and
the equivalent `Tau.CodingAgent.short_name/0`) that each provider/coding-agent
module implements. At compile time, a module attribute in `Tau.CLI` is built by
calling `short_name/0` on every module in the known list and inverting the
result into a `%{String.t() => module()}` map — exactly as in Proposal 2, but
derived from the modules themselves rather than hand-listed. The tail clause is
replaced with a map lookup. `Module.concat` and `String.capitalize` are removed.
For the open-set case (a user supplies a string not in the map), the proposal
**optionally** allows `String.to_existing_atom/1` to probe whether the atom
already exists in the system (meaning the module was compiled and loaded), which
is atom-safe by construction.

## Rationale

The current coupling is: the `cli.ex` author must know every module name AND
must maintain a parallel list of short-name aliases in function clauses. Adding
a new provider requires changes in two places (the provider module and the CLI
dispatcher). Giving each provider a `short_name/0` callback makes the module
itself the source of truth. The CLI becomes a simple collector: enumerate known
modules, collect their short names, build the map. The `String.capitalize`
defect is removed because short names are now explicit strings, not derived by
capitalisation. The atom-leak concern is addressed by deriving the map at
compile time from module literals (not from user input) and using
`String.to_existing_atom/1` for the optional open-set probe — that function
only succeeds if the atom was already interned (i.e. the module was compiled in),
never creating a new atom from user bytes.

## Sketch

```elixir
# lib/tau/provider.ex  — add to existing behaviour
@callback short_name() :: String.t() | [String.t()]

# Example implementation in lib/tau/providers/openai/chat.ex
@impl Tau.Provider
def short_name(), do: ["openai", "ollama", "local"]

# Example implementation in lib/tau/providers/anthropic.ex
@impl Tau.Provider
def short_name(), do: "anthropic"

# lib/tau/cli.ex — compile-time registry construction
@known_provider_modules [
  Tau.Providers.Anthropic,
  Tau.Providers.OpenAI.Chat,
  Tau.Providers.Bedrock,
  Tau.Providers.Gemini,
  Tau.Providers.DeepSeek,
  Tau.Providers.Groq,
  Tau.Providers.Mistral,
  Tau.Providers.AzureOpenAI,
  Tau.Providers.Custom,
  Tau.Providers.Replay
]

# Expand multi-value short_name/0 results at compile time
@provider_registry (
  for mod <- @known_provider_modules,
      name <- List.wrap(mod.short_name()),
      into: %{},
      do: {name, mod}
)

defp resolve_provider(nil), do: {:ok, Tau.Provider.default()}

defp resolve_provider(name) when is_binary(name) do
  case Map.fetch(@provider_registry, name) do
    {:ok, mod} ->
      {:ok, mod}

    :error ->
      # Atom-safe open-set probe: only succeeds if the atom is already interned.
      # Does NOT create a new atom when the module is unknown.
      try do
        mod = String.to_existing_atom("Elixir." <> name)
        if :erlang.function_exported(mod, :stream, 3), do: {:ok, mod}, else: :error
      rescue
        ArgumentError -> :error
      end
      |> case do
        {:ok, mod} -> {:ok, mod}
        _          -> {:error, :unknown_provider, name, Map.keys(@provider_registry)}
      end
  end
end
```

The `String.to_existing_atom` probe is safe: it raises `ArgumentError` (not
creates a new atom) when the atom does not already exist. This restores
meaningful open-set support for modules the user has compiled into the release,
without the atom leak.

File changes: `lib/tau/provider.ex` (add callback), each provider module (add
`short_name/0` implementation), `lib/tau/cli.ex` (replace resolve functions).

## Tradeoffs

### Strengths

- Removes `Module.concat` / `String.capitalize` — acceptance criterion fully
  satisfied.
- Each provider owns its short name: adding a new provider no longer requires
  touching `cli.ex`.
- The `String.to_existing_atom` probe restores a meaningful open-set path for
  modules compiled into the release — the one real-world scenario where the
  tail clause was useful — without creating atoms from arbitrary strings.
- Compile-time map means registry errors (duplicate short names, typos) surface
  at compile time, not at runtime.
- `@known_provider_modules` attribute is also useful for `doctor_cmd`,
  documentation generation, and `--help` enumeration.

### Weaknesses

- **Largest scope of change**: touches `lib/tau/provider.ex`, every provider
  module, `lib/tau/cli.ex`, and analogously `Tau.CodingAgent` behaviour and
  each coding-agent module.
- Adding `short_name/0` to the `Tau.Provider` behaviour is an API-breaking
  behaviour change: any external adapter that does not implement it will fail to
  compile against the new behaviour. This is a real cost if the behaviour is used
  outside the main repo.
- The `String.to_existing_atom` probe is correct but slightly surprising; its
  inclusion must be explained in a comment to avoid a future maintainer removing
  it as "dead code".
- The `try/rescue` around `String.to_existing_atom` conflicts with OTP
  non-negotiable #7 ("MUST NOT `try/rescue` across process boundaries") in
  letter if not in spirit — this is an intra-function defensive pattern, not
  a cross-process boundary, but it will attract scrutiny in review.
- Incremental delivery is harder: the `short_name/0` callback must land before
  or with the `cli.ex` refactor.

### Costs

- Changes to 10+ provider modules (add one callback each), `provider.ex`,
  `coding_agent.ex`, and `cli.ex`.
- Test impact: provider behaviour tests must include `short_name/0`; CLI tests
  for the open-set probe.
- Estimated PR size: 150–250 lines changed across many files.

## Dependencies

- `Tau.Provider` behaviour already exists (`lib/tau/provider.ex`). The
  `short_name/0` callback is additive; it does not alter existing callbacks.
- All provider modules must be in scope in the same PR.

## Confidence

Medium. The approach is sound and the atom-safety of `String.to_existing_atom`
is well-established. Confidence would be higher with a prototype confirming
the compile-time `for` comprehension over module attributes works as expected
in Mix (it does, but it is worth verifying with a spike).

## Prior art / references

- Elixir `Ecto.Adapter` behaviour: adapters declare their capabilities via
  callbacks; the Ecto registry enumerates known adapters.
- `String.to_existing_atom/1` — Elixir docs explicitly describe this as the
  safe alternative to `String.to_atom/1`: "Will raise an ArgumentError if the
  atom does not exist."
- Hex `nerves_system_*` packages: each declares a `target/0` callback used by
  Nerves CLI to discover available targets — same pattern as `short_name/0`.
