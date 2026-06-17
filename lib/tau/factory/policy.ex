defmodule Tau.Factory.Policy do
  @moduledoc """
  Factory policy struct — the per-run configuration record pinned at admission.

  INV-MODEL-POLICY (issue #552): no role's model assignment is hardcoded in
  engine code. The `model_per_role` field carries the model string for each
  agent role; it is pinned to a unit at admission via `Policy.Owner.pin/3` and
  resolved thereafter via `Policy.Owner.resolve/3`.

  ## Fields

    - `:version`               — integer; policy format version.
    - `:model_per_role`        — `%{role_atom => model_string}`; the model to
                                 use for each agent role (FR-7.4). Engine code
                                 MUST read this field — never a hardcoded constant.
    - `:retry_bound_n`         — positive_integer(); maximum refine-cycle count
                                 per PR (factory-loop N = 3 default).
    - `:budget`                — map with keys `:token`, `:cost`, `:wall_time`,
                                 `:iteration`; absolute spend ceilings.
    - `:priority_order`        — list of issue selectors; determines unit ordering.
    - `:conflict_predicate`    — 2-arity function; returns true when two work
                                 items conflict and must be serialized.
    - `:gate_manifest`         — list of gate identifiers (atoms) to run.
    - `:escalation_thresholds` — map; keyed thresholds that trigger escalation
                                 (e.g. `%{upheld_challenges: 2}`).

  See `docs/spec/SPEC-FACTORY-GOV.md`, D-319, D-351–D-353; issue #552.
  """

  @enforce_keys [:version, :model_per_role]
  defstruct [
    :version,
    :model_per_role,
    :retry_bound_n,
    :budget,
    :priority_order,
    :conflict_predicate,
    :gate_manifest,
    :escalation_thresholds
  ]

  @type role :: atom()
  @type model :: String.t()

  @type t :: %__MODULE__{
          version: pos_integer(),
          model_per_role: %{role() => model()},
          retry_bound_n: pos_integer() | nil,
          budget: map() | nil,
          priority_order: list() | nil,
          conflict_predicate: (term(), term() -> boolean()) | nil,
          gate_manifest: [atom()] | nil,
          escalation_thresholds: map() | nil
        }
end
