---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: `@stream_contract` module attribute + compile-time typedoc spec

## Approach

Add a machine-readable `@stream_contract` module attribute to `Tau.Provider`
that declares the mandatory event-emission sequence for `stream/3` in a
structured Elixir term. The attribute is not executed at runtime; it is
documentation that any adapter can `use Tau.Provider` to inherit, and that a
Mix task (`mix tau.check_stream_contract`) reads at compile time to assert each
adapter's moduledoc or typespec references the required sequence. The
`@callback stream/3` docstring is updated to reference the contract attribute
by name, and the event module's `@moduledoc` cross-links it. No runtime
overhead; conformance is a documentation/review gate, not an execution gate.

## Rationale

The complecting hypothesis is that event-sequencing rules are decided per adapter
rather than declared at the behaviour layer. This proposal decomplects by placing
the canonical sequence definition at exactly one location — the behaviour module
— while leaving adapter implementations unchanged. Consumers gain a single
authoritative spec to read; a new adapter author following the behaviour has
immediate guidance. The compile-time check makes deviations detectable without
reading decode paths. This is the lowest-disruption approach: it adds no runtime
path, no struct changes, no new supervision entry, and cannot break an already-
running stream.

## Sketch

```elixir
# lib/tau/provider.ex — new module-level attribute

@stream_contract %{
  text_block: %{
    required_sequence: [:TextStart, {:one_or_more, :TextDelta}, :TextEnd],
    block_id: :must_be_unique_per_stream,
    note: "Adapters that emit TextDelta without framing MUST be updated or wrapped."
  },
  tool_call_block: %{
    required_sequence: [:ToolCallStart, {:zero_or_more, :ToolCallDelta}, :ToolCallEnd],
    block_id: :equals_tool_call_id,
    note: "ToolCallDelta MAY be absent for providers that batch args."
  },
  thinking_block: %{
    required_sequence: [:ThinkingStart, {:one_or_more, :ThinkingDelta}, :ThinkingEnd],
    block_id: :must_be_unique_per_stream,
    note: "Only emitted when capabilities().thinking == true."
  },
  stream_envelope: %{
    required_sequence: [:Start, {:zero_or_more, :block}, :Done],
    note: "Error may appear at any position; terminates the stream."
  }
}

@doc """
...existing doc...

## Stream contract

All adapters MUST conform to `@stream_contract` (see `Tau.Provider.stream_contract/0`).
The minimum well-formed text turn is:

    %Start{} → %TextStart{block_id: "b0"} → %TextDelta{block_id: "b0", text: …}+
             → %TextEnd{block_id: "b0"} → %Done{}

block_id values MUST be unique within a stream. Emitting TextDelta without a
preceding TextStart on the same block_id violates the contract.
"""
@callback stream(messages(), stream_opts(), ctx()) ::
            {:ok, Enumerable.t()} | {:error, term()}

# Accessor so tooling can read the contract at runtime/test time
@spec stream_contract() :: map()
def stream_contract, do: @stream_contract
```

```elixir
# mix/tasks/tau.check_stream_contract.ex (new file, ~60 lines)
defmodule Mix.Tasks.Tau.CheckStreamContract do
  @shortdoc "Verifies each provider adapter module-doc references the stream contract."
  use Mix.Task

  @adapters [
    Tau.Providers.Anthropic,
    Tau.Providers.Bedrock,
    Tau.Providers.Gemini,
    Tau.Providers.OpenAI.Chat,
    Tau.Providers.OpenAI.Responses,
    Tau.Providers.Groq,
    Tau.Providers.Mistral,
    Tau.Providers.DeepSeek,
    Tau.Providers.AzureOpenAI,
    Tau.Providers.Custom,
    Tau.Providers.Copilot
  ]

  def run(_) do
    contract = Tau.Provider.stream_contract()
    Enum.each(@adapters, fn mod ->
      doc = mod.__info__(:attributes)[:moduledoc] || ""
      missing = missing_contract_refs(doc, contract)
      unless missing == [] do
        Mix.raise("#{mod} stream/3 doc missing contract refs: #{inspect(missing)}")
      end
    end)
    Mix.shell().info("All adapters reference stream contract. OK.")
  end

  defp missing_contract_refs(_doc, _contract), do: []
  # real impl: scan doc string for block kind keywords; flag absences
end
```

## Tradeoffs

### Strengths

- Zero runtime cost: no new process, no ETS, no wrapper around the enumerable.
- Acceptance criterion is met: the behaviour module declares the mandatory
  event-emission rules; deviations are detectable by reading `@stream_contract`
  rather than every adapter's decode path.
- Idempotent: can be merged without any adapter change; adapter fixes are
  separate PRs.
- The Mix task doubles as CI lint — a new adapter that omits the doc fails the
  build.

### Weaknesses

- The check is doc-coverage, not behavioural correctness: an adapter can comply
  with the doc check while still emitting non-conforming events at runtime.
- `@stream_contract` is a bare map, not a machine-executable validator; it
  cannot generate test fixtures or guard a stream automatically.
- Mix task enforcement relies on moduledoc text patterns — fragile if doc
  conventions drift.
- Does not fix the Bedrock/Gemini non-conformance; it only makes the gap
  detectable.

### Costs

- ~1 PR: attribute addition to `provider.ex`, updated `@callback` doc, new Mix
  task (~60 LOC), CI job step.
- Adapter authors must add a one-paragraph compliance note to their moduledoc
  (11 adapters × ~5 min = ~1 hour editorial).
- No migration: consumers unchanged.

## Dependencies

- None. Can land independently of any adapter fix.

## Confidence

medium — the approach is well-understood; the weakness is that it does not
mechanically enforce correct runtime behaviour. Confidence would rise to high
with a runtime validator (see Proposal 2).

## Prior art / references

- Elixir `@moduledoc` and module attributes as machine-readable spec metadata:
  standard idiom in Phoenix (`@doc false`, `@behaviour` guards).
- `mix xref` (Elixir stdlib) as a compile-time cross-reference checker —
  analogous pattern for detecting missing references.
- Tau SPEC-USER-TURN §4 uses a declarative contract table with similar shape.
