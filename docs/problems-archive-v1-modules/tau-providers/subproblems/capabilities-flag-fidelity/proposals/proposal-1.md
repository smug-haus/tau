---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Enforce capability flags via mandatory optional callbacks

## Approach

For each capability flag that implies a protocol obligation, introduce a
corresponding optional callback in `Tau.Provider` and add a compile-time
`@impl` enforcement check via a `__using__/1` macro. Specifically:

- `prompt_caching: true` requires the adapter to export `cache_regions/2`
  (already optional today — make it mandatory when the flag is `true`).
- `thinking: true` requires the adapter to export a new `thinking_config/1`
  callback that returns the provider-specific thinking-parameter block.

Adapters declaring a flag `true` without the corresponding callback produce
a compile-time warning (or error via `@enforce_capabilities true`) in the
macro-expanded `__using__` block. Bedrock and Gemini either implement the
callbacks or demote their flags to `false`.

## Rationale

The core complect is that `capabilities/0` makes a claim but the behaviour
places no obligation on adapters to back the claim. The fix is to couple the
claim to an obligation at the behaviour level: a flag can only truthfully be
`true` if the adapter exports the callbacks that make it so. This uses the
BEAM's existing module-attribute + behaviour-checking machinery — no new
runtime infrastructure. Callers that branch on `capabilities().thinking` gain
a contractual guarantee that `thinking_config/1` is also present and callable.

## Sketch

```elixir
# lib/tau/provider.ex — new section

@doc """
Per-turn thinking configuration. MUST be exported when `capabilities().thinking == true`.
Returns the provider-specific thinking-parameter block to embed in the request body.
"""
@callback thinking_config(stream_opts()) :: map()

# cache_regions/2 already exists; annotation only:
# MUST be exported when capabilities().thinking == true (prompt_caching already handled)

@optional_callbacks [configure: 1, chat: 3, cache_regions: 2, context_window: 1,
                     thinking_config: 1]

defmacro __using__(opts) do
  quote do
    @behaviour Tau.Provider
    @before_compile Tau.Provider.CapabilityEnforcer
    @tau_provider_opts unquote(opts)
  end
end

# lib/tau/provider/capability_enforcer.ex — new file

defmodule Tau.Provider.CapabilityEnforcer do
  @moduledoc """
  Compile-time check: for each adapter that declares a capability flag `true`,
  verify the corresponding callback is exported. Emits a compile warning by
  default; set `@enforce_capabilities :error` to turn it into a compile error.
  """

  @flag_to_callbacks %{
    thinking: [:thinking_config],
    prompt_caching: [:cache_regions]
  }

  defmacro __before_compile__(env) do
    mod = env.module
    caps = Module.get_attribute(mod, :tau_capabilities) || %{}
    level = Module.get_attribute(mod, :enforce_capabilities) || :warn

    Enum.each(@flag_to_callbacks, fn {flag, required_cbs} ->
      if Map.get(caps, flag) == true do
        Enum.each(required_cbs, fn cb ->
          arity = if cb == :cache_regions, do: 2, else: 1
          unless Module.defines?(mod, {cb, arity}) do
            msg = "#{inspect(mod)} declares capabilities #{flag}: true but does not export #{cb}/#{arity}"
            case level do
              :error -> raise CompileError, description: msg, file: env.file, line: env.line
              _ -> IO.warn(msg, Macro.Env.stacktrace(env))
            end
          end
        end)
      end
    end)

    :ok
  end
end
```

```elixir
# lib/tau/providers/bedrock.ex — fix: demote or implement
# Option A: demote flags (minimal change)
def capabilities do
  %{thinking: false, tools: true, vision: true,
    prompt_caching: false, parallel_tools: true}
end

# lib/tau/providers/gemini.ex — same pattern
def capabilities do
  %{thinking: false, tools: true, vision: true,
    prompt_caching: false, parallel_tools: true}
end
```

Adapter `use Tau.Provider` triggers the `__before_compile__` check. The
`@enforce_capabilities :error` attribute can be set repo-wide via
`config :tau, :enforce_capabilities, :error` once all adapters are compliant.

## Tradeoffs

### Strengths

- Contractual: a compiler-surfaced link between flag and callback — callers
  can rely on the flag without reading adapter internals.
- Minimal new runtime surface: enforcer is a `@before_compile` hook that
  vanishes after compilation.
- Incremental: adopters can start with `:warn` and graduate to `:error`.
- Directly satisfies the acceptance criterion: every `true` flag has a
  corresponding behaviour-enforced callback.
- Consistent with existing `cache_regions/2` pattern — extends rather than
  invents.

### Weaknesses

- Requires `use Tau.Provider` discipline: adapters that implement `@behaviour
  Tau.Provider` directly (without `use`) skip the `@before_compile` check.
  Must audit all adapters; Replay adapter is a likely non-`use` case.
- `thinking_config/1` is a new callback: implementing it for Anthropic and
  OpenAI-reasoning adapters adds non-trivial surface even for the "currently
  working" cases.
- Compile warnings are easy to ignore; the `:error` upgrade requires
  coordinated cleanup of Bedrock and Gemini before it can be enabled.
- Does not address the case where an adapter implements `thinking_config/1`
  but the decode path still doesn't emit `ThinkingStart`/`ThinkingEnd` events —
  the callback only proves something is exported, not that it wires through.

### Costs

- New file: `lib/tau/provider/capability_enforcer.ex` (~50 LOC).
- Modify `lib/tau/provider.ex`: add `thinking_config/1` callback, `__using__/1`
  macro, update `@optional_callbacks`.
- Modify all adapters to `use Tau.Provider` if they don't already.
- Bedrock and Gemini: either implement `thinking_config/1` + `cache_regions/2`
  (2–3 PRs of feature work) or demote flags to `false` (trivial).
- Property tests: one property per flag checking `capabilities().X == true →
  function_exported?(mod, cb, arity)`.

## Dependencies

- All adapters must opt in to `use Tau.Provider`; currently only some do.
- If `thinking_config/1` is added, the Anthropic and OpenAI-family adapters
  must implement it before the flag check fires for them.

## Confidence

Medium. The compile-time enforcement pattern is well-established in Elixir
(`@before_compile`); the uncertainty is in whether `thinking_config/1` is the
right callback shape to enforce thinking fidelity, vs a simpler flag-only
demotion approach. Confidence rises if the scope is narrowed to "demote Bedrock
and Gemini flags + enforce cache_regions via existing callback" (no new callback).

## Prior art / references

- Elixir `@before_compile` behaviour enforcement: used by Ecto adapters
  (`Ecto.Adapter`) to verify optional callbacks based on declared features.
- `Phoenix.Socket` `__using__/1` macro for transport-specific enforcement.
- `cache_regions/2` in `lib/tau/provider.ex` — existing optional callback
  pattern this proposal extends.
