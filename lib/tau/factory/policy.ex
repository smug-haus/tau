defmodule Tau.Factory.Policy do
  @moduledoc """
  Pure functions over `%Policy{}`: the engine-clamp boundary (SPEC-FACTORY-GOV
  §4 B6, C5, HR-8).

  ## HR-8 — engine-clamp

  No safety invariant's *enforcement* lives in policy — only its *parameters*,
  and only where the invariant holds for **all** admissible parameter values.
  `clamp/1` makes this true by construction: every candidate policy value is
  validated or tightened before it can govern a unit.

  ### Guarded dimensions

  - **Gate-floor non-shrinkable (`enforce_gate_floor`):** the `gate_manifest`
    MUST be a superset of `{:mutation, :critic, :reviewer}`. A missing floor
    half is rejected (`{:error, {:gate_floor_violation, _}}`). Protects
    D-300/D-306/D-354.

  - **`N = min(policy, ceiling)` (`clamp_retry_bound`):** `retry_bound_n` is
    clamped to `@hard_ceiling_n`. A larger policy value is tightened, never
    honoured. Protects D-318.

  - **Oracle-substitution rejected (`reject_oracle_key`):** an `oracle` key in
    a policy map is NOT a parameter within a safe envelope — it is a
    gate-result substitution (enforcement living in policy data). Any candidate
    carrying `oracle:` is **rejected** (`{:error, {:oracle_substitution,
    :gate_result_enforcement_in_policy}}`). This closes the INV-POLICY-DATA
    unguarded path in `Gate.Oracle.select/1` (SPEC-FACTORY-GOV HR-8 /
    issue #553).

  - **∞-budget rejected (`reject_infinite_budget`):** budget dimensions that are
    **present** (`token`, `cost`, `wall_time`, `iteration`) MUST be positive
    integers; an `:infinity`/`≤0` sentinel is rejected (an ∞ budget defeats
    INV-21 outright). A dimension that is **absent** (nil / not set) is simply
    not constrained by this policy and is skipped silently — absent ≠ infinite.
    Protects D-320/D-321.

  ## Process

  `Policy` is a **pure module** — no process, no state, no GenServer. It is
  called by `Policy.Owner` at admission and can be exercised property-first in
  any test without infrastructure.
  """

  @hard_ceiling_n 10

  @doc """
  Clamp a candidate policy value to the engine-enforced safe envelope (HR-8).

  Returns `{:ok, clamped}` when every protected floor holds in `clamped` (with
  numeric values tightened where needed), or `{:error, reason}` for a value
  that cannot be admitted:

  - `{:error, {:oracle_substitution, :gate_result_enforcement_in_policy}}` —
    the candidate carries an `oracle` key, which is gate-result enforcement
    living in policy data (INV-POLICY-DATA / HR-8). Rejected outright; stripping
    is not permitted because oracle admission must be a hard stop.
  - `{:error, {:gate_floor_violation, missing}}` — the `gate_manifest` omits one
    or more floor members from `{:mutation, :critic, :reviewer}`.
  - `{:error, {:infinite_budget, dimension}}` — a budget dimension is **present**
    and is `:infinity`, or `≤ 0`. Absent dimensions (nil / not set) are skipped.

  Pure: no side effects, no process. Properties before examples (OTP
  non-negotiable #6).
  """
  @spec clamp(map()) :: {:ok, map()} | {:error, term()}
  def clamp(candidate) when is_map(candidate) do
    with :ok <- reject_oracle_key(candidate),
         :ok <- enforce_gate_floor(candidate),
         :ok <- reject_infinite_budget(candidate) do
      {:ok, clamp_retry_bound(candidate)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private guard: oracle-substitution rejection (INV-POLICY-DATA / HR-8)
  # ---------------------------------------------------------------------------

  defp reject_oracle_key(candidate) do
    if Map.has_key?(candidate, :oracle) do
      {:error, {:oracle_substitution, :gate_result_enforcement_in_policy}}
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private guard: gate-floor non-shrinkable (D-300/D-306/D-354)
  # ---------------------------------------------------------------------------

  @gate_floor [:mutation, :critic, :reviewer]

  defp enforce_gate_floor(%{gate_manifest: manifest}) when is_list(manifest) do
    missing = Enum.reject(@gate_floor, &(&1 in manifest))

    case missing do
      [] -> :ok
      missing -> {:error, {:gate_floor_violation, missing}}
    end
  end

  defp enforce_gate_floor(_candidate),
    do: {:error, {:gate_floor_violation, @gate_floor}}

  # ---------------------------------------------------------------------------
  # Private guard: ∞-budget rejection (D-320/D-321)
  #
  # Every admitted policy MUST have all four budget dimensions present and set
  # to strictly positive integers.  nil, :infinity, floats, zero, and negative
  # values are all infinite-budget sentinels and are REJECTED.
  # SPEC-FACTORY-GOV §4 B6: ":infinity"/"nil"/"≤0" sentinel is rejected.
  # ---------------------------------------------------------------------------

  @budget_dimensions [:token, :cost, :wall_time, :iteration]

  defp reject_infinite_budget(candidate) do
    Enum.reduce_while(@budget_dimensions, :ok, fn dim, :ok ->
      v = Map.get(candidate, dim)

      if is_integer(v) and v > 0 do
        {:cont, :ok}
      else
        {:halt, {:error, {:infinite_budget, dim}}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private clamp: retry-bound ceiling (D-318)
  # ---------------------------------------------------------------------------

  defp clamp_retry_bound(%{retry_bound_n: n} = candidate)
       when is_integer(n) and n > @hard_ceiling_n do
    Map.put(candidate, :retry_bound_n, @hard_ceiling_n)
  end

  defp clamp_retry_bound(candidate), do: candidate
end
