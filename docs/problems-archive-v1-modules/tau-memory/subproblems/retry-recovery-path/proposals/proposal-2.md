---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Store-internal `handle_info(:retry_sweep, ...)` timer inside Store.SQLite

## Approach

Add a periodic timer directly inside `Tau.Memory.Store.SQLite`: `init/1` sends
`Process.send_after(self(), :retry_sweep, interval)` after the DB opens, and
`handle_info(:retry_sweep, state)` runs the SQL query and re-dispatches
`embedder.embed/3` for each retriable row, then reschedules itself. No new process
or supervisor child. The retry sweep runs inside the existing store GenServer's
message loop, using its held DB connection directly — no new store API surface.

## Rationale

The store already owns the DB connection; it can query for retriable rows cheaply
without a mailbox round-trip. This keeps the retry path in one process, one module,
and one file — the smallest footprint of any option. There is no new process to
supervise, no new API to maintain, and no inter-process coordination. The coupling
is local: both the status-write and the retry-trigger live inside `Store.SQLite`.

## Sketch

```elixir
# In Tau.Memory.Store.SQLite

@default_retry_interval_ms 60_000

# init/1 — append to successful branch:
{:ok, %{db: db}, {:continue, :schedule_retry_sweep}}

# handle_continue/2 — add clause:
def handle_continue(:schedule_retry_sweep, state) do
  interval = Application.get_env(:tau, :retry_sweep_interval_ms, @default_retry_interval_ms)
  Process.send_after(self(), {:retry_sweep, interval}, interval)
  {:noreply, Map.put(state, :retry_interval, interval)}
end

# handle_info/2 — add clauses:
def handle_info({:retry_sweep, interval}, %{db: db} = state) do
  embedder = Application.get_env(:tau, :embedder, Tau.Memory.EmbeddingWorker)
  server = self()

  case do_list_retriable(db) do
    {:ok, entries} ->
      Enum.each(entries, fn {id, content} ->
        :telemetry.execute([:tau, :memory, :retry_enqueue], %{}, %{entry_id: id})
        embedder.embed(server, id, content)
      end)

    {:error, reason} ->
      Logger.warning("[Store.SQLite] retry sweep failed: #{inspect(reason)}")
  end

  Process.send_after(self(), {:retry_sweep, interval}, interval)
  {:noreply, state}
end

# Private helper — runs on the GenServer, uses held db reference directly:
defp do_list_retriable(db) do
  sql = """
  SELECT id, content FROM memory_entries
  WHERE embedding_status = 'pending'
     OR (embedding_status = 'failed'
         AND json_extract(metadata, '$.embedding_error_kind') = 'transient')
  """

  with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
       {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
       :ok <- Exqlite.Sqlite3.release(db, stmt) do
    {:ok, Enum.map(rows, fn [id, content] -> {id, content} end)}
  end
end
```

No changes to `Tau.Memory.Supervisor` or `Tau.Memory.Embedder`.

## Tradeoffs

### Strengths

- Minimum surface area: one module, no new process, no supervisor change.
- DB read uses the held connection directly — no mailbox round-trip to
  `list_retriable`.
- No new API: existing test harness is unchanged; no new mock surface.
- Failure of the sweep (DB error, embedder call error) does not crash the store —
  it logs and reschedules.

### Weaknesses

- Violates OTP non-negotiable #3 in spirit: a stateless periodic action (sweep)
  is now woven into the stateful DB-owner GenServer. The store's `handle_info`
  clause count grows with a concern unrelated to write/search/embedding.
- The retry sweep competes with the store's mailbox — during high write bursts,
  sweep messages may be delayed arbitrarily.
- A bug in the sweep logic can hang or crash the store process, taking the entire
  memory subsystem down. There is no isolation between retry bugs and store
  availability.
- Testing requires either controlling the timer interval or using `:sys.replace_state`
  to inject state; no clean `trigger_sweep/0` public API.
- Harder to remove or replace: the concern is inlined, not composed.

### Costs

- ~50 LOC added to an already-large `store/sqlite.ex` (currently ~700 LOC).
- No new modules or supervisor changes.
- Existing `store/sqlite.ex` tests need a timer-drain helper or a config override
  to `0` ms interval to exercise the sweep path without wall-clock waiting.

## Dependencies

- The Finch name mismatch must be fixed; otherwise sweeping re-enqueues entries
  that fail immediately.
- No other structural dependencies.

## Confidence

medium-low — the approach is simple but the OTP non-negotiable concern (#3 —
don't wrap stateless logic in the GenServer managing something else) is a genuine
risk. Confidence would rise if the sweep logic were kept strictly read-only and
side-effect-free in its DB path (no mutations from the sweep itself), since that
limits blast radius of a sweep bug.

## Prior art / references

- `Phoenix.PubSub` internal cleanup timers: some OTP libraries do schedule
  maintenance work inside the owner GenServer when the work is tightly coupled
  to the connection resource. Acknowledged as a tradeoff, not a pattern to emulate.
- OTP non-negotiable #3: "MUST NOT wrap stateless logic in a GenServer."
