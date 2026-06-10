---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Fix non-conforming adapters at source — behaviour-correcting rewrites of Bedrock and Gemini decode paths

## Approach

Rewrite `Tau.Providers.Bedrock.decode_anthropic_event/2` and
`Tau.Providers.Gemini`'s event-emission path to emit conformant
`TextStart` / `TextEnd` framing and genuine per-block unique `block_id`
values, eliminating the hardcoded `"text"` sentinel. For Gemini, also
introduce a `ToolCallDelta` emission between `ToolCallStart` and `ToolCallEnd`
containing the partial argument JSON (or a single full-arg delta immediately
before `ToolCallEnd` for the atomic case). Simultaneously add a `@spec` to
`@callback stream/3`'s docstring declaring the now-uniform mandatory sequence.
The behaviour remains unchanged in callback count; the contract is declared in
the docstring and in a `Tau.Provider.ContractTest` that exercises all adapters
via Replay fixtures and asserts the framing invariants hold.

## Rationale

The root cause of consumer resilience being complected with provider conformance
is that two specific adapters (Bedrock and Gemini) emit structurally incorrect
event sequences. The prior three proposals document, wrap, or codify the gap
without eliminating it. This proposal eliminates the source of divergence:
Bedrock and Gemini emit what the contract requires. Once both adapters conform,
the `@callback` docstring can describe a single mandatory sequence without
caveats. The normaliser (Proposal 2) becomes unnecessary; the contract struct
(Proposal 3) collapses to a single valid shape. Consumers can drop all ad-hoc
tolerances unconditionally, not just behind a wrapper.

## Sketch

```elixir
# lib/tau/providers/bedrock.ex — decode_anthropic_event/2, revised

# Before (non-conforming):
#   emits only: %TextDelta{block_id: "text", text: t}

# After (conforming):
defp decode_anthropic_event(
       %{"type" => "content_block_start", "index" => idx, "content_block" => %{"type" => "text"}},
       _acc
     ) do
  block_id = "bedrock-text-#{idx}"
  {:emit, %Event.TextStart{block_id: block_id}, %{block_id: block_id}}
end

defp decode_anthropic_event(
       %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => t}},
       %{block_id: bid}
     ) do
  {:emit, %Event.TextDelta{block_id: bid, text: t}, %{block_id: bid}}
end

defp decode_anthropic_event(
       %{"type" => "content_block_stop"},
       %{block_id: bid}
     ) do
  {:emit, %Event.TextEnd{block_id: bid}, %{}}
end

# tool-use block start (was: silently ignored)
defp decode_anthropic_event(
       %{"type" => "content_block_start", "index" => idx,
         "content_block" => %{"type" => "tool_use", "id" => tool_id, "name" => name}},
       _acc
     ) do
  block_id = tool_id || "bedrock-tool-#{idx}"
  {:emit, %Event.ToolCallStart{tool_call_id: block_id, name: name}, %{tool_id: block_id}}
end
```

```elixir
# lib/tau/providers/gemini.ex — emit_events/1, revised (excerpt)

# Before: emits TextDelta{block_id: "text"} with no framing
# After:  emits TextStart, TextDelta+, TextEnd per candidate.content part

defp emit_text_part(text, stream_state) do
  idx = stream_state.text_index
  bid = "gemini-text-#{idx}"
  [
    %Event.TextStart{block_id: bid},
    %Event.TextDelta{block_id: bid, text: text},
    %Event.TextEnd{block_id: bid}
  ]
end

# Before: emits ToolCallStart + ToolCallEnd in a single chunk, no ToolCallDelta
# After:  emits ToolCallStart, synthetic ToolCallDelta with full args JSON, ToolCallEnd

defp emit_tool_call(fc, stream_state) do
  id = fc["id"] || "gemini-tool-#{stream_state.tool_index}"
  args_json = Jason.encode!(fc["args"] || %{})
  [
    %Event.ToolCallStart{tool_call_id: id, name: fc["name"]},
    %Event.ToolCallDelta{tool_call_id: id, json_fragment: args_json},
    %Event.ToolCallEnd{tool_call_id: id, params: fc["args"] || %{}}
  ]
end
```

