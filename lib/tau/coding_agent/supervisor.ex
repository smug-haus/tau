defmodule Tau.CodingAgent.Supervisor do
  @moduledoc """
  `DynamicSupervisor` for `Tau.CodingAgent.Dispatcher` children.

  Coding-agent runs are short-lived sub-processes. Each `Delegate`
  tool call or `--coding-agent` session-mode invocation starts a
  dispatcher under this supervisor. The dispatcher owns either
  an OS `Port` (subprocess-backed adapters) or an in-BEAM stream
  source (Replay).

  Boots between `Tau.MCP.Supervisor` and `Tau.Sessions.Supervisor`
  in `Tau.Application` (`:rest_for_one`):

  * MCP must already be up — the future `tau-context` MCP server
    that adapters spawn alongside is registered there.
  * Sessions come after — session FSMs may reference dispatchers
    by id.
  """

  use DynamicSupervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Start a dispatcher under this supervisor. `args` is forwarded to
  `Tau.CodingAgent.Dispatcher.start_link/1`.
  """
  @spec start_dispatcher(keyword()) :: DynamicSupervisor.on_start_child()
  def start_dispatcher(args) do
    DynamicSupervisor.start_child(__MODULE__, {Tau.CodingAgent.Dispatcher, args})
  end

  @doc """
  Currently-running dispatcher children. Used by the AC-5 property
  test to assert zero zombies after random cancel timings.
  """
  @spec which_children() :: [tuple()]
  def which_children, do: DynamicSupervisor.which_children(__MODULE__)

  @doc "Count of currently-running dispatchers."
  @spec count() :: non_neg_integer()
  def count do
    %{active: n} = DynamicSupervisor.count_children(__MODULE__)
    n
  end
end
