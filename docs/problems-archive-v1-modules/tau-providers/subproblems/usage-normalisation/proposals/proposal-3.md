---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Stream post-processor normalises `Done.usage` at the session boundary

## Approach

Leave all adapters unchanged. Instead, add a `Tau.Provider.UsageNorm.normalise/1`
stream transform applied in `Tau.Session` immediately after the provider stream
is obtained, before the stream is consumed by the render loop. This function maps
over every event in the stream; when it encounters `%Event.Done{usage: u}` where
`u` is missing `input_tokens` or `output_tokens`, it replaces `u` with a
normalised map that has all required keys defaulted to `0`. Adapters that already
emit canonical usage (Anthropic) pass through untouched. No adapter code is
modified.

## Rationale

This proposal treats usage normalisation as a **consumer-side contract** rather
than a producer-side obligation. The session is the single consumer of every
provider stream; applying normalisation there eliminates the per-adapter scatter
without touching eleven adapter modules. It decomplects (1) by removing the
consumer's dependence on adapter identity at the point of use — the consumer
always sees a canonical map regardless of which adapter produced the event.
Complecting hypothesis (2) is addressed partially: the shared scaffold exists in
`UsageNorm.normalise/1` rather than at the behaviour boundary, so adapters
still have no normalisation obligation — but consumers are no longer broken by
absent keys.

## Sketch

```elixir
# lib/tau/provider/usage_norm.ex  (new file)
defmodule Tau.Provider.UsageNorm do
  @moduledoc """
  Stream-level normaliser for `%Event.Done{usage: map()}`.

  Applied as a stream transform at the session boundary; wraps the
  provider's raw stream so every `Done` event carries the B3 canonical key
  set with non-negative-integer values.
  """

  alias Tau.Provider.Event

  @canonical_keys ~w(input_tokens output_tokens cache_read cache_write)a

  @doc """
  Wraps `stream` in a lazy transform that normalises every `%Event.Done{}`
  usage map into the B3 canonical key set.  Non-Done events are passed through
  unchanged.
  """
  @spec normalise(Enumerable.t()) :: Enumerable.t()
  def normalise(stream) do
    Stream.map(stream, &normalise_event/1)
  end

  defp normalise_event(%Event.Done{usage: u} = done) do
    %{done | usage: canonicalise(u)}
  end
  defp normalise_event(event), do: event

  defp canonicalise(u) when is_map(u) do
    Enum.reduce(@canonical_keys, u, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, v} when is_integer(v) and v >= 0 -> acc
        _ -> Map.put(acc, key, 0)
      end
    end)
  end
  defp canonicalise(_), do: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0}
end

# lib/tau/session.ex  (diff: wrap stream after provider call)
# Before (approximately):
#   {:ok, stream} = provider.stream(messages, opts, ctx)
#   consume(stream, ...)
#
# After:
#   {:ok, raw_stream} = provider.stream(messages, opts, ctx)
#   stream = Tau.Provider.UsageNorm.normalise(raw_stream)
#   consume(stream, ...)
```

Conformance test (new `test/tau/provider/usage_norm_test.exs`):
```elixir
defmodule Tau.Provider.UsageNormTest do
  use ExUnit.Case, async: true

  alias Tau.Provider.Event
  alias Tau.Provider.UsageNorm

  test "normalises missing keys to 0" do
    stream = [%Event.Done{stop_reason: :stop, usage: %{}}]
    [%Event.Done{usage: u}] = stream |> UsageNorm.normalise() |> Enum.to_list()
    assert u.input_tokens == 0
    assert u.output_tokens == 0
    assert u.cache_read == 0
    assert u.cache_write == 0
  end

  test "preserves existing non-negative values" do
    stream = [%Event.Done{stop_reason: :stop,
                          usage: %{input_tokens: 10, output_tokens: 5,
                                   cache_read: 0, cache_write: 0}}]
    [%Event.Done{usage: u}] = stream |> UsageNorm.normalise() |> Enum.to_list()
    assert u.input_tokens == 10
    assert u.output_tokens == 5
  end

  test "replaces negative values with 0" do
    stream = [%Event.Done{stop_reason: :stop, usage: %{input_tokens: -1, output_tokens: 3}}]
    [%Event.Done{usage: u}] = stream |> UsageNorm.normalise() |> Enum.to_list()
    assert u.input_tokens == 0
    assert u.output_tokens == 3
  end

  test "passes non-Done events through unchanged" do
    stream = [%Event.TextDelta{block_id: "text", text: "hello"}]
    result = stream |> UsageNorm.normalise() |> Enum.to_list()
    assert result == stream
  end
end
```

