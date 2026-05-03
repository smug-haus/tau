# L0 Protocol Reference

The L0 protocol is the core discovery engine of the PSDH method. It is a set of 8 structured questions applied systematically to a component's architecture description. The questions surface implicit constraints — assumptions, ordering dependencies, failure modes, and coordination gaps — that are not visible from normal reading of design documents.

L0 is the highest-ROI activity in the method. In research validation, it captured approximately 70% of all unique constraints found across all formalism levels. The remaining 30% came from L1 state enumeration (for concurrent/stateful systems) and L2 formal specification (for precision, not discovery).

**When to use:** After a component passes triage (score >= 2 on the [triage checklist](triage-checklist.md)). Apply to the component's architecture description, design document, or natural-language specification.

**Expected effort:** 10-15 minutes per component.

**Expected output:** 5-12 raw constraints in natural language, each describing a gap, ambiguity, or implicit assumption in the component's design.

---

## The 8 L0 Questions

### Q1: Shared Mutable State

> **What can be written by more than one actor?**

**Origin:** Distributed systems failure analysis (Lamport, Vogels). Concurrent writes without coordination are the single most common source of silent correctness failures.

**What it targets:** Components where multiple actors (processes, threads, services, hooks, agents) read or write the same data. Files, databases, shared memory, message queues, configuration state.

**When it matters most:** Any system where two or more writers can operate on the same resource. Particularly important for file-mediated coordination, shared databases, and in-memory caches accessed by multiple services.

**How to apply:** List every piece of state in or around the component. For each, ask: who writes it? If the answer is "more than one actor," you have shared mutable state. Then ask: what prevents concurrent writes from conflicting? If the answer is "nothing explicit," you have a constraint to record.

**What good output looks like:**

- "The job state record is written by workers (ack_success, ack_failure), the queue service (visibility reclaim), and the DLQ monitor (retry, archive). No mechanism prevents concurrent modification by two of these actors on the same job."
- "The configuration file is read by all services at startup but written by the admin tool and the auto-scaler. Write conflicts are resolved by last-write-wins, which means auto-scaler changes can silently overwrite admin changes."

**What bad output looks like:**

