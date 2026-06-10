---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md]
selection_method: single
revision: 0
---

# Solution: Tau.Memory.RetrySweeper — dedicated supervised GenServer with periodic timer

## Recommendation

Introduce `Tau.Memory.RetrySweeper`, a new `GenServer` child under
`Tau.Memory.Supervisor`, whose sole responsibility is periodically querying
the DB for `"pending"` and `"failed"`/`embedding_error_kind: "transient"` rows
and re-dispatching `embedder.embed/3` for each. The sweep interval is
configurable via `:tau, :retry_sweep_interval_ms` (default 60_000 ms). The
store gains one new API call, `list_retriable/1`, returning retriable entries.
`trigger_sweep/0` provides a synchronous handle for tests and operator tooling.
The supervision strategy stays `:one_for_one`; sweeper and store fail
independently.

## Selected from

- **Chosen:** `proposals/proposal-1.md`
- **Why chosen:** Proposal 1 is the only candidate that simultaneously satisfies
  the acceptance criterion, respects OTP non-negotiables #1 and #3, and carries
  low migration risk with high reversibility. The comparison below makes the
  choice decisive.

### Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|---------------|------|---------------|
| 1 | Yes | Substantial | Low | Low | Easy |
| 2 | Yes | Surface | Low | Medium | Easy |
| 3 | Partially | Substantial | Low | Low | Easy |
| 4 | Yes | Deep | High | Medium | Hard |

**Proposal 2** scores "Surface" on decomplecting depth because the retry concern
is inlined into the store GenServer rather than separated: the status-write path
and the retry-trigger live in the same module and process. It also violates OTP
non-negotiable #3 in spirit (stateless periodic logic woven into the stateful
DB-owner GenServer). A sweep bug can stall or crash the store; there is no process
isolation. Disqualified on OTP grounds and on the Hickey heuristic
(decomplecting depth over cost).

**Proposal 3** is event-driven, which is an attractive decoupling, but earns
"Partially" on fit because the acceptance criterion requires re-submission
"within a bounded time window." Proposal 3's bound is "next successful write,"
not a clock interval. If the configuration is fixed but no new writes occur, the
startup sweep fires once; any entries that fail again during that sweep remain
stuck until a write arrives. The bound is open-ended in the write-idle case.
Proposal 3 is also strictly more complex than Proposal 1: the telemetry
attach/detach lifecycle, potential message storm under high write volume, and the
debounce concern add surface area without resolving the bounded-time-window
requirement. Proposal 3 also depends on `list_retriable/1`, the same store
addition Proposal 1 requires — no differential cost on that axis.

**Proposal 4** earns "Deep" on decomplecting depth (the FSM makes retryability a
first-class state transition) but the migration cost is materially higher — a
DB migration with backfill from JSON metadata, two new modules, a `BootSweep`
with a `Process.sleep/1` timing fragility, and a harder-to-reverse schema
change. The proposer rates confidence "low-medium," the lowest of the four. The
depth of decomplecting is genuine but the problem statement does not require it:
the acceptance criterion asks for automatic re-submission within a bounded window;
it does not require an explicit FSM. The `EmbeddingState` decomplecting can be
deferred to a targeted future PR without blocking recovery. Proposal 4 is the
right answer to a larger problem; it is over-scoped for this sub-problem.

Proposal 1 wins on fit + decomplecting depth relative to Proposal 2, on fit
relative to Proposal 3, and on migration cost + risk + reversibility relative to
Proposal 4. No hybrid is justified: Proposal 1 does not need elements from other
proposals to satisfy the acceptance criterion.

## What changes

- **New module** `lib/tau/memory/retry_sweeper.ex` (~80 LOC): `GenServer` with
  `init/1` scheduling the first sweep via `{:continue, :schedule}`,
  `handle_info(:sweep, ...)` running the sweep and rescheduling, `handle_call(:sweep, ...)` for synchronous `trigger_sweep/0`, and telemetry spans on
  sweep and per-enqueue events.
- **New store API** in `lib/tau/memory/store/sqlite.ex` (~30 LOC): public
  `list_retriable/1` spec + implementation; private `handle_call(:list_retriable,
  ...)` with the SQL query filtering `"pending"` and `"failed"`/transient rows.
- **Supervisor change** in `lib/tau/memory/supervisor.ex` (~3 LOC): add
  `{Tau.Memory.RetrySweeper, opts}` as a `:one_for_one` sibling after
  `Store.SQLite`.
- **New test module** for `RetrySweeper`: unit tests using `trigger_sweep/0`;
  integration test wiring the sweeper against a test store instance.

## What does not change

- `Tau.Memory.Store.SQLite` — no changes to existing callbacks or the write/embedding
  path; `list_retriable/1` is additive only.
- `Tau.Memory.Embedder` behaviour — no new callbacks; `embed/3` is called
  exactly as it is today.
- `Tau.Memory.Supervisor` supervision strategy — stays `:one_for_one`.
- DB schema — no migration; the query reads existing `embedding_status` and
  `metadata` columns as-is.
- `Tau.Memory.EmbeddingWorker` — no changes; the sweeper calls the same
  `embed/3` the write path calls.
- The complecting between `pending` (lost Task) and `in_flight` (active Task)
  is not resolved here (deferred to `pending-rot-observability` sub-problem).

## Migration sketch

Land `list_retriable/1` on `Store.SQLite` first (additive, no callers yet).
Introduce `RetrySweeper` next; it is inert until added to the supervisor.
Add the supervisor child last — at that point the sweeper begins firing. All
three changes can land in one PR; the ordering of commits within the PR
provides reviewability. Set `:tau, :retry_sweep_interval_ms` to a short value
(e.g. 500 ms) in the test environment; use `trigger_sweep/0` in tests that
need deterministic control rather than relying on the timer.

## Open questions

1. **Duplicate-embedding race:** if the sweeper dispatches an entry currently
   mid-embedding (e.g. the Finch fix was applied and a new write just submitted
   the same entry), two `embed/3` calls race. The store's `do_store_embedding`
   is claimed to be idempotent (DELETE + INSERT in a transaction) — this should
   be verified in the implementation PR.
2. **Sweep under high write load:** `list_retriable/1` routes through the store
   mailbox, competing with writes. Under high write bursts, a sweep call may be
   delayed. The periodic model means the next sweep fires regardless; the delay
   affects only the current cycle. Whether this is acceptable at expected
   `memory_entries` row counts (thousands) should be benchmarked in the
   implementation PR.
3. **Startup delay:** the first sweep fires after one full interval (default
   60 s). For entries stuck before restart, this is the maximum initial wait.
   If operators need faster initial drain, the sweeper could fire once at
   startup via `{:continue, :startup_sweep}` before scheduling the interval —
   a trivial addition, but not included in this recommendation to keep scope
   minimal.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Tau.Memory.RetrySweeper, dedicated supervised GenServer with periodic timer **(selected)**
- `proposals/proposal-2.md` — Store-internal `handle_info(:retry_sweep)` timer inside Store.SQLite (OTP non-negotiable violation; no process isolation)
- `proposals/proposal-3.md` — Telemetry-driven re-enqueue on write events (partially fits; open-ended time bound in write-idle case)
- `proposals/proposal-4.md` — Explicit EmbeddingState FSM with re-enqueue as first-class transition (over-scoped; DB migration required; low-medium confidence)

## Revision history

- (revision 0 — initial)
