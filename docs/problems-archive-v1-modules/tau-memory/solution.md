---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: root
synthesised_from:
  - subproblems/finch-name-mismatch/solution.md
  - subproblems/silent-failure-propagation/solution.md
  - subproblems/pending-rot-observability/solution.md
  - subproblems/retry-recovery-path/solution.md
selection_method: synthesis
mode: non-leaf
revision: 0
---

# Solution: Bind the Finch name, make the embedding pipeline self-healing, observable, and recoverable

## Recommendation

Repair the embedding pipeline along the four layers the decomposition identified
— root-cause wiring, crash-to-callback propagation, pending-rot observability,
and retry/recovery — in a single coherent module-level change set landed across
three sequenced PRs. The wiring fix (a shared `Tau.Providers.Config.finch_name/0`
constant) eliminates the root-cause drift seam. The crash-to-callback fix
restructures `Store.SQLite` around a `pending_tasks: %{reference() => entry_id}`
map in GenServer state, fed by a new `Tau.Memory.Embedder.embed_async/1`
behaviour callback whose Task result is routed through `handle_info({ref,
result}, ...)` and whose abnormal `{:DOWN, ref, ...}` exit is routed to
`do_mark_embedding_failed/3` — making success and crash paths symmetric and the
Store the sole writer. A periodic `handle_info(:check_pending_age, ...)` clause
inside the same Store GenServer emits `[:tau, :memory, :pending_rot, :detected]`
telemetry and a structured log warning whenever any `embedding_status =
'pending'` row exceeds a configurable stale threshold. A new sibling
`Tau.Memory.RetrySweeper` GenServer under `Tau.Memory.Supervisor` polls a new
`Store.SQLite.list_retriable/1` API and re-invokes `embed_async/1` for stale
`"pending"` rows and `"failed"`-with-`:transient` rows, closing the loop after
either a configuration fix or a transient fault clears. Together these changes
make the acceptance criterion mechanically true: every entry under default
configuration reaches `"ready"` or `"failed"` (with actionable telemetry) within
a bounded window, with no permanent-`"pending"` failure mode remaining.

## Selected from

- **Synthesised from:**
  - `subproblems/finch-name-mismatch/solution.md` — shared `Tau.Providers.Config`
    module binds the Finch pool name at both sites (selection_method: single).
  - `subproblems/silent-failure-propagation/solution.md` — ref-map in
    `Store.SQLite` state + structured-result `embed_async/1` embedder contract
    (selection_method: hybrid).
  - `subproblems/pending-rot-observability/solution.md` — in-process
    `handle_info(:check_pending_age)` timer inside `Store.SQLite`
    (selection_method: single).
  - `subproblems/retry-recovery-path/solution.md` — dedicated supervised
    `Tau.Memory.RetrySweeper` GenServer with periodic timer
    (selection_method: single).

- **Composition rationale:** the four child solutions compose **directly**;
  there is no conflict to resolve. The composition has three interfaces and
  one ordering constraint:

  1. **Wiring → everything else.** The `finch-name-mismatch` fix is the
     prerequisite: every downstream change (crash propagation, observability,
     retry) is dead code if the Finch pool name is still wrong, because no
     embedding call ever reaches the HTTP path. Land the wiring fix first.

  2. **Crash propagation ↔ retry path share the `Embedder` contract.** The
     crash-propagation solution introduces `embed_async/1` as the canonical
     `Tau.Memory.Embedder` behaviour callback (replacing the
     fire-and-forget `embed/3` + callback-from-worker pattern). The retry
     sweeper's child solution names `embedder.embed/3` because at the time it
     was authored that was the live contract; in the composed plan the sweeper
     invokes `embed_async/1` instead, routing the resulting Task ref through the
     same `pending_tasks` map and the same `handle_info` clauses as the primary
     write path. There is exactly one dispatch path; the sweeper and the write
     path differ only in *who* enqueues the work, not in *how* the result
     propagates. This is the load-bearing simplification — sweeper-dispatched
     embeddings get the same crash-to-`"failed"` guarantee as write-dispatched
     embeddings, automatically.

  3. **Observability ↔ retry are complementary, not redundant.** The
     observability timer *detects* stale `"pending"` entries and emits
     telemetry; the retry sweeper *acts* on stale `"pending"` and
     transient-`"failed"` entries by re-dispatching. They run on independent
     intervals in different processes (the timer is `handle_info` inside
     `Store.SQLite`; the sweeper is a sibling GenServer under
     `Tau.Memory.Supervisor`). Operators see "pending rot detected" telemetry
     even when the sweeper is firing — telemetry is the signal, sweeping is
     the remediation. This separation is intentional: an operator can disable
     the sweeper (via a long sweep interval) and still see the rot signal, or
     keep the sweeper short and see the signal decay as the sweep drains the
     queue.

  No child solution is in tension with another. The decomposition was
  layered (one concern per layer); the layers stack without overlap.

