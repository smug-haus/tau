defmodule Tau.MCP.Transport.Stdio do
  @moduledoc """
  Stdio transport for MCP.

  MCP framing is newline-delimited JSON-RPC, so we open the Port with
  `{:line, _}`. stderr is **not** merged with stdout — instead it's
  swallowed by the Port's default behaviour and surfaced via the
  `[:tau, :mcp, :stderr]` telemetry channel where the GenServer
  forwards individual chunks.

  Config:

      %{
        "command" => "npx",
        "args"    => ["@modelcontextprotocol/server-filesystem", "/tmp"],
        "env"     => %{"MCP_LOG" => "debug"}
      }
  """

  @behaviour Tau.MCP.Transport

  @max_line 4 * 1024 * 1024

  @impl Tau.MCP.Transport
  def connect(%{} = config) do
    cmd = Map.get(config, "command") || Map.get(config, :command)
    args = Map.get(config, "args") || Map.get(config, :args, [])
    env = Map.get(config, "env") || Map.get(config, :env, %{})

    case System.find_executable(cmd) do
      nil ->
        {:error, {:not_found, cmd}}

      exe ->
        port =
          Port.open(
            {:spawn_executable, exe},
            [
              :binary,
              :exit_status,
              :hide,
              :use_stdio,
              {:line, @max_line},
              {:args, args},
              {:env, env_pairs(env)}
            ]
          )

        {:ok, %{port: port, partial: ""}}
    end
  end

  @impl Tau.MCP.Transport
  def send(%{port: port} = state, payload) do
    line = IO.iodata_to_binary(payload)

    line =
      if String.ends_with?(line, "\n"), do: line, else: line <> "\n"

    Port.command(port, line)
    {:ok, state}
  end

  @impl Tau.MCP.Transport
  def recv(%{port: port} = state, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        {:ok, [state.partial <> line], %{state | partial: ""}}

      {^port, {:data, {:noeol, partial}}} ->
        recv(%{state | partial: state.partial <> partial}, timeout)

      {^port, {:exit_status, n}} ->
        {:error, {:exit, n}}
    after
      timeout -> {:error, :timeout}
    end
  end

  @impl Tau.MCP.Transport
  def close(%{port: port}) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp env_pairs(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {to_charlist(to_string(k)), to_charlist(to_string(v))} end)
  end
end
