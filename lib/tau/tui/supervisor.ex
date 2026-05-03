defmodule Tau.TUI.Supervisor do
  @moduledoc """
  Dedicated DynamicSupervisor for the Ratatouille runtime subtree.

  The TUI is launched lazily; this supervisor exists at boot so the
  Ratatouille runtime is always supervised when started, never orphaned
  to a Task spawned from `Tau.Application.start/2`. See
  ADR-0018 for the rationale.
  """
  use DynamicSupervisor

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start a Ratatouille runtime subtree under this supervisor."
  @spec start_runtime(keyword()) :: DynamicSupervisor.on_start_child()
  def start_runtime(runtime_opts) do
    spec = %{
      id: Ratatouille.Runtime.Supervisor,
      start: {Ratatouille.Runtime.Supervisor, :start_link, [[runtime: runtime_opts]]},
      restart: :transient,
      type: :supervisor
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
