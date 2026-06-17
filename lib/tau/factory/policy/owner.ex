defmodule Tau.Factory.Policy.Owner do
  @moduledoc """
  Supervised `GenServer` that owns the per-unit policy ETS snapshot.

  Holds pinned `%Policy{}` versions keyed by unit ID.  Reads hit the ETS
  table directly (no mailbox bottleneck — B6 pattern, identical to
  `Budget.Owner`).

  ## Responsibilities

  - Maintains a named ETS table (`read_concurrency: true`) keyed by
    `{unit_id, field}` and by `unit_id` (the full pinned policy).
  - `pin/3` — freezes the clamped `%Policy{}` to a unit for its life.
    In-flight units keep their pin across a version bump.
  - `resolve/3` — reads a single field from the unit's pinned snapshot
    directly from ETS (no `GenServer.call` on the hot path).

  ## Invariants

  - ETS table owned by this process; created in `init/1`; dies with
    the process; rebuilt on restart (OTP-1 — no ETS outside an owner).
  - A policy is pinned AFTER `Policy.clamp/1` — the clamped version
    is the pinned one (SPEC-FACTORY-GOV B6 / C206).
  - Two units may pin two different versions concurrently; neither can
    mutate the other's pin (C202).
  - The process is the sole writer of the ETS table; readers bypass the
    mailbox (OTP non-negotiable #1 / #3).
  """

  use GenServer

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the `Policy.Owner` and register it under `:name`.

  Accepts `name:` in opts (an atom); if absent, the process is anonymous.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Pin `policy` to `unit_id` under the owner identified by `owner`.

  `owner` is a `GenServer.server()` reference (pid or registered name).
  The policy MUST already be clamped (`Policy.clamp/1` at admission).
  Returns `:ok`.
  """
  @spec pin(GenServer.server(), String.t(), Tau.Factory.Policy.t()) :: :ok
  def pin(owner, unit_id, policy) do
    GenServer.call(owner, {:pin, unit_id, policy})
  end

  @doc """
  Resolve `field` from the pinned policy for `unit_id`.

  Reads the ETS table directly — no `GenServer.call` on the hot path.
  `owner` must be a registered atom name (so the ETS table can be
  looked up by atom).

  Returns the field value, or raises `KeyError` if the unit has no pin.
  """
  @spec resolve(atom(), String.t(), atom()) :: term()
  def resolve(owner, unit_id, field) do
    case :ets.lookup(owner, {unit_id, field}) do
      [{{^unit_id, ^field}, value}] -> value
      [] -> raise KeyError, key: {unit_id, field}, term: owner
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    table =
      :ets.new(name, [
        :set,
        :named_table,
        :protected,
        read_concurrency: true
      ])

    {:ok, %{name: name, table: table}}
  end

  @impl GenServer
  def handle_call({:pin, unit_id, policy}, _from, state) do
    # Store each field as a separate {unit_id, field} → value row so that
    # resolve/3 can look up individual fields directly.
    policy
    |> Map.from_struct()
    |> Enum.each(fn {field, value} ->
      :ets.insert(state.table, {{unit_id, field}, value})
    end)

    {:reply, :ok, state}
  end
end
