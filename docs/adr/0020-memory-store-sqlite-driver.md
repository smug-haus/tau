# ADR-0020: Memory Store uses SQLite via Exqlite with a single write-owning GenServer

- **Status:** Accepted
- **Date:** 2026-05-18
- **Deciders:** @smug-haus
- **Related:**
  - Issue: #67
  - Supersedes: ADR-0006 deferral of `Tau.Memory.Cache`
  - Cites: ADR-0010 (ETS lifecycle-anchor pattern)
  - SPEC: `docs/spec/SPEC-MEMORY-STORE.md`

## Context

ADR-0006 deleted `Tau.Memory.Cache` — a `GenServer` that owned a named ETS
table that was never written to nor read from. The decision was correct: dead
code that implied a non-existent cache. The deferral clause read "re-add when
measurements show disk reads are a bottleneck."

Issue #67 requests a qualitatively different capability: not a cache, but a
**write-durable, queryable memory store** — structured notes that survive session
boundaries and (in later PRs) support full-text and semantic retrieval. No
measurement threshold applies; this is a new feature, not a premature
optimisation.

SQLite is the natural fit: it is embedded (no external process), FTS5 ships
in the bundled build of `exqlite`'s NIF (no separate dependency), `sqlite-vec`
can be added for vector search (PR3), and WAL mode gives concurrent readers
alongside a single writer without blocking.

The `exqlite` library (`~> 0.27`) wraps the NIF. It ships a bundled SQLite with
FTS5 compiled in.

## The single-writer routing question

ADR-0010 established the lifecycle-anchor pattern: `Tau.Cost.Tracker` is a
`GenServer` whose **only** job is to own an ETS table. Critically, the cost
tracker does **not** route writes through its mailbox — writers call
`:ets.update_counter/3` directly and the telemetry handler runs in the emitting
process. Bypassing the mailbox was correct for ETS because ETS is designed for
concurrent access; the `write_concurrency: true` flag makes atomic counter
bumps lock-free.

The memory store makes the opposite choice: **all writes are routed through the
`Store.SQLite` GenServer's mailbox**. The reason is the SQLite single-writer
constraint. Unlike ETS, a `Exqlite.Connection` handle is not safe for concurrent
writes from multiple processes. Two processes writing through the same connection
simultaneously corrupt the WAL; two processes each opening their own connection
deadlock at the WAL lock. The GenServer mailbox is the natural serialisation
point — it has zero additional overhead beyond what SQLite requires anyway.

| | `Tau.Cost.Tracker` (ADR-0010) | `Tau.Memory.Store.SQLite` (this ADR) |
|---|---|---|
| Storage | ETS (`:public`, `write_concurrency: true`) | SQLite connection (single-writer) |
| Write routing | Direct from emitting process (bypasses mailbox) | Through GenServer mailbox |
| Why | ETS is concurrency-safe; mailbox is overhead | SQLite is not concurrency-safe; mailbox is required |
| Read routing | Direct ETS scan (no mailbox) | Read connections opened per-caller (PR2+) |
| Crash consequence | Counters lost (acceptable; observability) | DB file intact (durable) |

## Decision

`Tau.Memory.Store.SQLite` is a `GenServer` that:

1. Opens a `Exqlite.Connection` in WAL mode in `init/1`.
2. Runs all pending schema migrations via `Tau.Memory.Migrations.run/1` in
   `init/1`, before reporting `{:ok, state}`. A migration failure returns
   `{:stop, {:migration_failed, reason}}` — hard-failing boot (D-047).
3. Holds the write connection in its `state`. The connection handle never
   escapes the process heap (D-045).
4. Serves `write/1` and `delete/1` via `handle_call`, serialising all mutations
   through the mailbox.
5. Emits `[:tau, :memory, :write | :delete, :start | :stop | :exception]`
   telemetry events.

`Tau.Memory.Migrations` is a **pure module** (no process, no GenServer) that
holds the ordered migration list and applies them idempotently — checking
`schema_migrations` before each entry.

`Tau.Memory.Supervisor` is a `Supervisor` (`one_for_one`) hosting
`Store.SQLite`. It sits in `Tau.Application`'s `:rest_for_one` tree after
`Tau.Settings.Watcher` (which resolves `data_dir/0`) and before `Finch` (which
embedding calls will use in PR3). Placement is deliberate: a crash cascades
forward to Finch and everything below it, which is acceptable — a broken memory
store should not allow new sessions to start with an inconsistent DB.

## Consequences

- Write latency adds one `GenServer.call` round-trip (< 1 µs on loopback; not
  on the hot path for any user-visible operation).
- Concurrent reads (PR2+) open per-caller read-only connections in WAL mode;
  they do not serialise through the owner.
- Schema migrations are idempotent and version-tracked; adding a migration never
  requires touching existing SQL.
- The DB file (`~/.tau/memory.db`) survives process crashes — data is not lost
  on restart, unlike the ETS cost counters.
- PR2 and PR3 add virtual tables to the same DB file via the same migration
  mechanism.

## Alternatives considered

- **ETS for memory entries.** Does not survive restart. Eliminates FTS5 and
  vector search paths entirely. Not viable for durable memory.
- **`:dets`.** Survives restart but no structured query, no full-text, no
  vector. Viable only as a fallback persistence backend (already exists for
  `Tau.Persistence.Dets`).
- **One GenServer per write, no owning process.** Opens and closes a connection
  per write. SQLite WAL handles this but at the cost of O(n) checkpoint pressure
  and connection setup overhead per write.
- **Ecto + SQLite adapter.** Pulls in Phoenix data layer; violates the
  preference for minimal, well-established dependencies. `exqlite` directly is
  sufficient for the access patterns here.
- **Bypass mailbox + SQLite mutex.** Possible via `:persistent_term` holding a
  mutex ref and each caller acquiring it before writing. More code, no
  measurable benefit over a GenServer call for this write rate.
