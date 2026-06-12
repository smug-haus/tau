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
  - `merge_outcome_for/2` — return the latest durable merge outcome for a unit
    (D-355 / RPO=0). Used by `Tau.Factory.Unit` at `:awaiting_merge` entry to
    reconcile without re-submitting an already-landed merge (D-344).

  ## Why reads go through the Writer process

  SQLite's single-writer constraint and WAL mode do permit concurrent readers
  from separate connections, but opening a second connection introduces lifecycle
  complexity and a second file descriptor per Ledger instance. Given that resume
  reads are rare (once per Coordinator restart) the marginal cost of routing
  through the Writer's mailbox is negligible, and the design stays simple.
  """

  alias Tau.Factory.Ledger.Writer

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

  @doc """
  Return the latest durable merge outcome for `unit_id` (D-355 / RPO=0).

  Used by `Tau.Factory.Unit` at `:awaiting_merge` on-entry to reconcile against
  the Ledger before re-calling `merge_fun` (D-344 — re-does no terminal work).

  Returns:
    - `{:merged, commit_sha}` — the unit was merged; `commit_sha` is the tip.
    - `{:rejected, reason}` — the unit's merge was rejected.
    - `:none` — no outcome row exists (fresh; proceed with `merge_fun`).
  """
  @spec merge_outcome_for(GenServer.server(), String.t()) ::
          {:merged, String.t()} | {:rejected, term()} | :none
  def merge_outcome_for(server, unit_id) do
    Writer.merge_outcome_for(server, unit_id)
  end
end
