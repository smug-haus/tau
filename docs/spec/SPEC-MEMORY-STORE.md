# SPEC-MEMORY-STORE — Persistent Memory Store

**Status:** Active  
**Version:** 1.0  
**Date:** 2026-05-18  
**PRs:** PR 1 of 3 (write/delete + schema), PR 2 (FTS5 full-text search), PR 3 (sqlite-vec semantic search)

---

## §0 Why

Tau sessions load `TAU.md` cascades from disk on every start (ADR-0006). That
is sufficient for the current workload. However, a persistent memory store is
required for a qualitatively different capability: structured, queryable notes
that survive session boundaries, support full-text search, and will support
semantic (embedding-based) retrieval. The store is not a replacement for the
cascade; it is a separate substrate for long-lived agent memory.

ADR-0006 deferred `Tau.Memory.Cache` until measured. This component is
distinct: it is not a cache — it is a write-durable, queryable store. No
measurement threshold applies.

---

## §1 PSDH Triage — Score 3/5

| Property | Present? | Rationale |
|---|---|---|
| **P** — shared mutable state | Yes | Single SQLite database; multiple callers |
| **S** — temporal ordering constraints | Yes | Migrations before use; embedding pipeline ordering |
| **D** — cross-process data flow | Yes | Write path serialised through owner; read path concurrent |
| **H** — hard real-time constraints | No | Best-effort; no latency SLA |

Score 3/5. Spec is mandatory under `spec-before-code.md`.

---

## §2 Components

```
Tau.Memory.Supervisor            ── Supervisor (one_for_one)
  └── Tau.Memory.Store.SQLite    ── GenServer; owns write connection
                                    runs migrations in init/1

Tau.Memory.Store                 ── Behaviour (write/1, delete/1; search/1 PR2+)
Tau.Memory.Migrations            ── Pure module; ordered migration list
```

**PR 1 of 3 scope:** `Supervisor`, `Store` behaviour, `Store.SQLite` (write +
delete only), `Migrations` (schema v1 — `memory_entries` + `schema_migrations`).

**PR 2 scope:** FTS5 virtual table `memory_fts`; `Store.search/2` full-text.

**PR 3 scope:** `sqlite-vec` virtual table `memory_vec`; `Store.semantic_search/2`.

---

## §3 Constraints (L0)

### Write-path constraints

**C-001** — Exactly one process holds the write `Exqlite.Connection`. No
`Exqlite.Connection` handle escapes the `Tau.Memory.Store.SQLite` GenServer
process. Callers use the public `write/1` / `delete/1` API; the connection is
never returned from any public function.

**C-002** — All writes are serialised through the owner's mailbox
(`GenServer.call`). SQLite has a single-writer constraint at the connection
level; mailbox serialisation enforces it without external locking. Read
connections (PR2+) may be opened per-caller as read-only connections.

### Embedding-status constraints

**C-003** — Every `memory_entries` row has an `embedding_status` field whose
value is one of `"pending"`, `"ready"`, or `"failed"`. No other values are
permitted; the constraint is enforced at the SQL column level via a CHECK
constraint.

**C-004** — `"failed"` carries a retriable-vs-terminal distinction encoded in
`metadata` as `%{"embedding_error_kind" => "transient" | "terminal"}`. A
transient failure (e.g. network timeout) is eligible for retry by the embedding
pipeline (PR3). A terminal failure (e.g. content too long, policy rejection) is
not retried. Search (PR2+) MUST NOT silently drop rows with `embedding_status =
"pending"` from full-text results; pending rows are included in FTS but excluded
from vector results until their status is `"ready"`.

### Migration constraints

**C-005** — Schema migrations are idempotent: re-running the migration list
from a fully-migrated DB is a no-op, not an error. Idempotency is enforced by
recording applied migrations in `schema_migrations` and skipping any already
recorded.

**C-006** — Migrations run to completion in `Tau.Memory.Store.SQLite.init/1`
before the process reports `{:ok, state}`. A migration that fails causes
`init/1` to return `{:stop, reason}`, which hard-fails boot. A half-migrated
database is not tolerated; the supervisor's crash will surface the error.

**C-007** — Migrations are append-only. An existing migration's SQL MUST NOT
be mutated; add a new migration entry instead.

### Supervision constraints

**C-008** — `Tau.Memory.Supervisor` is started after `Tau.Settings.Watcher`
(which resolves `data_dir/0`) and before `Finch` (which embedding calls will
use in PR3). Position in `Tau.Application`'s `:rest_for_one` child list is
fixed; a crash cascades to everything below it.

---

## §4 Boundary Contracts

### Write contract

```
Tau.Memory.Store.write(entry :: map()) :: {:ok, id :: String.t()} | {:error, term()}
```

`entry` shape (all string-keyed):

