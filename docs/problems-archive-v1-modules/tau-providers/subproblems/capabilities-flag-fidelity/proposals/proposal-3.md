---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Documented advisory caveat in behaviour — no enforcement, maximum honesty

## Approach

Do not change the `capabilities/0` return type or add new callbacks. Instead,
(1) add a module-level `@doc` contract to `@callback capabilities/0` that
explicitly defines the truthfulness semantics of each flag — distinguishing
"enforced by a mandatory callback" from "advisory (provider may support it but
Tau does not actively request or synthesise it)" — and (2) demote Bedrock and
Gemini's `thinking` and `prompt_caching` flags to `false` to match their actual
decode paths. The behaviour @doc becomes the single source of truth for what
each flag means; the codebase is correct-by-inspection rather than
correct-by-enforcement.

## Rationale

The acceptance criterion allows a third path: "at minimum an explicit documented
caveat in the behaviour that names which flags are advisory vs enforceable." The
core harm today is not a missing type: it is that adapters declare `true` for
features they do not implement, and no documentation warns callers. Demoting the
lying flags to `false` eliminates the silent misleading. The doc contract
formalises what "true" guarantees so future adapters cannot misread it.
This is the smallest change that fully satisfies the criterion without
introducing compile-time machinery or API breakage.

## Sketch

```elixir
# lib/tau/provider.ex — updated callback doc

@typedoc """
Static capability flags declared by an adapter.

## Flag semantics

  * `thinking`        — `true` IFF the adapter (a) sends the provider-specific
                        thinking-parameter block in `build_body/3` and (b) emits
                        `%Event.ThinkingStart{}`, `%Event.ThinkingDelta{}`, and
                        `%Event.ThinkingEnd{}` events in its decode path.
                        Advisory: if the adapter merely passes through reasoning
                        content that the provider returns unprompted, set `false`
                        and document the pass-through in the module @doc.

  * `prompt_caching`  — `true` IFF the adapter exports `cache_regions/2`.
                        Because `cache_regions/2` is a behaviour callback, this
                        flag is verifiable: `function_exported?(mod, :cache_regions, 2)`.

  * `tools`           — `true` IFF the adapter serialises tool specs in `build_body/3`
                        and dispatches `%Event.ToolCallStart{}`/`%Event.ToolCallDelta{}`/
                        `%Event.ToolCallEnd{}` events in its decode path.

  * `vision`          — `true` IFF the adapter serialises image content blocks
                        in `build_body/3`.

  * `parallel_tools`  — `true` IFF the adapter's provider supports issuing
                        multiple concurrent tool calls in a single turn, and the
                        adapter serialises `tool_choice: :auto` to request it.

All flags are `true` only when Tau actively exercises the feature on the adapter,
not merely because the underlying provider API supports it.
"""
@type capabilities :: %{
        thinking: boolean(),
        tools: boolean(),
        vision: boolean(),
        prompt_caching: boolean(),
        parallel_tools: boolean()
      }

@doc """
Returns the static capability flags for this adapter.

See `t:capabilities/0` for the truthfulness contract of each flag.

Callers MAY verify `prompt_caching` mechanically:

    caps = adapter.capabilities()
    if caps.prompt_caching do
      true = function_exported?(adapter, :cache_regions, 2)
    end

All other flags are verified only by reading the adapter's decode path.
"""
@callback capabilities() :: capabilities()
```

```elixir
# lib/tau/providers/bedrock.ex — demote to honest values
def capabilities do
  %{
    thinking: false,        # decode path handles only text/tool; no ThinkingStart/Delta/End
    tools: true,
    vision: true,
    prompt_caching: false,  # no cache_regions/2 exported
    parallel_tools: true
  }
end

# lib/tau/providers/gemini.ex — demote to honest values
def capabilities do
  %{
    thinking: false,        # decode path handles only text deltas and functionCall parts
    tools: true,
    vision: true,
    prompt_caching: false,  # no cache_regions/2 exported
    parallel_tools: false
  }
end
```

