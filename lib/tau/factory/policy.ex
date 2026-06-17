defmodule Tau.Factory.Policy do
  @moduledoc """
  Versioned policy data for the factory governance plane (C5, SPEC-FACTORY-GOV).

  `%Policy{}` carries every operator-tunable governance parameter. The
  engine-`clamp/1` (HR-8) runs at admission before any pin: it enforces that
  every safety invariant's parameters are within the safe envelope, rejecting or
  tightening unsafe values. No safety invariant's *enforcement* ever moves into
  policy — only its *parameters*.

  ## Fields

    - `:version`               — monotonic version counter; bumped on each policy
                                 reload by `Policy.Owner`.
    - `:model_per_role`        — `%{role_atom => model_id_string}` (FR-7.4); the
                                 engine resolves the model for a role from this map,
                                 never from a hardcoded constant (INV-MODEL-POLICY).
    - `:retry_bound_n`         — maximum refine attempts per PR (D-318); clamped to
                                 `@hard_ceiling_n` by `clamp/1`.
    - `:budget`                — `%{token: pos_integer, cost: pos_integer,
                                    wall_time: pos_integer, iteration: pos_integer}`;
                                 every dimension MUST be a positive integer
                                 (∞-budget rejected, D-320/D-321).
    - `:priority_order`        — list of issue selectors for ordering (FR-7.2).
    - `:conflict_predicate`    — `(a, b -> boolean)`; extra conflict narrowing beyond
                                 the engine floor ([C218], D-312).
    - `:gate_manifest`         — list of gate halves; MUST be a superset of
                                 `[:mutation, :critic, :reviewer]` (gate-floor,
                                 D-300/D-306/D-354).
    - `:escalation_thresholds` — `%{upheld_challenges: pos_integer}` and similar.

  See SPEC-FACTORY-GOV §4 B6, §3 [C202-B6], [C206-B6], [C218-B6].
  """

  @hard_ceiling_n 10

  @gate_floor MapSet.new([:mutation, :critic, :reviewer])

  @enforce_keys [
    :version,
    :model_per_role,
    :retry_bound_n,
    :budget,
    :priority_order,
    :conflict_predicate,
    :gate_manifest,
    :escalation_thresholds
  ]

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
  @type model_id :: String.t()

  @type t :: %__MODULE__{
          version: pos_integer(),
          model_per_role: %{role() => model_id()},
          retry_bound_n: pos_integer(),
          budget: %{
            token: pos_integer(),
            cost: pos_integer(),
            wall_time: pos_integer(),
            iteration: pos_integer()
          },
          priority_order: list(),
          conflict_predicate: (any(), any() -> boolean()),
          gate_manifest: [atom()],
          escalation_thresholds: map()
        }

  @doc """
  Engine-clamp (HR-8): enforces that the policy's parameters stay within the
  safe envelope before the policy is pinned to a unit at admission.

  Returns `{:ok, clamped_policy}` when the policy is valid and within the safe
  envelope (possibly tightening `retry_bound_n` to `@hard_ceiling_n`). Returns
  `{:error, reason}` for values that cannot be safely clamped:

    - `{:error, {:gate_floor_violation, missing}}` — `gate_manifest` is missing
      one or more floor halves (`[:mutation, :critic, :reviewer]`).
    - `{:error, {:infinite_budget, dim}}` — a budget dimension is `:infinity`,
      `nil`, or `<= 0`.

  `model_per_role` is NEVER overwritten: the engine must not override the
  caller-supplied map with a hardcoded model string (INV-MODEL-POLICY, FR-7.4).

  SPEC-FACTORY-GOV §4 B6 [C206-B6], [C218-B6].
  """
  @spec clamp(t()) :: {:ok, t()} | {:error, term()}
  def clamp(%__MODULE__{} = policy) do
    with :ok <- enforce_gate_floor(policy),
         :ok <- reject_infinite_budget(policy) do
      clamped = %{policy | retry_bound_n: min(policy.retry_bound_n, @hard_ceiling_n)}
      {:ok, clamped}
    end
  end

  # ---------------------------------------------------------------------------
  # Private clamp helpers
  # ---------------------------------------------------------------------------

  defp enforce_gate_floor(%__MODULE__{gate_manifest: manifest}) do
    manifest_set = MapSet.new(manifest)
    missing = MapSet.difference(@gate_floor, manifest_set)

    if MapSet.size(missing) == 0 do
      :ok
    else
      {:error, {:gate_floor_violation, MapSet.to_list(missing)}}
    end
  end

  defp reject_infinite_budget(%__MODULE__{budget: budget}) do
    dims = [:token, :cost, :wall_time, :iteration]

    Enum.reduce_while(dims, :ok, fn dim, :ok ->
      val = Map.get(budget, dim)

      cond do
        val == :infinity -> {:halt, {:error, {:infinite_budget, dim}}}
        is_nil(val) -> {:halt, {:error, {:infinite_budget, dim}}}
        not is_integer(val) -> {:halt, {:error, {:infinite_budget, dim}}}
        val <= 0 -> {:halt, {:error, {:infinite_budget, dim}}}
        true -> {:cont, :ok}
      end
    end)
  end
end
