---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Telemetry handler on `[:tau, :memory, :write, :stop]` with in-process age tracking via ETS

## Approach

Replace polling with a push-based approach. At `Store.SQLite` init time, attach
a `:telemetry` handler for `[:tau, :memory, :write, :stop]` that records
`{entry_id, dispatched_at_monotonic}` into an ETS table owned by the store
process. A second handler for `[:tau, :memory, :embedding, :stop]` removes the
entry from ETS when embedding completes. A lightweight `handle_info(:age_check,
...)` timer (default 30 s, matching `@request_timeout_ms`) fires once per
timeout window and scans the ETS table for entries older than the threshold —
the check is O(in-flight count) not O(total memory rows), since only active
dispatches are tracked. Stale entries emit `[:tau, :memory, :pending_rot,
:detected]`. The ETS table is in-process state: no separate GenServer, no
database query during detection.

## Rationale

The current failure mode involves two complected absences: no completion-
tracking mechanism and no alerting mechanism. Proposals 1–3 add alerting by
querying the database periodically. This proposal instead tracks in-flight
dispatches in memory (ETS), decoupling the alerting from the database entirely:
the ETS table is the "in-flight registry," and the telemetry events that already
fire on write and embedding completion become the insertion and removal triggers.
This means detection of stuck entries does not require reading from SQLite at
all — the ETS lookup is O(in-flight) and sub-microsecond per entry. It also
means the telemetry emission on `[:tau, :memory, :embedding, :stop]` provides
an additional signal: entries that leave the ETS normally (embedding completed)
are inherently observable.

## Sketch

### ETS table ownership

The table is created in `Store.SQLite.init/1` and owned by the GenServer process:

```elixir
@impl GenServer
def init(opts) do
  # ... existing init ...
  table = :ets.new(:tau_memory_pending_dispatches, [:set, :protected, :named_table])
  :ok = attach_telemetry_handlers(table)
  Process.send_after(self(), :age_check, @request_timeout_ms)
  {:ok, %{db: db, pending_table: table}}
end
```

### Telemetry handler — on write stop, record dispatch

```elixir
defp attach_telemetry_handlers(table) do
  :telemetry.attach(
    "tau-memory-pending-write",
    [:tau, :memory, :write, :stop],
    fn _event, _measurements, %{id: entry_id}, _config ->
      :ets.insert(table, {entry_id, :erlang.monotonic_time(:millisecond)})
    end,
    nil
  )

  :telemetry.attach(
    "tau-memory-pending-embedding",
    [:tau, :memory, :embedding, :stop],
    fn _event, _measurements, %{entry_id: entry_id}, _config ->
      :ets.delete(table, entry_id)
    end,
    nil
  )

  :ok
end
```

### Age check timer

```elixir
@impl GenServer
def handle_info(:age_check, %{pending_table: table} = state) do
  now_ms = :erlang.monotonic_time(:millisecond)
  threshold_ms = Application.get_env(:tau, :embedding_stale_threshold_ms, 35_000)

  stale =
    :ets.tab2list(table)
    |> Enum.filter(fn {_id, inserted_ms} -> now_ms - inserted_ms > threshold_ms end)

  if stale != [] do
    count = length(stale)
    oldest_age_ms = Enum.max(Enum.map(stale, fn {_id, ms} -> now_ms - ms end))
    entry_ids = Enum.map(stale, fn {id, _} -> id end)

    :telemetry.execute(
      [:tau, :memory, :pending_rot, :detected],
      %{count: count},
      %{entry_ids: entry_ids, oldest_age_ms: oldest_age_ms}
    )

    Logger.warning(
      "[Memory.Store] #{count} stale pending embedding(s); " <>
        "oldest #{oldest_age_ms} ms"
    )
  end

  Process.send_after(self(), :age_check, @request_timeout_ms)
  {:noreply, state}
end
```

### Cleanup in `terminate/2`

