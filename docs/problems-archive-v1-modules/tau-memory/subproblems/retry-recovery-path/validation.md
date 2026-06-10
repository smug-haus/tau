---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/4
revision_triggered: none
---

# Validation: Tau.Memory.RetrySweeper — dedicated supervised GenServer with periodic timer

## Overview

The solution proposes a new `Tau.Memory.RetrySweeper` GenServer child under
`Tau.Memory.Supervisor` that periodically queries `list_retriable/1` on the
store and re-dispatches `embed/3` for stuck `"pending"` and transient-`"failed"`
entries. Six distinct claims are extracted from the Recommendation and
What-changes sections. Five withstand falsification; one (the duplicate-race
idempotency claim) is partially falsified — the qualifier is narrowed in place
and no solution revision is required.

---

## Toulmin per claim

### Claim 1: RetrySweeper satisfies the acceptance criterion (bounded-time automatic re-submission without operator intervention)

- **Claim (C):** "any memory entry that is in `embedding_status: 'pending'` or
  `embedding_status: 'failed'` with `embedding_error_kind: 'transient'` is
  automatically re-submitted for embedding without operator intervention, within
  a bounded time window."
- **Grounds (G):** The current `lib/tau/memory/store/sqlite.ex` contains no
  `handle_info(:timeout, ...)`, `Process.send_after/3`, or periodic-sweep clause
  (confirmed by reading the full file: lines 1–708). `lib/tau/memory/supervisor.ex`
  line 29 has a single child `{Tau.Memory.Store.SQLite, opts}`. The proposed
  sweeper adds a `Process.send_after`-based loop with configurable interval
  (default 60 000 ms), directly addressing the absence. The `embed/3` callback
  at `lib/tau/memory/embedding_worker.ex:49–71` is the existing dispatch
  mechanism; invoking it from the sweeper reuses an established path.
- **Warrant (W):** A supervised process with a periodic `send_after` loop
  provides a wall-clock upper bound on re-submission latency equal to the
  configured interval. This is sufficient to satisfy "within a bounded time
  window" as stated in the acceptance criterion.
- **Qualifier (Q):** The bound holds absent runaway store-mailbox congestion or
  OOM conditions that would prevent the sweeper from sending its `:sweep`
  message. At expected row counts (thousands) this is not a realistic constraint.
- **Rebuttal (R):** If the store GenServer's mailbox is saturated by write load,
  `list_retriable/1` blocks inside the mailbox queue and the sweep fires later
  than the nominal interval. The time bound is probabilistic, not hard-real-time.
  The problem statement does not require hard-real-time, so this does not
  falsify the claim.
- **Backing (B):** Problem.md acceptance criterion; OTP non-negotiable #1
  (`.claude/rules/otp-non-negotiables.md`): "Stateful subsystems MUST run as
  supervised processes." SPEC-MEMORY-STORE.md §3 C-004, §6 D-046.

#### Falsification attempt for claim 1

- **Strategy:** Edge-case enumeration — enumerate failure modes that would leave
  an entry permanently unreachable despite the sweeper running.
- **Attempt:** (a) Entry in `"pending"` with active in-flight Task: sweeper
  dispatches a second `embed/3`; addressed in Open Question 1. (b) Store crash
  before sweep completes: sweeper survives independently under `:one_for_one`;
  next sweep fires after restart. (c) Sweeper crashes: restarted by supervisor;
  next sweep fires after restart interval. (d) Entry permanently stuck as
  `"terminal"`: the solution explicitly excludes terminal entries from
  `list_retriable/1` filter, so this is correct non-retry. (e) Write-idle
  system: the timer fires regardless of write activity; no open-ended bound.
- **Outcome:** Withstood — no enumerated case leaves a retriable entry
  permanently unreachable.
- **Action:** None.

---

### Claim 2: The GenServer is the correct OTP primitive (not a bare timer or inlined into the store)

- **Claim (C):** "`Tau.Memory.RetrySweeper`, a new `GenServer` child under
  `Tau.Memory.Supervisor`, whose sole responsibility is periodically querying
  the DB for `"pending"` and `"failed"`/transient rows and re-dispatching
  `embedder.embed/3`."
