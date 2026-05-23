defmodule Tau.Memory.Supervisor do
  @moduledoc """
  Supervision subtree for the persistent memory store.

  Hosts `Tau.Memory.Store.SQLite` under a `one_for_one` strategy. Sits in
  `Tau.Application`'s `:rest_for_one` child list after `Tau.Settings.Watcher`
  (which resolves `data_dir/0` — required before the store can open its DB)
  and before `Finch` (the embedding pipeline uses Finch).

  A crash of `Store.SQLite` restarts only that child. A crash of this supervisor
  cascades to Finch and everything below it in the application tree — acceptable,
  since a broken memory store should not allow sessions to start with an
  inconsistent DB.

  See `docs/spec/SPEC-MEMORY-STORE.md` and `docs/adr/0020-memory-store-sqlite-driver.md`.
  """

  use Supervisor

  @doc "Start the memory supervisor (called by `Tau.Application`)."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {Tau.Memory.Store.SQLite, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
