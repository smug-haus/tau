defmodule Tau.Settings.Cache do
  @moduledoc """
  Owns the merged settings struct and writes it through to `:persistent_term`
  for lock-free reads from the hot path.

  Loader order (later overrides earlier; arrays concat; deny always wins):

    1. Managed (`/etc/tau/managed.json`, OS-specific elsewhere)
    2. User (`~/.tau/settings.json`)
    3. Project (`<cwd>/.tau/settings.json`)
    4. Local (`<cwd>/.tau/settings.local.json`)

  On boot we read once. `Tau.Settings.Watcher` informs us of subsequent file
  changes and we re-publish. The merged struct lives in `:persistent_term`
  under `{Tau, :settings}` so any process can `:persistent_term.get/1` it
  without a GenServer call.

  M0 stub: stores an empty `%Tau.Settings{}` and emits `:reloaded` once.
  """
  use GenServer

  @persistent_key {Tau, :settings}

  @doc "Get the current merged settings (lock-free)."
  @spec get() :: map()
  def get, do: :persistent_term.get(@persistent_key, %{})

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :persistent_term.put(@persistent_key, %{})

    :telemetry.execute([:tau, :settings, :reloaded], %{count: 1}, %{
      sources: []
    })

    {:ok, %{}}
  end
end
