defmodule Tau.Factory.Policy do
  @moduledoc """
  Pure data + clamp logic for the governance policy plane (C5 in SPEC-FACTORY-GOV).

  ## Struct fields

  - `:version`              — positive integer; policy version (monotone).
  - `:model_per_role`       — `%{role_atom => model_id_string}`; the engine
    resolves the model for each role from this map, never from a hardcoded
    constant (FR-7.4, INV-MODEL-POLICY).
  - `:retry_bound_n`        — positive integer; max refine attempts per PR.
    Clamped to `@hard_ceiling_n` (HR-8).
  - `:budget`               — `%{token:, cost:, wall_time:, iteration:}`; every
    dimension is a positive finite integer.  `:infinity`/`nil`/`≤0` is rejected
    (HR-8 / D-320).
  - `:priority_order`       — list of unit-id atoms/strings; admission order hint.
  - `:conflict_predicate`   — 2-arity function `(a, b) -> bool`; must be
    only-tightenable (engine floor composed via `&&`).
  - `:gate_manifest`        — list of gate atoms; MUST be a superset of
    `{:mutation, :critic, :reviewer}` (HR-8 / D-306/D-354).
  - `:escalation_thresholds` — map; currently carries `upheld_challenges` (D-332).

  ## `clamp/1`

  Pure function.  Applies the HR-8 engine-clamp before admission:

    - Gate-floor non-shrinkable: rejects if the manifest is missing any floor
      half (`{:mutation, :critic, :reviewer}`).
    - `retry_bound_n` clamped to `@hard_ceiling_n`.
    - Budget dimensions validated: every dimension must be a positive integer;
      `:infinity`/nil/`≤0` is rejected.
    - `conflict_predicate` is accepted as-is (the engine wraps it with its
      own floor predicate at the call site; this module only validates arity).

  See `docs/spec/SPEC-FACTORY-GOV.md` §4 B6, C218.
  """

  @hard_ceiling_n 10

  @gate_floor MapSet.new([:mutation, :critic, :reviewer])

  @type role :: atom()
  @type model_id :: String.t()
  @type budget :: %{
          token: pos_integer(),
          cost: pos_integer(),
          wall_time: pos_integer(),
          iteration: pos_integer()
        }

  @type t :: %__MODULE__{
          version: pos_integer(),
          model_per_role: %{role() => model_id()},
          retry_bound_n: pos_integer(),
          budget: budget(),
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
  Engine-clamp (HR-8): validate and tighten a candidate `%Policy{}`.

  Returns `{:ok, clamped_policy}` when all invariants hold (after tightening
  `retry_bound_n`), or `{:error, reason}` for values that cannot be safely
  admitted (infinite budget, missing gate-floor half).

  See `SPEC-FACTORY-GOV §4 B6`, C218.
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
  # Private clamp clauses
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

    bad =
      Enum.filter(dims, fn dim ->
        val = Map.get(budget, dim)
        not (is_integer(val) and val > 0)
      end)

    if bad == [] do
      :ok
    else
      {:error, {:infinite_budget, bad}}
    end
  end
end
