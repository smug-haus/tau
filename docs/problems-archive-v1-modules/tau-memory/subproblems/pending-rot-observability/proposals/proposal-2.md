---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Timestamp-differentiated status values — introduce `"pending_dispatched_at"` metadata

## Approach

Change the data shape of the `"pending"` state rather than adding a sweeper
process. When the store dispatches an embedding (currently in
`handle_continue/2`), it writes a `dispatched_at` ISO8601 timestamp into a new
nullable `embedding_dispatched_at` column. The EmbeddingWorker and SQLite store
are unchanged otherwise. A new telemetry tap — implemented as a
`:telemetry.attach/4` handler registered at application start — subscribes to
the existing `[:tau, :memory, :write, :stop]` event, reads the new column on
each write, and immediately detects in-progress entries. Staleness is surfaced
by reading `dispatched_at` vs `now()` at any query point; the existing
`[:tau, :memory, :write, :stop]` event's metadata is extended to include
`dispatched_at`. A startup audit (called once from `Store.SQLite.init/1`)
queries for entries where `embedding_status = 'pending'` and
`dispatched_at < now - threshold`, logging a structured warning and emitting
`[:tau, :memory, :pending_rot, :detected]` for any found.

## Rationale

The complecting hypothesis identifies that the in-flight and stuck states are
indistinguishable because the `"pending"` value carries no age information.
Separating them at the data-shape level removes the complection at its root:
once `dispatched_at` is available in the row, any reader — the store itself, a
query tool, a monitoring query — can distinguish the two cases without a
separate sweeper process. The startup audit catches entries that survived a
prior crash (e.g. the node went down mid-embedding). This approach avoids
adding a new long-running process and relies on existing telemetry
infrastructure.

## Sketch

### Schema migration (new)

```sql
-- Migration 009 (or next unused number)
ALTER TABLE memory ADD COLUMN embedding_dispatched_at TEXT;
```

### `handle_continue/2` change in `store/sqlite.ex`

```elixir
@impl GenServer
def handle_continue({:dispatch_embedding, id, content}, %{db: db} = state) do
  embedder = Application.get_env(:tau, :embedder, Tau.Memory.EmbeddingWorker)
  server = self()
  now = DateTime.utc_now() |> DateTime.to_iso8601()

  # Record dispatch time before spawning, so the column is populated even if
  # the task crashes immediately.
  :ok = do_set_dispatched_at(db, id, now)

  Task.Supervisor.async_nolink(Tau.Tools.TaskSupervisor, fn ->
    embedder.embed(server, id, content)
  end)

  {:noreply, state}
end
```

```elixir
# New private helper
defp do_set_dispatched_at(db, id, iso8601) do
  # UPDATE memory SET embedding_dispatched_at = ?1 WHERE id = ?2
  with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, @sql_set_dispatched_at),
       :ok <- Exqlite.Sqlite3.bind(stmt, [iso8601, id]),
       :done <- Exqlite.Sqlite3.step(db, stmt) do
    Exqlite.Sqlite3.release(db, stmt)
    :ok
  end
end
```

### Startup audit in `init/1`

```elixir
# Called at the end of a successful init/1, before {:ok, state} is returned.
defp audit_stale_pending(db) do
  threshold_ms = Application.get_env(:tau, :embedding_stale_threshold_ms, 35_000)

  case query_stale_pending(db, threshold_ms) do
    {:ok, []} ->
      :ok

    {:ok, rows} ->
      count = length(rows)
      oldest_age_ms = Enum.max(Enum.map(rows, & &1.age_ms))

      :telemetry.execute(
        [:tau, :memory, :pending_rot, :detected],
        %{count: count},
        %{entry_ids: Enum.map(rows, & &1.id), oldest_age_ms: oldest_age_ms, source: :startup_audit}
      )

      Logger.warning(
        "[Memory.Store] #{count} stale pending embedding(s) at startup; " <>
          "oldest #{oldest_age_ms} ms"
      )

    {:error, _reason} ->
      :ok
  end
end
```

The `query_stale_pending/2` SQL:

```sql
SELECT id,
       CAST((julianday('now') - julianday(embedding_dispatched_at)) * 86400000 AS INTEGER)
         AS age_ms
FROM   memory
WHERE  embedding_status = 'pending'
  AND  embedding_dispatched_at IS NOT NULL
  AND  age_ms > ?1
ORDER  BY age_ms DESC
```

Entries where `embedding_dispatched_at IS NULL` are a legacy condition (written
before the migration). They are logged separately:

```elixir
Logger.warning("[Memory.Store] #{undispatch_count} pending entries lack dispatched_at; " <>
  "may predate migration 009")
```

## Tradeoffs

### Strengths

- Decomplects the data shape: the row itself distinguishes in-flight from
  potentially-stuck at any read point; no runtime process required.
- The startup audit catches rot from prior crashes on every boot — high
  signal for operators doing a rolling restart after a wiring fix.
- Extends existing code paths minimally: one additional DB write per embedding
  dispatch, one new SQL column, one startup query.
- No new supervised process; supervision tree unchanged (simpler operational
  footprint).
- `embedding_dispatched_at` is useful to the `retry-recovery-path`
  sub-problem as the basis for its re-enqueue eligibility check.

### Weaknesses

- Detection is only at startup and when explicitly queried; no continuous
  runtime alerting between restarts. If a node runs for hours, new rot
  accumulates silently until the next restart.
- Requires a schema migration adding a nullable column; existing `"pending"`
  rows from before the migration will have `NULL` in `embedding_dispatched_at`,
  requiring a fallback branch.
- Writing `dispatched_at` before spawning the Task adds a synchronous DB write
  to `handle_continue/2`; this is on the hot path (every write to the store
  triggers an embedding dispatch). Under high write volume this may be
  measurable.
- The startup audit does not cover rot that accumulates while the node is
  running; combining with Proposal 1 would be needed for continuous coverage,
  but that introduces both approaches' costs.

### Costs

- 1 schema migration (ALTER TABLE — safe on SQLite; no lock contention on boot).
- ~40 lines of new code in `sqlite.ex` (migration, helper, audit).
- Test surface: 1 migration test, 1 unit test for `audit_stale_pending/1`,
  1 property test confirming `dispatched_at` is set before `embed/3` is called.
- No new dependencies.

## Dependencies

- Schema migration must be numbered correctly (next after existing migrations).
- The `inserted_at` vs `dispatched_at` distinction must be documented in
  `SPEC-MEMORY-STORE.md` §3 as a new constraint.

## Confidence

**Medium.** The schema change and startup-audit pattern are well-understood. The
`handle_continue/2` synchronous write on the hot path requires benchmarking
under realistic write rates to confirm it is acceptable. Confidence would be
`high` after a micro-benchmark showing the extra write is < 1 ms on the expected
hardware.

## Prior art / references

- Outbox pattern (reliable message dispatch): the `dispatched_at` column is a
  minimal form of the outbox pattern's "dispatched" marker.
- SQLite `ALTER TABLE ... ADD COLUMN` — SQLite documentation: safe, O(1) on
  all SQLite versions.
- Startup consistency audits: common in database-backed services; analogous to
  Ecto's startup migration check in Phoenix apps.
