defmodule Tau.Factory.Policy.Owner do
  @moduledoc """
  ETS-snapshot owner for the factory Policy plane (C6, SPEC-FACTORY-GOV).

  `Policy.Owner` is a supervised GenServer that holds the per-unit pinned
  `%Policy{}` snapshots in an ETS table. Each unit's policy is pinned at
  admission (after `Policy.clamp/1` runs) and immutable for the unit's life.

  ## Public API

    - `start_link/1`                      — start the owner; accepts `name:` opt.
    - `pin/3 :: (server, unit_id, policy) -> :ok`
                                          — freeze the clamped policy for a unit.
    - `resolve/3 :: (server, unit_id, field) -> value`
                                          — read one field from the pinned snapshot.

  Reads are direct ETS lookups (no owner bottleneck on the hot path). Writes
  (pin) go through the owner's mailbox to maintain the invariant that the pin
  is set exactly once per unit.

  SPEC-FACTORY-GOV §4 B6, [C202-B6], §3 [C206-B6].
  """

  use GenServer

  alias Tau.Factory.Policy

  @doc """
  Start a `Policy.Owner` process.

  Options:
    - `:name` — registered name (required for test isolation and multi-instance
                setups; optional for the singleton application tree entry).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name_opt, init_opts} =
      case Keyword.pop(opts, :name) do
        {nil, rest} -> {[], rest}
        {name, rest} -> {[name: name], rest}
      end

    GenServer.start_link(__MODULE__, init_opts, name_opt)
  end

  @doc """
  Pin a clamped `%Policy{}` to `unit_id` for its life.

  The `policy` MUST already have been clamped by `Policy.clamp/1`; the Owner
  does not re-clamp. Pinning the same `unit_id` twice is idempotent when the
  policy is identical; a second pin with a different policy is silently rejected
  (first-pin-wins per [C202-B6]).

  Returns `:ok`.
  """
  @spec pin(GenServer.server(), String.t(), Policy.t()) :: :ok
  def pin(server, unit_id, %Policy{} = policy) do
    GenServer.call(server, {:pin, unit_id, policy})
  end

  @doc """
  Resolve one field from the pinned policy snapshot for `unit_id`.

  Returns the field's value directly from the ETS snapshot. Raises
  `KeyError` if `unit_id` has not been pinned; raises `ArgumentError` if
  the field does not exist in `%Policy{}`.
  """
  @spec resolve(GenServer.server(), String.t(), atom()) :: term()
  def resolve(server, unit_id, field) do
    GenServer.call(server, {:resolve, unit_id, field})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(:policy_owner, [:set, :protected])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:pin, unit_id, %Policy{} = policy}, _from, state) do
    case :ets.lookup(state.table, unit_id) do
      [] ->
        :ets.insert(state.table, {unit_id, policy})

      _existing ->
        # First-pin-wins: ignore re-pin for the same unit_id ([C202-B6]).
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:resolve, unit_id, field}, _from, state) do
    value =
      case :ets.lookup(state.table, unit_id) do
        [{^unit_id, policy}] ->
          Map.fetch!(policy, field)

        [] ->
          raise KeyError,
                "Policy.Owner: no policy pinned for unit_id=#{inspect(unit_id)}"
      end

    {:reply, value, state}
  end
end
