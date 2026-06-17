defmodule Tau.Factory.Policy.Owner do
  @moduledoc """
  Supervised `GenServer` that owns the per-unit policy ETS snapshot.

  ## Responsibilities

  - Accepts policy candidates via `pin/3`, running `Policy.clamp/1` at
    admission before freezing the clamped version in ETS (SPEC-FACTORY-GOV
    §4 B6, C206-B6, HR-8).
  - Exposes `resolve/3` for direct ETS reads — bypasses the owner mailbox
    on the hot read path (B6: reads hit the ETS snapshot directly).
  - Rejects any policy carrying an `oracle` key before it governs a unit
    (INV-POLICY-DATA / HR-8 / issue #553).

  ## Invariants

  - **clamp at admission (C206-B6).** `pin/3` calls `Policy.clamp/1` BEFORE
    writing to ETS. The pinned version is always the clamped one; an
    un-clamped value never reaches ETS.
  - **Immutable once pinned (C202-B6).** A unit's policy pin is frozen for
    its lifetime. Subsequent `pin/3` calls for the same `unit_id` replace
    the entry; in production a unit is pinned exactly once at admission.
  - **ETS owned by this process (OTP-1).** Table is created in `init/1`,
    owned by this process, and dies with it. No ETS outside an owner process.
  - **Reads bypass the mailbox (B6).** `resolve/3` does an ETS lookup
    directly — no `GenServer.call` on the read path when the name is known.

  ## Public API

    - `start_link/1` — start and optionally register.
    - `pin/3`        — admit and freeze a clamped policy for a unit.
    - `resolve/3`    — read a single field from the pinned policy snapshot.
  """

  use GenServer

  alias Tau.Factory.Policy

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the `Policy.Owner` process.

  Options:
    - `:name` — atom; registered name for the GenServer and the ETS table
      (optional; when omitted the process is anonymous and `resolve/3` uses
      a `GenServer.call`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Pin a clamped policy version to `unit_id`.

  Calls `Policy.clamp/1` at admission (C206-B6). On success the clamped
  policy map is stored in ETS and `:ok` is returned. On rejection the ETS
  table is not modified and `{:error, reason}` is returned.

  The `owner` argument accepts a GenServer server reference (pid or name).
  """
  @spec pin(GenServer.server(), String.t(), map()) ::
          :ok | {:error, term()}
  def pin(owner, unit_id, candidate) do
    GenServer.call(owner, {:pin, unit_id, candidate})
  end

  @doc """
  Resolve `field` from the pinned policy for `unit_id`.

  Reads the ETS table **directly** (by registered name) — does NOT issue a
  `GenServer.call`. Returns `{:ok, value}` if a pin exists for `unit_id`,
  or `{:error, :not_pinned}` if the unit has no admitted policy.

  When `owner` is a pid, falls back to a synchronous `GenServer.call`
  because the ETS table name is not available without contacting the process.
  """
  @spec resolve(GenServer.server(), String.t(), atom()) ::
          {:ok, term()} | {:error, :not_pinned}
  def resolve(owner, unit_id, field) when is_atom(owner) do
    case :ets.lookup(owner, unit_id) do
      [{^unit_id, policy_map}] ->
        case Map.fetch(policy_map, field) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :not_pinned}
        end

      [] ->
        {:error, :not_pinned}
    end
  end

  def resolve(owner, unit_id, field) when is_pid(owner) do
    GenServer.call(owner, {:resolve, unit_id, field})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    table_name =
      case Keyword.fetch(opts, :name) do
        {:ok, name} -> name
        :error -> :"#{__MODULE__}_#{System.unique_integer([:positive])}"
      end

    table = :ets.new(table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table, table_name: table_name}}
  end

  @impl true
  def handle_call({:pin, unit_id, candidate}, _from, state) do
    case Policy.clamp(candidate) do
      {:ok, clamped} ->
        :ets.insert(state.table_name, {unit_id, clamped})
        {:reply, :ok, state}

      {:error, _reason} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:resolve, unit_id, field}, _from, state) do
    result =
      case :ets.lookup(state.table_name, unit_id) do
        [{^unit_id, policy_map}] ->
          case Map.fetch(policy_map, field) do
            {:ok, value} -> {:ok, value}
            :error -> {:error, :not_pinned}
          end

        [] ->
          {:error, :not_pinned}
      end

    {:reply, result, state}
  end
end
