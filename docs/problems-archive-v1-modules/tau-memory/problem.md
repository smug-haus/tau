---
template_version: 1
template_name: problem
node_kind: internal
depth: 0
parent: —
status: decomposed
---

# Problem: Embedding pipeline is silently broken under default configuration

## Statement

`Tau.Memory.EmbeddingWorker` defaults its Finch pool name to `Tau.Finch`
(`embedding_worker.ex:106`), but `Tau.Application` registers the pool as
`Tau.Providers.Finch` (`application.ex:78`). Every embedding request made
without an explicit `:tau, :finch_name` override resolves to a non-existent
process, returns `{:error, :transient, ...}`, and leaves the entry with
`embedding_status: "pending"` indefinitely. The failure is invisible: no log
line names the real cause, no metric fires, and no operator signal surfaces that
semantic search is permanently degraded.

## Context

- `lib/tau/memory/embedding_worker.ex:106` — `Application.get_env(:tau, :finch_name, Tau.Finch)`; the default is a name that does not exist in the supervision tree.
- `lib/tau/application.ex:78` — `{Finch, name: Tau.Providers.Finch}` — the only Finch pool registered.
- `lib/tau/memory/store/sqlite.ex:306` — `handle_continue/2` dispatches embedding via the configured embedder; no return-value check on the dispatch.
- `lib/tau/memory/store/sqlite.ex:279-288` — `handle_call({:store_embedding, ...})` accepts `{:error, :transient, _}` and calls `do_mark_embedding_failed/3`, setting `embedding_status = "failed"`. But with the noproc failure the Task crashes before calling back, so the entry stays `"pending"`.
- `SPEC-MEMORY-STORE.md` D-045/D-046 — connection-ownership and embedding-status invariants are satisfied by the design; this bug is a configuration/wiring defect, not a design defect.
- `.code_audit/archive/v1-flat/06-infrastructure.md §9` — classified as a critical bug (cross-system identifier drift).

## Complecting hypothesis

- The Finch pool name used at call-site is complected with the name declared in the supervision tree because there is no shared constant or compile-time reference binding them; the two sites drifted independently.
- The error classification path (transient/terminal) is complected with the observability path: a noproc crash that never calls back produces an entry that looks identical to a legitimately in-flight embedding, hiding the failure class from operators.
- Recovery semantics (retry transient failures) are complected with the absence of a retry trigger: the "transient" classification implies retryability, but there is no mechanism to re-enqueue pending entries after a configuration fix or transient fault clears.

## Decomposition strategy

The parent problem decomposes cleanly along **failure layer**: each sub-problem
owns one distinct layer at which the failure manifests or needs to be addressed.
The four layers are mutually exclusive (a concern belongs to exactly one layer)
and collectively exhaustive (every aspect of the broken pipeline — the root
cause, the crash propagation, the persistent degraded state, and the recovery
path — is covered):

1. **Configuration wiring** — the wrong Finch name at the call-site (root cause).
2. **Crash-to-callback propagation** — the noproc crash kills the Task without triggering the store-embedding callback, leaving entries in `"pending"` rather than `"failed"`.
3. **Observability of pending rot** — `"pending"` entries are indistinguishable from legitimately in-flight embeddings; no telemetry or log surfaces the stuck state.
4. **Retry / recovery path** — once the wiring is fixed (or a transient fault clears), there is no mechanism to re-enqueue stuck `"pending"` entries.

## Sub-problems (filled by decomposer)

1. **finch-name-mismatch** — Fix the root-cause configuration drift: align the Finch pool name used by `EmbeddingWorker` with the name registered in `Tau.Application`.
2. **silent-failure-propagation** — Address the Task-crash-without-callback path: when the embedding Task crashes before calling `store_embedding/3`, the entry must transition to `"failed"` rather than remaining `"pending"`.
3. **pending-rot-observability** — Surface stuck `"pending"` entries to operators: telemetry events and/or log warnings that fire when entries age past an expected embedding window.
4. **retry-recovery-path** — Provide a mechanism to re-enqueue `"pending"` or `"failed: transient"` entries so they can be embedded after a configuration fix or transient fault clears.

## Acceptance criterion

Every memory entry written under the default application configuration either
reaches `embedding_status: "ready"` when the embedding API responds successfully,
or transitions to `embedding_status: "failed"` with an actionable log/telemetry
event, within the request timeout window — and no entry remains permanently in
`embedding_status: "pending"` due to a wiring defect or silent crash.

## Out of scope

- The embedding model, dimension, or API provider selection.
- FTS5 search correctness (`search/2`).
- SQLite migration correctness.
- `Tau.Memory.Loader` (loads `TAU.md` files; unrelated to embeddings).
- Performance of the embedding pipeline under load.

## Amendment log

- (none yet)
