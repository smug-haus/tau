defmodule Tau.MCP.Manager do
  @moduledoc """
  Reads `settings.mcp` and starts/stops `Tau.MCP.Server` GenServers under
  `Tau.MCP.ServerSupervisor`. Reacts to settings reloads by diffing
  the desired set vs. the running set.

  Each entry in `settings.mcp` is a map with at least a `name` and either
  `command` (stdio), `url` (http), or `sse_url`+`post_url` (sse).
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  List the configured MCP servers along with the currently-running pid (if
  any). Returned shape:

      [%{name: name, config: config, pid: pid_or_nil, alive?: bool}]

  `pid` is `nil` for desired-but-not-yet-started servers (Manager hasn't
  reconciled yet) or for entries the manager couldn't start. CLI / TUI
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
    {:ok, %{started: %{}}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    desired = Tau.Settings.Cache.get() |> Map.get(:mcp, [])
    desired = if is_list(desired), do: desired, else: []

    state = reconcile(desired, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:reload, state) do
    desired = Tau.Settings.Cache.get() |> Map.get(:mcp, [])
    desired = if is_list(desired), do: desired, else: []

    state = reconcile(desired, state)
    :telemetry.execute([:tau, :mcp, :manager, :reloaded], %{count: length(desired)}, %{})
    {:noreply, state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    desired = Tau.Settings.Cache.get() |> Map.get(:mcp, [])
    desired = if is_list(desired), do: desired, else: []

    entries =
      Enum.map(desired, fn config ->
        name = server_name(config)
        pid = Map.get(state.started, name)
        alive? = is_pid(pid) and Process.alive?(pid)
        %{name: name, config: config, pid: pid, alive?: alive?}
      end)

    {:reply, entries, state}
  end

  defp reconcile(desired, %{started: started} = state) do
    desired_names = Enum.map(desired, &server_name/1) |> MapSet.new()
    running_names = MapSet.new(Map.keys(started))

    Enum.each(MapSet.difference(running_names, desired_names), fn name ->
      pid = Map.get(started, name)
      DynamicSupervisor.terminate_child(Tau.MCP.ServerSupervisor, pid)
    end)

    started =
      Enum.reduce(desired, started, fn config, acc ->
        name = server_name(config)

        case Map.get(acc, name) do
          nil ->
            case start_server(config) do
              {:ok, pid} -> Map.put(acc, name, pid)
              _ -> acc
            end

          pid ->
            if Process.alive?(pid), do: acc, else: Map.delete(acc, name)
        end
      end)

    %{state | started: started}
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
