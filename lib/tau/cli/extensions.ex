defmodule Tau.CLI.Extensions do
  @moduledoc """
  Handlers for the `tau extensions` subcommand group.

    * `tau extensions list` — show loaded extensions: each entry's
      `key` (module or path) and the modules registered from it.
    * `tau extensions reload` — re-run `Tau.Extensions.Loader` against
      every entry in `settings.extensions`.
    * `--json` for scripting.

  Reads come from `Tau.Extensions.Loader.list/0`.
  """

  @type opts :: [json: boolean()]

  @doc "Handler for `tau extensions list`."
  @spec list(opts()) :: 0
  def list(opts \\ []) do
    entries = safe_list()

    if Keyword.get(opts, :json, false) do
      payload =
        Enum.map(entries, fn %{key: key, info: info} ->
          %{
            key: stringify(key),
            modules: Enum.map(modules_for(info), &inspect/1),
            path: info[:path]
          }
        end)

      IO.puts(Jason.encode!(payload))
    else
      if entries == [] do
        IO.puts("(no extensions loaded)")
      else
        IO.puts("key\tmodules")

        Enum.each(entries, fn %{key: key, info: info} ->
          mods = modules_for(info) |> Enum.map(&inspect/1) |> Enum.join(",")
          IO.puts("#{stringify(key)}\t#{mods}")
        end)
      end
    end

    0
  end

  @doc "Handler for `tau extensions reload`."
  @spec reload(opts()) :: 0 | 2
  def reload(opts \\ []) do
    case safe_reload() do
      :ok ->
        if Keyword.get(opts, :json, false) do
          IO.puts(Jason.encode!(%{ok: true}))
        else
          IO.puts("extensions reload requested")
        end

        0

      {:error, reason} ->
        IO.puts(:stderr, "extensions reload failed: #{inspect(reason)}")
        2
    end
  end

  defp safe_list do
    Tau.Extensions.Loader.list()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_reload do
    Tau.Extensions.Loader.reload_all()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp modules_for(info) when is_map(info) do
    cond do
      is_list(info[:modules]) -> info[:modules]
      info[:module] -> [info[:module]]
      true -> []
    end
  end

  defp modules_for(_), do: []

  defp stringify(k) when is_atom(k), do: inspect(k)
  defp stringify(k) when is_binary(k), do: k
  defp stringify(k), do: inspect(k)
end