```elixir
# lib/tau/provider.ex — updated @callback docstring (no new callbacks)
@doc """
...

## Mandatory event sequence (all adapters)

A minimal well-formed text turn MUST emit:

    %Start{}
    %TextStart{block_id: b}       — b is unique within this stream
    %TextDelta{block_id: b, ...}+ — one or more deltas
    %TextEnd{block_id: b}
    %Done{}

A tool-call block MUST emit:

    %ToolCallStart{tool_call_id: id, name: n}
    %ToolCallDelta{tool_call_id: id, json_fragment: f}+  — MAY be a single full-args fragment
    %ToolCallEnd{tool_call_id: id, params: p}

block_id values MUST be unique within a stream. The sentinel "text" is not conformant.
"""
@callback stream(messages(), stream_opts(), ctx()) ::
            {:ok, Enumerable.t()} | {:error, term()}
```

## Tradeoffs

### Strengths

- Eliminates rather than papers over the source of divergence.
- Consumers can drop all ad-hoc tolerances unconditionally — no wrapper
  required, no conditional logic per adapter.
- The `@callback` docstring describes a single mandatory sequence with no
  adapter-specific caveats, fully satisfying the acceptance criterion.
- Bedrock and Gemini users gain correct `block_id` values (useful for
  block-level attribution and replay fidelity).

### Weaknesses

- Highest risk: changes live decode paths for Bedrock and Gemini. A bug in the
  rewrite breaks streaming for those providers.
- Bedrock uses `InvokeModelWithResponseStream` with Anthropic-format events;
  the decode path is tightly coupled to that wire format. Regression testing
  requires either live AWS credentials or a byte-accurate Bedrock Replay
  fixture.
- Gemini's `functionCall` response does not include a streaming intermediate —
  the `ToolCallDelta` emitted here is always a single-chunk atomic delta, not
  true streaming. This is semantically correct but may surprise consumers that
  optimise for incremental argument display.
- Does not address OpenAI shared wire path synthesis gaps
  (`openai_chat_wire.ex:108-166`), which has a conditional TextStart synthesis
  that silently omits the event on empty deltas.
- Requires comprehensive Replay fixtures for Bedrock and Gemini to land safely.

### Costs

- ~2 PRs: Bedrock decode rewrite (~40 LOC diff) + Gemini emit rewrite (~30 LOC
  diff), each with matching Replay fixtures and property tests.
- Existing tests for Bedrock and Gemini may break if they assert on the old
  non-conforming event sequences — those tests must be updated.
- If `Tau.Message.Assembler` has hardcoded tolerances for the `"text"` sentinel
  block_id, those must be removed in a follow-on PR.

## Dependencies

- Byte-accurate Replay fixtures for Bedrock `content_block_start` /
  `content_block_stop` events (check `test/support/fixtures/`).
- Byte-accurate Replay fixture for Gemini `functionCall` response with `args`.
- `Tau.Message.Assembler` tolerances should be removed in the same PR or a
  tightly-coupled follow-on to avoid a window where the assembler is too
  strict before the fix lands.

## Confidence

medium — the code changes are straightforward given the wire format docs;
the risk is fixture completeness. Confidence would rise to high with confirmed
byte-accurate Bedrock and Gemini Replay fixtures available in the test suite.

## Prior art / references

- `lib/tau/providers/shared/openai_chat_wire.ex:108-166` — existing synthesis
  of TextStart/TextEnd in a shared wire decoder; confirms the pattern is viable
  in Tau's architecture.
- Anthropic `content_block_start` / `content_block_stop` SSE format docs —
  the Bedrock rewrite mirrors the Anthropic decode path already in
  `lib/tau/providers/anthropic.ex:182-246`.
- `lib/tau/providers/anthropic.ex:182-246` — reference conformant implementation
  to clone structure from.
