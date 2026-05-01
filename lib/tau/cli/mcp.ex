defmodule Tau.CLI.MCP do
  @moduledoc """
  Handlers for the `tau mcp` subcommand group.

    * `tau mcp list` — configured MCP servers (name, transport,
      command/url).
    * `tau mcp status` — health: which entries have a live `Tau.MCP.Server`
      pid.
    * `tau mcp reload` — force `Tau.MCP.Manager` to re-reconcile against
      the current settings.
    * `--json` on any subcommand for piping.

  Reads come from `Tau.MCP.Manager.list/0`, which returns desired entries
  from `Tau.Settings.Cache` joined with the manager's `started` map.
  """

  @type opts :: [json: boolean()]

  @doc "Handler for `tau mcp list`."
  @spec list(opts()) :: 0
  def list(opts \\ []) do
    entries = safe_list()

    if Keyword.get(opts, :json, false) do
      payload =
        Enum.map(entries, fn e ->
          %{name: e.name, transport: transport_for(e.config), config: stringify_keys(e.config)}
        end)

      IO.puts(Jason.encode!(payload))
    else
      if entries == [] do
        IO.puts("(no MCP servers configured)")
      else
        IO.puts("name\ttransport\ttarget")

        Enum.each(entries, fn e ->
          IO.puts("#{e.name}\t#{transport_for(e.config)}\t#{target_for(e.config)}")
        end)
      end
    end

    0
  end

  @doc "Handler for `tau mcp status`."
  @spec status(opts()) :: 0
  def status(opts \\ []) do
    entries = safe_list()

    if Keyword.get(opts, :json, false) do
      payload =
        Enum.map(entries, fn e ->
          %{
            name: e.name,
            alive: e.alive?,
            pid: e.pid && inspect(e.pid)
          }
        end)

      IO.puts(Jason.encode!(payload))
    else
      if entries == [] do
        IO.puts("(no MCP servers configured)")
      else
        IO.puts("name\tstatus\tpid")

        Enum.each(entries, fn e ->
          status = if e.alive?, do: "running", else: "down"
          IO.puts("#{e.name}\t#{status}\t#{(e.pid && inspect(e.pid)) || "-"}")
        end)
      end
    end

    0
  end

  @doc "Handler for `tau mcp reload`."
  @spec reload(opts()) :: 0 | 2
  def reload(opts \\ []) do
    case safe_reload() do
      :ok ->
        if Keyword.get(opts, :json, false) do
          IO.puts(Jason.encode!(%{ok: true}))
        else
          IO.puts("mcp manager reload requested")
        end

        0

      {:error, reason} ->
        IO.puts(:stderr, "mcp reload failed: #{inspect(reason)}")
        2
    end
  end

  defp safe_list do
    Tau.MCP.Manager.list()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_reload do
    Tau.MCP.Manager.reload()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp transport_for(config) do
    cond do
      Map.has_key?(config, :transport) -> to_string(config[:transport])
      Map.has_key?(config, "transport") -> to_string(config["transport"])
      Map.has_key?(config, :command) or Map.has_key?(config, "command") -> "stdio"
      Map.has_key?(config, :sse_url) or Map.has_key?(config, "sse_url") -> "sse"
      Map.has_key?(config, :url) or Map.has_key?(config, "url") -> "http"
      true -> "?"
    end
  end

  defp target_for(config) do
    case fetch_any(config, [:command, "command"]) do
      nil ->
        case fetch_any(config, [:url, "url", :sse_url, "sse_url"]) do
          nil -> "?"
          url -> url
        end

      cmd ->
        args = fetch_any(config, [:args, "args"]) || []
        Enum.join([cmd | args], " ")
    end
  end

  defp fetch_any(map, keys) do
    Enum.find_value(keys, fn k -> Map.get(map, k) end)
  end

  defp stringify_keys(m) when is_map(m) do
    Map.new(m, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(v), do: v
end
