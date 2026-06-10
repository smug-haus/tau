---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: usage-normalisation

## Statement

`%Tau.Provider.Event.Done{usage: map()}` carries an implicit per-adapter
schema. SPEC-PROMPT-CACHING §4 B3 defines the canonical key set
(`input_tokens`, `output_tokens`, `cache_read`, `cache_write`,
`cache_breakdown`), but only Anthropic's `merge_usage/2` emits it. All adapters
using `OpenAIChatWire.decode/2` emit `%Event.Done{stop_reason: ..., usage: %{}}`
— an empty map — regardless of whether the upstream API returned token counts.
Bedrock and Gemini also emit empty usage. Consumers relying on usage maps for
cost tracking, context-window percentage display, or cache-efficiency reporting
silently receive zero or absent values for all non-Anthropic providers.

## Context

- `lib/tau/provider/event.ex:90-95` — `Done.t()` specifies `usage: map()` with
  no further constraint on which keys are present.
- `lib/tau/providers/anthropic.ex:284-315` — `merge_usage/2` normalises
  `message_start` + `message_delta` usage blocks into the B3 canonical map.
  It is an adapter-private function, not a shared utility or callback.
- `lib/tau/providers/shared/openai_chat_wire.ex:66` — `%Event.Done{stop_reason:
  :stop}` (no `usage:` key; defaults to `%{}`). The OpenAI Chat Completions
  SSE stream does include token usage in the final `[DONE]` delta when
  `stream_options: {include_usage: true}` is set, but `build_body/4` never
  sets it — so the data is never requested.
- `lib/tau/providers/bedrock.ex:121-123` — `message_stop` handler emits
  `%Event.Done{stop_reason: :stop}` with no usage.
- `lib/tau/providers/gemini.ex:112-118` — finish-reason handler emits
  `%Event.Done{stop_reason: :stop}` with no usage. The Gemini response does
  include `usageMetadata` at the top level, but `decode_chunk/2` never reads it.
- SPEC-PROMPT-CACHING §4 B3 and D-065 define the canonical usage contract; the
  SPEC names it as "each adapter's own `merge_usage`-side responsibility" but
  provides no scaffold or shared utility to enforce it.

## Complecting hypothesis

1. **Usage key presence is complected with adapter identity:** whether
   `Done.usage` carries meaningful token counts depends on which adapter
   produced the event, not on the declared event type contract.
2. **Raw wire-protocol usage fields are complected with normalisation
   responsibility:** each adapter is individually responsible for mapping its
   wire-format usage fields to canonical Tau keys, but the behaviour provides
   no shared utility, no typespec constraint on the `usage` map, and no test
   fixture to validate conformance.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

Every production adapter that receives token-usage data from its upstream API
emits a `%Event.Done{usage: map()}` where `usage` contains at minimum the
canonical keys `input_tokens` and `output_tokens` with non-negative integer
values, and where any absent upstream field yields `0` rather than a missing key
— verified by a shared conformance test or typespec that all adapters satisfy.

## Out of scope

- Event sequencing (TextStart/TextEnd framing) — covered by
  `callback-contract-drift`.
- Capabilities flag accuracy — covered by `capabilities-flag-fidelity`.
- Auth-resolution — covered by `auth-resolution-scatter`.
- The `cache_read` / `cache_write` / `cache_breakdown` sub-keys for
  adapters that do not support prompt caching — these are legitimately `0`
  or absent for non-caching adapters; the acceptance criterion only requires
  the base `input_tokens`/`output_tokens` pair.

## Amendment log

- (none yet)
