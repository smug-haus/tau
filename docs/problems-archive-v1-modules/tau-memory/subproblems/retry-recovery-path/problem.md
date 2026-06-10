---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: No mechanism exists to re-enqueue stuck "pending" or transient-failed entries

## Statement

`Tau.Memory.EmbeddingWorker` classifies `Mint.TransportError` and generic
network errors as `:transient`, meaning they are eligible for retry. However,
once an entry sits in `embedding_status: "pending"` (lost Task) or
`embedding_status: "failed"` with `embedding_error_kind: "transient"`, there is
no scheduled sweep, GenServer timer, or API call that re-dispatches embedding for
it. Fixing the Finch name mismatch and the silent-crash path will prevent new
entries from getting stuck, but all entries already stuck — including any
accumulated during the broken period — will remain permanently unreachable to
`semantic_search/2` unless manually handled.

## Context

- `lib/tau/memory/store/sqlite.ex` — no `handle_info(:timeout, ...)`, `Process.send_after/3`, or periodic sweep for stale `"pending"` / transient-`"failed"` rows.
- `lib/tau/memory/supervisor.ex` — supervises only `Store.SQLite`; no worker or periodic-task child for re-embedding.
- `lib/tau/memory/embedder.ex` — `embed/3` callback is fire-and-forget; the behaviour has no `retry/2` or `requeue/1` surface.
- D-046 (`SPEC-MEMORY-STORE.md`) — `"failed"` with `:transient` kind implies the failure is retryable, but the spec does not prescribe a retry mechanism.
- OTP non-negotiable #1: stateful subsystems must run as supervised processes; a retry sweep belongs under `Tau.Memory.Supervisor`, not as an ad-hoc timer in the GenServer.

## Complecting hypothesis

- The retryability classification (`:transient` / `:terminal`) is complected with the absence of a retry trigger: the classification is recorded in metadata but nothing reads it to act.
- The recovery concern (re-enqueue stuck entries) is complected with the observability concern (knowing which entries are stuck): without observability, recovery must query the DB directly; with observability, recovery can be event-driven.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

After the Finch name mismatch is fixed, any memory entry that is in
`embedding_status: "pending"` or `embedding_status: "failed"` with
`embedding_error_kind: "transient"` is automatically re-submitted for embedding
without operator intervention, within a bounded time window.

## Out of scope

- The root-cause Finch name mismatch (covered by `finch-name-mismatch`).
- The Task-crash-without-callback path (covered by `silent-failure-propagation`).
- Observability of the stuck state (covered by `pending-rot-observability`), though the retry mechanism should emit telemetry for re-enqueue events.
- Terminal failures (`embedding_error_kind: "terminal"` — content-too-long, policy rejection) are not retried by definition.

## Amendment log

- (none yet)
