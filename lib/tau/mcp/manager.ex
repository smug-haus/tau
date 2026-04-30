defmodule Tau.MCP.Manager do
  @moduledoc """
  Reads `settings.mcp` and starts/stops `Tau.MCP.Server` processes under
  `Tau.MCP.ServerSupervisor`. Reacts to settings reloads by diffing the
  desired vs. running set.

  M0 stub: idle.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{servers: %{}}}
end
