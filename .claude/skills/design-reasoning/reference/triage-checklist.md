# Triage Checklist

The triage checklist determines whether a component warrants PSDH analysis. It is the gateway to the method — components that fail triage are skipped entirely.

This is the method's most important efficiency feature. PSDH analysis produces high-value output for coordination-heavy components and near-zero value for simple ones. Applying the method uniformly wastes effort. The triage step prevents that waste.

**Expected effort:** 30 seconds per component.

**Decision rule:** Score >= 2 → proceed to [L0 protocol](l0-protocol.md). Score < 2 → skip.

---

## The 5 Properties

Score 1 point for each property present in the component. A property is "present" if you can identify a concrete instance of it in the component's architecture or design description. Partial presence (the property exists but is minor or contained) scores 1 — the threshold is existence, not severity.

### 1. Shared Mutable State

**Definition:** Multiple actors can read and write the same data.

**What counts:** Files written by multiple processes. Database records modified by multiple services. In-memory state accessed by multiple threads or coroutines. Configuration state modified by both automated systems and human operators.

**What does not count:** Read-only shared data (multiple readers, single writer with no concurrent writes). Immutable message passing (messages created once, consumed once). Local state private to a single actor.

**Test question:** Is there any piece of state that two or more independent actors can modify?

### 2. Temporal Coupling

**Definition:** Correctness depends on operations happening in a specific order, where that order is not enforced by the system.

**What counts:** Startup sequences where service A must be ready before service B connects. Multi-step workflows where step N assumes step N-1 has completed. Timeout-based recovery where the timeout creates an implicit ordering contract. Event handlers that assume events arrive in a specific sequence.

**What does not count:** Enforced ordering (explicit barriers, locks, dependency injection that guarantees initialization order). Single-threaded sequential execution where ordering is inherent.

**Test question:** Does the component assume operations happen in a specific order, and is that order enforced by mechanism (not by convention or timing)?

### 3. Cross-Process Coordination

**Definition:** Components in different processes, services, or execution contexts must agree on shared state or protocol.

**What counts:** Microservices that coordinate through a shared database or message queue. Hooks and agents that communicate through files. Distributed workers that must agree on job ownership. Any system where two independently executing units must reach a consistent view of the world.

**What does not count:** In-process function calls (same execution context, no coordination problem). Stateless API calls where each request is independent. Isolated services that do not share state.

**Test question:** Do two or more independently executing components need to agree on something?

### 4. Feedback Loops

**Definition:** The output of one component feeds back as input to another (or the same) component, with potential for divergence or amplification.

**What counts:** Retry mechanisms where failures feed back into the retry queue. Autoscaling where load metrics trigger scaling decisions that change the load. Cache invalidation where invalidation triggers refills that trigger further invalidation. Any cycle in the control flow or dataflow graph where the cycle can amplify rather than dampen.

**What does not count:** One-shot pipelines (data flows in one direction, no cycles). Monitoring that observes but does not act (no feedback, just observation). Feedback loops with proven convergence (e.g., PID controllers with known stability bounds).

**Test question:** Can the output of this component's operation become the input to a subsequent operation, and could that cycle grow rather than stabilize?

### 5. State Accumulation

**Definition:** The component's behaviour depends on accumulated history, not just its current input.

**What counts:** Attempt counters that determine retry vs. dead-letter decisions. Sliding windows of observations that determine escalation thresholds. Session state that grows across interactions. Caches whose contents affect future behaviour. Logs or histories that are consumed by decision-making logic (not just recorded for humans).

**What does not count:** Stateless request processing (each request handled independently). Append-only logs that are never read by the system. Counters used only for monitoring/metrics with no behavioural effect.

**Test question:** Does this component's behaviour change based on what happened in previous operations (not just the current input)?

---

## Scoring

For each property, score 1 if it is present and 0 if it is not. Partial presence counts as 1.

| Score | Decision | Rationale |
|-------|----------|-----------|
| 0-1 | **Skip.** Do not apply the L0 protocol. | Components with 0-1 coordination properties produce near-zero non-obvious constraints from structured questioning. The method adds nothing that a competent code review would miss. |
| 2 | **Proceed with L0.** Apply the 8-question protocol. L1 state enumeration is optional. | Moderate coordination complexity. L0 typically surfaces 2-4 non-obvious constraints. Sufficient for most components at this level. |
| 3 | **Proceed with L0 + L1.** Apply the 8-question protocol, then escalate to state enumeration for the highest-risk interactions. | High coordination complexity. L0 surfaces 4-6 constraints; L1 adds 1-3 more, particularly temporal and concurrent state interactions. |
| 4-5 | **Proceed with L0 + L1. Consider L2.** Full protocol plus state enumeration. For the highest-risk subsystems, consider explicit state machine specification or formal verification (Alloy). | Very high coordination complexity. These components are where the most dangerous bugs live — silent, structural, and invisible to standard testing. |

---

## Examples: Components That Score >= 2

### Distributed Task Queue (score: 4.5)

A task queue where workers pull jobs, a visibility timeout prevents duplicate processing, failed jobs are retried or dead-lettered, and a DLQ monitor can retry or archive dead-lettered jobs.

| Property | Present? | Evidence |
|----------|----------|----------|
| Shared mutable state | Yes | The queue: multiple workers and the DLQ monitor read/write job state. |
| Temporal coupling | Yes | Visibility timeout creates implicit ordering. DLQ retry creates temporal dependency between monitor decisions and worker activity. |
| Cross-process coordination | Yes | Workers are independent processes coordinating through the queue. |
| Feedback loops | Yes | DLQ retry feeds jobs back into the main queue. Backoff strategy affects system load, which affects failure rate, which affects DLQ volume. |
| State accumulation | Partial | Attempt counter accumulates across retries. Job history records all transitions. |

