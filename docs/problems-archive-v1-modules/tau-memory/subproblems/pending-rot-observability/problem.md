---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Stuck "pending" entries are indistinguishable from in-flight embeddings

## Statement

`embedding_status: "pending"` is used both for entries whose embedding Task is
legitimately in flight (expected to resolve within `@request_timeout_ms = 30 s`)
and for entries whose Task has already crashed or whose callback was silently
lost. There is no telemetry event, log line, or gauge that distinguishes these
two cases or that alerts when entries age past the expected embedding window.
Operators cannot determine whether the embedding pipeline is functioning without
querying the database directly; degradation is invisible until a user notices
that `semantic_search/2` returns no results.

## Context

- `lib/tau/memory/embedding_worker.ex:52-68` — emits `[:tau, :memory, :embedding]` telemetry via `:telemetry.span`, but only on Task normal-exit; a Task crash before the span fires produces no telemetry at all.
- `lib/tau/memory/store/sqlite.ex:190-220` — `handle_call({:write, ...})` emits `[:tau, :memory, :write]` telemetry but no follow-on event tracking that embedding dispatch was initiated.
- No scheduled check, GenServer timer, or periodic sweep exists anywhere in `lib/tau/memory/` to detect stale `"pending"` entries.
- OTP non-negotiable #5 (`otp-non-negotiables.md`): telemetry events MUST cover everything user-visible or perf-sensitive; semantic search degradation is user-visible.

## Complecting hypothesis

- The "in-flight" status and the "silently stuck" status are complected in the same `"pending"` value, making it impossible to distinguish the two states from the outside without knowing the entry's age.
- The absence of a completion-tracking mechanism is complected with the absence of an alerting mechanism: both gaps reinforce each other, so adding observability alone does not fix the missing callback, and fixing the callback alone still leaves no visibility into pre-existing stuck entries.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

An operator can determine — without querying the database directly — whether any
memory entries have been in `embedding_status: "pending"` longer than the
embedding timeout, via a telemetry event or structured log line that fires when
such entries are detected.

## Out of scope

- The root-cause Finch name mismatch (covered by `finch-name-mismatch`).
- Fixing the Task-crash-without-callback path (covered by `silent-failure-propagation`).
- Re-enqueuing stuck entries once detected (covered by `retry-recovery-path`).
- FTS5 search observability.

## Amendment log

- (none yet)
