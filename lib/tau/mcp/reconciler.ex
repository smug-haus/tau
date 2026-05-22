defmodule Tau.MCP.Reconciler do
  @moduledoc """
  Reads `settings.mcp` and starts/stops `Tau.MCP.Server` GenServers under
  `Tau.MCP.ServerSupervisor`. Reacts to settings reloads by diffing the
  desired set vs. the running set.

  The running set is *not* cached: it is derived on demand from
  `Tau.MCP.Registry`, which `Tau.MCP.Server` registers itself with under
  its server name. The supervisor and registry are the authoritative
  source of running-server truth; a cached map would only drift from it.

  Each entry in `settings.mcp` is a map with at least a `name` and either
  `command` (stdio), `url` (http), or `sse_url`+`post_url` (sse).
  """
  use GenServer

  @doc """
  Start the MCP reconciler. Schedules an initial reconcile against
  `settings.mcp` on boot.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  List the configured MCP servers along with the currently-running pid (if
  any). Returned shape:

      [%{name: name, config: config, pid: pid_or_nil, alive?: bool}]

  `pid` is `nil` for desired-but-not-yet-started servers (the reconciler
  hasn't reconciled yet) or for entries it couldn't start. CLI / TUI
  callers want this to render server status without poking GenServer
  internals.
  """
  @spec list() :: [
          %{name: String.t(), config: map(), pid: pid() | nil, alive?: boolean()}
        ]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc """
  Force a reconcile pass against the current settings. Useful after
  editing `.tau/settings.json` from the CLI.
  """
  @spec reload() :: :ok
  def reload, do: GenServer.cast(__MODULE__, :reload)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :reconcile, 0)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile(desired_servers())
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:reload, state) do
    desired = desired_servers()
    reconcile(desired)
    :telemetry.execute([:tau, :mcp, :reconciler, :reloaded], %{count: length(desired)}, %{})
    {:noreply, state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    entries =
      Enum.map(desired_servers(), fn config ->
        name = server_name(config)
        pid = running_pid(name)
        %{name: name, config: config, pid: pid, alive?: is_pid(pid)}
      end)

    {:reply, entries, state}
  end

  # Diffs the desired server set against the running set (derived from the
  # registry): terminates running servers no longer desired, starts desired
  # servers not yet running.
  defp reconcile(desired) do
    desired_names = Enum.map(desired, &server_name/1) |> MapSet.new()

    Enum.each(running(), fn {name, pid} ->
      unless MapSet.member?(desired_names, name) do
        DynamicSupervisor.terminate_child(Tau.MCP.ServerSupervisor, pid)
      end
    end)

    Enum.each(desired, fn config ->
      name = server_name(config)
      if running_pid(name) == nil, do: start_server(config)
    end)

    :ok
  end

  # The desired MCP server set, read from settings. Always a list.
  defp desired_servers do
    case Tau.Settings.Cache.get() |> Map.get(:mcp, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # The running server set, derived from the registry: [{name, pid}].
  defp running do
    Registry.select(Tau.MCP.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  # The live pid for a server name, or nil if not running.
  defp running_pid(name) do
    case Registry.lookup(Tau.MCP.Registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp start_server(config) do
    DynamicSupervisor.start_child(
      Tau.MCP.ServerSupervisor,
      {Tau.MCP.Server, config}
    )
  end

  defp server_name(%{"name" => n}), do: n
  defp server_name(%{name: n}), do: n
  defp server_name(_), do: "default"
end
