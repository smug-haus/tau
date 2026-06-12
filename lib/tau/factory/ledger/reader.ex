defmodule Tau.Factory.Ledger.Reader do
  @moduledoc """
  Read-only projections over the factory Ledger.

  All read operations are executed synchronously via `GenServer.call/2` to the
  `Ledger.Writer` process, which owns the sole connection to the SQLite database.
  This serialisation guarantees reads see all prior WAL-committed writes.

  ## API

  - `latest_unit_snapshots/1` — return the latest snapshotted state per
    `unit_id` (highest row id wins) across the whole ledger. Used by
    `Tau.Factory.Coordinator.init/1` to resume from the durable Ledger after a
    crash (D-344, D-315 / RPO=0).

  ## Why reads go through the Writer process

  SQLite's single-writer constraint and WAL mode do permit concurrent readers
  from separate connections, but opening a second connection introduces lifecycle
  complexity and a second file descriptor per Ledger instance. Given that resume
  reads are rare (once per Coordinator restart) the marginal cost of routing
  through the Writer's mailbox is negligible, and the design stays simple.
  """

  @doc """
  Return the latest snapshotted Unit FSM state per `unit_id`.

  Highest row `id` wins — `INSERT OR IGNORE` idempotency means that for a given
  `unit_id`, the row with the highest `id` records the most-recently-appended
  snapshot. Terminal states (`:merged`, `:escalated`) appear in the map just
  like non-terminal ones; the Coordinator filters them on resume.

  Returns `%{unit_id :: String.t() => state_atom :: atom()}`. Returns `%{}`
  when no snapshots exist (fresh ledger).
  """
  @spec latest_unit_snapshots(GenServer.server()) :: %{String.t() => atom()}
  def latest_unit_snapshots(server) do
    GenServer.call(server, :latest_unit_snapshots)
  end
end
