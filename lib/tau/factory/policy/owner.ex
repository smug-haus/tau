defmodule Tau.Factory.Policy.Owner do
  @moduledoc """
  Policy Owner (SPEC-FACTORY-GOV §4 B6 — Policy.Owner ↔ Policy boundary).

  Supervised GenServer that pins a `%Tau.Factory.Policy{}` per unit at
  admission and resolves policy fields by unit ID. This ensures model and
  budget configuration per role is driven by the pinned policy, not by
  hardcoded engine constants (INV-MODEL-POLICY / D-319).

  ## Public API

    - `start_link/1`          — start the owner process.
    - `pin/3`                 — pin a clamped policy for a unit at admission.
    - `resolve/3`             — resolve a policy field for a unit; returns the
                                field value or `nil` when the unit is unknown.

  OTP non-negotiable §1: all pinned policy state lives in this supervised
  process — no module-level ETS outside an owner process.
  """

  use GenServer

  alias Tau.Factory.Policy

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start and link the Policy.Owner GenServer.

  Accepts `:name` in `opts` for registration (required for
  `pin/3` and `resolve/3` calls by name).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Pin a clamped policy for `unit_id`.

  Must be called at admission before the first `resolve/3` for the unit.
  Returns `:ok`.
  """
  @spec pin(GenServer.server(), String.t(), Policy.t()) :: :ok
  def pin(server, unit_id, %Policy{} = policy) do
    GenServer.call(server, {:pin, unit_id, policy})
  end

  @doc """
  Resolve a policy field for `unit_id`.

  Returns the field value from the pinned policy, or `nil` when the
  unit has not been admitted (i.e., `pin/3` was not called for it).
  """
  @spec resolve(GenServer.server(), String.t(), atom()) :: term()
  def resolve(server, unit_id, field) do
    GenServer.call(server, {:resolve, unit_id, field})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:pin, unit_id, policy}, _from, state) do
    {:reply, :ok, Map.put(state, unit_id, policy)}
  end

  def handle_call({:resolve, unit_id, field}, _from, state) do
    value =
      case Map.get(state, unit_id) do
        nil -> nil
        policy -> Map.get(policy, field)
      end

    {:reply, value, state}
  end
end
