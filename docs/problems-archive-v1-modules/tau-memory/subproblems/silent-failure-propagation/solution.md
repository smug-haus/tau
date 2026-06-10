---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-4.md]
selection_method: hybrid
revision: 0
---

# Solution: Ref-map in GenServer state + structured-result embedder contract

## Recommendation

Adopt a hybrid of Proposal 1 and Proposal 4. The immediate crash-detection
gap is closed exactly as Proposal 1 describes — a `%{reference() => entry_id}`
map in `Store.SQLite` state, populated at dispatch and consumed by a real
`{:DOWN, ref, ...}` clause that calls `do_mark_embedding_failed/3` with
`:transient`. Simultaneously, adopt Proposal 4's inversion-of-control
elimination: change the `Tau.Memory.Embedder` behaviour so `embed_async/1`
returns a Task whose result message is `{:ok, embedding} | {:error, kind,
reason}` delivered to the GenServer's mailbox, making the Store the sole
writer and removing the callback-from-worker pattern. The `{ref, result}`
success clause handles the result value directly instead of discarding it.
Together, the crash path and the success path become symmetric, both routed
through `handle_info` using the same ref map — directly decomplecting task
identity from entry identity and eliminating the inversion-of-control that
made crash outcomes invisible.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-1.md` and `proposals/proposal-4.md`
- **Why chosen:** Proposal 1 directly addresses the problem's named complects
  with minimal risk and no rule violations, but leaves the inversion-of-control
  intact — the `{ref, result}` success clause still silently discards the result
  because the worker calls back separately. Proposal 4 eliminates the
  inversion-of-control root cause and makes the success path carry the result
  as a value, but this is only sound combined with the ref map (Proposal 1's
  contribution), since the crash path still needs `(ref → entry_id)` to act.
  Proposal 2 is eliminated by the OTP non-negotiable rule 7 hard block
  (`try/rescue` across process boundaries). Proposal 3 is sound OTP but
  carries the `trap_exit` correctness caveat (without `trap_exit: true`,
  `terminate/2` is not called on abnormal exits), requires two new modules,
  and demands an API-breaking `embed_sync/1` callback — higher migration cost
  for no additional fit over the hybrid. The hybrid combines Proposal 1's
  targeted ref-map fix (low risk, reuses existing `do_mark_embedding_failed/3`)
  with Proposal 4's structural improvement (removes inversion-of-control,
  makes success and crash symmetric), and satisfies the acceptance criterion
  more completely than either alone.

## Scoring table

| #  | Fit        | Decomplecting depth | Migration cost | Risk   | Reversibility |
|----|------------|---------------------|----------------|--------|---------------|
| 1  | Yes        | Substantial         | Low            | Low    | Easy          |
| 2  | Partially  | Surface             | Low            | High   | Easy          |
| 3  | Yes        | Deep                | High           | Medium | Hard          |
| 4  | Yes        | Deep                | Medium         | Medium | Medium        |
| H  | Yes        | Deep                | Medium         | Low    | Medium        |

*H = selected hybrid (1 + 4). Fit "Partially" for Proposal 2 because the
double-spawn layering means the `rescue` block may not fire for the primary
failure mode; the OTP rule violation is a hard gate block regardless.*

## What changes

- **`lib/tau/memory/store/sqlite.ex`**
  - State type extended: add `pending_tasks: %{reference() => String.t()}`;
    `init/1` initialises to `%{}`.
  - `handle_continue({:dispatch_embedding, id, content}, state)`: call
    `embedder.embed_async(content)` (new behaviour callback), capture the
    returned Task ref, store `ref → id` in `pending_tasks`.
  - `handle_info({ref, embed_result}, state)`: demonitor, remove from map,
    call `do_store_embedding/3` on `{:ok, embedding}` or
    `do_mark_embedding_failed/3` on `{:error, kind, _reason}`.
  - `handle_info({:DOWN, ref, :process, _pid, reason}, state)` where
    `reason != :normal`: look up entry ID in map, call
    `do_mark_embedding_failed/3` with `:transient`, remove from map.
  - `handle_call({:store_embedding, ...})` clause: remove (no external
    caller after this change).

- **`lib/tau/memory/embedding_worker.ex`**
  - Remove `store_embedding/3` call-back logic.
  - Implement new `embed_async/1` callback: start a `Task.Supervisor.async_nolink`
    whose body calls the HTTP/vector endpoint and returns
    `{:ok, embedding} | {:error, kind, reason}`. Return `{:ok, task}`.
  - The existing `embed/3` (fire-and-forget with callback) is removed.

- **`lib/tau/memory/embedder.ex`** (behaviour module)
  - Replace `embed/3` callback declaration with `embed_async/1 ::
    {:ok, Task.t()} | {:error, term()}`.

- **`lib/tau/memory/memory_store.ex`** (public API)
  - Remove `store_embedding/3` public function (no external callers remain).

- **`test/`** — all embedder test doubles that implement `Tau.Memory.Embedder`
  must implement `embed_async/1` instead of `embed/3`.

## What does not change

- `do_mark_embedding_failed/3` in `Store.SQLite` — already exists at line 286;
  invoked without modification.
- `do_store_embedding/3` in `Store.SQLite` — already exists; now called from
  `handle_info` rather than `handle_call`.
- `Tau.Memory.Supervisor` child list — no new supervised children.
- `Tau.Memory.EmbeddingSupervisor` / `EmbeddingTask` — not introduced (Proposal
  3 elements excluded).
- D-046 invariant semantics — `"failed"` with `:transient` error kind; unchanged.
- `embedding_status` column schema — unchanged.

## Migration sketch

1. Amend `Tau.Memory.Embedder` behaviour first (add `embed_async/1`, mark
   `embed/3` deprecated or remove it).
2. Update `EmbeddingWorker` to implement `embed_async/1`; remove callback to
   `store_embedding/3`.
3. Update `Store.SQLite`: extend state, replace `handle_continue`, add real
   `{:DOWN, ...}` clause body, update `{ref, result}` clause to consume result
   value; remove `handle_call({:store_embedding, ...})`.
4. Remove `MemoryStore.store_embedding/3` public function.
5. Update all test doubles in `test/` to implement `embed_async/1`.
6. Add one test: kill the Task ref, assert DB row transitions to
   `embedding_status: "failed"`; add one regression test for the success path
   via `{ref, {:ok, embedding}}`.

Steps 1–2 are prerequisite to 3; 3–4 ship together; 5–6 accompany 3–4.

## Open questions

- **Inner-Task layering in `EmbeddingWorker`**: the current `embed/3` at line
  51 of `embedding_worker.ex` spawns its own inner Task. The new `embed_async/1`
  must resolve whether to flatten to a single Task (cleanest) or forward the
  inner ref. This must be decided before step 2 of migration; incorrect routing
  means `{ref, result}` never reaches the GenServer's mailbox.
- **`{ref, result}` clause guard**: the clause `when is_reference(ref)` must not
  accidentally match unrelated messages with a reference in position 0. Review
  the GenServer's full message surface before landing.
- **`{:DOWN, :normal}` double-cleanup**: if the Task exits `:normal` because the
  callback succeeded (the pre-change code path for embedders that don't adopt
  `embed_async/1` during a partial rollout), both `{ref, result}` and
  `{:DOWN, :normal}` fire; the map lookup in the `:DOWN` clause must tolerate
  `Map.fetch/2` returning `:error` (already guarded in Proposal 1's sketch).

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Ref-to-ID map in GenServer state (crash path fix;
  directly addresses both named complects; low cost, reuses existing
  `do_mark_embedding_failed/3`)
- `proposals/proposal-2.md` — `try/rescue/catch` wrapper (eliminated: OTP
  non-negotiable rule 7 hard block; double-spawn layering means the rescue may
  not fire for the primary failure mode)
- `proposals/proposal-3.md` — `EmbeddingTask` supervised process per entry
  (sound OTP but `trap_exit` caveat is non-trivial, two new modules, API-breaking
  `embed_sync/1`, higher cost for equivalent fit)
- `proposals/proposal-4.md` — Structured-result embedder contract (inversion-of-
  control elimination; complements Proposal 1 by making success and crash paths
  symmetric and removing the callback API)

## Revision history

- (revision 0 — initial)
