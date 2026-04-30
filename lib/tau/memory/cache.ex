defmodule Tau.Memory.Cache do
  @moduledoc """
  Caches loaded `TAU.md` (and `CLAUDE.md`-via-import) memory files in ETS,
  keyed by `{path, mtime, size}`.

  The cascade walks from `cwd` up to the git root, collecting `TAU.md` at
  each level, plus `~/.tau/TAU.md`. Imports of the form `@path/to/file.md`
  are resolved recursively (max depth 5; cycles detected via canonicalised
  path set). Per-file cap of 25 KiB / 200 lines is enforced *post-import*.

  M0 stub: creates the ETS table and exits to its idle loop.

  ETS table options follow the Phase-11 hot-path expectations:

    * `:public` — readers are session FSMs scattered across schedulers
    * `:set` — one row per `{path, mtime, size}` key
    * `read_concurrency: true` — reads dominate writes
    * `decentralized_counters: true` — per-scheduler counters keep the
      hot read path off a single contended atomic on OTP 23+
  """
  use GenServer

  @table :tau_memory_cache

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      decentralized_counters: true
    ])

    {:ok, %{table: @table}}
  end
end
