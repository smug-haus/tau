defmodule Tau.Factory.KillSwitch.Store do
  @moduledoc """
  ETS-owning control owner for the kill-switch halt flag.

  INV-KILLSWITCH-OPERATOR-STATE: the halt flag is durable operator state — an
  ETS flag under a supervised control owner — never stored solely in process
  heap. This module is the ETS owner: it creates and holds the table for the
  lifetime of the supervisor, independently of the `KillSwitch` GenServer.

  Because the ETS table is owned by this `GenServer`, the flag survives a crash
  and restart of the `KillSwitch` process: the `Store` process continues to hold
  the table even when the `KillSwitch` GenServer is restarted by its supervisor.

  ## API

    - `start_link/1` — starts and registers the Store.
    - `armed?/1`     — returns `true` if the halt flag is set.
    - `set_armed/1`  — arms the halt flag (called by `KillSwitch` on request_halt
                       and by `StepJob` when checking the sentinel).

  See `docs/spec/SPEC-FACTORY-CORE.md`, D-321; `Tau.Factory.KillSwitch`.
  """

  use GenServer

  # ETS key for the halt flag.
  @halt_key :halt

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start and register the Store.

  Options:
    - `:name` (required) — atom; registered name for this GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns `true` if the halt flag has been set in the ETS table owned by the
  Store identified by `name`. Reads directly from ETS (no GenServer roundtrip).
  """
  @spec armed?(GenServer.server()) :: boolean()
  def armed?(name) do
    table = table_name(name)

    case :ets.lookup(table, @halt_key) do
      [{@halt_key, true}] -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc """
  Set the halt flag in the ETS table owned by the Store identified by `name`.
  Returns `:ok`.
  """
  @spec set_armed(GenServer.server()) :: :ok
  def set_armed(name) do
    GenServer.call(name, :set_armed)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = :ets.new(table_name(name), [:set, :public, :named_table])

    {:ok, %{table: table, name: name}}
  end

  @impl GenServer
  def handle_call(:set_armed, _from, state) do
    :ets.insert(state.table, {@halt_key, true})
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Derive a stable ETS table name from the Store's registered name.
  # Using a named table allows `armed?/1` to look up the table by name
  # without a GenServer call.
  defp table_name(name) when is_atom(name) do
    :"kill_switch_store_#{name}"
  end

  defp table_name(name) when is_pid(name) do
    :"kill_switch_store_#{:erlang.pid_to_list(name)}"
  end
end