- **Grounds (G):** Solution.md §Selected from — Proposal 2 rejected because
  "A sweep bug can stall or crash the store; there is no process isolation."
  Proposal 3 rejected for open-ended time bound in write-idle case. The solution
  description explicitly names a separate supervised GenServer. OTP
  non-negotiable #3 states "No GenServer wrapping stateless logic" — the sweeper
  has stateful periodic-timer logic (the `:sweep` message cycle), satisfying the
  non-negotiable's carve-out.
- **Warrant (W):** Separating the retry concern into its own supervised process
  follows OTP non-negotiable #1 (stateful subsystems as supervised processes)
  and gives crash isolation: a bug in sweep logic cannot stall the store's
  mailbox.
- **Qualifier (Q):** Provided the interval configuration is thread-local to the
  sweeper's state (not shared `Application.put_env`); if the interval is written
  via `Application.put_env` at runtime it would violate non-negotiable #1's
  spirit, but the solution specifies reading it in `init/1` — this is standard
  practice and acceptable.
- **Rebuttal (R):** OTP non-negotiable #3 warns against GenServers wrapping
  stateless logic. If `list_retriable/1` + dispatch were purely functional and
  idempotent, a `GenServer` wrapper would be marginal. However, the timer-loop
  state (the `after` reference, the interval, the last-run metadata) is
  inherently stateful, so the non-negotiable is not violated.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §1 and §3.
  Solution.md scoring table (Proposal 2 disqualification rationale).

#### Falsification attempt for claim 2

- **Strategy:** Dependency check — verify that `Tau.Memory.Supervisor` uses
  `:one_for_one`, so adding a child does not change the restart semantics of
  existing children.
- **Attempt:** `lib/tau/memory/supervisor.ex:32` — `Supervisor.init(children,
  strategy: :one_for_one)`. Adding `RetrySweeper` as a sibling does not affect
  the restart policy of `Store.SQLite`.
- **Outcome:** Withstood — `:one_for_one` is confirmed; the claim about
  independent failure is accurate.
- **Action:** None.

---

### Claim 3: `list_retriable/1` is additive-only and does not modify existing store callbacks

- **Claim (C):** "`Tau.Memory.Store.SQLite` — no changes to existing callbacks
  or the write/embedding path; `list_retriable/1` is additive only."
- **Grounds (G):** The proposed store addition is a new `handle_call(:list_retriable, ...)`
  clause and a public `list_retriable/1` function. The existing `handle_call`
  clauses at `lib/tau/memory/store/sqlite.ex:190–289` are not touched. No
  change to `do_write/2`, `do_mark_embedding_failed/3`, `do_store_embedding/3`,
  or `handle_continue/2`.
- **Warrant (W):** Adding a new `handle_call` pattern to a GenServer does not
  change the semantics of existing patterns; Elixir/Erlang pattern-match
  dispatch is order-sensitive but the new clause matches a new atom `:list_retriable`
  that has no existing handler, eliminating any shadowing risk.
- **Qualifier (Q):** Absent a pre-existing `handle_call(:list_retriable, ...)` clause
  (confirmed absent in the current file), this is non-invasive.
- **Rebuttal (R):** If a future PR adds a wildcard `handle_call` catch-all
  before the new clause, the new clause would be shadowed. This is a future
  authoring risk, not a current one.
- **Backing (B):** `lib/tau/memory/store/sqlite.ex:190–289` (no existing
  `:list_retriable` clause). SPEC-MEMORY-STORE.md Appendix B source map
  (identifies `store/sqlite.ex` as in-scope; additive changes are compatible
  with C-001, C-002).

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction — attempt to find a path where
  adding `list_retriable/1` changes an existing callback's observable behaviour.
- **Attempt:** The new clause matches `{:list_retriable, opts}`. No existing
  clause matches this tuple (confirmed by scanning lines 190–289). The SQL query
  inside the new handler is a SELECT; it holds no write lock (SQLite WAL allows
  concurrent reads). The mailbox serialisation still applies, so high-frequency
  sweep calls compete with writes — but this is a performance concern, not a
  correctness change to existing callbacks.
- **Outcome:** Withstood — no counter-example found.
- **Action:** None.

---

### Claim 4: `do_store_embedding` is idempotent, making duplicate-embedding races safe

- **Claim (C):** "The store's `do_store_embedding` is claimed to be idempotent
  (DELETE + INSERT in a transaction) — this should be verified in the
  implementation PR."
