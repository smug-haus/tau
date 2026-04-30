defmodule Tau.Settings.Watcher do
  @moduledoc """
  Watches the settings cascade for file changes and notifies
  `Tau.Settings.Cache` to re-load.

  Wraps `:file_system` (provided by the `file_system` dep). Coalesces rapid
  successive changes via a small debounce timer to avoid thrashing.

  M0 stub: starts but watches nothing. Wired up in M3.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}
end
