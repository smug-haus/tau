defmodule Tau.Extensions.Loader do
  @moduledoc """
  Compiles, registers, and hot-reloads `Tau.Extension` modules.

  On boot:

    1. Read `settings.extensions` — a list of `{module, opts}` tuples or
       directory paths (strings).
    2. For each path, `Code.compile_file/1` every `.ex` file found,
       discover modules implementing `Tau.Extension`, register their
       tools/hooks/commands/skills.
    3. For each `{module, _opts}`, just register (assume already loaded).

  Hot reload:

    * `:file_system` watches each path; on `:modified` events,
      `unload/1` then `load/1` for that path.
    * Sessions resolve tools at dispatch time via Tau.Tool.lookup/1, so
      they pick up new code automatically.
  """
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :boot_load, 0)
    {:ok, %{loaded: %{}, watcher: nil}}
  end

  @impl true
  def handle_info(:boot_load, state) do
    settings = Tau.Settings.Cache.get()
    entries = Map.get(settings, :extensions, [])

    state =
      Enum.reduce(entries, state, fn entry, acc ->
        case load_entry(entry) do
          {:ok, key, info} -> %{acc | loaded: Map.put(acc.loaded, key, info)}
          _ -> acc
        end
      end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  Public entry: load an extension. `entry` is one of:

    * a module implementing `Tau.Extension` (already loaded)
    * a path to a directory or `.ex` file containing extension modules
    * `{module, opts}`
  """
  def reload(entry), do: GenServer.cast(__MODULE__, {:reload, entry})

  @doc """
  Reload every entry currently configured in `settings.extensions`.
  Used by `tau extensions reload`.
  """
  @spec reload_all() :: :ok
  def reload_all, do: GenServer.cast(__MODULE__, :reload_all)

  @doc """
  List loaded extensions. Each entry is `%{key: term(), info: map()}`,
  where `key` is the module (for `module` / `{module, opts}` entries)
  or path string (for directory/file entries) and `info` carries the
  modules registered from that entry.
  """
  @spec list() :: [%{key: term(), info: map()}]
  def list, do: GenServer.call(__MODULE__, :list)

  @impl true
  def handle_cast({:reload, entry}, state) do
    state =
      case load_entry(entry) do
        {:ok, key, info} -> %{state | loaded: Map.put(state.loaded, key, info)}
        _ -> state
      end

    :telemetry.execute([:tau, :extensions, :reloaded], %{count: 1}, %{entry: entry})

    {:noreply, state}
  end

  def handle_cast(:reload_all, state) do
    settings = Tau.Settings.Cache.get()
    entries = Map.get(settings, :extensions, [])

    state =
      Enum.reduce(entries, state, fn entry, acc ->
        case load_entry(entry) do
          {:ok, key, info} -> %{acc | loaded: Map.put(acc.loaded, key, info)}
          _ -> acc
        end
      end)

    :telemetry.execute([:tau, :extensions, :reloaded], %{count: length(entries)}, %{
      reason: :reload_all
    })

    {:noreply, state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    entries =
      Enum.map(state.loaded, fn {key, info} -> %{key: key, info: info} end)

    {:reply, entries, state}
  end

  defp load_entry(mod) when is_atom(mod), do: register_module(mod)

  defp load_entry({mod, _opts}) when is_atom(mod), do: register_module(mod)

  defp load_entry(path) when is_binary(path) do
    paths =
      cond do
        File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.ex"))
        File.regular?(path) -> [path]
        true -> []
      end

    modules =
      Enum.flat_map(paths, fn p ->
        try do
          Code.compile_file(p) |> Enum.map(fn {m, _} -> m end)
        rescue
          e ->
            Logger.warning("extension compile failed: #{p}: #{Exception.message(e)}")
            []
        end
      end)

    extension_modules = Enum.filter(modules, &is_extension?/1)
    Enum.each(extension_modules, &register_module/1)
    {:ok, path, %{path: path, modules: extension_modules}}
  end

  defp load_entry(_), do: :error

  defp register_module(mod) do
    if is_extension?(mod) do
      Enum.each(mod.tools(), fn t -> Tau.Tool.register(t) end)

      Enum.each(mod.hooks(), fn {ev, h} ->
        Registry.register(Tau.Hooks.Registry, ev, h)
      end)

      Enum.each(mod.commands(), fn {name, c} ->
        Registry.register(Tau.Commands.Registry, name, c)
      end)

      # Parse the skill at registration time so the registry value is a
      # %Tau.Skill{} struct — same shape sessions get from filesystem
      # discovery via Tau.Skills.Loader.discover/1 (ADR-0005). A bad
      # path is logged + skipped rather than crashing the loader.
      Enum.each(mod.skills(), fn {name, path} ->
        case Tau.Skills.Loader.parse(path) do
          {:ok, skill} ->
            Registry.register(Tau.Skills.Registry, name, %{skill | name: name})

          {:error, reason} ->
            Logger.warning(
              "Tau.Extensions.Loader: skipping skill #{inspect(name)} at #{inspect(path)}: #{inspect(reason)}"
            )
        end
      end)

      {:ok, mod, %{module: mod}}
    else
      :error
    end
  end

  defp is_extension?(mod) when is_atom(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :tools, 0) and
      function_exported?(mod, :hooks, 0)
  end

  defp is_extension?(_), do: false
end