- **Grounds (G):** `lib/tau/memory/store/sqlite.ex:543–576` — `do_store_embedding/3`
  executes `BEGIN`, `DELETE FROM memory_vec WHERE entry_id = ?1`,
  `INSERT INTO memory_vec(entry_id, embedding) VALUES (...)`, `COMMIT`, then
  `update_embedding_status(db, entry_id, "ready")`. The DELETE is unconditional;
  the INSERT follows. This implements DELETE-then-INSERT inside a transaction.
- **Warrant (W):** DELETE-then-INSERT is idempotent for the `memory_vec` row.
  However, idempotency of the overall operation requires that the final
  `embedding_status` is deterministic regardless of call order. Two concurrent
  calls complete independently; the second call's `update_embedding_status` to
  `"ready"` overwrites the first's — both calls produce `"ready"` — so the
  status outcome is idempotent.
- **Qualifier (Q):** *Narrowed (partial falsification below):* Idempotency holds
  for the `embedding_status` and `memory_vec` row **when both embed calls
  succeed**. When one call succeeds and a subsequent sweep dispatches a second
  call for the same entry — which is now `"ready"` — `list_retriable/1` MUST
  exclude `"ready"` entries or the second embed call is a wasted round-trip (not
  a correctness failure, since the status will be set to `"ready"` again).
- **Rebuttal (R):** If `list_retriable/1` queries entries that have transitioned
  to `"ready"` between the query and the dispatch (TOCTOU on the status column),
  an extra `embed/3` call fires. This is a wasted network call but does not
  corrupt the store — the final status converges to `"ready"`.
- **Backing (B):** `lib/tau/memory/store/sqlite.ex:543–576`. SQLite
  transaction semantics (serialized writes through the GenServer mailbox, per
  D-045). SPEC-MEMORY-STORE.md §6 D-045.

#### Falsification attempt for claim 4

- **Strategy:** Edge-case enumeration — enumerate the TOCTOU window between
  `list_retriable/1` returning an entry and `embed/3` completing.
- **Attempt:** Scenario A: Entry is `"pending"` when `list_retriable/1` runs.
  Before the sweeper dispatches `embed/3`, the original write-triggered embed
  call completes and sets status to `"ready"`. The sweeper now dispatches a
  second `embed/3`. Both calls complete successfully; `memory_vec` ends with the
  second call's vector; status is `"ready"`. No data corruption — but two
  embedding API calls are made for one entry.

  Scenario B: Entry is `"pending"`. Sweeper dispatches second `embed/3`. Both
  embed calls are in flight concurrently. The first completes (`BEGIN` / DELETE
  / INSERT / COMMIT / `update_embedding_status`). The second then runs its
  `BEGIN` — it will delete the first's vector row and insert a new one. Both
  complete; status `"ready"`; `memory_vec` row reflects whichever INSERT ran
  last. No corruption; extra API cost.

  Scenario C: `list_retriable/1` returns a `"failed"` / transient row. The
  sweeper dispatches `embed/3`. Before the task completes, another write to the
  same entry calls `delete/1`, removing it. `do_store_embedding` then tries to
  `UPDATE memory_entries SET embedding_status = 'ready' WHERE id = ?` — the row
  is gone, so `update_embedding_status` runs but affects 0 rows (no error
  surfaced, since the UPDATE returns `:done` regardless of rows affected). The
  `memory_vec` INSERT references a deleted `entry_id` — the FK constraint (if
  any) would reject it, but the schema in Appendix A does not declare a FK from
  `memory_vec` to `memory_entries`. A dangling vector row could exist. This is a
  narrow edge case (delete during active retry) and is a pre-existing risk in
  the write path, not introduced by the sweeper.

- **Outcome:** Partially falsified — the claim that idempotency makes
  duplicate-embedding races "safe" is too broad. In Scenario C (delete during
  retry), a dangling `memory_vec` row can result. The qualifier is narrowed: the
  DELETE + INSERT pattern is idempotent **absent concurrent deletion of the
  entry**. The solution's "should be verified in the implementation PR" language
  already acknowledges uncertainty; narrowing the qualifier is appropriate rather
  than triggering a solution revision.
- **Action:** Narrow qualifier (done above). Note as outstanding doubt for
  parent-level validator.

