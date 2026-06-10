---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: capabilities-flag-fidelity

## Statement

`capabilities/0` returns a static map of feature flags (`thinking`,
`prompt_caching`, `tools`, `vision`, `parallel_tools`) but the flags are not
enforced against actual adapter behaviour. Bedrock declares
`thinking: true, prompt_caching: true` while its decode path emits no
`ThinkingStart`/`ThinkingEnd`/`ThinkingDelta` events and has no
`cache_regions/2` implementation. Gemini similarly declares
`thinking: true, prompt_caching: true` with neither feature implemented.
Consumers that branch on `capabilities().thinking` or `capabilities().
prompt_caching` to enable features silently receive a provider that does not
honour them.

## Context

- `lib/tau/provider.ex:59-65` — `@type capabilities` defines the flag map;
  `@callback capabilities/0` has no contract on flag truthfulness.
- `lib/tau/providers/bedrock.ex:35-37` — declares
  `%{thinking: true, tools: true, vision: true, prompt_caching: true,
  parallel_tools: true}`.
- `lib/tau/providers/bedrock.ex:111-123` — `decode_anthropic_event/2` handles
  only `message_start`, `content_block_delta` (text only), and `message_stop`;
  no thinking block events; no `cache_regions/2` callback.
- `lib/tau/providers/gemini.ex:29-31` — declares
  `%{thinking: true, ..., prompt_caching: true, ...}`.
- `lib/tau/providers/gemini.ex:74-121` — decode path handles only text deltas
  and functionCall parts; no thinking events; no `cache_regions/2` callback.
- `lib/tau/providers/anthropic.ex:69-77` — declares `thinking: true,
  prompt_caching: true` AND implements both (ThinkingStart/Delta/End emitted in
  `dispatch/3`; `cache_regions/2` returns `:explicit`).
- `lib/tau/providers/shared/openai_chat_wire.ex:115-166` — does synthesise
  ThinkingStart/ThinkingDelta/ThinkingEnd for the `delta.reasoning` field
  (DeepSeek-R1, Qwen3), but only providers using this wire module with
  `thinking: true` have the capability actually delivered.

## Complecting hypothesis

1. **Capability declaration is complected with decode implementation:** whether a
   flag is true is only discoverable by reading the adapter's decode path, not
   the `capabilities/0` return value, because the behaviour places no obligation
   on flag truthfulness.
2. **Feature-gate logic in callers is complected with per-adapter decode
   assumptions:** code that branches on `capabilities().thinking` to decide
   whether to send thinking params or render thinking blocks must secretly also
   know which adapters lie, rather than relying on the declared map.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

Every `capabilities/0` flag that is `true` for a given adapter is backed by an
observable guarantee — either a behaviour-enforced contract (e.g. adapter must
implement `cache_regions/2` if `prompt_caching: true`), a compile-time
assertion, or at minimum an explicit documented caveat in the behaviour that
names which flags are advisory vs enforceable — such that a caller cannot be
silently misled.

## Out of scope

- The structural event-sequence contract (TextStart/TextEnd framing) — covered
  by `callback-contract-drift`.
- Usage-map normalisation — covered by `usage-normalisation`.
- Auth-resolution — covered by `auth-resolution-scatter`.

## Amendment log

- (none yet)
