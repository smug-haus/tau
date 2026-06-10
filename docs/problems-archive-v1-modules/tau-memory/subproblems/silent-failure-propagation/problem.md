---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Task crash before store-embedding callback leaves entry permanently "pending"

## Statement

When the embedding Task spawned by `Store.SQLite.handle_continue/2` crashes
(e.g. because Finch raises `:noproc`), it exits without ever calling
`Store.SQLite.store_embedding/3`. The `handle_info/2` clause in `Store.SQLite`
silently discards the `{:DOWN, ...}` message. The entry's `embedding_status`
therefore remains `"pending"` indefinitely — it never transitions to `"failed"`,
so the D-046 invariant (`"failed"` carries the error kind) is never applied, and
the entry is excluded from `semantic_search/2` forever with no actionable signal.

## Context

- `lib/tau/memory/store/sqlite.ex:296-302` — `handle_info/2` for `{ref, _result}` and `{:DOWN, ...}` both `{:noreply, state}` silently; no callback to `store_embedding` and no status update.
- `lib/tau/memory/store/sqlite.ex:305-313` — `handle_continue({:dispatch_embedding, id, content}, state)` spawns via `Task.Supervisor.async_nolink`; does not store the task ref associated with `id`.
- `lib/tau/memory/embedding_worker.ex:49-71` — the `embed/3` Task body calls `MemoryStore.store_embedding/3` only on normal exit; an exception or `:noproc` before that call means the callback never fires.
- D-046 (`SPEC-MEMORY-STORE.md`) — requires `embedding_status` to be `"pending" | "ready" | "failed"` with `"failed"` carrying the error kind. The stuck-`"pending"` state violates the spirit of this invariant.

## Complecting hypothesis

- Task identity is complected with the entry it was dispatched for: the store holds no `(ref → entry_id)` mapping, so it cannot act on a `{:DOWN, ...}` message to update the entry's status.
- The "task completed normally" path and the "task crashed" path are complected in the same silent `handle_info/2` discard clause, erasing the distinction between a completed callback and a lost callback.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

When the embedding Task exits abnormally (crash, exception, or process-not-found)
before calling `store_embedding/3`, the corresponding memory entry transitions
to `embedding_status: "failed"` with kind `:transient` within the task's
monitored lifetime — satisfying D-046.

## Out of scope

- The root-cause Finch name mismatch that triggers the crash (covered by `finch-name-mismatch`).
- Observability of aged `"pending"` entries that predate this fix (covered by `pending-rot-observability`).
- Re-enqueuing already-stuck entries (covered by `retry-recovery-path`).

## Amendment log

- (none yet)
