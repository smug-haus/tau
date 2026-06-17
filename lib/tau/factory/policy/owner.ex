defmodule Tau.Factory.Policy.Owner do
  @moduledoc """
  Per-admission policy snapshot store (B6 boundary, SPEC-FACTORY-GOV §4).

  Holds pinned `%Policy{}` snapshots keyed by unit_id in an ETS table owned by
  this GenServer. The GenServer is the sole ETS owner; the table dies with it.

  INV-MODEL-POLICY (issue #552): `resolve/3` reads the pinned snapshot and
  returns the policy-driven value — it MUST NOT substitute a hardcoded constant
  for any field, including `model_per_role`.

  ## Public API

    - `start_link/1` — start and register the Owner.
    - `pin/3`        — pin a clamped `%Policy{}` at admission time.
    - `resolve/3`    — resolve a field from the pinned policy for a unit.
  """

  use GenServer

  @doc """
  Start the Policy.Owner.

  Required options:
    - `:name` — atom; registered name for this owner.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Pin a clamped `%Policy{}` for `unit_id` at admission time.

  Must be called before any `resolve/3` call for the same `unit_id`.
  Returns `:ok`.
  """
  @spec pin(GenServer.server(), String.t(), Tau.Factory.Policy.t()) :: :ok
  def pin(owner, unit_id, %Tau.Factory.Policy{} = policy) do
    GenServer.call(owner, {:pin, unit_id, policy})
  end

  @doc """
  Resolve a field from the pinned policy for `unit_id`.

  Returns the field value from the pinned snapshot. Raises `KeyError` if
  `unit_id` has not been pinned or `field` is not a valid struct key.

  INV-MODEL-POLICY: the returned value is ALWAYS the policy-driven value, never
  a hardcoded constant.
  """
  @spec resolve(GenServer.server(), String.t(), atom()) :: term()
  def resolve(owner, unit_id, field) do
    GenServer.call(owner, {:resolve, unit_id, field})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = :ets.new(table_name(name), [:set, :protected])
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:pin, unit_id, policy}, _from, state) do
    :ets.insert(state.table, {unit_id, policy})
    {:reply, :ok, state}
  end

  def handle_call({:resolve, unit_id, field}, _from, state) do
    case :ets.lookup(state.table, unit_id) do
      [{^unit_id, policy}] ->
        value = Map.fetch!(policy, field)
        {:reply, value, state}

      [] ->
        {:reply, {:error, {:not_pinned, unit_id}}, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp table_name(name), do: :"policy_owner_ets_#{name}"
end