Files changed:
- `lib/tau/provider/usage_norm.ex` — new (~40 lines)
- `lib/tau/session.ex` — +1 pipeline step after `provider.stream/3`
- `test/tau/provider/usage_norm_test.exs` — new

No adapter files modified.

## Tradeoffs

### Strengths

- **Minimal blast radius**: no adapter code changes; single session insertion
  point. Can ship in one small PR.
- The normalisation logic is self-contained and fully unit-testable without any
  adapter fixture.
- Behaviour-preserving from the adapter's perspective — no contract change,
  no new callback obligation.
- Fixes the consumer-side symptom (silent zero-valued fields) immediately for
  all adapters, including ones not yet identified.
- Low risk of introducing a regression in any adapter decode path.

### Weaknesses

- Does **not** fix the underlying data gap: adapters still emit `%{}` even when
  the upstream API returned actual token counts. Anthropic emits real counts;
  all others still emit zero (the normaliser pads absent keys to `0`, but cannot
  conjure counts that were never requested or parsed from the wire).
- Does not satisfy the acceptance criterion's intent "receives token-usage data
  from its upstream API": the `normalise/1` wrapper cannot know whether `0` means
  "API returned zero" or "API returned real counts that the adapter discarded".
- No enforcement at the adapter boundary: a new adapter can still omit usage
  extraction entirely and the normaliser will silently zero-fill, masking the
  implementation gap.
- Treats symptoms, not the cause: the `cache_read`/`cache_write` problem for
  Gemini (which does return `cachedContentTokenCount`) is not fixed — the
  adapter never reads it, so the normaliser sees `%{}` and returns `0`.
- Strictly speaking fails the acceptance criterion: "emits a `%Event.Done{usage:
  map()}` where `usage` contains ... `input_tokens` and `output_tokens` with
  non-negative integer values" requires the adapter to emit real counts, not for
  the consumer to paper over absent ones.

### Costs

- ~40 lines new code.
- 1–2 line change in `session.ex`.
- If `Session` uses `Stream.flat_map` over chunks rather than a simple stream,
  the insertion point may require more surgery — read `session.ex` to confirm.
- Real token-count data (Gemini, Bedrock, OpenAI-family) remains missing until
  adapters are updated separately.

## Dependencies

- No library additions.
- For real token counts from OpenAI-family, Bedrock, Gemini: adapter changes
  (orthogonal PRs) are needed separately. This proposal alone does not deliver
  them.

## Confidence

**Medium-low.** The normaliser logic is simple and high-confidence. Confidence
is low on satisfying the acceptance criterion fully — the AC explicitly requires
adapters to emit real counts, not consumers to zero-fill. This proposal is best
understood as a consumer-side safety net, not a complete fix for the stated
problem. Confidence would rise to **high** only if the acceptance criterion is
narrowed to "consumers always see a conforming key set regardless of source".

## Prior art / references

- `Stream.map/2` — idiomatic Elixir lazy stream transform.
- The existing Anthropic `merge_usage/2` — demonstrates that real data exists
  at the wire level when properly requested and parsed; this proposal does not
  replicate that for other adapters.
- "Postel's law" / defensive reading — the normaliser is an application of
  liberal input acceptance at the consumer boundary.