**Score: 4.5. Full L0 + L1 warranted.** When L0 was applied to this component, it surfaced 12 raw constraints, of which 6 were clearly non-obvious. L1 added 1 more. This is the method's sweet spot.

### Event-Driven Order Processing Pipeline (score: 3)

An e-commerce system where orders progress through states (placed, payment_pending, paid, fulfilling, shipped, delivered) via events published to a message broker. Multiple services consume events: payment service, inventory service, shipping service.

| Property | Present? | Evidence |
|----------|----------|----------|
| Shared mutable state | Yes | Order state is read and modified by multiple services (payment marks as paid, inventory reserves stock, shipping marks as shipped). |
| Temporal coupling | Yes | Payment must succeed before fulfillment begins. Inventory must be reserved before shipping is initiated. These orderings are implicit in the event flow. |
| Cross-process coordination | Yes | Payment, inventory, and shipping services must agree on order state. |
| Feedback loops | No | The pipeline flows in one direction: placed → shipped. No cycles. |
| State accumulation | No | Each order is processed independently. No cross-order history affecting decisions. |

**Score: 3. L0 + L1 warranted.** The temporal coupling between payment, inventory, and shipping creates opportunities for out-of-order event handling, partial failure scenarios (payment succeeds but inventory reservation fails), and state divergence between services.

### Cache Invalidation System (score: 3)

A distributed cache where application servers cache database query results. A change-data-capture (CDC) stream from the database publishes invalidation events. Application servers subscribe to the stream and evict stale entries.

| Property | Present? | Evidence |
|----------|----------|----------|
| Shared mutable state | Yes | The cache contents are read by request handlers and modified by invalidation consumers. |
| Temporal coupling | Yes | Invalidation events must be processed before subsequent reads for consistency. If an event is delayed, stale data is served. |
| Cross-process coordination | No | Each application server manages its own cache independently. No inter-server coordination. |
| Feedback loops | Yes | Cache misses after invalidation trigger database reads, which may appear in the CDC stream if they cause writes (e.g., materialized views), creating a potential invalidation cycle. |
| State accumulation | No | Cache entries are independent. No history-dependent behaviour. |

**Score: 3. L0 + L1 warranted.** The interaction between invalidation timing and read consistency is the primary risk area. L0's temporal coupling question (Q2) and partial failure question (Q3 — what if the CDC stream drops events?) are particularly relevant.

---

## Examples: Components That Score < 2

### REST API Endpoint — CRUD Operations (score: 0)

A typical REST endpoint: receives HTTP request, validates input, reads/writes database, returns response. Single-threaded request handling per request.

| Property | Present? | Evidence |
|----------|----------|----------|
| Shared mutable state | No | Each request has its own database transaction. No concurrent modification within the endpoint. |
| Temporal coupling | No | Each request is independent. No ordering assumptions between requests. |
| Cross-process coordination | No | Single service, single process per request. |
| Feedback loops | No | Request → response. One direction, no cycles. |
| State accumulation | No | Each request handled independently. |

**Score: 0. Skip.** Structured questioning would produce nothing useful. Standard code review and unit tests are sufficient.

### Data Transformation Pipeline (score: 1)

An ETL pipeline: read CSV → validate → transform → write to database. Single-threaded, batch processing.

| Property | Present? | Evidence |
|----------|----------|----------|
| Shared mutable state | No | Input is read-only; output is write-only. No concurrent access. |
| Temporal coupling | Yes | Records must be validated before transformation, and transformed before writing. But this ordering is inherent in the pipeline structure — it cannot be violated without rewriting the pipeline. |
| Cross-process coordination | No | Single process. |
| Feedback loops | No | One-direction flow. |
| State accumulation | No | Each record processed independently. |

**Score: 1. Skip.** The temporal coupling is enforced by the pipeline's structure, not by convention. There is nothing for the L0 protocol to discover.

### Static Configuration Loader (score: 0)

Reads a YAML configuration file at startup, validates against a schema, and makes values available to the application. No runtime modification.

| Property | Present? | Evidence |
|----------|----------|----------|
| Shared mutable state | No | Configuration is immutable after load. |
| Temporal coupling | No | One-time load at startup. |
| Cross-process coordination | No | Single process. |
| Feedback loops | No | No cycles. |
| State accumulation | No | No history-dependent behaviour. |

**Score: 0. Skip.**

---

## Guidance

### When in doubt, score conservatively

If you are unsure whether a property is present, score it as 1. It is better to run the L0 protocol on a component that turns out to be simple (wasting 10 minutes) than to skip a component that harbours hidden coordination constraints (potentially missing a structural bug that surfaces months later).

### Triage is per-component, not per-project

A single project may contain components at every complexity level. The task queue scores 4.5; its REST API endpoints score 0. Apply the method where it earns its keep and skip where it does not. Applying the method uniformly to all components in a project is a common failure mode.

### Triage is fast and revisitable

The initial triage should take 30 seconds. If you later discover that a component has coordination properties you missed (e.g., a "simple" API endpoint turns out to share a database lock with a background worker), re-triage it. The checklist is a heuristic, not a contract.

### The threshold of 2 is empirically derived

In research validation, components with 0-1 coordination properties produced 0-1 non-obvious constraints from L0 (near-zero yield). Components with 2+ properties produced 2-6 non-obvious constraints (meaningful yield). The drop-off is sharp, not gradual. The threshold of 2 sits at the inflection point.
