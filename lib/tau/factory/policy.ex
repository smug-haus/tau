defmodule Tau.Factory.Policy do
  @moduledoc """
  Versioned policy data for the factory governance plane.

  `%Policy{}` carries the parameters the engine interprets; no safety
  invariant's *enforcement* lives here — only its *parameters*, within
  a safe envelope established by `clamp/1`.

  ## Engine-clamp (HR-8)

  `clamp/1` is a pure function run at admission before the policy is
  pinned to a unit.  It:

  - Rejects `:infinity`, `nil`, zero, or negative `retry_bound_n`
    (REJECTED, not clamped — `∞` defeats bounded-retry; D-318).
  - Clamps `retry_bound_n` to `@hard_ceiling_n` when the caller supplies
    a positive integer that exceeds the ceiling (N = min(policy, ceiling)).
  - Ensures `gate_manifest` is a superset of `{:mutation,:critic,:reviewer}`;
    a missing floor half is rejected.
  - Rejects any `budget` dimension that is not a positive integer.
  - Composes the `conflict_predicate` with the engine disjointness floor so a
    plugin predicate can only *tighten* the admissible set, never relax it.

  ## Invariants

  - Owned by SPEC-FACTORY-GOV (B6, HR-8).
  - Properties before examples: ∀ admissible p, clamp(p) preserves every floor.
  - No process: pure functions only.  The process is `Policy.Owner`.
  """

  alias Tau.Factory.ConflictCheck

  @hard_ceiling_n 3
  @gate_floor MapSet.new([:mutation, :critic, :reviewer])

  @type role :: atom()
  @type model :: String.t()
  @type conflict_pred :: (map(), map() -> boolean())

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          model_per_role: %{role() => model()},
          retry_bound_n: pos_integer(),
          budget: %{
            token: pos_integer(),
            cost: pos_integer(),
            wall_time: pos_integer(),
            iteration: pos_integer()
          },
          priority_order: list(),
          conflict_predicate: conflict_pred(),
          gate_manifest: [atom()],
          escalation_thresholds: map()
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

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Engine-clamp for a candidate `%Policy{}`.

  Pure, property-tested.  Returns `{:ok, clamped_policy}` when all floors
  hold (after clamping where allowed), or `{:error, reason}` for a value
  that cannot be made safe.

  Clamping rules (governance.md §3 / SPEC-FACTORY-GOV B6 / HR-8):

  - `retry_bound_n` that is not a positive integer (`:infinity`, `nil`,
    `<= 0`) → **rejected** (`{:error, {:infinite_retry_bound_rejected, v}}`).
  - `retry_bound_n > @hard_ceiling_n` → clamped to `@hard_ceiling_n`.
  - `gate_manifest` missing a floor half → **rejected**.
  - Any `budget` dimension not a positive integer → **rejected**.
  - `conflict_predicate` composed with engine disjointness floor (only tightened).
  """
  @spec clamp(t()) :: {:ok, t()} | {:error, term()}
  def clamp(%__MODULE__{} = p) do
    with :ok <- reject_infinite_retry(p.retry_bound_n),
         :ok <- reject_infinite_budget(p.budget),
         {:ok, manifest} <- enforce_gate_floor(p.gate_manifest),
         {:ok, pred} <- floor_conflict_predicate(p.conflict_predicate) do
      {:ok,
       %{
         p
         | retry_bound_n: min(p.retry_bound_n, @hard_ceiling_n),
           gate_manifest: manifest,
           conflict_predicate: pred
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Reject :infinity, nil, non-integers, and non-positive integers for retry_bound_n.
  # governance.md §3: "∞ rejected" — the sentinel must be rejected outright, not clamped.
  defp reject_infinite_retry(n) when is_integer(n) and n > 0, do: :ok
  defp reject_infinite_retry(n), do: {:error, {:infinite_retry_bound_rejected, n}}

  # Reject any budget dimension that is not a positive integer.
  # governance.md §3: "∞ sentinel REJECTED" for budget — defeats INV-21.
  defp reject_infinite_budget(%{token: t, cost: c, wall_time: w, iteration: i} = _b) do
    if Enum.all?([t, c, w, i], &(is_integer(&1) and &1 > 0)) do
      :ok
    else
      {:error, :infinite_budget_rejected}
    end
  end

  # {mutation, critic, reviewer} are non-shrinkable floor halves.
  # A manifest may ADD halves but MUST include the floor set.
  defp enforce_gate_floor(manifest) do
    m = MapSet.new(manifest)

    if MapSet.subset?(@gate_floor, m) do
      {:ok, manifest}
    else
      missing = MapSet.difference(@gate_floor, m)
      {:error, {:gate_floor_violation, missing}}
    end
  end

  # Compose the caller-supplied predicate with the engine disjointness floor.
  # A plugin predicate can only NARROW the admissible set — it is AND-ed with the floor.
  defp floor_conflict_predicate(policy_pred) do
    composed = &(ConflictCheck.engine_floor(&1, &2) and policy_pred.(&1, &2))
    {:ok, composed}
  end
end