- "There is shared state." (Too vague — doesn't identify which state, which actors, or what the consequence is.)
- A long list of every variable in the system. (Not selective — the question targets *multiply-written* state, not all state.)

---

### Q2: Temporal Coupling

> **What ordering assumptions are implicit?**

**Origin:** Distributed systems (Lamport's happened-before relation). Systems frequently assume operations occur in a specific order without enforcing that order.

**What it targets:** Components where correctness depends on operations happening in a specific sequence, but that sequence is enforced only by convention, timing assumptions, or accident.

**When it matters most:** Startup/shutdown sequences, multi-step workflows, systems with timeouts or retries, event-driven architectures where event order is not guaranteed.

**How to apply:** Trace the component's primary workflows. For each step, ask: what must have happened before this step? Is that ordering enforced by the system (explicit dependency, lock, barrier), or is it assumed (convention, documentation, "it just works because the first thing is always faster")? Unenforced orderings are constraints.

**What good output looks like:**

- "The protocol assumes pull happens before ack, but nothing prevents a late ack arriving after the visibility timeout has already reclaimed the job. The worker believes it is processing; the queue believes the job is available."
- "Service B reads the output of Service A, but there is no explicit signal that Service A has finished writing. The ordering assumption is that Service A is 'fast enough' — which fails under load."

**What bad output looks like:**

- "Things happen in order." (Not specific about *which* ordering matters or *why* it might break.)

---

### Q3: Partial Failure

> **What happens if a component fails silently?**

**Origin:** Complex system failure analysis (Allspaw, Cook). Silent failures — where a component stops functioning correctly without signaling an error — are the hardest to detect and the most damaging.

**What it targets:** Components where a failure in one part does not propagate an error to the rest of the system. Crashed workers, unresponsive services, corrupted state that passes validation, dropped messages.

**When it matters most:** Any distributed or multi-process system. Particularly important for fire-and-forget operations, timeout-based recovery, and systems where "no response" is ambiguous between "still working" and "dead."

**How to apply:** For each component or actor in the system, assume it fails silently (crashes, hangs, produces wrong output without error). Ask: what is the recovery mechanism? How long until the failure is detected? What state is corrupted or lost in the interval?

**What good output looks like:**

- "If a worker crashes after pulling a job but before acking, the visibility timeout is the only recovery mechanism. If the timeout is misconfigured (too long), the job is stuck until manual intervention. If too short, the job is reclaimed while still being processed elsewhere, producing duplicate work."
- "If the DLQ monitor crashes, dead-lettered jobs accumulate without bound. There is no backpressure mechanism and no alert on DLQ growth rate."

**What bad output looks like:**

- "The system should handle failures gracefully." (Not specific about *which* failure, *which* recovery mechanism, or *what happens when recovery fails*.)

---

### Q4: Interface Fidelity

> **What information crosses a boundary, and what is lost in transit?**

**Origin:** Information theory applied to system boundaries. Every interface is a lossy channel — some information available on the sending side is not transmitted to the receiving side.

**What it targets:** Component boundaries where data, context, or intent crosses from one actor to another. API calls, file exchanges, message passing, context injection, error propagation.

**When it matters most:** Error reporting (does the error message carry enough context for the receiver to act?), cross-service communication (are domain concepts translated correctly?), human-machine boundaries (does the UI convey what the system is actually doing?).

**How to apply:** For each boundary between components, list what information the sender has and what the receiver gets. The difference is information loss. Then ask: does the receiver need any of the lost information to make correct decisions?

**What good output looks like:**

- "The ack_failure call carries a status code but not a failure reason. The DLQ monitor must decide between retry (transient failure) and archive (permanent failure) without knowing which type of failure occurred. This is an information-loss boundary."
- "The context injection mechanism passes a text preamble to the subagent, but there is no confirmation that the preamble was received or retained. If it is truncated by a token limit, instructions are silently lost."

**What bad output looks like:**

- "Data is passed between components." (Doesn't identify *what* is lost or *why* it matters.)

---

### Q5: Feedback Stability

> **What feedback loops exist, and can they diverge?**

**Origin:** Control theory and complex systems analysis. Feedback loops that lack damping or termination conditions can amplify failures rather than correcting them.

**What it targets:** Any cycle in the system's dataflow or control flow where the output of one component feeds back as input to another (or the same) component. Retry loops, autoscaling, cache invalidation cycles, error-recovery-that-causes-more-errors.

**When it matters most:** Systems with retry mechanisms, autoscaling, load balancing, or any form of automatic recovery. The recovery mechanism itself can become the problem.

**How to apply:** Draw the dataflow graph (even informally). Identify cycles. For each cycle, ask: is there a termination condition? What happens if the termination condition is never met? What happens if the feedback amplifies the original problem?

**What good output looks like:**

- "DLQ retry creates a feedback loop: fail -> DLQ -> retry -> ready queue -> worker -> fail -> DLQ. If the failure is permanent (malformed payload), this loop is infinite. There is no retry limit on DLQ retries, only on per-job processing retries."
- "Exponential backoff without a ceiling can cause starvation: backoff delay exceeds system timeout, so the job is reclaimed before the retry fires, which counts as another failure, which increases the backoff further."

**What bad output looks like:**

- "There are feedback loops in the system." (Doesn't identify *which* loops, *whether* they can diverge, or *what happens* if they do.)

---

### Q6: Phase Invariants

> **What must be true before and after each phase transition?**

**Origin:** Design by Contract (Meyer). Every state transition has preconditions (what must be true before) and postconditions (what must be true after). Implicit invariants are the ones that get violated.

**What it targets:** State transitions in the component's lifecycle. Job status changes, connection state changes, initialization/teardown sequences, mode switches.

**When to use:** Any component with identifiable phases or states. Particularly important for components where transitions have side effects (writing files, sending messages, allocating resources).

**How to apply:** List the component's state transitions. For each transition, write down what must be true before it fires (precondition) and what must be true after it completes (postcondition). Then check: is the postcondition of transition A consistent with the precondition of transition B (where B follows A)?

**What good output looks like:**

- "The DLQ-to-ready transition must reset the attempt counter. Postcondition: attempt = 0. This is critical because the ready-to-DLQ transition has precondition: attempt >= max_retries. If the reset is missing, the job immediately satisfies the DLQ precondition after a single failure."
- "The spawning-to-monitoring transition must clear any stale kill signal. Postcondition: kill_signal.active == false. Without this, the new instance spawns into a pre-killed state inherited from the prior attempt."

**What bad output looks like:**

- "State transitions should be valid." (Not specific about *which* transitions, *which* pre/postconditions, or *what breaks* when they are violated.)

---

### Q7: Protocol Ordering

> **What is the communication protocol between these components, and what happens if a message arrives out of order?**

**Origin:** Session types (Honda, Yoshida). Every inter-component interaction has an implicit or explicit protocol — a sequence of expected messages. Protocol violations occur when messages arrive in an unexpected order.

**What it targets:** Multi-step interactions between components. Request-response pairs, handshake sequences, multi-phase coordination, any communication pattern more complex than a single call-and-return.

**When it matters most:** Systems with asynchronous communication, timeout-based recovery, or multi-party coordination. Any place where "the protocol" is documented as a sequence diagram but not enforced by the implementation.

**How to apply:** For each pair of communicating components, write down the expected message sequence. Then ask: what happens if message N+1 arrives before message N? What happens if message N arrives after a timeout has already triggered an alternative action? What happens if a message arrives for a protocol instance that has already terminated?

**What good output looks like:**

- "The retry protocol has an implicit ordering: kill -> summarize -> stop -> coordinator reads -> coordinator decides -> spawn next. But 'summarize' and 'stop' are not separate protocol steps. There is no explicit 'summary complete' signal. The coordinator relies on process termination, not semantic completion."
- "A late ack from a worker (arriving after visibility timeout reclaim) is a protocol ordering violation: the worker is in 'processing sent ack' state, but the queue has moved to 'reclaimed and re-enqueued' state. The ack must be rejected because the protocol instance (this worker's claim on this job) has terminated."

**What bad output looks like:**

- "Messages should arrive in order." (Not specific about *which* protocol, *which* messages, or *what happens* on violation.)

**Why this question was added:** The original 6-question protocol missed a genuine gap in protocol ordering during Phase 2b testing. Q2 (temporal coupling) catches ordering issues within a single component's execution. Q7 catches ordering issues *between* components — message-level protocol violations that Q2 identifies only in weaker form.

---

### Q8: Change Propagation

> **If you change component X, what properties of connected components Y and Z must be re-verified?**

**Origin:** Category theory (functorial preservation). When a transformation is applied to one part of a structured system, the question is which properties of connected parts are preserved and which must be re-established.

**What it targets:** Cross-cutting dependencies between components. Parameter coupling (changing one configuration value invalidates assumptions in other components), interface contracts (changing a component's behavior requires re-verifying consumers), and cascade effects (a local change with non-local consequences).

**When it matters most:** Systems where configuration parameters interact across components, where components share implicit assumptions about each other's behavior, or where a change in one module has non-obvious effects on distant modules.

**How to apply:** For each component, ask: if I change this component's behavior, configuration, or interface, what breaks? Trace the dependency graph outward. For each connected component, ask: which of its assumptions about the changed component are now invalid?

**What good output looks like:**

- "Visibility timeout, max_retries, and DLQ retry policy form a coupled parameter set. If visibility timeout decreases (more aggressive reclaim), workers that were safe before may now exceed the timeout, creating more duplicate work. If max_retries increases, DLQ volume decreases but per-job compute cost increases. These three parameters must be verified as a unit."
- "If the escalation ladder thresholds change (e.g., kill threshold from 0.8 to 0.7), the combined-trigger rule, the meta-restart trigger, and the context injection budget must all be re-verified. More kills means more attempt summaries means larger preambles."

**What bad output looks like:**

- "Changing things might break other things." (Not specific about *which* changes, *which* dependencies, or *which* properties need re-verification.)

**Why this question was added:** The original 6-question protocol did not catch cross-cutting parameter dependencies. During Phase 2b testing, Q8 surfaced a dependency between three configuration parameters that none of the other questions found. The concept derives from category theory's notion that structure-preserving maps (functors) must be explicitly verified when the source structure changes.

---

## Using the Protocol

### Preparation

1. Gather the component's architecture description. This can be a design document, a natural-language specification, a README, or even a verbal description recorded as notes. The protocol operates on *descriptions*, not code.
2. Confirm the component passed triage (score >= 2 on the [triage checklist](triage-checklist.md)). Do not apply the L0 protocol to components that fail triage — it produces low-value output for simple components.

### Execution

Apply each question in order (Q1-Q8) to the component description. For each question:

1. **Ask the question** about the specific component. Not in the abstract — with concrete references to the actors, state, and boundaries in the description.
2. **Record every constraint** surfaced. Use natural language. Each constraint should identify: what the problem is, which actors or state are involved, and what the consequence of violation would be.
3. **Mark non-obvious constraints.** A constraint is non-obvious if it is not visible from a normal-speed reading of the architecture description. These are the most valuable — they are the constraints that code review and standard testing will miss.

### After L0

- If the triage score was >= 3 (highly coordination-heavy), escalate to **L1 state enumeration** for the highest-risk interactions identified by L0. See the escalation criteria below.
- If the triage score was 2, L0 is typically sufficient. Proceed to contract expression.
- Feed L0 output into the contract expression step of the method, where raw constraints are normalized as PRE/POST/INV statements per component boundary.

---

## Escalation to L1: State Enumeration

L1 is a targeted amplifier for L0. It finds temporal and concurrent state interactions that structured questioning tends to miss. Apply it selectively — only to the highest-risk interactions identified by L0.

### When to escalate

Escalate to L1 when any of these conditions are met:

- **Triage score >= 3.** Components with high coordination complexity have state interactions that L0's question-at-a-time approach misses. L1 forces consideration of *combinations*.
- **L0 surfaced timing-dependent constraints.** If L0 found constraints involving "what happens if X and Y occur simultaneously" or "what if the ordering is reversed," L1 will find more in the same area.
- **Multiple actors modify the same state.** If Q1 revealed 3+ writers for the same resource, the combinatorial state space is large enough that L0 will miss some combinations.

### When NOT to escalate

- **Triage score = 2.** L0 is typically sufficient. The marginal yield of L1 is low for moderately complex components.
- **L0 found only structural constraints** (missing cleanup, information loss, undocumented assumptions). These are not the type L1 finds — L1 finds *temporal* issues.
- **The component is stateless or request-response only.** L1 adds nothing if there is no persistent state to enumerate.

### How L1 works

1. **List actors and their states.** For each actor in the component (process, service, hook, agent), enumerate every distinct state it can be in.
2. **Build the state table.** Create a matrix: Actor x State. Include states like "absent," "stale," "in-transition" — not just the happy-path states.
3. **Check combinations.** For every *pair* of actors, ask: are there state combinations that should not be reachable but are not explicitly prevented? These are the new constraints.

### Expected yield

In research validation, L1 added 3 constraints beyond L0's 6 — all involving temporal or concurrent state interactions. The effort was approximately 5-10 minutes on top of L0's 10-15 minutes. The constraints found at L1 are characteristically different from L0: they involve *combinations* of actor states rather than individual component gaps.

---

## Example: Task Queue (Abbreviated)

This abbreviated example shows the protocol applied to a distributed task queue with retry and dead-letter handling. It demonstrates the type and specificity of output expected from each question.

**Component:** Workers pull jobs from a ready queue. Failed jobs are retried up to max_retries, then moved to a dead-letter queue (DLQ). A visibility timeout prevents duplicate processing. A DLQ monitor can retry, archive, or inspect dead-lettered jobs.

| Question | Key constraint found |
|----------|---------------------|
| Q1 (shared mutable state) | Job state is written by workers (ack), the queue (visibility reclaim), and the DLQ monitor (retry). No mechanism prevents concurrent modification on the same job. |
| Q2 (temporal coupling) | The pull-process-ack sequence has no protocol enforcement. A late ack (after visibility timeout) creates a semantic conflict: the worker thinks it is processing; the queue thinks the job is available. |
| Q3 (partial failure) | If a worker crashes after pulling but before acking, the visibility timeout is the sole recovery mechanism. A misconfigured timeout means the job is either stuck or duplicated. |
| Q4 (interface fidelity) | ack_failure carries no failure reason. The DLQ monitor must decide retry vs. archive without knowing whether the failure was transient or permanent. |
| Q5 (feedback stability) | DLQ retry creates a feedback loop. If the failure is permanent, the loop is infinite: fail -> DLQ -> retry -> fail -> DLQ. No DLQ retry limit exists. |
| Q6 (phase invariants) | The DLQ-to-ready transition must reset the attempt counter. Without reset, the job immediately re-enters the DLQ after one failure (attempt is already at max_retries). |
| Q7 (protocol ordering) | A late ack from the original worker (after visibility reclaim and reassignment) is a protocol violation. It must be rejected — the original worker's claim has terminated. |
| Q8 (change propagation) | Visibility timeout, max_retries, and DLQ retry policy form a coupled parameter set. Changing any one requires re-verifying the other two. |

This produced 12 raw constraints, of which 6 were clearly non-obvious. The protocol exceeded the 5-constraint threshold for a useful L0 session.

---

## Summary

The L0 protocol is 8 questions. The questions are not original — they condense well-known failure analysis patterns from distributed systems, session types, control theory, and design by contract. The contribution is the finding that *applying these questions systematically* is the highest-value activity in design constraint discovery, ahead of any formal notation or specialized tool.

The questions work because they force structured attention to specific failure classes. An engineer who reads an architecture document and "thinks about it" will miss the temporal issues, the information-loss boundaries, and the coupled parameters. An engineer who applies these 8 questions systematically will find most of them.