| Field | Type | Required | Notes |
|---|---|---|---|
| `"kind"` | String.t() | Yes | Entry type tag (e.g. `"note"`, `"fact"`) |
| `"scope"` | String.t() | Yes | Namespacing key (e.g. session_id, `"global"`) |
| `"content"` | String.t() | Yes | The memory text |
| `"metadata"` | map() | No | Caller-defined; stored as JSON |

Returns `{:ok, id}` where `id` is a ULID. Returns `{:error, reason}` on
constraint violation or DB error; never raises on invalid input.

### Delete contract

```
Tau.Memory.Store.delete(id :: String.t()) :: :ok | {:error, term()}
```

Deletes by primary key. Returns `:ok` whether or not the row existed (idempotent
delete). Returns `{:error, reason}` only on DB error.

### Search contract (PR2)

```
Tau.Memory.Store.search(query :: String.t(), opts :: keyword()) ::
  {:ok, [map()]} | {:error, term()}
```

`pending` rows are included. `failed` rows are included. Results ordered by FTS
rank descending. `opts`: `limit` (default 10), `scope` (filter by scope).

### Semantic search contract (PR3)

```
Tau.Memory.Store.semantic_search(embedding :: [float()], opts :: keyword()) ::
  {:ok, [map()]} | {:error, term()}
```

Only `ready` rows are returned. `pending` rows are excluded (not yet embedded).
`failed` rows are excluded.

### Migration-hard-fail-on-boot contract

If `Tau.Memory.Migrations.run/1` returns `{:error, reason}`, `init/1` returns
`{:stop, {:migration_failed, reason}}`. The supervisor escalates the crash.
Operator remediation: fix the DB and restart the application. No partial-schema
recovery path is provided in code; correctness over availability.

---

## §5 Acceptance Criteria

**AC-1** — `Tau.Memory.Store.SQLite.write/1` inserts a row with
`embedding_status = "pending"` and returns `{:ok, ulid}`.

**AC-2** — `Tau.Memory.Store.SQLite.delete/1` removes a row by id and returns
`:ok` even if the id did not exist.

**AC-3** — Re-running migrations against a fully-migrated DB is a no-op (no
error, no duplicate rows in `schema_migrations`).

**AC-4** — A migration error in `init/1` causes the GenServer to fail to start
(`:stop` return), which the test can observe as `{:error, _}` from
`GenServer.start_link`.

**AC-5** — Telemetry events `[:tau, :memory, :write, :start]`,
`[:tau, :memory, :write, :stop]`, `[:tau, :memory, :delete, :start]`,
`[:tau, :memory, :delete, :stop]` are emitted on each operation.

---

## §6 D-NNN Invariants

**D-045** — Exactly one process holds the write `Exqlite.Connection` for the
memory store. No handle to that connection escapes `Tau.Memory.Store.SQLite`'s
process heap. Callers interact only through the public `write/1` / `delete/1`
API.

**D-046** — Every `memory_entries` row's `embedding_status` is one of
`"pending"`, `"ready"`, or `"failed"`. The `"failed"` state carries a
`"transient"` / `"terminal"` kind in `metadata["embedding_error_kind"]`.
Search (PR2+) MUST NOT silently drop `"pending"` rows from full-text results.

**D-047** — Schema migrations are idempotent and run to completion in
`Tau.Memory.Store.SQLite.init/1` before the process reports `{:ok, state}`. A
failed migration causes `init/1` to return `{:stop, reason}`, hard-failing
boot.

---

## Appendix A — Schema (PR1)

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
  version     TEXT PRIMARY KEY,
  applied_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS memory_entries (
  id               TEXT PRIMARY KEY,
  kind             TEXT NOT NULL,
  scope            TEXT NOT NULL,
  content          TEXT NOT NULL,
  metadata         TEXT NOT NULL DEFAULT '{}',
  embedding_status TEXT NOT NULL DEFAULT 'pending'
                   CHECK (embedding_status IN ('pending', 'ready', 'failed')),
  created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  updated_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
```

PR2 adds: `CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(...)`.  
PR3 adds: `CREATE VIRTUAL TABLE IF NOT EXISTS memory_vec USING vec0(...)`.

---

## Appendix B — Source Map

Files in scope of this SPEC (a PR touching any of these MUST name its AC-N /
D-NNN):

```
lib/tau/memory/store.ex
lib/tau/memory/store/sqlite.ex
lib/tau/memory/migrations.ex
lib/tau/memory/supervisor.ex
lib/tau/application.ex            (Memory.Supervisor entry only)
test/tau/memory/store_sqlite_test.exs
test/tau/memory/migrations_test.exs
docs/spec/SPEC-MEMORY-STORE.md
docs/adr/0019-memory-store-sqlite-driver.md
```
