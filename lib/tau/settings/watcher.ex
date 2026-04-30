defmodule Tau.Settings.Watcher do
  @moduledoc """
  Watches the settings cascade for file changes and notifies
  `Tau.Settings.Cache` to re-load.

  Wraps `:file_system`. Coalesces rapid successive change events with a
  small debounce timer to avoid thrashing on editor save-bursts.

  Watches:

    * `~/.tau/`
    * `<cwd>/.tau/`

  Reloads on any `created`, `modified`, `removed`, or `renamed` event
  whose path matches `*settings*.json` or `TAU.md`.
  """
  use GenServer
  require Logger

  @debounce_ms 300

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    cwd = File.cwd!()
    home = System.user_home!() || "."

    dirs =
      [Path.join(home, ".tau"), Path.join(cwd, ".tau"), cwd]
      |> Enum.uniq()
      |> Enum.filter(&File.dir?/1)

    state =
      case maybe_start_watcher(dirs) do
        {:ok, pid} ->
          %{watcher: pid, dirs: dirs, debounce: nil}

        other ->
          Logger.debug("Tau.Settings.Watcher disabled: #{inspect(other)}")
          %{watcher: nil, dirs: dirs, debounce: nil}
      end

    {:ok, state}
  end

  defp maybe_start_watcher(dirs) do
    cond do
      not Code.ensure_loaded?(FileSystem) ->
        {:error, :file_system_not_loaded}

      dirs == [] ->
        {:error, :no_dirs}

      true ->
        try do
          case FileSystem.start_link(dirs: dirs) do
            {:ok, pid} ->
              FileSystem.subscribe(pid)
              {:ok, pid}

            other ->
              {:error, other}
          end
        rescue
          e -> {:error, Exception.message(e)}
        catch
          :exit, reason -> {:error, reason}
          kind, reason -> {:error, {kind, reason}}
        end
    end
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    if relevant?(path) do
      state = reset_debounce(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher, :stop}, state), do: {:noreply, state}

  def handle_info(:reload, state) do
    Tau.Settings.Cache.reload()
    {:noreply, %{state | debounce: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp relevant?(path) do
    base = Path.basename(path)
    base == "TAU.md" or String.contains?(base, "settings") or String.ends_with?(base, ".json")
  end

  defp reset_debounce(%{debounce: ref} = state) do
    if ref, do: Process.cancel_timer(ref)
    new_ref = Process.send_after(self(), :reload, @debounce_ms)
    %{state | debounce: new_ref}
  end
end
