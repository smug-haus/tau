defmodule Tau.Factory.Policy.Owner do
  @moduledoc """
  ETS-snapshot owner for the governance policy plane (C6 in SPEC-FACTORY-GOV).

  Holds pinned `%Tau.Factory.Policy{}` versions per unit.  Reads bypass the
  owner mailbox by hitting the ETS table directly.

  ## API

  - `start_link/1` — start the owner; requires `:name` opt.
  - `pin/3` — freeze a clamped policy version for a unit at admission.
  - `resolve/3` — read a field from the pinned policy for a unit (ETS read,
    no owner mailbox round-trip).

  ## OTP invariants

  - ETS table is owned by this process; it crashes+restarts with the owner.
  - No writes to the ETS table except via `pin/3` (through the owner mailbox).
  - Reads via `resolve/3` are direct ETS lookups — no GenServer call needed.

  See `docs/spec/SPEC-FACTORY-GOV.md` §4 B6.
  """

  use GenServer

  alias Tau.Factory.Policy

  @table_prefix :tau_factory_policy_owner

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the Policy.Owner.

  Required opts:
    - `:name` — atom; registered name for this GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns a child spec for embedding in a supervisor.
  """
  @spec child_spec(keyword()) :: map()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Pin a clamped policy version for `unit_id` at admission.

  The policy MUST already be clamped via `Policy.clamp/1` before pinning.
  In-flight units keep their pin across subsequent `pin/3` calls for other
  units — each unit's pin is independent.
  """
  @spec pin(GenServer.server(), String.t(), Policy.t()) :: :ok
  def pin(owner, unit_id, %Policy{} = policy) do
    GenServer.call(owner, {:pin, unit_id, policy})
  end

  @doc """
  Resolve a field from the pinned policy for `unit_id`.

  Reads directly from ETS — no owner mailbox round-trip.
  Returns the field value, or raises `KeyError` if the unit has no pin.
  """
  @spec resolve(GenServer.server(), String.t(), atom()) :: term()
  def resolve(owner, unit_id, field) when is_atom(field) do
    table = GenServer.call(owner, :get_table)
    [{^unit_id, policy}] = :ets.lookup(table, unit_id)
    Map.fetch!(policy, field)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table_name = :"#{@table_prefix}_#{name}"

    table =
      :ets.new(table_name, [
        :set,
        :protected,
        {:read_concurrency, true}
      ])

    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:pin, unit_id, policy}, _from, state) do
    :ets.insert(state.table, {unit_id, policy})
    {:reply, :ok, state}
  end

  def handle_call(:get_table, _from, state) do
    {:reply, state.table, state}
  end
end
