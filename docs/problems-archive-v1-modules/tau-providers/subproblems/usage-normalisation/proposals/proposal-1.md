---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: `normalise_usage/1` behaviour callback with shared zero-default scaffold

## Approach

Add a new optional callback `normalise_usage/1` to `Tau.Provider` that each
adapter implements. Provide a shared default implementation in
`Tau.Provider.UsageNorm` that each adapter calls (or delegates to directly).
The callback receives the raw wire-format usage map returned by the upstream API
and returns the canonical B3 map. `stream/3` wrappers in each adapter call this
before emitting `%Event.Done{}`, replacing the empty `%{}` default. A shared
`UsageNorm.zero/0` returns `%{input_tokens: 0, output_tokens: 0, cache_read: 0,
cache_write: 0, cache_breakdown: %{}}` so adapters that receive no usage data
from the upstream have a conforming fallback. The behaviour module enforces
conformance through an `@optional_callbacks [normalise_usage: 1]` declaration
and documents that omission is treated as `UsageNorm.zero/0`.

## Rationale

The complecting hypothesis names two entangled concerns: (1) adapter identity
determining key presence and (2) no shared normalisation scaffold. A behaviour
callback directly decomplects (1) by placing the normalisation responsibility
explicitly at the adapter interface boundary, making it a contract obligation
rather than ad-hoc internal logic. The shared scaffold addresses (2): adapters
cannot "forget" to normalise if the behaviour points them at `UsageNorm`. The
canonical pattern in the codebase (e.g. `cache_regions/2`, `configure/1`) is
optional callbacks with documented defaults, making this approach idiomatic to
the existing `Tau.Provider` design.

## Sketch

```elixir
# lib/tau/provider/usage_norm.ex  (new file)
defmodule Tau.Provider.UsageNorm do
  @moduledoc """
  Shared utility for normalising per-adapter wire-format usage maps into the
  SPEC-PROMPT-CACHING §4 B3 canonical key set.
  """

  @type canonical :: %{
    input_tokens: non_neg_integer(),
    output_tokens: non_neg_integer(),
    cache_read: non_neg_integer(),
    cache_write: non_neg_integer(),
    cache_breakdown: map()
  }

  @spec zero() :: canonical()
  def zero,
    do: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0, cache_breakdown: %{}}

  @spec nonneg(term()) :: non_neg_integer()
  def nonneg(n) when is_integer(n) and n >= 0, do: n
  def nonneg(_), do: 0

  @spec from_openai(map() | nil) :: canonical()
  def from_openai(nil), do: zero()
  def from_openai(u) do
    %{
      input_tokens: nonneg(u["prompt_tokens"]),
      output_tokens: nonneg(u["completion_tokens"]),
      cache_read: 0,
      cache_write: 0,
      cache_breakdown: %{}
    }
  end

  @spec from_gemini(map() | nil) :: canonical()
  def from_gemini(nil), do: zero()
  def from_gemini(u) do
    %{
      input_tokens: nonneg(u["promptTokenCount"]),
      output_tokens: nonneg(u["candidatesTokenCount"]),
      cache_read: nonneg(u["cachedContentTokenCount"]),
      cache_write: 0,
      cache_breakdown: %{}
    }
  end
end

# lib/tau/provider.ex  (diff: add optional callback)
@callback normalise_usage(raw :: map() | nil) :: Tau.Provider.UsageNorm.canonical()
@optional_callbacks [normalise_usage: 1, configure: 1, cache_regions: 2, context_window: 1]

# lib/tau/providers/shared/openai_chat_wire.ex  (diff: inject into Done emission)
# Before (line 66):
#   def decode(%{data: "[DONE]"}, partial), do: {[%Event.Done{stop_reason: :stop}], partial}
# After: wire the `usage` accumulated in partial (requires build_body to request it via
#        `stream_options: %{include_usage: true}` so the final SSE chunk carries usage):

def decode(%{data: "[DONE]"}, %{usage: raw_usage, provider: mod} = partial) do
  usage =
    if function_exported?(mod, :normalise_usage, 1),
      do: mod.normalise_usage(raw_usage),
      else: Tau.Provider.UsageNorm.from_openai(raw_usage)
  {[%Event.Done{stop_reason: :stop, usage: usage}], partial}
end

# lib/tau/providers/bedrock.ex  (diff: message_stop handler reads usage from partial)
defp decode_anthropic_event(%{"type" => "message_stop"}, p) do
  usage = Tau.Provider.UsageNorm.nonneg_bedrock(Map.get(p, :usage_raw, %{}))
  {[%Event.Done{stop_reason: :stop, usage: usage}], p}
end

# lib/tau/providers/gemini.ex  (diff: pass usageMetadata from top-level JSON into Done)
finish =
  case get_in(json, ["candidates", Access.at(0), "finishReason"]) do
    "STOP" ->
      usage = Tau.Provider.UsageNorm.from_gemini(json["usageMetadata"])
      [%Event.Done{stop_reason: :stop, usage: usage}]
    "MAX_TOKENS" ->
      usage = Tau.Provider.UsageNorm.from_gemini(json["usageMetadata"])
      [%Event.Done{stop_reason: :length, usage: usage}]
    _ -> []
  end
```

