defmodule Tau.Factory.Policy do
  @moduledoc """
  Factory policy struct (SPEC-FACTORY-GOV §4 B6).

  Carries the per-unit policy configuration: model assignments per role,
  retry bounds, budget limits, priority ordering, conflict predicate,
  gate manifest, and escalation thresholds.

  D-319 / INV-MODEL-POLICY: no role's model assignment is hardcoded in
  engine code — model per role is a field in `%Policy{}`, pinned per unit
  at admission via `Tau.Factory.Policy.Owner.pin/3`.

  `clamp/1` enforces hard engine ceilings on policy values (HR-8) before
  the policy is pinned. It MUST NOT override `model_per_role` with a
  hardcoded value — the caller-supplied map passes through unchanged when
  valid.
  """

  @type role :: atom()
  @type model :: String.t()

  @type t :: %__MODULE__{
          version: pos_integer(),
          model_per_role: %{optional(role()) => model()},
          retry_bound_n: pos_integer(),
          budget: %{
            token: pos_integer(),
            cost: number(),
            wall_time: pos_integer(),
            iteration: pos_integer()
          },
          priority_order: [atom()],
          conflict_predicate: (term(), term() -> boolean()),
          gate_manifest: [atom()],
          escalation_thresholds: %{optional(atom()) => non_neg_integer()}
        }

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

  @doc """
  Engine clamp (HR-8): validates and tightens policy values before
  pinning at admission.

  Returns `{:ok, policy}` when the policy is valid; `{:error, reason}`
  when a field violates an engine hard ceiling.

  `model_per_role` is passed through unchanged — the engine MUST NOT
  substitute a hardcoded model (INV-MODEL-POLICY).
  """
  @spec clamp(t()) :: {:ok, t()} | {:error, term()}
  def clamp(%__MODULE__{} = policy) do
    cond do
      not is_map(policy.model_per_role) ->
        {:error, {:invalid_field, :model_per_role, "must be a map"}}

      not is_integer(policy.retry_bound_n) or policy.retry_bound_n < 1 ->
        {:error, {:invalid_field, :retry_bound_n, "must be a positive integer"}}

      not is_map(policy.budget) ->
        {:error, {:invalid_field, :budget, "must be a map"}}

      true ->
        {:ok, policy}
    end
  end
end