---

### Claim 5: `Tau.Memory.Embedder.embed/3` requires no new callbacks; the sweeper calls it as-is

- **Claim (C):** "`Tau.Memory.Embedder` behaviour — no new callbacks; `embed/3`
  is called exactly as it is today."
- **Grounds (G):** `lib/tau/memory/embedder.ex:37` — the behaviour defines a
  single callback `@callback embed(store, entry_id, content)`. The sweeper
  retrieves `content` from the store via `list_retriable/1` (new query) and
  passes it to `embed/3` with the same three-argument signature.
  `lib/tau/memory/embedding_worker.ex:49` implements this callback
  identically for all callers.
- **Warrant (W):** A behaviour with a stable three-argument callback can be
  invoked by any caller who can supply the three arguments. The sweeper supplies
  (store_pid, entry_id, content) just as `handle_continue/2` does at
  `lib/tau/memory/store/sqlite.ex:305–313`. No new dispatch surface is needed.
- **Qualifier (Q):** The sweeper must retrieve `content` from the store as part
  of `list_retriable/1`'s return payload. If the new query omits `content` from
  its column list, the sweeper cannot call `embed/3` without an additional
  round-trip. The solution does not specify the SQL column list for
  `list_retriable/1`; the implementation PR must include `content` in the SELECT.
- **Rebuttal (R):** If `list_retriable/1` returns only `(id, embedding_status,
  metadata)` without `content`, the sweeper cannot reconstruct the `embed/3`
  call without a follow-up `SELECT content FROM memory_entries WHERE id = ?1` —
  adding mailbox contention and complexity. This is an implementation detail not
  in scope for the solution; the solution is correct in principle.
- **Backing (B):** `lib/tau/memory/embedder.ex:37`. `lib/tau/memory/store/sqlite.ex:305–313`
  (existing embed dispatch pattern). `lib/tau/memory/embedding_worker.ex:49`.

#### Falsification attempt for claim 5

- **Strategy:** Integration check — verify that the call site shape used by
  `handle_continue/2` is reproducible by the sweeper without a behaviour change.
- **Attempt:** `handle_continue({:dispatch_embedding, id, content}, state)` at
  line 305 passes `(server, id, content)` to `embedder.embed/3`. The sweeper
  needs the same three values. `list_retriable/1` can return rows with `id` and
  `content` included (the `memory_entries` table has `content` as a NOT NULL
  column). The sweep therefore has all three arguments available from a single
  query result without behaviour changes.
- **Outcome:** Withstood — no integration gap found, given `list_retriable/1`
  returns `content`.
- **Action:** None. Implementation PR must include `content` in the SQL SELECT.

---

### Claim 6: The supervision strategy stays `:one_for_one`; sweeper and store fail independently

- **Claim (C):** "The supervision strategy stays `:one_for_one`; sweeper and
  store fail independently."
- **Grounds (G):** `lib/tau/memory/supervisor.ex:32`: `Supervisor.init(children,
  strategy: :one_for_one)`. The solution explicitly states "add
  `{Tau.Memory.RetrySweeper, opts}` as a `:one_for_one` sibling after
  `Store.SQLite`" — no strategy change required.
- **Warrant (W):** Under `:one_for_one`, a child crash restarts only that child.
  A sweeper crash (e.g. bug in sweep logic) does not restart `Store.SQLite`.
  A store crash does not restart the sweeper (though the sweeper's next
  `list_retriable/1` call will block until the store restarts, then succeed or
  return an error that the sweeper must handle gracefully).
- **Qualifier (Q):** The sweeper's `list_retriable/1` call will return an error
  or block during a store restart. The sweeper must handle `{:error, reason}`
  from `GenServer.call` (including `:noproc` / `:timeout`) gracefully — logging
  and rescheduling — otherwise the sweeper itself crashes on the store's
  transient restart, converting one crash into two. The solution does not
  explicitly specify error handling in the sweep loop; the implementation PR must
  address this.
- **Rebuttal (R):** If the sweeper does not guard against store unavailability,
  a store restart triggers a sweeper crash, and under `:one_for_one` both
  restart independently — the claimed independence still holds structurally, but
  the effective restart rate doubles. This is a design detail, not a falsification
  of independence.
