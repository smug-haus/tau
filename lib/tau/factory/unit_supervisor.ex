defmodule Tau.Factory.UnitSupervisor do
  @moduledoc """
  Dynamic supervisor for `Tau.Factory.Unit` processes.

  Each Unit child is started with `restart: :temporary` — the Unit FSM
  manages its own terminal transitions; supervisor restarts are not used.

  See `docs/spec/SPEC-FACTORY-CORE.md` §5, D-340.
  """

  use DynamicSupervisor

  @doc """
  Start the UnitSupervisor and register it under `:name`.

  Required options:
    - `:name` — atom; registered name for this supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a `Tau.Factory.Unit` as a child of the given supervisor.

  Returns the `pid` of the new Unit process directly, or raises on failure.

  `unit_opts` is the options keyword list accepted by `Tau.Factory.Unit.start_link/1`.
  """
  @spec start_unit(atom() | pid(), keyword()) :: pid()
  def start_unit(supervisor, unit_opts) do
    child_spec = %{
      id: make_ref(),
      start: {Tau.Factory.Unit, :start_link, [unit_opts]},
      restart: :temporary,
      type: :worker
    }

    {:ok, pid} = DynamicSupervisor.start_child(supervisor, child_spec)
    pid
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
