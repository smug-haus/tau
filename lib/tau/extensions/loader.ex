defmodule Tau.Extensions.Loader do
  @moduledoc """
  Compiles, registers, and hot-reloads `Tau.Extension` modules.

  On boot (synchronous in `init/1`, D-121):

    1. Read `settings.extensions` — a list of directory path strings.
    2. Auto-discover `~/.tau/extensions/` and `<cwd>/.tau/extensions/`.
    3. For each path, `Code.compile_file/1` every `.ex` file found,
       discover modules implementing `Tau.Extension`, register their
       tools/hooks/commands/skills.
    4. For each `{module, _opts}` entry (programmatic API, not from settings),
       just register (assume already loaded).

  All registration is crash-isolated: a failing extension is logged,
  telemetered, and skipped — never fatal (D-120, D-122, C-001).

  Hot reload:

    * `reload/1` unloads the prior generation then loads the new one
      (D-124). Sessions resolve tools at dispatch time via
      `Tau.Tool.lookup/1`, so they pick up new code automatically.

  SPEC-EXTENSIONS §3, §4, D-120..D-129.
  """
  use GenServer
  require Logger

  alias Tau.Settings.Cache

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    # Allow tests to pass a custom name via opts[:name] (for anonymous instances).
    # Production start_link is called with [] from the supervision tree, which
    # defaults to the module name as required by D-121.
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Load (or reload) an extension entry. `entry` is one of:

    * a module implementing `Tau.Extension` (already loaded)
    * a path to a directory or `.ex` file containing extension modules
    * `{module, opts}` (programmatic API; module assumed already loaded)
  """
  def reload(entry), do: GenServer.cast(__MODULE__, {:reload, entry})

  @doc """
  Unload an extension entry, removing its registrations from all four
  registries. No-op if the entry was never loaded. Used by tests to
  remove loaded extensions and prevent cross-test registry leakage.
  """
  @spec unload(term()) :: :ok
  def unload(entry), do: GenServer.cast(__MODULE__, {:unload, entry})

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

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # Synchronous load in init/1 — D-121, C-004.
    # This is safe because Settings.Cache starts before the Loader in the
    # :rest_for_one tree (position 5 vs 14). A crash in an extension callback
    # is caught inside load_entry/1 (D-120, D-122). The only way init/1 can
    # return {:stop, _} is if Settings.Cache.get/0 itself raises — which
    # would indicate a deeper startup ordering bug.
    #
    # opts[:entries] — if present, use as the entries list directly, bypassing
    # Settings.Cache and auto-discovery. Used only in tests. D-122.
    {explicit_entries, discovered_entries} =
      if Keyword.has_key?(opts, :entries) do
        {Keyword.fetch!(opts, :entries), []}
      else
        settings = Cache.get()
        {Map.get(settings, :extensions, []), discover_extension_dirs()}
      end

    # Deduplicate: explicit entries take priority over discovered ones.
    all_entries = explicit_entries ++ Enum.reject(discovered_entries, &(&1 in explicit_entries))

    state =
      Enum.reduce(all_entries, %{loaded: %{}, watcher: nil}, fn entry, acc ->
        case load_entry(entry) do
          {:ok, key, info} -> %{acc | loaded: Map.put(acc.loaded, key, info)}
          _error -> acc
        end
      end)

    {:ok, state}
  end

  @impl true
  def handle_cast({:reload, entry}, state) do
    # Unload prior generation before loading new one — D-124, C-008.
    state = unload_entry(entry, state)

    state =
      case load_entry(entry) do
        {:ok, key, info} -> %{state | loaded: Map.put(state.loaded, key, info)}
        _error -> state
      end

    :telemetry.execute([:tau, :extensions, :reloaded], %{count: 1}, %{entry: entry})

    {:noreply, state}
  end

  def handle_cast({:unload, entry}, state) do
    state = unload_entry(entry, state)
    {:noreply, state}
  end

  def handle_cast(:reload_all, state) do
    settings = Cache.get()
    explicit_entries = Map.get(settings, :extensions, [])
    discovered_entries = discover_extension_dirs()
    all_entries = explicit_entries ++ Enum.reject(discovered_entries, &(&1 in explicit_entries))

    state =
      Enum.reduce(all_entries, state, fn entry, acc ->
        acc = unload_entry(entry, acc)

        case load_entry(entry) do
          {:ok, key, info} -> %{acc | loaded: Map.put(acc.loaded, key, info)}
          _error -> acc
        end
      end)

    :telemetry.execute([:tau, :extensions, :reloaded], %{count: length(all_entries)}, %{
      reason: :reload_all
    })

    {:noreply, state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    entries = Enum.map(state.loaded, fn {key, info} -> %{key: key, info: info} end)
    {:reply, entries, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Auto-discovery — C-006, D-123
  # ---------------------------------------------------------------------------

  # Returns a list of directory path strings to scan.
  # Uses File.cwd/0 (non-raising) so a missing cwd does not propagate
  # as an unguarded raise from init/1 — D-122.
  defp discover_extension_dirs do
    home = System.user_home() || "."

    cwd_dirs =
      case File.cwd() do
        {:ok, cwd} -> [Path.join(cwd, ".tau/extensions")]
        {:error, _reason} -> []
      end

    [Path.join(home, ".tau/extensions") | cwd_dirs]
    |> Enum.filter(&File.dir?/1)
  end

  # ---------------------------------------------------------------------------
  # Entry load / unload
  # ---------------------------------------------------------------------------

  defp load_entry(mod) when is_atom(mod) do
    crash_safe_register(mod, mod)
  end

  defp load_entry({mod, _opts}) when is_atom(mod) do
    crash_safe_register(mod, {mod, nil})
  end

  defp load_entry(path) when is_binary(path) do
    paths =
      cond do
        File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.ex"))
        File.regular?(path) -> [path]
        true -> []
      end

    modules =
      Enum.flat_map(paths, fn p ->
        # Check for module-name collision BEFORE compiling — D-123, C-007.
        compile_with_collision_guard(p)
      end)

    extension_modules = Enum.filter(modules, &is_extension?/1)

    registered =
      Enum.flat_map(extension_modules, fn mod ->
        case crash_safe_register(mod, path) do
          {:ok, _key, _info} -> [mod]
          _error -> []
        end
      end)

    {:ok, path, %{path: path, modules: registered}}
  end

  defp load_entry(_), do: :error

  # Compile a single file, guarding against module-name collisions.
  # Returns a list of compiled module atoms.
  defp compile_with_collision_guard(path) do
    # Peek at what modules the file will define by reading the source and
    # checking defmodule declarations. If any are already loaded, skip.
    case peek_module_names(path) do
      {:ok, names} ->
        collisions = Enum.filter(names, &Code.ensure_loaded?/1)

        if collisions != [] do
          Logger.warning(
            "Tau.Extensions.Loader: skipping #{path} — module name collision: " <>
              inspect(collisions) <>
              ". A prior extension already defined these modules. " <>
              "Rename the conflicting module(s) to avoid a silent BEAM clobber."
          )

          []
        else
          do_compile_file(path)
        end

      :error ->
        # Could not peek — compile anyway; a real error will surface from compile.
        do_compile_file(path)
    end
  end

  defp do_compile_file(path) do
    try do
      Code.compile_file(path) |> Enum.map(fn {m, _} -> m end)
    rescue
      e ->
        Logger.warning(
          "Tau.Extensions.Loader: extension compile failed: #{path}: #{Exception.message(e)}"
        )

        []
    end
  end

  # Best-effort extraction of module names from source without full compilation.
  # Looks for `defmodule Foo.Bar` patterns. Returns {:ok, [atom]} or :error.
  #
  # Uses String.to_atom/1 (not String.to_existing_atom/1) so that module names
  # that have never been compiled — i.e. brand-new extension modules — are
  # still extracted and checked for collisions via Code.ensure_loaded?/1.
  # Module names in extension files are bounded in number, so adding atoms here
  # is acceptable. — D-123.
  defp peek_module_names(path) do
    case File.read(path) do
      {:ok, src} ->
        names =
          Regex.scan(~r/defmodule\s+([\w.]+)/, src, capture: :all_but_first)
          |> List.flatten()
          # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
          |> Enum.map(fn name -> String.to_atom("Elixir." <> name) end)

        {:ok, names}

      _error ->
        :error
    end
  end

  # ---------------------------------------------------------------------------
  # Crash-safe module registration — D-120, C-001, C-002
  # ---------------------------------------------------------------------------

  defp crash_safe_register(mod, key) do
    start_time = System.monotonic_time()
    meta = %{entry: key}

    :telemetry.execute(
      [:tau, :extensions, :load, :start],
      %{system_time: System.system_time()},
      meta
    )

    try do
      result = register_module(mod)
      duration = System.monotonic_time() - start_time

      case result do
        {:ok, _mod, info} ->
          :telemetry.execute(
            [:tau, :extensions, :load, :stop],
            %{duration: duration},
            Map.merge(meta, %{result: :ok, modules: [mod]})
          )

          {:ok, key, info}

        :error ->
          duration_val = System.monotonic_time() - start_time

          :telemetry.execute(
            [:tau, :extensions, :load, :stop],
            %{duration: duration_val},
            # result: :skipped distinguishes "loaded nothing" from :ok (SPEC-EXTENSIONS §5).
            Map.merge(meta, %{result: :skipped, skipped: true})
          )

          :error
      end
    rescue
      e ->
        duration = System.monotonic_time() - start_time
        stacktrace = __STACKTRACE__

        Logger.warning(
          "Tau.Extensions.Loader: extension #{inspect(mod)} registration raised: #{Exception.message(e)}"
        )

        :telemetry.execute(
          [:tau, :extensions, :load, :exception],
          %{duration: duration},
          Map.merge(meta, %{kind: :error, reason: e, stacktrace: stacktrace})
        )

        :error
    end
  end

  defp register_module(mod) do
    if is_extension?(mod) do
      # Callbacks are called directly. Any exception propagates to
      # crash_safe_register/2 which logs + skips the entire extension
      # and emits [:tau, :extensions, :load, :exception]. C-001, D-120.
      Enum.each(mod.tools(), fn t ->
        Tau.Tool.register(t)
      end)

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

  # ---------------------------------------------------------------------------
  # Unload — D-124, C-008, C-009
  # ---------------------------------------------------------------------------

  # Remove all registry entries for the given entry's prior generation.
  # Registry.unregister/2 is keyed by the calling process — since the Loader
  # registered the entries, the Loader must unregister them.
  defp unload_entry(entry, state) do
    key = entry_key(entry)

    case Map.get(state.loaded, key) do
      nil ->
        state

      info ->
        do_unload(info)
        %{state | loaded: Map.delete(state.loaded, key)}
    end
  end

  defp entry_key(mod) when is_atom(mod), do: mod
  defp entry_key({mod, _opts}) when is_atom(mod), do: {mod, nil}
  defp entry_key(path) when is_binary(path), do: path
  defp entry_key(other), do: other

  defp do_unload(%{module: mod}) do
    unload_module(mod)
  end

  defp do_unload(%{modules: modules}) do
    Enum.each(modules, &unload_module/1)
  end

  defp do_unload(_info), do: :ok

  defp unload_module(mod) do
    if is_extension?(mod) do
      # Unregister tools: use unregister_match to remove only this process's
      # entries for each tool name. C-009.
      tools =
        try do
          mod.tools()
        rescue
          _ -> []
        end

      Enum.each(tools, fn t ->
        tool_name = try_tool_name(t)

        if tool_name do
          Registry.unregister_match(Tau.Tools.Registry, tool_name, t)
        end
      end)

      # Hooks: unregister all of this process's entries for each event.
      hooks =
        try do
          mod.hooks()
        rescue
          _ -> []
        end

      Enum.each(hooks, fn {ev, _h} ->
        Registry.unregister(Tau.Hooks.Registry, ev)
      end)

      # Commands: unregister by name (unique registry).
      commands =
        try do
          mod.commands()
        rescue
          _ -> []
        end

      Enum.each(commands, fn {name, _c} ->
        Registry.unregister(Tau.Commands.Registry, name)
      end)

      # Skills: unregister by name (unique registry).
      skills =
        try do
          mod.skills()
        rescue
          _ -> []
        end

      Enum.each(skills, fn {name, _path} ->
        Registry.unregister(Tau.Skills.Registry, name)
      end)
    end
  end

  defp try_tool_name(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :name, 0) do
      mod.name()
    else
      nil
    end
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp is_extension?(mod) when is_atom(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :tools, 0) and
      function_exported?(mod, :hooks, 0)
  end

  defp is_extension?(_), do: false
end
