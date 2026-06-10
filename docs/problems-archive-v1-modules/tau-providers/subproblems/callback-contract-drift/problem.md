---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: callback-contract-drift

## Statement

The `stream/3` callback's implicit structural contract — which event types an
adapter MUST emit, in which order, and for which content-block kinds — is
unspecified in the behaviour. Adapters diverge: Bedrock and Gemini emit raw
`TextDelta` without framing `TextStart`/`TextEnd`; Gemini emits `ToolCallStart`
+ `ToolCallEnd` in a single chunk with no `ToolCallDelta` intermediates; Bedrock
ignores `content_block_start` events for tool-use blocks entirely. Consumers
(`Tau.Message.Assembler`, the session FSM render loop) must silently tolerate
or paper over missing framing events rather than relying on a declared contract.

## Context

- `lib/tau/provider/event.ex:20-46` — `TextStart`, `TextDelta`, `TextEnd` are
  sibling event types in the union; the behaviour module-doc does not specify
  which adapters MUST emit them.
- `lib/tau/providers/anthropic.ex:182-246` — `dispatch/3` emits
  `TextStart` on `content_block_start`, `TextDelta` on `content_block_delta`,
  `TextEnd` on `content_block_stop`.
- `lib/tau/providers/shared/openai_chat_wire.ex:108-166` — synthesises
  `TextStart` on first non-empty `content` delta, `TextEnd` on `finish_reason`.
  Synthesis is present but silently omitted for stream paths that never reach
  a non-empty delta.
- `lib/tau/providers/bedrock.ex:118-119` — `decode_anthropic_event/2` emits only
  `TextDelta{block_id: "text", text: t}` with no start/end framing. The block_id
  is a hardcoded sentinel `"text"`, not a per-block identity.
- `lib/tau/providers/gemini.ex:95-109` — emits `TextDelta{block_id: "text"}`
  with no start/end framing; emits `ToolCallStart` + `ToolCallEnd` in a single
  step, never `ToolCallDelta`.
- The `@callback stream/3` doc-string in `lib/tau/provider.ex:67` says "elements
  are `Tau.Provider.Event` structs" but specifies nothing about ordering,
  pairing, or mandatory event types.

## Complecting hypothesis

1. **The stream contract (event sequencing) is complected with each adapter's
   wire protocol knowledge:** whether a text block must be bracketed by Start/End
   events is decided independently per adapter rather than declared at the
   behaviour layer.
2. **Consumer resilience is complected with provider conformance:** `Tau.Message.
   Assembler` and the render loop carry adapter-specific workarounds (e.g.
   tolerating un-started blocks) instead of receiving guaranteed framing.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The `@behaviour Tau.Provider` (or an accompanying spec module / typespec)
declares the mandatory event-emission rules for `stream/3` — specifically: which
event types bracket text and tool-call blocks, what `block_id` uniqueness
guarantees hold, and what the mandatory event sequence looks like for a
minimal-turn response — such that any adapter not conforming to these rules is
detectable without reading the adapter's decode path.

## Out of scope

- Usage-map normalisation within `%Event.Done{}` — covered by
  `usage-normalisation`.
- `capabilities/0` flag accuracy — covered by `capabilities-flag-fidelity`.
- Auth-resolution logic — covered by `auth-resolution-scatter`.
- Transport or SSE parsing internals.

## Amendment log

- (none yet)
