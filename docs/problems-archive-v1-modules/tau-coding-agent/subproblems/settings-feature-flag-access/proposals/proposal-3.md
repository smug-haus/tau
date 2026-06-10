---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Data-shape change — introduce a FeatureFlag.t() struct that encodes origin alongside value

## Approach

Introduce a new `Tau.CodingAgent.FeatureFlag` module (or a struct in
`Tau.CodingAgent.Settings`) with a type `t()` that encodes not just the
boolean value but the origin of the flag: `:configured`, `:default`, or
`:cache_unavailable`. Replace the bare `boolean()` return of
`expose_tau_context?/0` with `%FeatureFlag{value: boolean(), origin: atom()}`.
`maybe_start_tau_context/1` pattern-matches on `origin` to decide behaviour:
`:cache_unavailable` → fail-closed + telemetry; `:default` or `:configured` →
use `value`. This decomplects by making the provenance of the boolean a
first-class part of the data, not a side-channel hidden in the rescue.

## Rationale

The complecting hypothesis is that the same `true` value is produced by two
completely different situations (absent cache vs. genuine default). The
resolution is to give the value a carrier that records how it was produced.
This is a data-shape change: instead of the boolean losing provenance at the
rescue boundary, provenance survives as a struct field. Callers can then branch
on `origin` rather than on the opaque boolean. This is more expressive than a
tagged tuple (Proposal 1) because additional origins (e.g. `:env_override`,
`:runtime_updated`) can be added to the struct without changing call sites that
only care about `:cache_unavailable`.

## Sketch

```elixir
# lib/tau/coding_agent/feature_flag.ex  (new file)
defmodule Tau.CodingAgent.FeatureFlag do
  @moduledoc """
  Carries a feature-flag boolean together with the provenance of its value.
  Callers that need to distinguish 'explicitly configured' from
  'cache unavailable' pattern-match on `origin`.
  """

  @type origin :: :configured | :default | :cache_unavailable
  @type t :: %__MODULE__{value: boolean(), origin: origin()}

  defstruct [:value, :origin]

  @spec new(boolean(), origin()) :: t()
  def new(value, origin), do: %__MODULE__{value: value, origin: origin}
end
```

```elixir
# lib/tau/coding_agent/dispatcher.ex  (modified)
alias Tau.CodingAgent.FeatureFlag

defp expose_tau_context?() do
  try do
    settings = SettingsCache.get()
    ca = Map.get(settings, :coding_agent, %{})
    case ca do
      %{} ->
        raw = Map.get(ca, :expose_tau_context, Map.get(ca, "expose_tau_context", :not_set))
        case raw do
          :not_set -> FeatureFlag.new(true, :default)
          v        -> FeatureFlag.new(v, :configured)
        end
      _ ->
        FeatureFlag.new(true, :default)
    end
  rescue
    _ -> FeatureFlag.new(false, :cache_unavailable)
  catch
    _, _ -> FeatureFlag.new(false, :cache_unavailable)
  end
end

defp maybe_start_tau_context(state) do
  case expose_tau_context?() do
    %FeatureFlag{origin: :cache_unavailable} ->
      :telemetry.execute(
        [:tau, :coding_agent, :tau_context, :settings_unavailable],
        %{system_time: System.system_time()},
        %{adapter: state.adapter}
      )
      state

    %FeatureFlag{value: false} ->
      state

    %FeatureFlag{value: true} ->
      do_start_tau_context(state)
  end
end
```

The `:not_set` sentinel distinguishes "the key was absent in the map" (origin
`:default`) from "the key was explicitly set" (origin `:configured`), enabling
future call sites to treat these differently if needed.

## Tradeoffs

### Strengths

- Directly satisfies the acceptance criterion: caller can distinguish all three
  meaningful states in a single pattern match on `origin`.
- Extensible: new origins (`:env_override`, `:runtime_updated`) add without
  changing existing call-site patterns that only care about `:cache_unavailable`.
- Decomplects provenance from value structurally, not just at the call site.
- Fail-closed on `:cache_unavailable` fixes the silent-enable defect.
- `:default` vs `:configured` distinction enables future auditing or logging
  of "how many runs used a default vs explicit setting".

### Weaknesses

- Introduces a new module for what is currently a simple boolean — may be seen
  as over-engineering for a private predicate used in one place.
- `expose_tau_context?/0` still contains `rescue`/`catch`; does not satisfy
  OTP non-negotiables rule 7 any more than Proposal 1 does.
- The `:not_set` sentinel and three-branch match in `expose_tau_context?/0`
  are more complex than the original; a reader needs to understand `FeatureFlag`
  to follow the logic.
- If `FeatureFlag` is only ever used by this one function, it may be removed
  in a future cleanup as unnecessary indirection.
- Test surface increases: all tests for `maybe_start_tau_context/1` must now
  stub SettingsCache to return values that produce each of the three origins.

### Costs

- One new file: `lib/tau/coding_agent/feature_flag.ex` (~20 lines).
- ~15 line change in `dispatcher.ex`.
- New unit tests for `FeatureFlag.new/2` and the three `maybe_start_tau_context`
  branches.
- No external API change (both functions are private).

## Dependencies

- No upstream changes required; `SettingsCache` is not modified.
- If a future `Tau.CodingAgent.Settings` module is planned (for settings
  normalisation), `FeatureFlag` might belong there instead of being a
  standalone module.

## Confidence

Medium. The struct is straightforward; the pattern-match branches are clear.
Confidence would be higher if the `:not_set` / `:configured` / `:default`
distinction is actually needed (e.g. by observability consumers); if the
distinction is never used, Proposal 1's simpler tagged tuple is sufficient.

## Prior art / references

- Rich Hickey's "Simple Made Easy": giving data provenance is a form of
  complecting-removal at the data layer rather than the control-flow layer.
- Elixir `%URI{}`, `%DateTime{}`, `%Range{}` — structs that carry metadata
  alongside values so callers need not reconstruct origin from context.
- `Tau.Session.Events` pattern: a family of structs encoding event type +
  payload rather than polymorphic maps.
