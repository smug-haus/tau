defmodule Tau.Extensions.Loader do
  @moduledoc """
  Compiles, registers, and hot-reloads `Tau.Extension` modules.

  On boot, reads `settings.extensions` (list of `{module, opts}` tuples or
  directory paths). For each path, compiles `.ex` files, locates modules
  implementing the `Tau.Extension` behaviour, and registers their tools,
  hooks, commands, and skills with the appropriate `Registry`.

  Hot reload uses `:file_system` to watch extension paths. On change:
  unregister old keys, recompile, register new modules. Live sessions
  resolve tools at dispatch time so they pick up new code automatically.

  M0 stub: empty state.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{loaded: %{}}}
end
