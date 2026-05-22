# ADR-0019: Circuit breaker uses an ETS-owner shape, not a GenServer-per-resource

- **Status:** Accepted
- **Date:** 2026-05-18
- **Deciders:** the agent loop, with no objection from @smug-haus
- **Related:**
  - Issue: #65 (M2)
  - Spec: `docs/spec/SPEC-CIRCUIT-BREAKER.md`
  - Prior: ADR-0010 (cost tracker owns ETS — the ETS-owner precedent),
    ADR-0011 (per-provider rate limiter is a stateful GenServer — the
    contrasting pattern), ADR-0012 (provider fallback is FSM-internal retry)

## Context

The circuit breaker must gate outgoing provider calls in `:closed`,
`:open`, and `:half_open` states. Every concurrent session-turn task
reads the breaker state on each provider call; failures and successes
update it. The question is whether this is better served by the
GenServer-per-resource shape (ADR-0011) or the ETS-owner shape
(ADR-0010).

### Why ADR-0011's GenServer shape does not fit here

ADR-0011 chose a GenServer for the rate limiter because:

1. Token-bucket arithmetic is intrinsically serial — `take(bucket, n)`
   depends on the result of every prior `take` since the last refill.
   The counter update cannot be expressed as a CRDT-style merge.
2. Wait queues are intrinsically serial — when the bucket is empty,
   callers block on `GenServer.call/3`. The GenServer mailbox *is* the
   wait queue.
3. Reads and writes are 1:1 — every provider call is exactly one
   `acquire` call.

The circuit breaker does not share these properties:

1. **Counter writes commute.** Failure-count increments are independent;
   no increment depends on the previous increment's result. Two tasks
   that both observe failure and both increment `failure_count` produce
   the same result in either order. `:ets.update_counter/3` is atomic
   and handles this correctly without mailbox serialisation.
2. **No wait queue.** A circuit breaker never blocks callers. It either
   admits the call (`:closed` or admitted probe in `:half_open`) or
   rejects it immediately (`{:error, :circuit_open}`). There is no
   "wait until the breaker closes" semantic — callers receive the
   rejection and surface it to the user.
3. **Read fan-out is high.** Every concurrent session turn reads the
   breaker state before invoking the provider. With N active sessions,
   a GenServer mailbox would serialise N concurrent reads on every
   turn — the exact bottleneck ADR-0010 identified for the cost tracker.

### Why state transitions still require atomic operations

Although counter writes commute, full state transitions
(`:closed → :open`, `:open → :half_open`, etc.) must not race. Two
concurrent failure-count increments that both simultaneously compute
"we just crossed the threshold" must not both initiate an open
transition. This is handled by `:ets.select_replace/2` with a guard on
the current state field — a full-row CAS that only one process wins.
The loser treats the `0` match count as a no-op; its transition already
happened via the winner.

The half-open probe admission case requires the same treatment: exactly
one concurrent caller is admitted. `:ets.select_replace/2` on the
`probe_slot` field (`0 → 1`) provides the atomic swap; a match count of
`1` means admitted, `0` means rejected.

No state transition requires two separate ETS writes. The row layout
in SPEC §4 B2 is designed so that every transition is either a single
`update_counter` (counter bump) or a single `select_replace` (full-row
CAS). This is a binding constraint enforced by D-044.

### Why not a Manager GenServer

A single `Tau.CircuitBreaker.Manager` GenServer holding state for all
providers is forbidden by OTP non-negotiable #1 ("MUST NOT introduce a
Manager / Service GenServer for shared state"). Even a per-provider
GenServer is contraindicated by the absence of a wait-queue requirement
and the commutative-write property — it would serialise reads for no
benefit.

## Decision

`Tau.CircuitBreaker.Store` is a `GenServer` whose **only** job is to
own the ETS table named `:tau_circuit_breakers` and serve as its
lifecycle anchor. It exposes `probe_admitted?/1` (a synchronous call
that performs a `select_replace` on the `probe_slot` field) and
`transition/3` (for full-row state transitions via `select_replace`).
All reads and counter increments go directly to ETS from the caller
process — no `GenServer.call/3` serialisation.

Specifically:

- **Table options:**
  `:named_table, :public, :set, read_concurrency: true, write_concurrency: true`
- **Row layout (positional, fixed):**
  `{provider_key, state_atom, failure_count, success_count, opened_at_ms, probe_slot}`
- **Counter writes:** `:ets.update_counter/3` directly from the caller
  process. No mailbox hop.
- **State transitions:** `:ets.select_replace/2` via `Store` (GenServer
  call), which serialises only the CAS — not the reads or counter bumps.
- **Probe admission:** `:ets.select_replace/2` on `probe_slot` (0 → 1)
  via `Store` call. Returns `true` (admitted) or `false` (rejected).
- **Lifecycle:** `Store.init/1` creates the table; `Store.terminate/2`
  deletes it. A crash restarts the process and recreates the table
  empty — all breakers reset to `:closed`. Counter loss on crash is
  acceptable; breaker state is derived signal, not user data.

The pure state-machine logic lives in `Tau.CircuitBreaker.State`
(PR1): a struct and pure functions with no process or ETS dependency.
The public façade `Tau.CircuitBreaker` (PR3) composes `State` and
`Store` into the `call/3` entry point.

## Consequences

- Concurrent session turns read breaker state from ETS without touching
  the `Store` mailbox — read fan-out scales with scheduler count.
- Failure and success counter bumps are lock-free atomic operations.
- Full state transitions and probe admissions go through one `Store.call/3`
  per transition — a low-frequency operation (transitions happen at the
  failure-threshold boundary, not per call).
- Crashing `Store` resets all breaker state. Sessions experience a
  brief `:noproc` on any in-flight `probe_admitted?` or `transition`
  call; the supervisor restarts `Store` immediately. The cost is
  re-opening breakers that were already open — a safe conservative
  fallback (providers get another chance).
- `:tau_circuit_breakers` is `:public`; tests can seed rows directly.
  The table is named so tests can reset it via `:ets.delete_all_objects/1`.
- The row layout in §4 B2 of the SPEC is immutable within a schema
  version (D-044). Field additions require a schema-version bump.

## Alternatives considered

- **GenServer-per-provider (ADR-0011 shape).** Rejected: counter
  writes commute, no wait-queue requirement, read fan-out would be
  serialised through the mailbox unnecessarily.
- **Manager GenServer for all providers.** Rejected by OTP
  non-negotiable #1.
- **`:counters` BIF module.** Faster than ETS for raw counter bumps
  but provides no key-based lookup (each provider would need a separate
  ref stored elsewhere) and no conditional replace for CAS operations.
  ETS `select_replace` is the only atomic conditional write primitive
  available for keyed state.
- **`persistent_term`.** Write-once / read-many semantics; each write
  triggers a global GC scan. Circuit-breaker counters update on every
  provider call — `persistent_term` is inappropriate for high-frequency
  writes.
- **Exposing all writes through `Store` calls.** Rejected: serialising
  every failure-count increment through the GenServer mailbox
  re-introduces the bottleneck we are avoiding. Only the CAS operations
  (state transition, probe admission) need serialisation; commutative
  counter bumps do not.

## Notes

This decision deliberately differs from ADR-0011 because the circuit
breaker's write pattern (commutative counters, no wait queue) matches
ADR-0010's topology (fan-in writers, fan-out readers, lock-free ETS
writes) rather than ADR-0011's topology (serial arithmetic, wait
queue). The decision boundary is the write-commutativity question: if
writes commute, use ETS; if they do not (or if a wait queue is needed),
use a GenServer.
