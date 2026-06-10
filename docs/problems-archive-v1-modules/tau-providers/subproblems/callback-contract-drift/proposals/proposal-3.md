---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: API-breaking `stream_contract/0` callback + Dialyzer-enforced type spec

## Approach

Add a mandatory `@callback stream_contract() :: Tau.Provider.StreamContract.t()`
to the `Tau.Provider` behaviour. Define `Tau.Provider.StreamContract` as a
struct with fields that declare, per event-block kind, whether Start/End
framing is guaranteed and whether Delta streaming is used. All eleven adapters
must implement `stream_contract/0`; the compiler emits a behaviour warning for
any that don't. A `mix tau.verify_stream_contracts` task instantiates each
adapter's contract, validates it against a whitelist of legal combinations, and
reports conformance gaps. A test in `test/tau/provider_stream_contract_test.exs`
calls `stream_contract/0` on all adapters, exercises a minimal live stream (or
Replay fixture), and asserts that the emitted events match the adapter's own
declared contract — making the contract self-falsifying if the adapter lies.

## Rationale

The first complecting hypothesis is that stream-contract decisions are made
per-adapter rather than at the behaviour layer. This proposal addresses the root
cause rather than wrapping it: it promotes the contract to the behaviour's
mandatory interface, forces each adapter to make an explicit declaration, and
then holds adapters to their declarations via a property test. An adapter that
emits bare `TextDelta` (Bedrock, Gemini) must declare
`text_framing: :delta_only` — making the non-conformance visible in code rather
than only in runtime observation. Consumers can then pattern-match on the
adapter's declared contract rather than maintaining silent tolerances.

## Sketch

```elixir
# lib/tau/provider/stream_contract.ex (new file)
defmodule Tau.Provider.StreamContract do
  @moduledoc """
  Declared event-emission contract for a Tau.Provider adapter.

  Each adapter returns one of these from stream_contract/0.
  The struct encodes what the adapter guarantees; test helpers and
  consumers pattern-match on it rather than reading adapter source.
  """
  @enforce_keys [:text_framing, :tool_call_delta, :block_id_uniqueness]
  defstruct [
    :text_framing,          # :start_delta_end | :delta_only
    :tool_call_delta,       # :streaming | :atomic (End only, no Delta intermediates)
    :block_id_uniqueness,   # :per_stream | :sentinel (hardcoded string, not unique)
    thinking_framing: :not_supported  # :start_delta_end | :delta_only | :not_supported
  ]

  @type text_framing :: :start_delta_end | :delta_only
  @type tool_call_delta :: :streaming | :atomic
  @type block_id_uniqueness :: :per_stream | :sentinel
  @type thinking_framing :: :start_delta_end | :delta_only | :not_supported

  @type t :: %__MODULE__{
    text_framing: text_framing(),
    tool_call_delta: tool_call_delta(),
    block_id_uniqueness: block_id_uniqueness(),
    thinking_framing: thinking_framing()
  }

  @doc "The only fully-conforming contract shape."
  def conformant do
    %__MODULE__{
      text_framing: :start_delta_end,
      tool_call_delta: :streaming,
      block_id_uniqueness: :per_stream
    }
  end
end
```

```elixir
# lib/tau/provider.ex — new mandatory callback
@callback stream_contract() :: Tau.Provider.StreamContract.t()
```

```elixir
# lib/tau/providers/bedrock.ex — example non-conforming declaration
@impl Tau.Provider
def stream_contract do
  %Tau.Provider.StreamContract{
    text_framing: :delta_only,
    tool_call_delta: :streaming,
    block_id_uniqueness: :sentinel
  }
end
```

```elixir
# lib/tau/providers/anthropic.ex — example conforming declaration
@impl Tau.Provider
def stream_contract do
  Tau.Provider.StreamContract.conformant()
end
```

```elixir
# test/tau/provider_stream_contract_test.exs (new file, excerpt)
defmodule Tau.ProviderStreamContractTest do
  use ExUnit.Case, async: true

  @adapters Tau.Provider.known_adapters()  # returns the 11-module list

  describe "stream_contract/0 self-consistency" do
    for adapter <- @adapters do
      test "#{adapter} declared contract matches observed events (Replay fixture)" do
        contract = unquote(adapter).stream_contract()
        {:ok, stream} = unquote(adapter).stream(
          TestFixtures.minimal_messages(),
          %{},
          TestFixtures.ctx_for(unquote(adapter))
        )
        events = Enum.to_list(stream)
        assert_contract_matches(contract, events)
      end
    end
  end

  defp assert_contract_matches(%{text_framing: :start_delta_end}, events) do
    # assert TextDelta events are always preceded by TextStart on same block_id
    ...
  end
  defp assert_contract_matches(%{text_framing: :delta_only}, events) do
    # assert no TextStart/TextEnd present — pure delta stream
    ...
  end
end
```

## Tradeoffs

### Strengths

- Acceptance criterion fully satisfied: the behaviour declares the mandatory
  emission rules AND makes them machine-checkable against the adapter's own
  declaration.
- Promotes non-conformance from implicit (read the decode path) to explicit
  (read `stream_contract/0`) — new adapter authors see the contract immediately
  via `@impl` requirements.
- Dialyzer will flag any adapter whose `stream_contract/0` return type doesn't
  match `StreamContract.t()`.
- The self-consistency test creates a regression gate: if Bedrock is later fixed
  to emit framing, its `stream_contract/0` must be updated or the test fails.

### Weaknesses

- API-breaking: adds a mandatory callback, so all eleven adapters need a
  `stream_contract/0` implementation before the PR can compile. This is the
  highest migration cost of the four proposals.
- A dishonest declaration (`stream_contract/0` returns `:start_delta_end` while
  the adapter still emits bare deltas) passes the contract type check but fails
  the self-consistency test only if the test runs with a real or realistic
  fixture.
- The Replay adapter is intentionally divergent (non-production); its
  `stream_contract/0` needs a special case or a `:replay` sentinel value.
- `Tau.Provider.known_adapters/0` doesn't exist yet — must be added or the test
  must hardcode the list.

### Costs

- ~1–2 PRs: new `StreamContract` struct, new callback, 11 adapter
  implementations, new test module, optional `known_adapters/0` helper.
- Each adapter's `stream_contract/0` is ~5 LOC; total adapter burden is ~55 LOC
  across 11 files.
- Test fixture setup for non-Anthropic adapters (Bedrock, Gemini) requires
  Replay-style fixtures — depends on what test infra exists for those adapters.

## Dependencies

- `Tau.Providers.Replay` must handle `stream_contract/0` gracefully (return a
  special value or implement a `:test_only` framing variant).
- Test fixture infrastructure for Bedrock and Gemini streams (may be partially
  present already via `test/support/`).

## Confidence

medium — the struct and callback are straightforward; the self-consistency test
is well-defined in concept but may encounter fixture gaps for non-Anthropic
adapters that make it hard to land as a single atomic PR.

## Prior art / references

- `Tau.Provider.capabilities/0` — same pattern: a struct returned from a
  mandatory callback that declares static adapter properties.
- SPEC-PROMPT-CACHING `cache_regions/2` — behaviour callback that declares
  adapter caching strategy; similar "declare your posture" idiom.
- Erlang `:gen_statem` callback-mode declaration (`callback_mode/0`) — a
  mandatory callback whose return value tells the OTP framework what contract
  the implementation uses.
