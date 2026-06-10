---
template_version: 1
template_name: solution
parent_problem: ../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-3.md]
selection_method: single
revision: 1
---

# Solution: In-process `handle_info(:check_pending_age)` timer inside `Store.SQLite`

## Recommendation

Add a `Process.send_after(self(), :check_pending_age, @check_interval_ms)` to
`Store.SQLite.init/1` and a corresponding `handle_info/2` clause that queries
stale `embedding_status = 'pending'` rows directly against `state.db`, emits
`[:tau, :memory, :pending_rot, :detected]` telemetry with `%{count:
non_neg_integer()}` measurements and `%{entry_ids: [binary()], oldest_age_ms:
non_neg_integer()}` metadata, logs a structured warning, and reschedules itself.
No new module, no new supervised child, no new public API on the store. The
detection query reads the existing `created_at` column on the `memory_entries`
table (per `lib/tau/memory/migrations.ex:35-48`) — `created_at` is the row's
insertion timestamp, stored as ISO-8601 UTC via the SQLite default
`strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`, which makes `julianday(created_at)`
arithmetic well-defined.

## Selected from

- **Chosen:** `proposals/proposal-3.md`
- **Why chosen:** Proposal 3 is the only single proposal that satisfies the
  acceptance criterion with the lowest code surface and no inter-process coupling
  overhead. It runs the detection query directly against `state.db` (no
  `GenServer.call` round-trip), adds no new module or supervised child, and
  modifies a single file (`store/sqlite.ex`). Proposal 1 (separate sweeper
  GenServer) also satisfies the AC fully but introduces a new module, a new
  public API surface on `Store.SQLite`, and a new supervisor child — all
  unnecessary given that the detection query can run in-process. Proposal 2
  (schema + startup audit) only partially fits the AC: it catches rot at startup
  but leaves rot that accumulates while the node is running invisible; it also
  adds a schema migration and a write on the hot path (`handle_continue/2`),
  costs that belong to the `retry-recovery-path` sub-problem rather than to
  observability alone. Proposal 4 (ETS + telemetry push) has a genuine
  restart-time gap that also undermines the AC unless augmented, adds telemetry
  handler lifecycle risk (dangling ETS reference, idempotency hazard on rapid
  restart), and is not easily reversible once woven in. On the comparison axes,
  Proposal 3 wins on decomplecting depth relative to cost: it does not
  restructure the data shape (Proposal 2's strength) but that restructuring is
  not required by this sub-problem's AC, and avoiding it keeps this change
  strictly inside the observability boundary the problem declares.

  **Synthesis correction:** All four proposals (and the prior revision-0
  solution) named the row insertion timestamp as `inserted_at` on a table
  `memory`. The actual schema (`lib/tau/memory/migrations.ex:35-48`,
  migration `20260518_002_memory_entries`) defines the table as
  `memory_entries` and the column as `created_at`. This solution adopts the
  schema as it exists; the proposals' SQL is corrected wherever copied below.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|---|---|---|---|---|
| 1 | Yes | Surface | Medium | Low | Easy |
| 2 | Partially | Substantial | Medium | Low | Easy |
| 3 | Yes | Surface | Low | Low | Easy |
| 4 | Partially | Substantial | High | Medium | Hard |

Proposal 2 scores "Partially" because the startup-only audit does not satisfy
the AC for a long-running node; new rot accumulates silently between restarts.
Proposal 4 scores "Partially" for the same restart-time gap and "Medium" risk
for the telemetry handler lifecycle hazard.

## What changes

- **`lib/tau/memory/store/sqlite.ex`**:
  - `init/1`: add `Process.send_after(self(), :check_pending_age,
    @check_interval_ms)` at the end of the successful init body.
  - New `@check_interval_ms` module attribute (default: `60_000`).
  - New `@stale_threshold_ms` module attribute (default: `35_000`; must exceed
    `EmbeddingWorker`'s `@request_timeout_ms` of `30_000` plus a grace margin).
  - New `handle_info(:check_pending_age, state)` clause: queries
    `query_stale_pending(state.db, @stale_threshold_ms)`, emits
    `[:tau, :memory, :pending_rot, :detected]` telemetry if any stale entries
    are found, logs a structured `Logger.warning/1`, and reschedules itself via
    `Process.send_after`.
  - New private `query_stale_pending/2` function: prepares and executes the
    stale-pending SQL using `Exqlite.Sqlite3` directly against `db`.
  - New private `@sql_stale_pending` module attribute. The SQL targets the
    `memory_entries` table and the `created_at` column as defined in
    `lib/tau/memory/migrations.ex:35-48`:

    ```sql
    SELECT id,
           CAST((julianday('now') - julianday(created_at)) * 86400000 AS INTEGER)
             AS age_ms
    FROM   memory_entries
    WHERE  embedding_status = 'pending'
      AND  CAST((julianday('now') - julianday(created_at)) * 86400000 AS INTEGER) > ?1
    ORDER  BY age_ms DESC
    ```

## What does not change

- `lib/tau/memory/supervisor.ex` — no new child.
- `lib/tau/memory/embedding_worker.ex` — no changes.
- `lib/tau/memory/store/sqlite.ex` public API — no new exported functions.
- Database schema — no migration required; uses the existing `created_at`
  column on `memory_entries`.
- `lib/tau/application.ex` — no changes.
- The `[:tau, :memory, :write]` and `[:tau, :memory, :embedding]` telemetry
  event shapes — unchanged.

## Migration sketch

Single-step: add the three private definitions and the `init/1` call to
`store/sqlite.ex`. The `created_at` column is already ISO-8601 UTC by schema
default (`strftime('%Y-%m-%dT%H:%M:%SZ', 'now')` in
`lib/tau/memory/migrations.ex:45`), so `julianday(created_at)` arithmetic is
well-defined without a migration. Run `EXPLAIN QUERY PLAN` on the
stale-pending query against a dev DB to confirm the plan is acceptable; an
index on `(embedding_status, created_at)` may be warranted if the
pending-row count can grow large but is not required at landing. Add one
`handle_info(:check_pending_age, ...)` test driving the timer directly in
`store/sqlite_test.exs`. The change is reversible by deleting the three
definitions and the `init/1` call; no schema rollback is required.

## Open questions

- Should `@check_interval_ms` and `@stale_threshold_ms` be compile-time
  constants or runtime-configurable via `Application.get_env`? The proposal
  uses compile-time; runtime config adds flexibility for environments with
  different SLAs at a small lookup cost.
- Is an index on `(embedding_status, created_at)` required at landing, or
  should it be a follow-up migration once the pending-row count is observed
  in production?
- Does the `:check_pending_age` message name conflict with any existing
  `handle_info` clause in `Store.SQLite`? Verify before landing.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Separate `PendingRotSweeper` GenServer; satisfies
  AC but adds unnecessary module/API/supervisor surface vs. Proposal 3.
- `proposals/proposal-2.md` — Schema `dispatched_at` column + startup audit;
  partially fits AC (startup-only detection); decomplects data shape at a cost
  more appropriate for `retry-recovery-path`.
- `proposals/proposal-3.md` — **Selected.** In-process `handle_info` timer;
  minimal footprint, full AC fit. (Proposal's SQL referencing `inserted_at`
  on table `memory` is corrected in this solution to `created_at` on
  `memory_entries` per the actual schema.)
- `proposals/proposal-4.md` — ETS + telemetry push; restart-time gap and
  handler lifecycle risk make it a partial fit at higher cost.

## Revision history

- (revision 0 — initial)
- revision 1 — Corrected column reference from `inserted_at` to `created_at`
  and table reference from `memory` to `memory_entries` to match the actual
  schema in `lib/tau/memory/migrations.ex:35-48` (migration
  `20260518_002_memory_entries`). All four proposals carried the same defect;
  the synthesis fixes it. Validator's prior falsification on this point is
  resolved.
