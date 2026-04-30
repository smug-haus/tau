defmodule Tau.Settings.Loader do
  @moduledoc """
  Pure loader + merger for the settings cascade.

  Order (later layers override earlier; arrays concat; deny rules are
  preserved across all layers regardless of order):

    1. Managed: `/etc/tau/managed.json` (or platform equivalent)
    2. User:    `~/.tau/settings.json`
    3. Project: `<cwd>/.tau/settings.json`
    4. Local:   `<cwd>/.tau/settings.local.json`

  This module is pure: input is a `cwd`, output is a merged settings map
  plus the list of source files actually read. Watching/reloading is
  `Tau.Settings.Watcher`'s job.
  """

  @doc "Load and merge the cascade for a given cwd."
  @spec load(Path.t()) :: %{settings: map(), sources: [Path.t()]}
  def load(cwd) do
    paths = paths(cwd)

    {merged, sources} =
      Enum.reduce(paths, {%{}, []}, fn path, {acc, sources} ->
        case read_layer(path) do
          {:ok, layer} -> {merge(acc, layer), [path | sources]}
          :missing -> {acc, sources}
          {:error, _} -> {acc, sources}
        end
      end)

    %{settings: merged, sources: Enum.reverse(sources)}
  end

  @doc "Pure deep-merge of two settings maps. Lists at known list-keys concatenate."
  @spec merge(map(), map()) :: map()
  def merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn k, v1, v2 -> merge_value(k, v1, v2) end)
  end

  defp merge_value(_k, v1, v2) when is_map(v1) and is_map(v2), do: merge(v1, v2)

  defp merge_value(k, v1, v2) when is_list(v1) and is_list(v2) do
    if k in list_keys() do
      v1 ++ v2
    else
      v2
    end
  end

  defp merge_value(_k, _v1, v2), do: v2

  @doc "Layer paths in cascade order (managed → user → project → local)."
  @spec paths(Path.t()) :: [Path.t()]
  def paths(cwd) do
    [
      managed_path(),
      Path.join(System.user_home!() || ".", ".tau/settings.json"),
      Path.join(cwd, ".tau/settings.json"),
      Path.join(cwd, ".tau/settings.local.json")
    ]
  end

  defp managed_path do
    case :os.type() do
      {:unix, :darwin} -> "/Library/Application Support/Tau/managed.json"
      {:unix, _} -> "/etc/tau/managed.json"
      {:win32, _} -> "C:\\ProgramData\\Tau\\managed.json"
    end
  end

  defp read_layer(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body, keys: :atoms) do
          {:ok, m} when is_map(m) -> {:ok, m}
          _ -> {:error, :bad_json}
        end

      {:error, :enoent} ->
        :missing

      err ->
        err
    end
  end

  defp list_keys do
    [
      :hooks,
      :extensions,
      :mcp,
      :allow,
      :deny,
      :ask,
      :permissions
    ]
  end
end
