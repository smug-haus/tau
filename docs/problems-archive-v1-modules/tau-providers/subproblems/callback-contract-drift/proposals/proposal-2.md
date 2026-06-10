---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: `Tau.Provider.EventNormaliser` stream wrapper — behaviour-preserving runtime enforcement

## Approach

Introduce `Tau.Provider.EventNormaliser`, a stateful stream transformer that
sits between any raw adapter enumerable and its consumer. The normaliser holds a
per-block-id state machine (`:idle → :open → :idle`) and automatically
synthesises the missing `TextStart` / `TextEnd` framing events when a
`TextDelta` arrives without a preceding `TextStart` or is followed by a
`TextDelta` for a different block (or by `Done`). Similarly, it synthesises a
`ToolCallDelta` wrapping the full args when `ToolCallEnd` arrives without a
preceding `ToolCallDelta`. `Tau.Provider`'s default `stream/3` wrapper in the
`__using__` macro (or the session FSM's call site in `Tau.Provider.chat/4`)
pipes every adapter's enumerable through `EventNormaliser.wrap/1` before
returning it to the caller. Non-conforming adapters are silently corrected at
the boundary; consumers receive a guaranteed-framed stream.

## Rationale

The second complecting hypothesis is that consumer resilience is complected with
provider conformance — `Tau.Message.Assembler` must tolerate un-started blocks
because adapters don't guarantee framing. This proposal decomplects by pushing
the tolerance one layer earlier (the boundary between adapter and consumer) and
making it explicit and testable. Rather than every consumer carrying ad-hoc
workarounds, a single normaliser carries all the repair logic. Adapters remain
unchanged for now; the normaliser is the specification made executable — if an
adapter emits a `TextDelta` with block_id "text", the normaliser fills in the
`TextStart` automatically. Conforming adapters (Anthropic) pass through
unchanged because the state machine's happy path emits nothing extra.

## Sketch

```elixir
# lib/tau/provider/event_normaliser.ex (new file)
defmodule Tau.Provider.EventNormaliser do
  @moduledoc """
  Stream transformer that guarantees every event stream from a provider adapter
  conforms to the Tau.Provider stream contract (TextStart before TextDelta,
  TextEnd after the last TextDelta, ToolCallDelta present before ToolCallEnd).

  Wrap an adapter enumerable:

      {:ok, raw} = adapter.stream(msgs, opts, ctx)
      {:ok, EventNormaliser.wrap(raw)}
  """

  alias Tau.Provider.Event

  @type block_state :: %{
    optional(String.t()) => :text | :tool | :thinking
  }

  @spec wrap(Enumerable.t()) :: Enumerable.t()
  def wrap(raw_stream) do
    Stream.transform(raw_stream, %{}, &normalise_event/2)
  end

  # --- text block: synthesise TextStart if missing ---
  defp normalise_event(%Event.TextDelta{block_id: bid} = e, state) do
    case Map.get(state, bid) do
      :text ->
        {[e], state}
      nil ->
        synthetic_start = %Event.TextStart{block_id: bid}
        {[synthetic_start, e], Map.put(state, bid, :text)}
    end
  end

  defp normalise_event(%Event.TextEnd{block_id: bid} = e, state) do
    {[e], Map.delete(state, bid)}
  end

  defp normalise_event(%Event.TextStart{block_id: bid} = e, state) do
    {[e], Map.put(state, bid, :text)}
  end

  # --- tool call: synthesise ToolCallDelta wrapping full args if missing ---
  defp normalise_event(%Event.ToolCallEnd{tool_call_id: id, params: p} = e, state) do
    case Map.get(state, {:delta_seen, id}) do
      true ->
        {[e], Map.delete(state, {:delta_seen, id})}
      _ ->
        synthetic_delta = %Event.ToolCallDelta{
          tool_call_id: id,
          json_fragment: Jason.encode!(p)
        }
        {[synthetic_delta, e], state}
    end
  end

  defp normalise_event(%Event.ToolCallDelta{tool_call_id: id} = e, state) do
    {[e], Map.put(state, {:delta_seen, id}, true)}
  end

  # --- Done: close any open text blocks ---
  defp normalise_event(%Event.Done{} = e, state) do
    synthetic_ends =
      state
      |> Enum.filter(fn {k, _} -> is_binary(k) end)
      |> Enum.map(fn {bid, :text} -> %Event.TextEnd{block_id: bid} end)
    {synthetic_ends ++ [e], %{}}
  end

  defp normalise_event(e, state), do: {[e], state}
end
```

```elixir
# lib/tau/provider.ex — wrap point in chat/4 (or stream/3 dispatch)
defp normalise_stream({:ok, raw}),
  do: {:ok, Tau.Provider.EventNormaliser.wrap(raw)}
defp normalise_stream(err), do: err
```

## Tradeoffs

### Strengths

- Consumers (`Tau.Message.Assembler`, render loop) can drop all ad-hoc
  tolerances for un-started blocks — the contract is now guaranteed.
- Acceptance criterion is satisfied: the behaviour (via `EventNormaliser.wrap`)
  declares and enforces the sequence; a conforming adapter is detectable by
  verifying the normaliser emits no synthetic events.
- Behaviour-preserving: existing adapter code does not change; Anthropic's
  well-formed output passes through with zero synthetic emissions.
- Testable in isolation: `EventNormaliser` is a pure `Stream.transform` — no
  process, no GenServer; property tests can fuzz adapter output and assert
  normalised framing.

### Weaknesses

- Hides non-conforming adapters rather than surfacing them: Bedrock and Gemini
  continue emitting bare `TextDelta`; the gap is papered over, not fixed.
  Technical debt accumulates silently.
- Synthetic `TextStart` events have a synthesised block_id identical to the
  original `TextDelta.block_id` — for Bedrock this is the sentinel `"text"`,
  which is not unique per block. Block identity semantics are still wrong; the
  normaliser cannot invent a real block_id.
- `ToolCallEnd` synthesis of `ToolCallDelta` encodes full args as
  `Jason.encode!/1` — if `params` is already a decoded map the round-trip is
  fine, but the semantics of `ToolCallDelta.json_fragment` (a streaming
  fragment) are slightly abused for the atomic case.
- Adds one `Stream.transform` traversal on every stream — negligible but
  non-zero overhead.

### Costs

- ~1 PR: new `EventNormaliser` module (~100 LOC), wrap-point in `provider.ex`,
  property tests for the state machine (25–40 test cases).
- `Tau.Message.Assembler` can simplify once normaliser is in place — optional
  follow-on PR.
- Jason compile-time dependency already present; no new deps.

## Dependencies

- `Jason` must be available at the wrap site (it is — already in `mix.exs`).
- No adapter changes required; this is intentionally a shim.

## Confidence

high — `Stream.transform` with a per-key state map is a standard Elixir idiom;
the state machine is straightforward. Prototype would take ~2 hours. Prior art
in the project: `openai_chat_wire.ex` already synthesises TextStart/End,
confirming the pattern is sound.

## Prior art / references

- `lib/tau/providers/shared/openai_chat_wire.ex:108-166` — existing synthesis
  pattern for TextStart/TextEnd; the normaliser generalises this approach to
  all adapters.
- Elixir `Stream.transform/3` docs — the standard accumulator-transform idiom.
- "Tolerant Reader" pattern (Fowler) — consumers tolerate variant inputs; here
  applied at the adapter boundary rather than the consumer.
