defmodule Tau.Factory.Policy.Owner do
  @moduledoc """
  Supervised `GenServer` that owns the per-unit policy snapshots.

  ## Responsibilities

  - Maintains a named ETS table (`:named_table`, `read_concurrency: true`)
    keyed by `{unit_id, field}`, holding `{key, value}` tuples.
  - `pin/3` freezes a clamped `%Policy{}` for a unit at admission time.
    The stored snapshot is immutable for the unit's life (C202,
    SPEC-FACTORY-GOV §3).
  - `resolve/3` reads the pinned field directly from ETS — no owner
    mailbox involved (B6 hot-path bypass).

  ## API

  - `start_link/1` — start and register under `:name`.
  - `pin/3` — freeze a clamped policy for a unit.
  - `resolve/3` — read a single field from a unit's pinned snapshot.

  ## Invariants

  - ETS table is created in `init/1` and owned by this process; destroyed
    on crash, rebuilt on restart (OTP-1).
  - `pin/3` always stores the *clamped* policy (the caller is responsible
    for clamping before pinning; see `Policy.clamp/1`).
  - `resolve/3` is a direct ETS read — it MUST NOT issue a
    `GenServer.call` (B6 / [C220]).
  """

  use GenServer

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
  Freeze the clamped `policy` for `unit_id` in the owner named `owner`.

  The caller MUST pass a pre-clamped `%Policy{}` (returned by
  `Policy.clamp/1`).  `pin/3` stores every field of the policy keyed by
  `{unit_id, field}` so `resolve/3` can read individual fields without
  deserialising the whole struct.

  Returns `:ok`.
  """
  @spec pin(GenServer.server(), String.t(), Policy.t()) :: :ok
  def pin(owner, unit_id, %Policy{} = policy) do
    GenServer.call(owner, {:pin, unit_id, policy})
  end

  @doc """
  Read the value of `field` from the policy pinned for `unit_id`.

  Reads the ETS table DIRECTLY by the registered owner name atom — does
  NOT issue a nested `GenServer.call` (hot-path bypass, B6 / [C220]).

  Returns the field's value, or raises `KeyError` if the unit has no
  pinned policy or the field is unknown.
  """
  @spec resolve(atom(), String.t(), atom()) :: term()
  def resolve(owner_name, unit_id, field) when is_atom(owner_name) do
    case :ets.lookup(owner_name, {unit_id, field}) do
      [{{^unit_id, ^field}, value}] -> value
      [] -> raise KeyError, key: {unit_id, field}, term: owner_name
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    table =
      :ets.new(name, [
        :set,
        :named_table,
        :public,
        read_concurrency: true
      ])

    {:ok, %{name: name, table: table}}
  end

  @impl GenServer
  def handle_call({:pin, unit_id, %Policy{} = policy}, _from, state) do
    policy
    |> Map.from_struct()
    |> Enum.each(fn {field, value} ->
      :ets.insert(state.table, {{unit_id, field}, value})
    end)

    {:reply, :ok, state}
  end
end