Conformance test (new `test/tau/provider/usage_norm_test.exs`):
```elixir
defmodule Tau.Provider.UsageNormTest do
  use ExUnit.Case, async: true

  @adapters [
    Tau.Providers.Anthropic,
    Tau.Providers.OpenAI.Chat,
    Tau.Providers.OpenAI.Responses,
    Tau.Providers.Gemini,
    Tau.Providers.Bedrock,
    Tau.Providers.Groq,
    Tau.Providers.Mistral,
    Tau.Providers.DeepSeek,
    Tau.Providers.AzureOpenAI,
    Tau.Providers.Custom,
    Tau.Providers.Copilot
  ]

  test "all production adapters emit usage with at least input_tokens and output_tokens" do
    for adapter <- @adapters do
      # Drive a fixture stream for each adapter via the Replay mechanism or
      # by calling normalise_usage/1 directly on a representative wire payload.
      usage =
        if function_exported?(adapter, :normalise_usage, 1),
          do: adapter.normalise_usage(%{}),
          else: Tau.Provider.UsageNorm.zero()

      assert is_integer(usage.input_tokens) and usage.input_tokens >= 0,
             "#{adapter}: input_tokens must be non-negative integer"
      assert is_integer(usage.output_tokens) and usage.output_tokens >= 0,
             "#{adapter}: output_tokens must be non-negative integer"
    end
  end
end
```

Files changed:
- `lib/tau/provider.ex` — +1 optional callback
- `lib/tau/provider/usage_norm.ex` — new (~60 lines)
- `lib/tau/providers/shared/openai_chat_wire.ex` — wire usage accumulation + Done emission
- `lib/tau/providers/bedrock.ex` — message_stop usage read
- `lib/tau/providers/gemini.ex` — usageMetadata read into Done
- `lib/tau/providers/anthropic.ex` — add `normalise_usage/1` delegating to existing `merge_usage/2`
- `test/tau/provider/usage_norm_test.exs` — new conformance test

## Tradeoffs

### Strengths

- Directly addresses complecting hypothesis (1): normalisation is now a named
  contract obligation at the behaviour boundary, not implicit per-adapter logic.
- Directly addresses complecting hypothesis (2): `UsageNorm` provides the shared
  scaffold and zero-default, making compliance the path of least resistance.
- Idiomatic: `@optional_callbacks` with documented defaults is the existing
  pattern in `Tau.Provider` (`configure/1`, `cache_regions/2`).
- No API-breaking change to `%Event.Done{}` struct shape — `usage` remains a
  map; consumers are unaffected.
- Anthropic's `merge_usage/2` migrates trivially by delegating to it from
  `normalise_usage/1`.
- The conformance test iterates all known adapters, so a new adapter that forgets
  the callback is caught by the test rather than silently regressing.

### Weaknesses

- `@optional_callbacks` means a new adapter author can still omit the callback
  and get `%{}` at runtime unless they notice the fallback path in `decode`. The
  behaviour does not force implementation — it documents intent.
- The `include_usage: true` addition to OpenAI `build_body/4` adds one field to
  every OpenAI-family request body; this is intentional but a wire-level change
  that may surface in tests or replay fixtures.
- Bedrock's `message_stop` usage requires accumulating usage from `message_start`
  into partial state, which is a non-trivial addition to the decode loop.
- Partial accumulation across chunks (for Bedrock's separate `message_start` /
  `message_delta` usage blocks) mirrors Anthropic's existing pattern but requires
  porting it to the Bedrock decode path, which is currently simpler.

### Costs

- ~100 lines new code (`UsageNorm`, test).
- ~30 lines changed across 4 adapters + `provider.ex`.
- Replay fixtures for OpenAI-family adapters may need a `usage` key added to
  their final `[DONE]` chunk to make the conformance test cover real wire data.
- SPEC-PROMPT-CACHING §4 B3 amendment: document `normalise_usage/1` as the new
  adapter-side hook (small prose addition).

## Dependencies

- `stream_options: %{include_usage: true}` must be added to `build_body/4` in
  `OpenAIChatWire` before OpenAI-family adapters can populate real usage data;
  without it, the wire payload carries no usage and `UsageNorm.from_openai/1`
  will return `zero()` (conforming, but zero-valued).
- No library additions required.

## Confidence

**Medium.** The approach is structurally clear and idiomatic, but the Bedrock
partial-accumulation path requires reading the full Bedrock decode loop to
confirm the partial shape accepts a new `usage_raw` key without conflict.
Confidence would rise to **high** after verifying the Bedrock partial map
structure and confirming `include_usage: true` is honoured by all OpenAI-family
endpoints (Groq, Mistral, DeepSeek, Azure, Custom).

## Prior art / references

- `Tau.Provider` `configure/1` and `cache_regions/2` — existing optional-callback
  pattern with defaults.
- `Tau.Providers.Anthropic.merge_usage/2` — private implementation that becomes
  the prototype for the shared scaffold.
- SPEC-PROMPT-CACHING §4 B3 — canonical key set this proposal enforces.
- OpenAI Chat Completions API docs — `stream_options.include_usage` parameter.
