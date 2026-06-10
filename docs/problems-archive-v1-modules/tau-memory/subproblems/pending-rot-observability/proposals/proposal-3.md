---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: In-process `handle_info(:check_pending_age, ...)` timer inside `Store.SQLite`

## Approach

Add a `Process.send_after(self(), :check_pending_age, @check_interval_ms)` to
`Store.SQLite.init/1`, rescheduled in each `handle_info(:check_pending_age,
...)` clause. The handle_info clause queries `stale_pending_entries` directly
against `state.db` (no external GenServer call; same process, same db
reference), emits `[:tau, :memory, :pending_rot, :detected]` telemetry if
any stale entries are found, then reschedules. No new module; no new supervised
child; no new public API surface. The detection logic is self-contained inside
the existing `Store.SQLite` GenServer.

## Rationale

The complecting hypothesis is that absence of a completion-tracking mechanism
and absence of an alerting mechanism are woven together. This proposal addresses
the alerting gap by collocating the detection timer with the process that owns
the database connection. Because `Store.SQLite` already holds `state.db`, the
stale-entry query needs no IPC — it runs directly against the connection without
a `GenServer.call` round-trip. This is the minimal viable alerting surface:
one `handle_info` clause, one SQL query, one telemetry emission. It does not
introduce a new process, a new behaviour, or a new module boundary.

## Sketch

### `init/1` change

```elixir
@check_interval_ms 60_000
@stale_threshold_ms 35_000   # > @request_timeout_ms (30_000) + grace

@impl GenServer
def init(opts) do
  # ... existing init body ...
  Process.send_after(self(), :check_pending_age, @check_interval_ms)
  {:ok, %{db: db}}
end
```

### New `handle_info` clause

```elixir
@impl GenServer
def handle_info(:check_pending_age, %{db: db} = state) do
  case query_stale_pending(db, @stale_threshold_ms) do
    {:ok, []} ->
      :ok

    {:ok, rows} ->
      count = length(rows)
      oldest_age_ms = Enum.max(Enum.map(rows, & &1.age_ms))
      entry_ids = Enum.map(rows, & &1.id)

      :telemetry.execute(
        [:tau, :memory, :pending_rot, :detected],
        %{count: count},
        %{entry_ids: entry_ids, oldest_age_ms: oldest_age_ms}
      )

      Logger.warning(
        "[Memory.Store] #{count} stale pending embedding(s); " <>
          "oldest #{oldest_age_ms} ms; entry_ids=#{inspect(entry_ids)}"
      )

    {:error, reason} ->
      Logger.error("[Memory.Store] stale_pending query error: #{inspect(reason)}")
  end

  Process.send_after(self(), :check_pending_age, @check_interval_ms)
  {:noreply, state}
end
```

### New private helper

```elixir
@sql_stale_pending """
  SELECT id,
         CAST((julianday('now') - julianday(inserted_at)) * 86400000 AS INTEGER) AS age_ms
  FROM   memory
  WHERE  embedding_status = 'pending'
    AND  CAST((julianday('now') - julianday(inserted_at)) * 86400000 AS INTEGER) > ?1
  ORDER  BY age_ms DESC
"""

@spec query_stale_pending(reference(), non_neg_integer()) ::
        {:ok, [%{id: binary(), age_ms: non_neg_integer()}]} | {:error, term()}
defp query_stale_pending(db, threshold_ms) do
  with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, @sql_stale_pending),
       :ok <- Exqlite.Sqlite3.bind(stmt, [threshold_ms]),
       {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt, 100) do
    Exqlite.Sqlite3.release(db, stmt)
    {:ok, Enum.map(rows, fn [id, age_ms] -> %{id: id, age_ms: age_ms} end)}
  end
end
```

Note: uses `inserted_at` (already present) rather than a new column.
This requires `inserted_at` to be stored in ISO8601 UTC and the query
to be validated against the schema.

## Tradeoffs

### Strengths

- Zero new modules, zero new supervised children, zero new public API surface.
- Detection query runs directly against `state.db` — avoids a `GenServer.call`
  round-trip and the associated mailbox pressure.
- Single diff location: only `store/sqlite.ex` changes; no supervisor or
  application changes required.
- Easy to test: existing `Store.SQLite` test infrastructure suffices; no mock
  store required.
- Satisfies OTP non-negotiable #5 with the smallest possible code surface.

### Weaknesses

- Adds a recurring `:check_pending_age` message to the `Store.SQLite` mailbox.
  Under very high write volume, if the mailbox is already pressured, the timer
  message may be delayed — detection latency becomes indefinite rather than
  bounded at the configured interval.
- The periodic SQL query runs in the owner GenServer, competing with writes and
  searches for DB time. On a loaded system, this could delay write replies.
  (Bounded: the query is a full-scan filtered by `embedding_status = 'pending'`
  and date arithmetic; without an index on `(embedding_status, inserted_at)` it
  is O(n) on pending rows.)
- All detection logic is inside `Store.SQLite`, coupling the alerting concern
  to the storage concern; a future refactor extracting `Store.SQLite` would need
  to extract the timer too.
- The `@check_interval_ms` and `@stale_threshold_ms` module attributes are
  compile-time constants; changing them requires recompilation (could be
  `Application.get_env` instead, at the cost of a tiny runtime lookup).

### Costs

- ~40 lines added to `store/sqlite.ex`.
- No new dependencies; no schema migrations.
- Test surface: 1 new `handle_info` test in `store/sqlite_test.exs`; existing
  test helpers may need a small extension to drive the timer.
- If an index on `(embedding_status, inserted_at)` is desired for performance,
  that is an additional migration (~3 lines).

## Dependencies

- `inserted_at` column must exist and be stored as ISO8601 UTC — verify in
  migrations. If not, an alternative is to accept a small migration adding an
  `inserted_at_unix_ms INTEGER` column populated by a trigger.
- No external dependencies.

## Confidence

**Medium-high.** The `handle_info` + `send_after` pattern is standard Elixir;
the query is simple SQL. Confidence would be `high` after:
1. Confirming the `inserted_at` column format in the migration files.
2. Running an `EXPLAIN QUERY PLAN` against the stale-pending query to confirm
   it hits an index or verifying the pending-row count is small enough for a
   full scan.

## Prior art / references

- `Process.send_after` periodic health checks: canonical pattern in Elixir
  GenServer design; e.g. Ecto connection pool health pings.
- SQLite `julianday` arithmetic: SQLite documentation §Date and Time Functions.
- The `:check_pending_age` message name is deliberately distinct from OTP
  system messages (`:timeout`, `:hibernate`) to avoid confusion.
