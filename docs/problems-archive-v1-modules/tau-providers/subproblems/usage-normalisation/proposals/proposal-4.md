---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Shared `ExUnit.Case` template + `mix tau.conformance` task enforces usage conformance via replay fixtures

## Approach

Add a shared `Tau.Test.ProviderConformance` ExUnit case template that all
adapter test modules include. The template defines a single parametrised test:
given a JSONL replay fixture for the adapter, the test asserts that the last
`%Event.Done{}` event carries `input_tokens` and `output_tokens` as non-negative
integers. The fixture format already exists (`priv/fixtures/*.jsonl`). The
enforcement mechanism is test-time, not type-system or behaviour-level: adapters
that emit `%{}` fail CI. To make the test pass, each adapter must be updated to
extract and emit real usage from its wire format — but the *forcing function* is
the test, not a behaviour change. Add a `mix tau.conformance` Mix task that runs
only the conformance tests (`@tag :conformance`) across all adapters as a fast,
targeted gate.

## Rationale

The acceptance criterion is "verified by a shared conformance test or typespec
that all adapters satisfy." This proposal satisfies it literally: a shared test
template is the scaffold, and the JSONL replay fixtures are the specification
artefacts that encode what real wire payloads look like per adapter. Adapters
that do not extract usage data fail the test; fixing the test failure requires
fixing the adapter. The test-forcing approach decomplects (2) by creating a
shared fixture-plus-assertion scaffold that documents what each adapter must
produce, without mandating *how* the adapter extracts it — each adapter keeps
its own extraction logic, but it must exist and must work on its fixture. It
addresses (1) by making divergence a CI failure rather than a silent runtime
discrepancy.

## Sketch

```elixir
# test/support/provider_conformance.ex  (new file)
defmodule Tau.Test.ProviderConformance do
  @moduledoc """
  Shared ExUnit case template for provider usage-normalisation conformance.

  Include in an adapter's test module:

      use Tau.Test.ProviderConformance,
        adapter: Tau.Providers.Gemini,
        fixture: "priv/fixtures/gemini_stream.jsonl"

  The template asserts that the last `%Event.Done{}` in the decoded fixture
  stream carries non-negative-integer `input_tokens` and `output_tokens`.
  """

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    fixture  = Keyword.fetch!(opts, :fixture)

    quote do
      @tag :conformance
      test "#{unquote(adapter)} Done.usage has canonical keys" do
        events =
          unquote(fixture)
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!/1)
          |> Enum.flat_map(fn raw ->
            {evts, _partial} = unquote(adapter).__decode_sse__(raw, initial_partial())
            evts
          end)

        done = Enum.find(events, &match?(%Tau.Provider.Event.Done{}, &1))
        assert done != nil, "No Done event in fixture stream for #{unquote(adapter)}"

        usage = done.usage
        assert is_integer(usage[:input_tokens]) and usage[:input_tokens] >= 0,
               "input_tokens missing or negative in #{unquote(adapter)}.Done.usage"
        assert is_integer(usage[:output_tokens]) and usage[:output_tokens] >= 0,
               "output_tokens missing or negative in #{unquote(adapter)}.Done.usage"
      end

      defp initial_partial do
        %{tool_calls: %{}, model: nil, provider: unquote(adapter)}
      end
    end
  end
end

# test/tau/providers/gemini_conformance_test.exs  (new, one per adapter)
defmodule Tau.Providers.GeminiConformanceTest do
  use ExUnit.Case, async: true
  use Tau.Test.ProviderConformance,
    adapter: Tau.Providers.Gemini,
    fixture: "priv/fixtures/gemini_stream.jsonl"
end

# test/tau/providers/openai_chat_conformance_test.exs
defmodule Tau.Providers.OpenAI.ChatConformanceTest do
  use ExUnit.Case, async: true
  use Tau.Test.ProviderConformance,
    adapter: Tau.Providers.OpenAI.Chat,
    fixture: "priv/fixtures/openai_chat_stream.jsonl"
end
# ... similar for Bedrock, Groq, Mistral, DeepSeek, AzureOpenAI, Custom, Copilot
```

Fixture format for an adapter that includes usage (Gemini example snippet):
```jsonl
{"candidates":[{"content":{"parts":[{"text":"Hello"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":4,"totalTokenCount":16}}
```

This fixture already exists for Anthropic (the replay mechanism); for other
adapters, minimal fixtures must be authored that include the upstream API's
usage fields in the final chunk.

Mix task:
```elixir
# lib/mix/tasks/tau.conformance.ex
defmodule Mix.Tasks.Tau.Conformance do
  use Mix.Task
  @shortdoc "Run provider usage-normalisation conformance tests"
  def run(_args) do
    Mix.Task.run("test", ["--only", "conformance"])
  end
end
```

