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
  Debit 1 unit from `dimension` for `unit_id` via the named owner process.

  Used by `Tau.Factory.Scheduler` on the `:admit` path (D-320 / FR-7.1
  conjunct 2): the Scheduler knows `owner_name` but not the underlying
  `Ledger.Writer` reference, so it delegates to the Owner to perform the
  debit through its own state.

  The Owner issues `GenServer.call(self(), {:debit_via_owner, unit_id,
  dimension})` internally — the actual write sequence (Ledger-first, then
  ETS) is identical to `debit/4` with `cost = 1`.

  Returns `:ok`.
  """
  @spec debit_admission(atom(), String.t(), atom()) :: :ok
  def debit_admission(owner_name, unit_id, dimension) do
    GenServer.call(owner_name, {:debit_via_owner, unit_id, dimension})
  end

  @doc """
  Debit `cost` units from `dimension` for `unit_id`.

  `writer` is the `Ledger.Writer` server reference (atom or pid). This
  function:

  1. Reads the current ETS remaining for `dimension` to compute the
     effective debit: `effective_cost = min(cost, remaining)`. This clamps
     the recorded Ledger cost to the amount actually consumable, preserving
     the D-332 conservation identity `spent + remaining = total` even when
     `cost` exceeds the remaining budget (overshoot).
  2. Calls `Ledger.Writer.debit_budget/4` with the effective cost first
     (WAL-before-ack; Ledger is truth). Only after the durable WAL commit
     does this function proceed.
  3. Looks up the ETS table associated with `writer` via `:persistent_term`
     and decrements the snapshot by the effective cost:
     `remaining' = remaining - effective_cost` (exact, no clamping needed
     since `effective_cost <= remaining`).

  D-332 invariant: `spent + remaining == total` holds at every observable
  point because `Σ effective_costs = total - remaining` by construction.

  Returns `:ok`.
  """
  @spec debit(GenServer.server(), String.t(), atom(), non_neg_integer()) :: :ok
  def debit(writer, unit_id, dimension, cost) do
    # Step 1: determine the ETS table and compute the effective debit cost.
    #
    # D-332 (CON-3 budget conservation): clamp cost to the current remaining
    # so the Ledger only records what is actually consumed.  This preserves
    # spent + remaining = total even on overshoot.
    {ets_table, effective_cost} =
      case :persistent_term.get({@pt_prefix, writer}, nil) do
        nil ->
          # No ETS owner registered — use the full cost (no projection to keep
          # consistent; Ledger-only path).
          {nil, cost}

        table ->
          remaining = ets_remaining_for(table, dimension)
          {table, min(cost, remaining)}
      end

    # Step 2: persist the effective cost to Ledger (truth, WAL-before-ack;
    # D-315 / D-320).  Skipped when effective_cost is 0 (already exhausted).
    if effective_cost > 0 do
      {:ok, _ref} = Writer.debit_budget(writer, unit_id, dimension, effective_cost)
    end

    # Step 3: update ETS snapshot by the same effective cost (projection
    # follows truth).
    if ets_table != nil and effective_cost > 0 do
      update_ets_remaining(ets_table, dimension, effective_cost)
    end

    :ok
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
    #
    # INV-DS-BUDGET-REBUILD: Writer.budget_debited/1 returns %{dim => total}
    # on success, or {:error, reason} if the ledger query fails (e.g. the
    # budget_debits table is missing after a DB corruption / schema migration).
    # A DB failure means the true debit total is UNKNOWN — NOT zero. Treating
    # it as zero would overstate available budget (limit - 0 = limit). Instead,
    # on any {:error, reason}, we populate ETS with remaining = 0 for all
    # dimensions (fully-exhausted safe default). This is conservative: no new
    # spend is admitted until the Ledger is healthy and the Owner is restarted
    # with accurate rebuild data. The supervisor can then retry or escalate.
    debited =
      case Writer.budget_debited(ledger) do
        {:error, reason} ->
          Logger.warning(
            "Budget.Owner: ledger rebuild failed (#{inspect(reason)}); " <>
              "ETS snapshot set to fully-exhausted to avoid overstating budget."
          )

          # Use totals as the debited map so remaining = max(0, limit - limit) = 0
          # for every dimension — a conservative safe default that prevents
          # admission of new spend when the true debit total is unknown.
          totals

        map when is_map(map) ->
          map
      end

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

  @impl GenServer
  def handle_call({:debit_via_owner, unit_id, dimension}, _from, %{ledger: ledger} = state) do
    # Called by debit_admission/3 from the Scheduler on every :admit path
    # (D-320 / FR-7.1 conjunct 2).  Uses the Owner's own ledger reference so
    # the Scheduler does not need to know the writer name.  Cost = 1 per
    # admitted unit.
    debit(ledger, unit_id, dimension, 1)
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Return the current remaining value for `dimension` from the ETS table, or
  # 0 if the dimension has no row.  Used by `debit/4` to compute the effective
  # debit cost before writing to the Ledger (D-332 conservation clamp).
  defp ets_remaining_for(table, dimension) do
    case :ets.lookup(table, dimension) do
      [{^dimension, remaining}] -> remaining
      [] -> 0
    end
  end

  # Decrement the ETS remaining counter by `cost`.
  #
  # By the time this is called from `debit/4`, `cost` has already been clamped
  # to `min(requested_cost, remaining)`, so `cost <= remaining` is guaranteed —
  # the floor guard `{2, -cost, 0, 0}` is kept for safety but should never
  # fire under normal operation.
  #
  # Uses `:ets.update_counter/3` with a threshold guard so the decrement is
  # atomic — no read-modify-write window. Tuple layout: {dimension, remaining},
  # so remaining is at position 2.
  #
  # Guards with `:ets.member/2` first so that a debit on an unconfigured
  # dimension (no ETS row) is a silent no-op rather than a raised error.
  defp update_ets_remaining(table, dimension, cost) do
    if :ets.member(table, dimension) do
      :ets.update_counter(table, dimension, {2, -cost, 0, 0})
    end

    :ok
  end
end