## What changes

The change set, grouped by file and tagged with its originating sub-problem.

### New files

- `lib/tau/providers/config.ex` *(finch-name-mismatch)* — `Tau.Providers.Config`
  with `@finch_name Tau.Providers.Finch` module attribute and a `finch_name/0`
  accessor (~10 LOC).
- `lib/tau/memory/retry_sweeper.ex` *(retry-recovery-path)* —
  `Tau.Memory.RetrySweeper` GenServer (~80 LOC) with `init/1` scheduling via
  `{:continue, :schedule}`, `handle_info(:sweep, ...)` that calls
  `Store.SQLite.list_retriable/1` and re-dispatches each row via
  `Tau.Memory.Embedder.embed_async/1` through the store's
  `handle_continue({:dispatch_embedding, id, content}, state)` path,
  `handle_call(:sweep, ...)` exposing `trigger_sweep/0` for tests and operator
  tooling, and telemetry spans on sweep and per-enqueue events.
- `test/tau/memory/retry_sweeper_test.exs` — unit tests using
  `trigger_sweep/0`; integration test wiring the sweeper against a test store.

### Modified files

- `lib/tau/application.ex` *(finch-name-mismatch)* — line 78,
  `{Finch, name: Tau.Providers.Finch}` → `{Finch, name:
  Tau.Providers.Config.finch_name()}`.
- `lib/tau/memory/embedder.ex` *(silent-failure-propagation)* — replace the
  `embed/3` callback declaration with `embed_async/1 :: {:ok, Task.t()} |
  {:error, term()}`.
- `lib/tau/memory/embedding_worker.ex` *(finch-name-mismatch + silent-failure-
  propagation)* — line 106, default Finch name argument
  `Tau.Finch` → `Tau.Providers.Config.finch_name()`; remove the
  `store_embedding/3` callback path; implement `embed_async/1` returning
  `{:ok, task}` where the Task body returns `{:ok, embedding} | {:error, kind,
  reason}`.
- `lib/tau/memory/store/sqlite.ex` *(silent-failure-propagation + pending-rot-
  observability + retry-recovery-path)*:
  - **State** — add `pending_tasks: %{reference() => String.t()}`; initialise
    to `%{}` in `init/1`.
  - **Dispatch** — `handle_continue({:dispatch_embedding, id, content}, state)`
    calls `embedder.embed_async(content)`, captures the Task ref, stores
    `ref → id` in `pending_tasks`.
  - **Success path** — new `handle_info({ref, embed_result}, state) when
    is_reference(ref)` demonitors, removes from map, calls
    `do_store_embedding/3` on `{:ok, embedding}` or
    `do_mark_embedding_failed/3` on `{:error, kind, _reason}`.
  - **Crash path** — new `handle_info({:DOWN, ref, :process, _pid, reason},
    state)` where `reason != :normal`: looks up entry ID in `pending_tasks`,
    calls `do_mark_embedding_failed/3` with `:transient`, removes from map.
    Tolerates `Map.fetch/2` returning `:error` (double-fire from `{ref,
    result}` then `{:DOWN, :normal}` benign).
  - **Remove** — `handle_call({:store_embedding, ...})` clause; no external
    caller after the contract change.
  - **Observability timer** — `init/1` schedules
    `Process.send_after(self(), :check_pending_age, @check_interval_ms)`;
    new `@check_interval_ms` (default `60_000`) and `@stale_threshold_ms`
    (default `35_000`, must exceed `EmbeddingWorker`'s `@request_timeout_ms`
    of `30_000` plus a grace margin) module attributes; new
    `handle_info(:check_pending_age, state)` clause running
    `query_stale_pending(state.db, @stale_threshold_ms)`, emitting
    `[:tau, :memory, :pending_rot, :detected]` telemetry with `%{count:
    non_neg_integer()}` measurements and `%{entry_ids: [binary()],
    oldest_age_ms: non_neg_integer()}` metadata when any are found, logging
    a structured `Logger.warning/1`, and rescheduling itself.
  - **Stale-pending query** — new private `query_stale_pending/2` and
    `@sql_stale_pending` module attribute. SQL targets the `memory_entries`
    table and `created_at` column per `lib/tau/memory/migrations.ex:35-48`:

    ```sql
    SELECT id,
           CAST((julianday('now') - julianday(created_at)) * 86400000 AS INTEGER)
             AS age_ms
    FROM   memory_entries
    WHERE  embedding_status = 'pending'
      AND  CAST((julianday('now') - julianday(created_at)) * 86400000 AS INTEGER) > ?1
    ORDER  BY age_ms DESC
    ```

  - **Retriable query** — new public `list_retriable/1` (~30 LOC) and private
    `handle_call(:list_retriable, ...)` returning rows where
    `embedding_status = 'pending'` AND age exceeds the stale threshold, OR
    `embedding_status = 'failed'` AND the metadata-encoded
    `embedding_error_kind = 'transient'`.
