---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Extract mode default policy into a ModePolicy data structure compiled at startup

## Approach

Introduce a `Tau.Permissions.ModePolicy` module that owns the per-mode
allow-set as a declarative, compile-time data structure (a map from mode atom to
a `%ModePolicy{}` struct). `default_for_mode/3` in `Evaluator` is replaced by a
single-clause delegation to `ModePolicy.default/3`. The Bash heuristic branch
inside `:accept_edits` becomes a field on `%ModePolicy{}` (`:bash_heuristic?
:: boolean()`). Property tests are added against `ModePolicy.default/3` directly
— they are now testing a *data-driven* contract, not a pattern-matched imperative
clause.

## Rationale

The complecting hypothesis is that `default_for_mode/3` implements secondary
static policy as imperative pattern-matching interleaved with the evaluator's
rule-set dispatch logic. Extracting this into a data structure separates
*what the policy is* from *when and how it is applied*. The allow-sets become
inspectable values (a map keyed by mode) rather than implicit values derivable
only by reading clause guards. A new mode is added by adding a map entry, not
by adding a `defp` clause; the invariant that "every mode must have a declared
policy" becomes statically enforceable by pattern-matching on the map at
startup. The heuristic exception for `:accept_edits` + Bash is expressed as a
data flag rather than a structural detour in the evaluator.

## Sketch

New file `lib/tau/permissions/mode_policy.ex`:

```elixir
defmodule Tau.Permissions.ModePolicy do
  @moduledoc """
  Static per-mode tool policy for the fallback path in
  `Tau.Permissions.Evaluator.evaluate/5`.

  Each mode has an explicit `%ModePolicy{}` describing:
  - `allow_set`: tools that yield `:allow` by default (no rule needed)
  - `default_outcome`: result for any tool NOT in the allow_set
  - `bash_heuristic?`: when true, Bash is evaluated by
    `Heuristics.destructive_bash?/1` rather than the default_outcome

  ADR basis: ADR-0014 (:plan ceiling), ADR-0015 (:auto/:accept_edits).
  "Agent" is in :plan/:auto allow_sets because it is dispatch
  infrastructure; the read-only constraint propagates into child
  sessions via Mode.clamp/2.
  """

  @enforce_keys [:allow_set, :default_outcome]
  defstruct allow_set: [], default_outcome: :ask, bash_heuristic?: false

  @type t :: %__MODULE__{
          allow_set: [String.t()],
          default_outcome: :allow | :deny | :ask,
          bash_heuristic?: boolean()
        }

  # Canonical policy table. Every mode atom MUST have an entry here.
  # Adding a mode without an entry will cause a KeyError at call time.
  @policies %{
    default: %__MODULE__{allow_set: [], default_outcome: :ask},
    plan: %__MODULE__{allow_set: ["Read", "Grep", "Glob", "Agent"], default_outcome: :deny},
    auto: %__MODULE__{allow_set: ["Read", "Grep", "Glob", "Agent"], default_outcome: :ask},
    accept_edits: %__MODULE__{
      allow_set: ["Read", "Write", "Edit", "Grep"],
      default_outcome: :ask,
      bash_heuristic?: true
    },
    dont_ask: %__MODULE__{allow_set: [], default_outcome: :deny},
    bypass: %__MODULE__{allow_set: :all, default_outcome: :allow}
  }

  @spec default(atom(), String.t(), map()) :: :allow | :deny | :ask
  def default(mode, tool_name, args) do
    policy = Map.fetch!(@policies, mode)
    cond do
      policy.allow_set == :all -> :allow
      tool_name in policy.allow_set -> :allow
      policy.bash_heuristic? and tool_name == "Bash" ->
        if Tau.Permissions.Heuristics.destructive_bash?(args), do: :deny, else: :allow
      true -> policy.default_outcome
    end
  end

  @doc "Returns the raw %ModePolicy{} for a mode. Used by tests and introspection."
  @spec for_mode(atom()) :: t()
  def for_mode(mode), do: Map.fetch!(@policies, mode)
end
```

`evaluator.ex` — replace the six `defp default_for_mode` clauses with:

```elixir
  defp default_for_mode(mode, tool_name, args),
    do: Tau.Permissions.ModePolicy.default(mode, tool_name, args)
```

Property tests in `evaluator_test.exs` (or a new `mode_policy_test.exs`):

```elixir
describe "ModePolicy default/3 invariants (properties)" do
  use ExUnitProperties
  alias Tau.Permissions.ModePolicy

  property ":plan denies tools outside allow_set" do
    policy = ModePolicy.for_mode(:plan)

    check all tool <- string(:alphanumeric, min_length: 1),
              tool not in policy.allow_set do
      assert ModePolicy.default(:plan, tool, %{}) == :deny
    end
  end

  property ":dont_ask denies all tools" do
    check all tool <- string(:alphanumeric, min_length: 1) do
      assert ModePolicy.default(:dont_ask, tool, %{}) == :deny
    end
  end

  property ":auto never allows tools outside its allow_set" do
    policy = ModePolicy.for_mode(:auto)

    check all tool <- string(:alphanumeric, min_length: 1),
              tool not in policy.allow_set,
              tool != "Bash" do
      refute ModePolicy.default(:auto, tool, %{}) == :allow
    end
  end
end
```

## Tradeoffs

### Strengths

- The allow-sets are now inspectable values: `ModePolicy.for_mode(:plan).allow_set`
  returns the set without reading pattern-match clauses.
- Adding a new mode requires one map entry; the `Map.fetch!/2` call then
  enforces exhaustiveness at call time (KeyError on unknown mode).
- Property tests target `ModePolicy.default/3` directly; they test the
  policy contract in isolation from evaluator rule-set logic.
- The bash-heuristic exception is a first-class field on the struct, not
  a structural detour; it is documented at the data layer.
- Satisfies the acceptance criterion fully (properties + documentation with
  ADR references).

### Weaknesses

- Adds a new module and file for what is currently ~30 lines of pattern-matching;
  some contributors may view this as over-engineering for the scope.
- `Map.fetch!/2` raises `KeyError` at call time for unknown modes rather than
  catching them at compile time; a typo in a mode atom is not caught until
  runtime (though the same was true before).
- The `allow_set: :all` special case for `:bypass` is a type-system anomaly
  (the field is declared `[String.t()]` but receives `:all`); requires a union
  type or separate handling.
- Tests now require importing `ModePolicy`; the existing `EvaluatorTest`
  integration tests still cover end-to-end paths, so test surface grows but
  does not shrink.

### Costs

- New file: `lib/tau/permissions/mode_policy.ex` (~60 lines).
- `evaluator.ex`: replace 6 `defp` clauses with 1 delegation (~net -20 lines).
- `evaluator_test.exs` or new `mode_policy_test.exs`: ~25 lines of properties.
- No consumer changes; `evaluate/5` signature is unchanged.

## Dependencies

- No upstream module changes required.
- `stream_data` already a dev dependency.

## Confidence

Medium-high. The data-structure extraction is a well-worn Elixir pattern (see
`Tau.Permissions.Mode`'s `@ranks` map). The `allow_set: :all` type anomaly
needs a decision (union type or a separate `:bypass` clause) before implementation.

## Prior art / references

- `Tau.Permissions.Mode` in this repo: `@ranks` compile-time map used for
  the lattice; same pattern (data table → pure function).
- Elixir `@doc` + `Map.fetch!/2` for exhaustive dispatch: a common idiom in
  Phoenix router tables and plug pipelines.
- ADR-0014, ADR-0015 in `docs/adr/` (allow-set rationale).
