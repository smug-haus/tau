defmodule Tau.Settings.Cache do
  @moduledoc """
  Owns the merged settings map and writes it through to `:persistent_term`
  so any process can read it lock-free.

  On boot we call `Tau.Settings.Loader.load/1` once. `Tau.Settings.Watcher`
  notifies us of subsequent file changes; we re-load and re-publish.
  """
  use GenServer

  @persistent_key {Tau, :settings}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Reload from disk and republish."
  @spec reload() :: :ok
  def reload, do: GenServer.cast(__MODULE__, :reload)

  @doc "Get the current merged settings (lock-free)."
  @spec get() :: map()
  def get, do: :persistent_term.get(@persistent_key, %{})

  @impl true
  def init(_opts) do
    publish(load())
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:reload, state) do
    publish(load())
    {:noreply, state}
  end

  defp load do
    cwd = File.cwd!()
    Tau.Settings.Loader.load(cwd)
  end

  defp publish(%{settings: settings, sources: sources}) do
    :persistent_term.put(@persistent_key, settings)

    if Process.whereis(Tau.Permissions.RuleSet) do
      send(Tau.Permissions.RuleSet, {:settings_reloaded, settings})
    end

    :telemetry.execute(
      [:tau, :settings, :reloaded],
      %{count: length(sources)},
      %{sources: sources}
    )
  end
end