- `lib/tau/memory/supervisor.ex` *(retry-recovery-path)* — add
  `{Tau.Memory.RetrySweeper, opts}` as a `:one_for_one` sibling after
  `Store.SQLite`. Strategy stays `:one_for_one`.
- `lib/tau/memory/memory_store.ex` *(silent-failure-propagation)* — remove the
  `store_embedding/3` public function; no external callers remain.
- All embedder test doubles in `test/` *(silent-failure-propagation)* —
  implement `embed_async/1` instead of `embed/3`.
- New regression tests:
  - kill the embed Task ref, assert DB row transitions to `embedding_status:
    "failed"` *(silent-failure-propagation)*;
  - success-path test via `{ref, {:ok, embedding}}` *(silent-failure-
    propagation)*;
  - `handle_info(:check_pending_age, ...)` driving the timer directly in
    `store/sqlite_test.exs`, asserting telemetry and log emission *(pending-
    rot-observability)*;
  - `RetrySweeper.trigger_sweep/0` re-dispatches a stuck `"pending"` row and
    a `transient`-`"failed"` row, both reach `"ready"` after a successful
    embed *(retry-recovery-path)*.

### New telemetry events

- `[:tau, :memory, :pending_rot, :detected]` *(pending-rot-observability)*
- `[:tau, :memory, :retry_sweeper, :sweep, :start | :stop]` spans
  *(retry-recovery-path)*
- `[:tau, :memory, :retry_sweeper, :enqueue]` per-enqueue events
  *(retry-recovery-path)*

### New configuration keys

- `:tau, :finch_name` *(finch-name-mismatch)* — already exists; default now
  derives from `Tau.Providers.Config.finch_name()`.
- `:tau, :retry_sweep_interval_ms` *(retry-recovery-path)* — default
  `60_000`; in the test environment set to a short value (e.g. `500`).

## What does not change

- The `Tau.Providers.Finch` atom itself — remains the canonical pool name.
- All callers of `EmbeddingWorker.embed/N` at signature level apart from the
  contract change; the contract change is intentional and covered above.
- The `embedding_status` enum values (`"pending"`, `"ready"`, `"failed"`)
  and D-046 invariant semantics.
- The `memory_entries` table schema — no migration; the new queries read
  existing `created_at`, `embedding_status`, and `metadata` columns as-is.
- `Tau.Memory.Supervisor` supervision strategy — stays `:one_for_one`.
- All other supervision tree entries and startup order in
  `Tau.Application`.
- `do_mark_embedding_failed/3` and `do_store_embedding/3` in `Store.SQLite`
  — already exist; called from `handle_info` rather than `handle_call`.
- The `[:tau, :memory, :write]` and `[:tau, :memory, :embedding]`
  telemetry event shapes — unchanged.
- FTS5 search, SQLite migrations, the embedding model/provider/dimension,
  `Tau.Memory.Loader`, and embedding-pipeline performance under load
  — all explicit out-of-scope items from the parent problem.

## Migration sketch

Sequence the change set across **three PRs** so each PR is independently
reviewable, gateable, and reversible per `factory-loop.md` / `worktree-
discipline.md`. The three PRs map cleanly to the dependency edges identified
in the composition rationale.

**PR-1 — Wiring fix (finch-name-mismatch).** Smallest, lowest-risk, unlocks
everything downstream. Introduce `Tau.Providers.Config`, switch
`application.ex` and `embedding_worker.ex` to use the shared accessor. Add
the optional companion test asserting
`Tau.Providers.Config.finch_name() == name registered by Tau.Application`
(closes the nominal-equality gap noted in finch-name-mismatch open
question 2). Ship and merge before PR-2. Reversible in one commit.

