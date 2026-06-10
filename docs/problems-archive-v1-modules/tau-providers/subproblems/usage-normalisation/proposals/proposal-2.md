---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: `%Event.Usage{}` typed struct replaces `usage: map()` in `Done.t()`

## Approach

Replace the `usage: map()` field on `%Event.Done{}` with `usage:
%Tau.Provider.Event.Usage{}` — a new struct with `@enforce_keys` requiring
`input_tokens` and `output_tokens`, and defaulting `cache_read`, `cache_write`,
and `cache_breakdown` to `0` / `%{}`. Every site that currently emits
`%Event.Done{stop_reason: ...}` (with the implicit `usage: %{}` default) must
provide an explicit `%Event.Usage{}`. The compiler enforces the required keys.
No new behaviour callback is added; normalisation is enforced by the type system
rather than by contract. A module-level `@type` on `Event.Usage` documents the
canonical key set; Dialyzer will catch consumers accessing keys that don't exist
on the struct.

## Rationale

The core complecting problem is that `usage: map()` is an unstructured type —
any key or no key is equally valid to the compiler. Replacing it with a struct
enforces the B3 canonical key set at the data-shape level rather than at the
interface level. This directly decomplects (1) adapter identity from key
presence: all adapters must produce the same struct shape, which cannot vary by
adapter without a compile or Dialyzer error. For (2), the struct's default
fields serve as the shared scaffold — adapters that can't populate a field
simply omit the key and get the declared default, rather than leaving the map
empty.

## Sketch

```elixir
# lib/tau/provider/event.ex  (diff: new struct + Done update)

defmodule Tau.Provider.Event.Usage do
  @moduledoc """
  Canonical token-usage record for a completed provider stream.

  `input_tokens` and `output_tokens` are required (non-negative integers).
  Cache-related keys default to 0 / empty map for providers that do not
  support prompt caching.
  """
  @enforce_keys [:input_tokens, :output_tokens]
  defstruct [
    :input_tokens,
    :output_tokens,
    cache_read: 0,
    cache_write: 0,
    cache_breakdown: %{}
  ]

  @type t :: %__MODULE__{
    input_tokens: non_neg_integer(),
    output_tokens: non_neg_integer(),
    cache_read: non_neg_integer(),
    cache_write: non_neg_integer(),
    cache_breakdown: map()
  }
end

defmodule Tau.Provider.Event.Done do
  @moduledoc "Stream finished cleanly."
  @enforce_keys [:stop_reason]
  defstruct [:stop_reason, usage: nil]
  @type t :: %__MODULE__{
    stop_reason: atom(),
    usage: Tau.Provider.Event.Usage.t() | nil
  }
end
```

Call-site changes (every `%Event.Done{}` without usage):
```elixir
# lib/tau/providers/shared/openai_chat_wire.ex
# Before:
%Event.Done{stop_reason: :stop}
# After (with include_usage SSE data accumulated in partial):
%Event.Done{
  stop_reason: :stop,
  usage: %Event.Usage{input_tokens: partial.usage_in, output_tokens: partial.usage_out}
}

# lib/tau/providers/bedrock.ex
%Event.Done{
  stop_reason: :stop,
  usage: %Event.Usage{
    input_tokens: Map.get(p, :usage_in, 0),
    output_tokens: Map.get(p, :usage_out, 0)
  }
}

# lib/tau/providers/gemini.ex
%Event.Done{
  stop_reason: :stop,
  usage: %Event.Usage{
    input_tokens: get_in(json, ["usageMetadata", "promptTokenCount"]) || 0,
    output_tokens: get_in(json, ["usageMetadata", "candidatesTokenCount"]) || 0,
    cache_read: get_in(json, ["usageMetadata", "cachedContentTokenCount"]) || 0
  }
}

# lib/tau/providers/anthropic.ex  (existing merge_usage/2 output wrapped)
%Event.Done{
  stop_reason: stop_reason,
  usage: struct!(Event.Usage, Anthropic.merge_usage(start_u, delta_u))
}
```

Conformance test (new):
```elixir
defmodule Tau.Provider.Event.UsageConformanceTest do
  use ExUnit.Case, async: true

  test "Event.Usage struct enforces required fields" do
    assert_raise ArgumentError, fn ->
      struct!(Tau.Provider.Event.Usage, %{})
    end
  end

  test "Event.Usage has correct defaults for cache fields" do
    u = %Tau.Provider.Event.Usage{input_tokens: 10, output_tokens: 5}
    assert u.cache_read == 0
    assert u.cache_write == 0
    assert u.cache_breakdown == %{}
  end
end
```