```elixir
# lib/tau/providers/shared/openai_chat_wire.ex — document the advisory case
# Adapters using this wire with thinking: true (DeepSeek-R1, Qwen3 via delta.reasoning)
# correctly declare thinking: true because the wire DOES emit ThinkingStart/Delta/End
# (lines 115–166 confirmed in problem.md context). No change needed.
```

```elixir
# Property test — test/tau/provider/capabilities_contract_test.exs (new)
defmodule Tau.Provider.CapabilitiesContractTest do
  @all_adapters [
    Tau.Providers.Anthropic, Tau.Providers.Bedrock, Tau.Providers.Gemini,
    Tau.Providers.OpenAI.Chat, Tau.Providers.OpenAI.Responses
    # ... all adapters
  ]

  for adapter <- @all_adapters do
    test "#{adapter}: prompt_caching: true iff cache_regions/2 exported" do
      caps = unquote(adapter).capabilities()
      if caps.prompt_caching do
        assert function_exported?(unquote(adapter), :cache_regions, 2),
               "#{unquote(adapter)} declares prompt_caching: true but does not export cache_regions/2"
      else
        refute function_exported?(unquote(adapter), :cache_regions, 2),
               "#{unquote(adapter)} exports cache_regions/2 but declares prompt_caching: false"
      end
    end
  end
end
```

The `prompt_caching` flag becomes mechanically verifiable via the existing
`cache_regions/2` optional callback. The `thinking` flag remains advisory
(defined in the doc contract) because there is no single "thinking callback"
to check against.

## Tradeoffs

### Strengths

- Zero API breakage: `capabilities/0` return type is unchanged; all callers
  continue to compile and run identically.
- Satisfies the acceptance criterion via the "documented caveat" path: flags
  are honest (demoted), and the doc contract explicitly names which flags are
  enforceable (prompt_caching via cache_regions/2) vs advisory (thinking).
- Smallest diff: two adapter capability maps + one @doc update + one test file.
- Immediately corrects the silent misleading without requiring a multi-PR
  migration.
- `prompt_caching` becomes mechanically verifiable via a property test.

### Weaknesses

- `thinking` flag remains advisory: there is still no compile-time or runtime
  check that an adapter declaring `thinking: true` actually emits
  `ThinkingStart/Delta/End` events. The documentation is honest, but a future
  adapter author can still lie.
- Doc contracts are not machine-readable: the guarantees only hold as long as
  humans read and honour the `@doc`. Dialyzer cannot enforce prose.
- Does not scale as new flags are added: each new flag needs a human to update
  the doc and demote any lying adapters.
- Property test for `prompt_caching` cannot be generalised to `thinking` without
  a new callback (the check is callback-specific, not structural).
- No enforcement prevents a future PR from silently re-elevating Bedrock or
  Gemini `thinking` to `true` without implementing the decode path.

### Costs

- New test file: `test/tau/provider/capabilities_contract_test.exs` (~40 LOC).
- Modify `lib/tau/provider.ex`: update `@doc` and `@typedoc` (~30 lines added).
- Modify `lib/tau/providers/bedrock.ex` and `lib/tau/providers/gemini.ex`:
  demote 4 flag values total (4 one-line changes).
- No migration of callers, adapters, or types.

## Dependencies

- None. This is a standalone documentation + correction change.

## Confidence

High. The change is purely additive documentation plus honest flag demotion.
The `prompt_caching` ↔ `cache_regions/2` relationship is already implicit in
the codebase and only needs to be made explicit. The property test pattern
is standard ExUnit parameterisation.

## Prior art / references

- Elixir `@optional_callbacks` documentation pattern: Phoenix uses prose
  contracts in `@doc` to define what "optional" means for each callback.
- `lib/tau/provider.ex:89-109` — the existing `cache_regions/2` @doc already
  uses this prose-contract pattern; this proposal extends it to `capabilities/0`.
- Bertrand Meyer PEGS framework: documented contracts are valid obligations
  even when not machine-enforced, provided they are clear and complete.