**PR-2 — Embedder contract + crash propagation + observability (silent-failure-
propagation + pending-rot-observability).** These two child solutions both
modify `lib/tau/memory/store/sqlite.ex` and must land together to avoid an
intermediate state where the observability timer fires against a Store whose
crash path is still broken. Land the `Embedder` behaviour change
(`embed_async/1`), update `EmbeddingWorker`, update test doubles, restructure
`Store.SQLite` (state, dispatch, success, crash, timer, queries), and add
the regression tests. The observability timer is inert until rows actually
linger; it can ship with a generous default threshold (`35_000` ms) so it
fires only on real anomalies. PR-2 is the largest of the three; review is
manageable because the changes are localised to four files plus tests.

**PR-3 — Retry sweeper (retry-recovery-path).** Introduce
`Store.SQLite.list_retriable/1` first (additive, no callers yet); add the
`Tau.Memory.RetrySweeper` module (inert until supervised); add the
supervisor child last. The sweeper invokes the PR-2 `embed_async/1`
contract, so PR-3 depends on PR-2 having landed. Set the sweep interval
short in the test environment and use `trigger_sweep/0` for deterministic
control. Reversible by removing the supervisor child and deleting the
module.

Each PR satisfies `spec-before-code.md` for `SPEC-MEMORY-STORE.md` (D-045 /
D-046 invariants are enforced, not changed). Each PR cites the
parent-problem acceptance criterion plus the relevant child sub-problem
ACs in its draft-PR body per `factory-loop.md`. The full gate
(`critic` + `reviewer`) runs against each PR; the post-merge `main` health
check follows each merge.

## Open questions

The composed plan inherits five open questions from the child solutions;
none block the recommendation but each should be resolved in the
implementation PR that owns it.

- **Namespace for `Tau.Providers.Config`** *(from finch-name-mismatch)* —
  alternatives are `Tau.Config` or `Tau.Infrastructure`. Defer to project
  conventions in `lib/tau/providers/`. Decision lands in PR-1.
- **`embed_async/1` inner-Task layering** *(from silent-failure-
  propagation)* — flatten to a single Task vs. forward the inner ref;
  must be decided before the contract change ships in PR-2. Incorrect
  routing means `{ref, result}` never reaches the mailbox.
- **`{ref, result}` clause guard discipline** *(from silent-failure-
  propagation)* — `when is_reference(ref)` must not accidentally match
  unrelated messages; review the GenServer's full message surface before
  PR-2 lands.
- **`@check_interval_ms` / `@stale_threshold_ms` runtime vs. compile-time**
  *(from pending-rot-observability)* — compile-time keeps the change
  smaller; runtime adds operator flexibility. Default to compile-time in
  PR-2 unless an operator requirement surfaces.
- **Index on `(embedding_status, created_at)`** *(from pending-rot-
  observability)* — not required at landing; revisit as a follow-up
  migration once pending-row counts are observed in production.
- **Duplicate-embedding race between sweeper and write path** *(from
  retry-recovery-path)* — if the sweeper dispatches an entry while the
  write path also has it in flight, two `embed_async/1` calls race. The
  Store's `do_store_embedding/3` is claimed idempotent (DELETE + INSERT
  in a transaction); verify in PR-3. A second-order mitigation is for the
  sweeper to skip rows whose Task ref is already in `pending_tasks` (the
  ref map introduced in PR-2 makes this cheap); decide in PR-3.
- **Sweeper first-fire latency** *(from retry-recovery-path)* — default
  is one full interval (60 s) after boot. If operators need a faster
  initial drain, add `{:continue, :startup_sweep}` to `RetrySweeper.init/1`
  before scheduling the interval. Defer unless operator requirement
  surfaces.

The parent acceptance criterion is not contingent on any of these
questions — each one is a tuning or namespace choice within a solution
that already satisfies the criterion.

## Linked sub-problems / proposals

- `subproblems/finch-name-mismatch/` → "Shared `Tau.Providers.Config` module
  binds the Finch pool name at both sites."
- `subproblems/silent-failure-propagation/` → "Ref-map in `Store.SQLite` state
  + structured-result `embed_async/1` embedder contract."
- `subproblems/pending-rot-observability/` → "In-process
  `handle_info(:check_pending_age)` timer inside `Store.SQLite`."
- `subproblems/retry-recovery-path/` → "`Tau.Memory.RetrySweeper` — dedicated
  supervised GenServer with periodic timer."

## Revision history

- (revision 0 — initial synthesis from four validated child solutions)
