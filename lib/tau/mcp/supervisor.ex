defmodule Tau.MCP.Supervisor do
  @moduledoc """
  Top-level MCP supervisor.

  Tree:

      Tau.MCP.Supervisor               (:one_for_one)
      ├── Tau.MCP.Reconciler           (reads settings, starts servers)
      └── Tau.MCP.ServerSupervisor     (DynamicSupervisor for per-server processes)
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Tau.MCP.ServerSupervisor, strategy: :one_for_one},
      Tau.MCP.Reconciler
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
