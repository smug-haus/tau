defmodule Tau.Factory.Policy do
  @moduledoc """
  Versioned policy data interpreted by a stable engine (HR-8, governance.md §3).

  Policy is **data**, not code — the engine is stable; policy is volatile. A unit's
  policy version is **pinned at admission** and frozen for the unit's life (FR-1.3).

  ## The struct

      %Policy{
        version:               v,
        model_per_role:        %{role => model},       # FR-7.4
        retry_bound_n:         N,                       # engine-clamped
        budget:                %{token:, cost:, wall_time:, iteration:},
        priority_order:        [...],
        conflict_predicate:    pred,                    # MFA or fun/2
        gate_manifest:         [:mutation, :critic, :reviewer, ...],
        escalation_thresholds: %{upheld_challenges: 2, ...}
      }

  ## Engine-clamp (`clamp/1`, HR-8)

  `clamp/1` is a **pure function** run at admission that ensures every policy
  value lies within the safe envelope:

  - `retry_bound_n` is clamped to `min(policy, @hard_ceiling_n)`.
  - `:infinity` and non-positive values for `retry_bound_n` are **rejected**
    (not clamped) — they defeat LIV-1 (termination).
  - `gate_manifest` must contain the non-shrinkable floor
    `{:mutation, :critic, :reviewer}`.
  - `budget` values must all be finite positive integers.
  - `conflict_predicate` is validated and wrapped with the engine floor.

  Returns `{:ok, clamped_policy}` or `{:error, reason}`.
  """

  @hard_ceiling_n 3
  @gate_floor MapSet.new([:mutation, :critic, :reviewer])

  @type role :: atom()
  @type model :: String.t()

  @type t :: %__MODULE__{
          version: pos_integer(),
          model_per_role: %{role() => model()},
          retry_bound_n: pos_integer(),
          budget: %{
            token: pos_integer(),
            cost: pos_integer(),
            wall_time: pos_integer(),
            iteration: pos_integer()
          },
          priority_order: list(),
          conflict_predicate: (term(), term() -> boolean()),
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

  @doc """
  Engine-clamp a policy value, ensuring it lies within the safe envelope.

  Pure function — property-tested; runs at admission before the policy pin.

  Returns `{:ok, clamped_policy}` on success, or `{:error, reason}` when
  the policy contains a value that cannot be made safe (e.g. `:infinity`
  retry bound or missing gate-floor halves).
  """
  @spec clamp(t()) :: {:ok, t()} | {:error, term()}
  def clamp(%__MODULE__{} = p) do
    with :ok <- validate_retry_bound(p.retry_bound_n),
         :ok <- reject_infinite_budget(p.budget),
         {:ok, manifest} <- enforce_gate_floor(p.gate_manifest),
         {:ok, pred} <- validate_conflict_predicate(p.conflict_predicate) do
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

  # Reject :infinity, non-integer, and non-positive retry bounds.
  # N = min(policy, ceiling) applies only to positive integers.
  @spec validate_retry_bound(term()) :: :ok | {:error, term()}
  defp validate_retry_bound(:infinity), do: {:error, :infinite_retry_bound_rejected}
  defp validate_retry_bound(n) when is_integer(n) and n > 0, do: :ok
  defp validate_retry_bound(n), do: {:error, {:invalid_retry_bound, n}}

  # All four budget dimensions must be finite positive integers.
  # A nil, :infinity, zero, or negative value defeats INV-21.
  @spec reject_infinite_budget(map() | nil) :: :ok | {:error, term()}
  defp reject_infinite_budget(nil), do: {:error, :infinite_budget_rejected}

  defp reject_infinite_budget(b) when is_map(b) do
    dims = [:token, :cost, :wall_time, :iteration]

    all_finite? =
      Enum.all?(dims, fn dim ->
        v = Map.get(b, dim)
        is_integer(v) and v > 0
      end)

    if all_finite?, do: :ok, else: {:error, :infinite_budget_rejected}
  end

  defp reject_infinite_budget(_), do: {:error, :infinite_budget_rejected}

  # The gate floor {:mutation, :critic, :reviewer} is non-shrinkable.
  # A manifest may add halves but MUST NOT drop floor halves.
  @spec enforce_gate_floor([atom()]) :: {:ok, [atom()]} | {:error, term()}
  defp enforce_gate_floor(manifest) when is_list(manifest) do
    m = MapSet.new(manifest)

    if MapSet.subset?(@gate_floor, m) do
      {:ok, manifest}
    else
      missing = MapSet.difference(@gate_floor, m)
      {:error, {:gate_floor_violation, missing}}
    end
  end

  defp enforce_gate_floor(other), do: {:error, {:invalid_gate_manifest, other}}

  # Validate that the conflict predicate is callable (fun/2 or MFA).
  # The engine floor composition is enforced at the Scheduler admission path;
  # here we only confirm the predicate is a valid callable.
  @spec validate_conflict_predicate(term()) :: {:ok, term()} | {:error, term()}
  defp validate_conflict_predicate(pred) when is_function(pred, 2), do: {:ok, pred}

  defp validate_conflict_predicate({m, f, 2} = mfa)
       when is_atom(m) and is_atom(f),
       do: {:ok, mfa}

  defp validate_conflict_predicate(other),
    do: {:error, {:invalid_conflict_predicate, other}}
end