```elixir
@impl GenServer
def terminate(_reason, %{db: db, pending_table: table}) do
  :telemetry.detach("tau-memory-pending-write")
  :telemetry.detach("tau-memory-pending-embedding")
  :ets.delete(table)
  Exqlite.Sqlite3.close(db)
  :ok
end
```

## Tradeoffs

### Strengths

- Detection is O(in-flight count) not O(total memory rows); the age check is
  a pure in-memory scan — no database query during detection.
- No schema migration required; no `inserted_at` format dependency.
- Telemetry handler on `[:tau, :memory, :embedding, :stop]` doubles as a
  completion signal; normal completions implicitly prove the pipeline is working.
- Produces real-time (within one timer interval) detection rather than
  scan-on-demand.
- Satisfies OTP non-negotiable #1 (ETS table is owned by the GenServer process,
  not a global).

### Weaknesses

- Complexity is higher than Proposals 1–3: ETS lifecycle, two telemetry handler
  registrations, handler cleanup in `terminate/2`.
- The ETS table is in-process memory state: if `Store.SQLite` crashes and
  restarts, the table is rebuilt from zero — entries that were `"pending"` at
  crash time are not in the new ETS table, so they become invisible to the
  in-memory tracker until the next write event. (Restart-time rot is missed
  unless combined with a startup DB query similar to Proposal 2.)
- `[:tau, :memory, :write, :stop]` fires only when `id` is present in
  metadata — this is the current behaviour (`:stop` metadata is `%{id: binary()}`
  for writes). If a write fails and emits `:exception` instead of `:stop`, the
  entry is never inserted into ETS; that is correct behaviour (no dispatch
  occurs on failed writes), but the handler must be robust to missing metadata.
- `:ets.tab2list/1` on a large in-flight set copies the entire table for the
  scan; under pathological conditions (thousands of stuck entries) this could
  spike memory allocation during the check. Bounded by the in-flight set size,
  which is bounded by write rate × timeout window.
- Attaching global telemetry handlers from inside a GenServer is unusual and
  can be surprising; the handler closures capture `table` (an ETS reference)
  which becomes a dangling reference if `terminate/2` deletes the table before
  the handler is detached.

### Costs

- ~80 lines in `store/sqlite.ex` (ETS init, two telemetry attach/detach pairs,
  age-check `handle_info`, `terminate/2` update).
- No new dependencies; no schema migrations.
- Test surface: 2 telemetry handler unit tests, 1 `handle_info(:age_check)`
  test, 1 integration test verifying ETS cleanup on terminate.
- Telemetry handler registration must be idempotent-safe (double-attach on
  rapid restart could error; wrap in `try/rescue` or use `:telemetry.attach`
  with a force-detach preceding it).

## Dependencies

- ETS named table `:tau_memory_pending_dispatches` must not conflict with any
  other table in the application; verify no collision.
- `[:tau, :memory, :embedding, :stop]` event metadata must carry `entry_id` —
  currently it does (`%{entry_id: entry_id}` in `embedding_worker.ex:54`);
  this is a dependency on that event shape remaining stable.

## Confidence

**Medium.** The ETS + telemetry-handler pattern is well-established in
Elixir/Erlang. The restart-time gap is a genuine weakness that reduces
confidence in covering the full acceptance criterion (which includes
pre-existing stuck entries). Confidence would be `high` after adding a startup
DB query to seed the ETS from `WHERE embedding_status = 'pending'` on init,
closing the restart gap — but that adds complexity.

## Prior art / references

- ETS-owner process pattern: OTP documentation §ETS, "Ownership"; see also
  `Tau.CircuitBreaker.Store` in this codebase for the owned-ETS pattern.
- Telemetry handler registration from a GenServer: used in several Erlang
  ecosystem libraries (Broadway, Oban) for per-instance metric tracking.
- `:erlang.monotonic_time/1` for age computation: preferred over `DateTime.utc_now()`
  for interval measurement as it is not subject to system clock adjustments.