Adapter changes required to make tests pass (not part of the template itself —
these are the implementation obligation the failing tests impose):

- `Tau.Providers.Gemini`: read `json["usageMetadata"]` in `decode_chunk/2`,
  emit `%Event.Done{stop_reason: :stop, usage: %{input_tokens: ..., output_tokens: ...}}`.
- `Tau.Providers.Bedrock`: accumulate usage from `message_start` into partial,
  emit it in `message_stop` handler.
- `OpenAIChatWire`: set `stream_options: %{include_usage: true}` in `build_body/4`;
  accumulate usage from the final SSE chunk that carries it; emit in Done.

Files changed (test infrastructure):
- `test/support/provider_conformance.ex` — new (~40 lines)
- `test/tau/providers/*_conformance_test.exs` — one new file per adapter (~5 lines each, ~9 files)
- `priv/fixtures/*.jsonl` — new or extended fixture files per adapter (~5–10 files)
- `lib/mix/tasks/tau.conformance.ex` — new Mix task (~10 lines)
- Each adapter that currently emits `%{}`: fix to extract wire usage (4 adapters + `OpenAIChatWire`)

## Tradeoffs

### Strengths

- Acceptance criterion satisfied literally: "verified by a shared conformance
  test" — the template is the shared test and the assertion is the criterion.
- Enforcement is CI-blocking: a new adapter that omits usage extraction will
  fail CI as soon as it includes the conformance template.
- The fixture-based approach documents exactly what each adapter's upstream
  wire format looks like (the fixture is also specification documentation).
- Decoupled from the behaviour: each adapter keeps its own extraction logic;
  the test only asserts on the output, not the mechanism.
- `mix tau.conformance` provides a fast targeted gate without running the full
  test suite — valuable during iterative adapter fixes.
- The shared template pattern is idiomatic to ExUnit (`use SomeCase`).

### Weaknesses

- The conformance test calls a semi-public `__decode_sse__/2` hook that does not
  currently exist on most adapters. Adding it requires either making the private
  decode functions public (or at least `@doc false` public), or restructuring
  each adapter to expose a testable decode entrypoint. This is a non-trivial
  refactor for some adapters.
- Fixture authoring is the largest cost: each of ~9 adapters needs a fixture
  that represents a real wire payload including usage fields. These must be
  maintained as the upstream APIs evolve.
- The template produces a test that only covers the fixture path; if the adapter
  has multiple Done emission paths (e.g. finish_reason "STOP" vs "MAX_TOKENS"),
  the conformance test covers only the one in the fixture unless it is parametrised
  further.
- Does not prevent adapters from emitting `%{}` at runtime through code paths
  not covered by the fixture — the test is a sampling check, not an exhaustive
  type-system enforcement.
- Cannot fix any silent zero-valued fields until the adapter changes are made
  (the test forces the fix but is not the fix itself).

### Costs

- Fixture authoring: ~9 JSONL fixture files, each 5–20 lines, plus finding/
  recording real upstream responses for adapters that lack fixtures today.
- `__decode_sse__/2` exposure: each adapter's internal decode function may need
  a thin public shim — ~5 lines per adapter, ~9 adapters.
- Adapter fixes (the actual substance): Gemini, Bedrock, OpenAI-family usage
  extraction — likely 10–20 lines each (same scope as Proposals 1 and 2, but
  the motivation comes from test failure rather than behaviour-level contract).
- Fixture maintenance: when an upstream API changes its usage field names, the
  fixture and the adapter decode must both update — two points of change.

## Dependencies

- JSONL fixture format: already established by the Replay provider.
- `mix test --only conformance` tag: requires no library additions.
- For OpenAI-family real usage: `stream_options: %{include_usage: true}` must be
  set in `build_body/4`.

## Confidence

**Medium.** The conformance template and Mix task are simple. Uncertainty is in
the `__decode_sse__/2` exposure surface: if adapters restructure their decode
around a public entrypoint, the approach is clean; if not, the test must call
internal functions via `:erlang.apply/3` or the adapter's top-level `stream/3`
with a mock HTTP client — more complex test infrastructure. Confidence would
rise to **high** after checking whether any existing adapter tests already call
decode functions directly (establishing precedent for the exposure pattern).

## Prior art / references

- `Tau.Providers.Replay` — existing JSONL fixture replay mechanism; the
  fixture format is established.
- ExUnit `use SomeCase` shared template pattern — e.g. `DataCase`, `ConnCase`
  in Phoenix projects.
- OpenAI Chat Completions `stream_options.include_usage` — the wire-level
  prerequisite for OpenAI-family adapters.
- `mix test --only <tag>` — standard ExUnit tag-based filtering used by the
  existing `mix test --only property` alias.
