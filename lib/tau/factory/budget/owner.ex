defmodule Tau.Factory.Budget.Owner do
  @moduledoc """
  Supervised `GenServer` that owns the per-dimension budget snapshot.

  ## Responsibilities

  - Tracks remaining budget per dimension (`%{atom => non_neg_integer()}`).
  - Maintains a named ETS table (`:named_table`, `read_concurrency: true`)
    keyed by `dimension` atom, holding `{dimension, remaining}` tuples.
  - The ETS table name equals the `:name` atom supplied at `start_link/1`,
    so `budget_precheck/2` can read it directly by atom without looking up
    the GenServer pid (B4 — mailbox bypass for the hot admission path).

  ## Invariants

  - **Truth lives in the Ledger.** `Ledger.Writer.debit_budget/4` is called
    BEFORE the ETS snapshot is updated (D-315 / D-320 WAL-before-ack).
  - **ETS is a derived projection.** On `init/1` the snapshot is rebuilt from
    `Ledger.Writer.budget_debited/1`, so a restarted Owner reflects all
    persisted debits.
  - **ETS table owned by this process.** Created in `init/1`; dies with the
    process; rebuilt on restart. No ETS outside an owner process (OTP-1).
  - **Writer → ETS table mapping** stored in `:persistent_term` so `debit/4`
    can locate the ETS table given only the writer name. The mapping is
    registered in `init/1` and erased in `terminate/2`.

  ## Public API

    - `start_link/1` — start and register the process.
    - `budget_precheck/2` — direct ETS read; returns `:ok` or
      `{:exhausted, dimension}` (B4).
    - `debit/4` — plain function: writes to Ledger first, then updates the
      ETS snapshot directly (D-320 truth-before-projection; no mailbox
      routing for this call).
  """

  use GenServer

  alias Tau.Factory.Ledger.Writer

  require Logger

  # `:persistent_term` key prefix for the ledger → ETS table mapping.
  @pt_prefix {__MODULE__, :ledger_ets_map}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the `Budget.Owner` and register it under `:name`.

  Required options:
    - `:ledger`  — `GenServer.server()` reference to a `Ledger.Writer`.
    - `:totals`  — `%{atom() => non_neg_integer()}` per-dimension limits.
    - `:name`    — atom; registered name for the GenServer AND the ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Check whether the budget for `dimension` has any remaining headroom.

  Reads the ETS table DIRECTLY by the registered name atom — does NOT issue a
  `GenServer.call`. Returns `:ok` if remaining > 0; `{:exhausted, dimension}`
  if remaining is 0 or the dimension is absent (B4 / D-320).
  """
  @spec budget_precheck(atom(), atom()) :: :ok | {:exhausted, atom()}
  def budget_precheck(name, dimension) do
    case :ets.lookup(name, dimension) do
      [{^dimension, remaining}] when remaining > 0 -> :ok
      _ -> {:exhausted, dimension}
    end
  end

  @doc """
  Debit `cost` units from `dimension` for `unit_id`.

  `writer` is the `Ledger.Writer` server reference (atom or pid). This
  function:

  1. Calls `Ledger.Writer.debit_budget/4` first (WAL-before-ack; Ledger is
     truth). Only after the durable WAL commit does this function proceed.
  2. Looks up the ETS table associated with `writer` via `:persistent_term`
     and decrements the snapshot: `remaining' = max(0, remaining - cost)`.

  Returns `:ok`.
  """
  @spec debit(GenServer.server(), String.t(), atom(), non_neg_integer()) :: :ok
  def debit(writer, unit_id, dimension, cost) do
    # Step 1: persist to Ledger (truth, WAL-before-ack; D-315 / D-320).
    {:ok, _ref} = Writer.debit_budget(writer, unit_id, dimension, cost)

    # Step 2: update ETS snapshot (projection follows truth).
    # Look up the ETS table name registered by this writer's Budget.Owner.
    case :persistent_term.get({@pt_prefix, writer}, nil) do
      nil ->
        # No owner registered for this writer — nothing to update.
        :ok

      ets_table ->
        update_ets_remaining(ets_table, dimension, cost)
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    totals = Keyword.fetch!(opts, :totals)
    name = Keyword.fetch!(opts, :name)

    # Rebuild projection from Ledger truth (D-315).
    debited = Writer.budget_debited(ledger)

    # Create the named ETS table owned by this process.
    # Table name == the registered GenServer name (B4).
    table =
      :ets.new(name, [
        :set,
        :named_table,
        :public,
        read_concurrency: true
      ])

    # Populate with remaining = max(0, total - debited) per dimension.
    Enum.each(totals, fn {dim, limit} ->
      spent = Map.get(debited, dim, 0)
      remaining = max(0, limit - spent)
      :ets.insert(table, {dim, remaining})
    end)

    # Register the writer → ETS table mapping so debit/4 can find the table.
    :persistent_term.put({@pt_prefix, ledger}, name)

    {:ok, %{ledger: ledger, totals: totals, name: name}}
  end

  @impl GenServer
  def terminate(_reason, %{ledger: ledger}) do
    # Clean up the persistent_term entry so a restarted owner can re-register.
    :persistent_term.erase({@pt_prefix, ledger})
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Decrement the ETS remaining counter by `cost`, flooring at 0.
  defp update_ets_remaining(table, dimension, cost) do
    case :ets.lookup(table, dimension) do
      [{^dimension, remaining}] ->
        new_remaining = max(0, remaining - cost)
        :ets.insert(table, {dimension, new_remaining})

      [] ->
        # Dimension not in totals — no ETS entry; nothing to update.
        :ok
    end
  end
end
