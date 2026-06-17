defmodule Tau.Factory.Policy do
  @moduledoc """
  Versioned policy data + pure `clamp/1` engine-clamp (HR-8).

  `%Policy{}` is the single authoritative record that parameterises every
  safety invariant the factory enforces.  It is:

  - **Versioned** — the `version` field monotonically increases on every
    operator reload, so in-flight units can keep their pinned version across a
    bump.
  - **Clamped before admission** — `clamp/1` runs at admission, before
    `Policy.Owner.pin/3` freezes the value per unit.  A candidate that fails
    any clamp clause is rejected; an unsafe value never reaches the engine.
  - **Immutable once pinned** — after `Policy.Owner.pin/3` the record is
    read-only for the unit's life.

  ## HR-8 engine-clamp contract (B6, SPEC-FACTORY-GOV §4)

  `clamp/1` enforces four floors:

  1. **Gate-floor non-shrinkable** — `:gate_manifest` MUST be a superset of
     `{:mutation, :critic, :reviewer}`.  A missing floor half returns
     `{:error, {:gate_floor_violation, missing_halves}}`.

  2. **`N = min(policy, ceiling)`** — `:retry_bound_n` is clamped to
     `@hard_ceiling_n = 10`.  Values above the ceiling are tightened, not
     rejected.

  3. **∞-budget rejected** — every budget dimension MUST be a positive
     integer.  An `:infinity`, `nil`, or `<= 0` value returns
     `{:error, {:infinite_budget, dimension}}`.

  4. **Conflict predicate passthrough** — `:conflict_predicate` is not
     modified by clamp (the engine composes it; the value supplied is
     preserved verbatim on the happy path).

  `model_per_role` is intentionally NOT touched by `clamp/1` — the engine
  resolves the model per role from the policy-driven map, not a hardcoded
  constant (INV-MODEL-POLICY, SPEC-FACTORY-GOV B6 FR-7.4).
  """

  # Hard ceiling for retry_bound_n.  Values above this are tightened.
  @hard_ceiling_n 10

  # Required gate halves that must always be in the manifest.
  @gate_floor MapSet.new([:mutation, :critic, :reviewer])

  # Required budget dimension keys.
  @budget_dimensions [:token, :cost, :wall_time, :iteration]

  @enforce_keys [:version, :model_per_role, :retry_bound_n, :budget, :gate_manifest]

  defstruct version: 1,
            model_per_role: %{},
            retry_bound_n: 3,
            budget: %{},
            priority_order: [],
            conflict_predicate: nil,
            gate_manifest: [:mutation, :critic, :reviewer],
            escalation_thresholds: %{}

  @typedoc "Versioned policy record.  Always clamp before pinning."
  @type t :: %__MODULE__{
          version: pos_integer(),
          model_per_role: %{atom() => String.t()},
          retry_bound_n: pos_integer(),
          budget: %{atom() => pos_integer()},
          priority_order: list(),
          conflict_predicate: nil | function(),
          gate_manifest: [atom()],
          escalation_thresholds: %{atom() => non_neg_integer()}
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Engine-clamp a candidate `%Policy{}` (HR-8, SPEC-FACTORY-GOV B6).

  Returns `{:ok, clamped_policy}` on success or `{:error, reason}` when a
  value that cannot be clamped safely is encountered.

  ## Clamp rules

  - `:gate_manifest` must be a superset of `{:mutation, :critic, :reviewer}`;
    any missing floor half is a hard reject.
  - `:retry_bound_n` is clamped to `@hard_ceiling_n = #{@hard_ceiling_n}`
    (tightened, not rejected).
  - Every budget dimension must be a positive integer; `:infinity`, `nil`, or
    `<= 0` is rejected.
  - `:model_per_role` is preserved verbatim — the caller supplies the
    policy-driven map; the engine never overrides it with a hardcoded value.
  """
  @spec clamp(t()) :: {:ok, t()} | {:error, term()}
  def clamp(%__MODULE__{} = policy) do
    with {:ok, policy} <- enforce_gate_floor(policy),
         {:ok, policy} <- clamp_retry_bound(policy) do
      reject_infinite_budget(policy)
    end
  end

  # ---------------------------------------------------------------------------
  # Private clamp clauses
  # ---------------------------------------------------------------------------

  # Gate-floor non-shrinkable (protects D-300/D-306/D-354).
  defp enforce_gate_floor(%__MODULE__{gate_manifest: manifest} = policy) do
    manifest_set = MapSet.new(manifest)
    missing = MapSet.difference(@gate_floor, manifest_set)

    if MapSet.size(missing) == 0 do
      {:ok, policy}
    else
      {:error, {:gate_floor_violation, MapSet.to_list(missing)}}
    end
  end

  # N = min(policy, ceiling) — protects D-318.
  defp clamp_retry_bound(%__MODULE__{retry_bound_n: n} = policy) do
    {:ok, %{policy | retry_bound_n: min(n, @hard_ceiling_n)}}
  end

  # ∞-budget rejected — protects D-320/D-321.
  defp reject_infinite_budget(%__MODULE__{budget: budget} = policy) do
    Enum.reduce_while(@budget_dimensions, {:ok, policy}, fn dim, {:ok, acc} ->
      case Map.get(budget, dim) do
        v when is_integer(v) and v > 0 ->
          {:cont, {:ok, acc}}

        v ->
          {:halt, {:error, {:infinite_budget, {dim, v}}}}
      end
    end)
  end
end
