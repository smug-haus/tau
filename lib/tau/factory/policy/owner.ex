defmodule Tau.Factory.Policy.Owner do
  @moduledoc """
  Supervised `GenServer` that owns the per-unit policy pin ETS table.

  ## Responsibilities

  - Maintains a named ETS table (`read_concurrency: true`) keyed by `unit_id`,
    holding `{unit_id, policy}` tuples.
  - `pin/3` — stores a clamped policy snapshot for a unit at admission.
  - `resolve/3` — direct ETS read (no mailbox round-trip) for a named field.

  ## Design

  Reads bypass the owner mailbox (ETS-under-owner pattern, INV-24 #1).
  The `pin/3` call goes through the GenServer to serialize writes; reads
  use the ETS table directly via the registered name.

  The table name equals the `:name` atom supplied at `start_link/1` —
  exactly the same pattern as `Budget.Owner` (governance.md §3).

  ## Public API

    - `start_link/1` — start and register the process; creates the ETS table.
    - `pin/3`     — `pin(server, unit_id, clamped_policy)` — pin a policy for a unit.
    - `resolve/3` — `resolve(server_or_table, unit_id, field)` — read a pinned field.
  """

  use GenServer

  require Logger

  alias Tau.Factory.Policy

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the `Policy.Owner` and register it under `:name`.

  Required options:
    - `:name` — atom; registered name for the GenServer AND the ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Pin a clamped policy for `unit_id` at admission.

  Serialized through the GenServer to ensure ordered ETS writes.
  Returns `:ok`.
  """
  @spec pin(GenServer.server(), String.t(), Policy.t()) :: :ok
  def pin(server, unit_id, %Policy{} = policy) do
    GenServer.call(server, {:pin, unit_id, policy})
  end

  @doc """
  Resolve a named field from the pinned policy for `unit_id`.

  Reads the ETS table directly by the registered name atom — does NOT issue a
  `GenServer.call`. Returns the field value, or raises if `unit_id` has no pin
  or the field does not exist.

  `server_or_table` must be the registered name atom (same as the `:name`
  option passed to `start_link/1`).
  """
  @spec resolve(atom(), String.t(), atom()) :: term()
  def resolve(table, unit_id, field) when is_atom(table) do
    case :ets.lookup(table, unit_id) do
      [{^unit_id, policy}] ->
        Map.fetch!(policy, field)

      [] ->
        raise ArgumentError,
              "Policy.Owner: no policy pinned for unit_id=#{inspect(unit_id)} in table #{inspect(table)}"
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    :ets.new(name, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    {:ok, %{name: name}}
  end

  @impl GenServer
  def handle_call({:pin, unit_id, policy}, _from, state) do
    :ets.insert(state.name, {unit_id, policy})
    {:reply, :ok, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # ETS table is owned by this process and will be garbage-collected
    # automatically on process exit. Explicit deletion avoids spurious
    # "table already exists" errors in test restarts.
    try do
      :ets.delete(state.name)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end
end