- **Backing (B):** `lib/tau/memory/supervisor.ex:32`. OTP non-negotiable #7
  (`.claude/rules/otp-non-negotiables.md`): "Let it crash; supervise; restart."
  `:one_for_one` semantics (OTP Supervisor documentation).

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — construct a scenario where adding
  `RetrySweeper` under `:one_for_one` changes the existing restart behaviour of
  `Store.SQLite`.
- **Attempt:** Under `:one_for_one`, each child is independent. The only way
  adding a sibling changes an existing child's restart behaviour is if the
  supervisor's `max_restarts` / `max_seconds` threshold is tripped — if the
  sweeper crashes frequently, the supervisor itself terminates, taking
  `Store.SQLite` with it. This is a cascade via the supervisor's intensity
  threshold, not via the child relationship. It is a known `:one_for_one`
  property and not a property of this specific design.
- **Outcome:** Withstood — the structural claim is accurate. The intensity-
  threshold cascade is a general OTP property acknowledged by "let it crash;
  supervise; restart" and is not a novel risk introduced by this design.
- **Action:** None.

---

## Cross-claim consistency

Claims 1–6 are mutually consistent:

- Claims 1 and 2 are complementary: Claim 2 argues for the correct primitive
  (GenServer); Claim 1 argues the design satisfies the acceptance criterion.
- Claim 3 (additive store change) and Claim 5 (no new embedder callbacks) align
  on the "minimal surface" design principle; neither contradicts the other.
- Claim 4's narrowed qualifier (idempotency absent concurrent deletion) is
  consistent with Claim 6's independent-failure assurance: a sweeper dispatch
  racing a delete is an application-level concern, not a supervision concern.
- Claim 6's sweeper-must-handle-store-unavailability qualifier is an
  implementation-detail gap, not a tension with other claims.

No cross-claim tension identified.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Sweeper satisfies bounded-time re-submission AC | Edge-case enumeration | Withstood | None |
| 2 | GenServer is correct OTP primitive; not inlined | Dependency check | Withstood | None |
| 3 | `list_retriable/1` is additive; no existing callback change | Counter-example construction | Withstood | None |
| 4 | `do_store_embedding` idempotency makes races safe | Edge-case enumeration | Partially falsified | Qualifier narrowed: safe absent concurrent entry deletion |
| 5 | `embed/3` called as-is; no new behaviour callbacks | Integration check | Withstood | Impl PR must include `content` in `list_retriable/1` SELECT |
| 6 | Supervision stays `:one_for_one`; independent failure | Counter-example construction | Withstood | None |

---

## Revision required

No revision is required. Claim 4's partial falsification is addressed by
narrowing the qualifier in place. The solution remains correct and
appropriately scoped.

---

## Outstanding doubts

1. **Dangling `memory_vec` row on concurrent delete-during-retry (Claim 4,
   Scenario C).** The schema at SPEC-MEMORY-STORE.md Appendix A does not declare
   a FK constraint from `memory_vec(entry_id)` to `memory_entries(id)`. A sweep
   that races a delete can leave a vector row referencing a deleted entry. This
   is pre-existing structural debt, not introduced by the sweeper, but the sweeper
   makes the race reachable in production for the first time. The implementation
   PR should either add an ON DELETE CASCADE FK on `memory_vec.entry_id`, or
   ensure `list_retriable/1` is called within a short enough window that an
   in-progress delete makes the entry disappear from the result set.

2. **Sweeper error handling on store unavailability (Claim 6).** The solution
   does not specify how the sweeper handles `GenServer.call` errors (`:noproc`,
   `:timeout`) when the store is mid-restart. The implementation PR must
   explicitly handle these to prevent the sweeper from crashing on the store's
   transient restart interval.

3. **`list_retriable/1` column set not specified.** The solution describes the
   API ("returning retriable entries") without specifying the return shape. The
   implementation PR must return at minimum `(id, content)` for the sweeper to
   reconstruct the `embed/3` call without a second query.

4. **Startup latency (solution's Open Question 3).** The solution notes that
   the first sweep fires after one full interval (default 60 s). Entries stuck
   before the last restart will wait up to 60 s. This is flagged but deferred;
   a `{:continue, :startup_sweep}` in `init/1` is trivially addable in the
   implementation PR without altering the solution's design.
