defmodule Tau.MCP.Server do
  @moduledoc """
  GenServer wrapping a single MCP server connection.

  Lifecycle:

    1. `init/1` — open transport, send `initialize` JSON-RPC, await response.
    2. On reply — call `tools/list`, then for each tool, generate a
       `Tau.MCP.ToolAdapter` module via `Module.create/3` implementing
       `Tau.Tool`. Register each with `Tau.Tools.Registry` under the
       namespaced key `"mcp__<server_name>__<tool_name>"`.
    3. Forward `handle_call({:invoke, name, params}, from, state)` to the
       transport: assign id, send request, store `from` in `pending`,
       no reply yet.
    4. Incoming `{:line, line}` from the transport → JSON-decode →
       route to pending caller via `GenServer.reply/2` (or as a
       notification).
  """

  use GenServer
  require Logger

  @rpc_version "2.0"
  @timeout 30_000

  # --- Public API -----------------------------------------------------------

  @doc """
  Start an MCP server process. `config` carries at least `:name` plus one
  of `:command` (stdio), `:url` (http), or `:sse_url` + `:post_url` (sse).
  """
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: via(config[:name] || config["name"]))
  end

  @doc """
  Send a `tools/call` to `server_name` for `tool_name` with `params`.
  Returns `{:ok, result}` or `{:error, reason}`. Times out at 30s.
  """
  def invoke(server_name, tool_name, params) when is_binary(server_name) do
    GenServer.call(via(server_name), {:invoke, tool_name, params}, @timeout)
  end

  defp via(name), do: {:via, Registry, {Tau.MCP.Registry, name}}

  # --- Callbacks ------------------------------------------------------------

  @impl true
  def init(config) do
    name = config[:name] || config["name"] || "default"
    transport = config[:transport] || config["transport"] || pick_transport(config)

    Process.flag(:trap_exit, true)
    Process.send_after(self(), :init_handshake, 0)

    {:ok,
     %{
       name: name,
       transport: transport,
       transport_state: nil,
       config: config,
       pending: %{},
       next_id: 1,
       tools: [],
       capabilities: %{},
       registered_keys: [],
       buffered_requests: []
     }}
  end

  @impl true
  def handle_info(:init_handshake, state) do
    case state.transport.connect(state.config) do
      {:ok, ts} ->
        state = %{state | transport_state: ts}
        request_init(state)

      {:error, reason} ->
        Logger.error("MCP #{state.name} transport connect failed: #{inspect(reason)}")
        {:stop, {:transport_failed, reason}, state}
    end
  end

  def handle_info({:line, line}, state), do: handle_message(line, state)

  def handle_info(_msg, state) do
    case state.transport_state && state.transport.recv(state.transport_state, 0) do
      {:ok, lines, ts} ->
        state = %{state | transport_state: ts}
        Enum.reduce(lines, {:noreply, state}, fn line, {:noreply, s} -> handle_message(line, s) end)

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:invoke, tool, params}, from, state) do
    {id, state} = next_id(state)

    rpc = %{
      "jsonrpc" => @rpc_version,
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => tool, "arguments" => params}
    }

    case state.transport.send(state.transport_state, Jason.encode!(rpc)) do
      {:ok, ts} ->
        state = %{state | transport_state: ts, pending: Map.put(state.pending, id, from)}
        emit_telemetry(:start, state.name, tool, id)
        {:noreply, state}

      {:error, e} ->
        {:reply, {:error, e}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.registered_keys, &Registry.unregister(Tau.Tools.Registry, &1))
    if state.transport_state, do: state.transport.close(state.transport_state)
    :ok
  end

  # --- Internals ------------------------------------------------------------

  defp request_init(state) do
    {id, state} = next_id(state)

    rpc = %{
      "jsonrpc" => @rpc_version,
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "clientInfo" => %{"name" => "tau", "version" => version()},
        "capabilities" => %{}
      }
    }

    case state.transport.send(state.transport_state, Jason.encode!(rpc)) do
      {:ok, ts} ->
        {:noreply,
         %{state | transport_state: ts, pending: Map.put(state.pending, id, {:internal, :init})}}

      {:error, e} ->
        {:stop, {:init_send_failed, e}, state}
    end
  end

  defp request_tools_list(state) do
    {id, state} = next_id(state)
    rpc = %{"jsonrpc" => @rpc_version, "id" => id, "method" => "tools/list"}

    case state.transport.send(state.transport_state, Jason.encode!(rpc)) do
      {:ok, ts} ->
        {:noreply,
         %{
           state
           | transport_state: ts,
             pending: Map.put(state.pending, id, {:internal, :tools_list})
         }}

      {:error, _} ->
        {:noreply, state}
    end
  end

  defp handle_message(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = msg} when is_integer(id) or is_binary(id) ->
        route_response(msg, state)

      {:ok, %{"method" => method} = notif} ->
        handle_notification(method, notif, state)

      _ ->
        {:noreply, state}
    end
  end

  defp route_response(%{"id" => id} = msg, state) do
    {target, pending} = Map.pop(state.pending, id)
    state = %{state | pending: pending}

    case target do
      nil -> {:noreply, state}
      {:internal, :init} -> handle_init_response(msg, state)
      {:internal, :tools_list} -> handle_tools_list_response(msg, state)
      from -> reply_to(from, msg, state)
    end
  end

  defp handle_init_response(%{"result" => result}, state) do
    state = %{state | capabilities: result["capabilities"] || %{}}
    request_tools_list(state)
  end

  defp handle_init_response(%{"error" => err}, state) do
    Logger.error("MCP init failed for #{state.name}: #{inspect(err)}")
    {:stop, {:init_error, err}, state}
  end

  defp handle_tools_list_response(%{"result" => %{"tools" => tools}}, state) do
    keys = Enum.map(tools, fn t -> register_tool(state.name, t) end)
    {:noreply, %{state | tools: tools, registered_keys: keys}}
  end

  defp handle_tools_list_response(_, state), do: {:noreply, state}

  defp handle_notification(_method, _notif, state), do: {:noreply, state}

  defp reply_to(from, %{"result" => result}, state) do
    GenServer.reply(from, {:ok, result})
    emit_telemetry(:stop, state.name, "*", nil)
    {:noreply, state}
  end

  defp reply_to(from, %{"error" => err}, state) do
    GenServer.reply(from, {:error, err})
    emit_telemetry(:stop, state.name, "*", nil)
    {:noreply, state}
  end

  defp register_tool(server_name, %{"name" => name} = tool_def) do
    key = "mcp__#{server_name}__#{name}"
    description = tool_def["description"] || "MCP tool from #{server_name}"
    parameters = tool_def["inputSchema"] || %{"type" => "object"}

    mod_name = Module.concat([Tau.MCP.ToolAdapter, server_name, name])
    Tau.MCP.ToolAdapter.build(mod_name, server_name, key, description, parameters)
    Registry.register(Tau.Tools.Registry, key, mod_name)
    key
  end

  defp next_id(state), do: {state.next_id, %{state | next_id: state.next_id + 1}}

  defp emit_telemetry(:start, name, tool, id) do
    :telemetry.execute([:tau, :mcp, :rpc, :start], %{system_time: System.system_time()}, %{
      server: name,
      tool: tool,
      id: id
    })
  end

  defp emit_telemetry(:stop, name, tool, id) do
    :telemetry.execute([:tau, :mcp, :rpc, :stop], %{system_time: System.system_time()}, %{
      server: name,
      tool: tool,
      id: id
    })
  end

  defp pick_transport(config) do
    cond do
      Map.has_key?(config, "command") or Map.has_key?(config, :command) ->
        Tau.MCP.Transport.Stdio

      Map.has_key?(config, "sse_url") or Map.has_key?(config, :sse_url) ->
        Tau.MCP.Transport.Sse

      Map.has_key?(config, "url") or Map.has_key?(config, :url) ->
        Tau.MCP.Transport.Http

      true ->
        Tau.MCP.Transport.Stdio
    end
  end

  defp version do
    case Application.spec(:tau, :vsn) do
      nil -> "0.0.0"
      v -> to_string(v)
    end
  end
end