Consumer migration: sites reading `event.usage["input_tokens"]` change to
`event.usage.input_tokens`; most consumers are in `Tau.Session` and
`Tau.Cost.Tracker`. The `usage: nil` default on `Done` (rather than `%{}`) lets
existing consumers guard on `is_nil(event.usage)` during migration.

Files changed:
- `lib/tau/provider/event.ex` — new `Usage` struct; update `Done.t()`
- `lib/tau/providers/shared/openai_chat_wire.ex` — emit `%Event.Usage{}`
- `lib/tau/providers/bedrock.ex` — emit `%Event.Usage{}`
- `lib/tau/providers/gemini.ex` — emit `%Event.Usage{}`
- `lib/tau/providers/anthropic.ex` — wrap `merge_usage/2` in `%Event.Usage{}`
- Any consumer reading `event.usage["..."]` → `event.usage.key`
- `test/tau/provider/event/usage_conformance_test.exs` — new

## Tradeoffs

### Strengths

- Strongest enforcement mechanism available without a runtime check: the
  compiler enforces `@enforce_keys`; Dialyzer enforces the field types.
- Decomplects (1) completely: adapter identity cannot influence key presence
  because the struct shape is fixed at the type level.
- Decomplects (2) by making the scaffold the struct itself — adapters
  trivially satisfy the contract by constructing `%Event.Usage{input_tokens: x,
  output_tokens: y}` and getting defaults for the rest.
- Zero runtime overhead over the existing map default.
- Future extensions (e.g. Anthropic's `cache_breakdown` sub-keys) are additions
  to the struct, not silent key-present/absent divergence.

### Weaknesses

- **API-breaking change**: every consumer of `event.usage["key"]` must migrate
  to `event.usage.key`. This includes `Tau.Session`, `Tau.Cost.Tracker`, any
  telemetry handlers, and any replay-fixture reader that materialises raw maps.
- The `@enforce_keys` on `%Event.Done{}` is not changed; `usage: nil` is still
  allowed (to avoid forcing all emit sites at once). This means a careless
  adapter can still emit `%Event.Done{stop_reason: :stop}` with `usage: nil`
  and pass compilation — only Dialyzer catches the mismatch.
- Replay fixture files that embed raw `%{usage: %{}}` JSON must be updated to
  produce `%Event.Usage{}` structs via the replay decoder.
- The `nil` fallback in `Done.t()` (during transition) complicates consumer
  pattern matching: `%Done{usage: %Usage{}}` only matches non-nil usages.

### Costs

- Consumer migration is the dominant cost: scanning `Tau.Session`,
  `Tau.Cost.Tracker`, `Tau.TUI.App` (context-window display) for
  `event.usage["..."]` or `Map.get(event.usage, ...)` calls. Likely ~10–20
  call-sites.
- SPEC amendment: `Event.Done.t()` type changes; SPEC-PROMPT-CACHING §4 B3 and
  `docs/spec/SPEC-USER-TURN.md` reference to `Done.usage` must be updated.
- Any JSON serialisation path that round-trips `%Event.Done{}` (Replay, JSONL
  fixture export) needs a `Usage` struct deserialiser.

## Dependencies

- No new library dependencies.
- Consumers of `event.usage` must migrate before or concurrently with this
  change; a two-phase rollout (struct first, `@enforce_keys` tighten later)
  is possible.
- Dialyzer PLT must cover `Event.Usage.t()` for type enforcement to fire on
  consumers — run `mix dialyzer` after the struct lands.

## Confidence

**Medium.** The struct shape is straightforward; the main uncertainty is the
blast radius of consumer migration. Confidence would rise to **high** after a
`grep -rn 'event\.usage\|\.usage\[' lib/ test/` pass to count call-sites.

## Prior art / references

- `Tau.Provider.Event.Error` — existing struct pattern in the same module that
  enforces required fields via `@enforce_keys`.
- Elixir `@enforce_keys` — struct-level required fields.
- SPEC-PROMPT-CACHING §4 B3 — B3 canonical key set this proposal makes
  structurally mandatory.
