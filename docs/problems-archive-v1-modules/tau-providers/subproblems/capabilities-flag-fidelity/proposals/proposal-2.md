---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Replace boolean flags with a typed capability level struct

## Approach

Replace the `capabilities/0` return type from a flat `boolean()` map to a
struct with three levels per feature: `:implemented`, `:advisory`, and
`:unsupported`. The new type `Tau.Provider.Capability` encodes the truthfulness
semantics directly in the data shape. Callers that previously branched on
`capabilities().thinking == true` now branch on
`capabilities().thinking == :implemented`; an adapter that has the decode path
but not the stream params uses `:advisory` to signal "provider may return this
but we don't actively request it." Adapters whose decode paths do not emit the
events use `:unsupported`. This is an API-breaking change to `capabilities/0`
return type.

## Rationale

Boolean flags have no vocabulary for "I claim this but can't back it" — the bit
is either set or not. The complect arises precisely because `true` is forced to
mean both "I declare this feature" and "I implement this feature," with no
gradient. A typed capability level breaks this conflation at the data-shape
layer: the type system carries the distinction, no separate callback enforcement
is needed, and a new adapter author cannot express `true` without choosing a
level that makes the degree of implementation visible. Callers get a richer
signal and can choose whether to require `:implemented` or accept `:advisory`.

## Sketch

```elixir
# lib/tau/provider/capability.ex — new file

defmodule Tau.Provider.Capability do
  @moduledoc """
  Typed capability level for a single feature.

    * `:implemented`  — the adapter actively requests, decodes, and emits the
                        feature. Callers may rely on it unconditionally.
    * `:advisory`     — the adapter may receive provider-side output for this
                        feature but does not actively request it or does not
                        fully synthesise the corresponding events. Callers
                        should treat this as opportunistic.
    * `:unsupported`  — the adapter does not implement this feature. Callers
                        MUST NOT rely on it.
  """
  @type t :: :implemented | :advisory | :unsupported
end
```

```elixir
# lib/tau/provider.ex — updated type

@typedoc "Per-feature capability levels declared by an adapter."
@type capabilities :: %{
        thinking:       Tau.Provider.Capability.t(),
        tools:          Tau.Provider.Capability.t(),
        vision:         Tau.Provider.Capability.t(),
        prompt_caching: Tau.Provider.Capability.t(),
        parallel_tools: Tau.Provider.Capability.t()
      }
```

```elixir
# lib/tau/providers/anthropic.ex — correct declaration
def capabilities do
  %{thinking: :implemented, tools: :implemented, vision: :implemented,
    prompt_caching: :implemented, parallel_tools: :implemented}
end

# lib/tau/providers/bedrock.ex — honest declaration
def capabilities do
  %{thinking: :unsupported, tools: :implemented, vision: :implemented,
    prompt_caching: :unsupported, parallel_tools: :implemented}
end

# lib/tau/providers/gemini.ex — honest declaration
def capabilities do
  %{thinking: :unsupported, tools: :implemented, vision: :implemented,
    prompt_caching: :unsupported, parallel_tools: :unsupported}
end

# lib/tau/providers/shared/openai_chat_wire.ex — adapters with reasoning field
# DeepSeek-R1/Qwen3 via openai_chat_wire (emit ThinkingDelta for delta.reasoning)
def capabilities do
  %{thinking: :advisory, ...}  # synthesises events but doesn't actively request
end
```

```elixir
# Caller migration — lib/tau/session.ex or similar
# Before:
if adapter.capabilities().thinking do ...
# After:
if adapter.capabilities().thinking == :implemented do ...
# Or, accepting advisory:
if adapter.capabilities().thinking in [:implemented, :advisory] do ...
```

```elixir
# Typespec helper for callers:
@spec capability_at_least?(Tau.Provider.Capability.t(), :implemented | :advisory) :: boolean()
def capability_at_least?(:implemented, _), do: true
def capability_at_least?(:advisory, :advisory), do: true
def capability_at_least?(_, _), do: false
```

## Tradeoffs

### Strengths

- The data shape now precisely models the fidelity spectrum; `:advisory`
  captures the OpenAI-wire "we synthesise but don't request" case which a
  boolean cannot express.
- Forces every adapter author to consciously choose a level — no way to
  accidentally assert `:implemented` for a feature that isn't wired.
- No new callbacks or macros: enforcement is structural rather than procedural.
- Satisfies the acceptance criterion: `:implemented` is a documented,
  observable guarantee; `:advisory` and `:unsupported` are explicit caveats
  in the type.
- Dialyzer catches callers comparing capabilities to `true`/`false`
  (incompatible type), surfacing migrations automatically.

### Weaknesses

- API-breaking: every caller of `capabilities/0` that pattern-matches on
  `true`/`false` must be updated. This includes session.ex, TUI render paths,
  and any external consumer.
- `:advisory` is a new concept that callers must understand — it adds cognitive
  load compared to a boolean.
- Does not mechanically enforce that `:implemented` is true: an adapter can
  still lie by declaring `:implemented` without the decode path. The type
  alone does not create a compile-time check.
- Dialyzer will flag mismatched callers as warnings, not errors, unless
  `--warnings-as-errors` is active for dialyzer in CI (it is not by default).
- Migration of eleven adapters is a coordinated, non-trivial change.

### Costs

- New file: `lib/tau/provider/capability.ex` (~25 LOC).
- Modify `lib/tau/provider.ex`: update `@type capabilities`.
- Modify all eleven adapters: replace boolean values with typed atoms.
- Modify all callers of `capabilities/0`: search-and-replace pattern + manual
  review for each branch. Estimate ~15–20 call sites based on the feature gating
  pattern.
- Update property tests and any fixture that asserts `capabilities()` structure.

## Dependencies

- No library or behaviour changes beyond `lib/tau/provider.ex`.
- Caller migration can be staged: ship the type change first with a Dialyzer
  run, fix callers in a second PR.

## Confidence

Medium-high. Elixir tagged atoms are idiomatic for typed enumerations; the
pattern is well-established. Uncertainty is in migration cost (unknown number
of call sites without a code scan) and in whether `:advisory` is a useful
level or overcomplicates the API for callers that just want a binary gate.

## Prior art / references

- Elixir typed option enumerations: `Phoenix.Socket.Transport` uses
  `:websocket | :longpoll` rather than booleans for transport type.
- `Ecto.Adapter.Migration` capability atoms: `:up | :down | :unknown`.
- Hickey "Simple Made Easy": distinguishing declaration from implementation
  as a decomplecting move at the data-shape layer.
