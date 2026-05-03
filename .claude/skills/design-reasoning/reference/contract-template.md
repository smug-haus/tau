# Contract Template

Express design constraints as boundary contracts: preconditions, postconditions, and invariants per component interface. Contracts normalize the raw constraints produced by the L0 protocol into a structured, reviewable format.

## When to Use This

After completing L0 elicitation (and L1 state enumeration, if applicable). You have raw constraints in natural language. Contract expression organizes them by boundary, makes obligation asymmetries explicit, and creates an artifact that reviewers can check for completeness and consistency without understanding the full system.

Contract expression does not discover new constraints. It reveals gaps — boundaries not questioned, obligations not assigned, postconditions that contradict preconditions at the next boundary. When a gap appears, return to the L0 protocol for the affected boundary.

## Blank Template

Copy this for each component boundary in your system.

```
BOUNDARY: [Component A] ↔ [Component B] ([operation or interaction name])

  PRE (what must be true before the interaction):
    - [condition 1]
    - [condition 2]

  POST (what the caller may assume after the interaction completes):
    - [outcome 1]
    - [outcome 2]
    - IF [condition]: [alternative outcome]

  INV (what must hold throughout the interaction):
    - [invariant 1]
    - [invariant 2]
```

### Template Fields

**BOUNDARY** — Names both sides and the specific operation. Be precise: "Worker ↔ Queue (pull)" is better than "Worker ↔ Queue" because a single boundary pair may have multiple operations with different contracts.

**PRE** — Conditions the *caller* (or initiator) must ensure before the interaction. If these are violated, the operation's behavior is undefined. List each condition separately. Use concrete state references where possible (e.g., `job.state == READY`) rather than vague descriptions.

**POST** — Outcomes the caller may rely on after the operation completes successfully. Use `IF/THEN` for conditional outcomes (different results depending on state). Every precondition-valid invocation must have a defined postcondition — if you find a valid input with no defined outcome, you have a gap.

**INV** — Properties that hold throughout the entire interaction, not just before and after. Invariants constrain intermediate states. They are the strongest form of contract clause and the hardest to enforce. Use sparingly — an invariant that nobody checks is worse than no invariant (it creates false confidence).

## Worked Example: Distributed Task Queue

This example uses the task queue from the Phase 3 prototype: a distributed queue where workers pull jobs, a visibility timeout prevents duplicate processing, failed jobs retry up to a limit and then enter a dead-letter queue (DLQ), and a DLQ monitor can retry or archive dead-lettered jobs.

### Boundary 1: Worker ↔ Queue (pull operation)

```
BOUNDARY: Worker ↔ Queue (pull)

  PRE:
    - Queue has at least one job with state == READY
    - That job's invisible_until <= now (visibility window has expired or was never set)

  POST:
    - Exactly one job transitions READY → PROCESSING
    - job.invisible_until = now + visibility_timeout
    - job.worker_id = caller
    - job.attempt += 1

  INV:
    - A PROCESSING job is invisible to all other pull() calls
    - No two workers hold the same job simultaneously
```

### Boundary 2: Worker ↔ Queue (ack_failure operation)

```
BOUNDARY: Worker ↔ Queue (ack_failure)

  PRE:
    - job.state == PROCESSING
    - job.worker_id == caller (the acknowledging worker is the one that pulled the job)

  POST:
    - IF attempt < max_retries: job.state = READY, job re-enqueued, job visible
    - IF attempt >= max_retries: job.state = DEAD_LETTER, job added to DLQ

  INV:
    - Job is in exactly one of {ready_queue, processing, dlq} at any point
```

### Boundary 3: DLQ Monitor ↔ Queue (dlq_retry operation)

```
BOUNDARY: DLQ Monitor ↔ Queue (dlq_retry)

  PRE:
    - job.state == DEAD_LETTER
    - job_id present in DLQ

  POST:
    - job.state = READY
    - job.attempt = 0 (counter reset — the job gets a full retry budget)
    - job present in ready_queue
    - job NOT present in DLQ

  INV:
    - After retry, job has max_retries attempts available
    - Job never exists in both ready_queue and DLQ simultaneously
```

### Boundary 4: Queue ↔ Time (visibility reclaim)

```
BOUNDARY: Queue ↔ Time (visibility reclaim)

  PRE:
    - job.state == PROCESSING
    - job.invisible_until <= now (visibility window has expired)

  POST:
    - job.state = READY
    - job.worker_id = None
    - job present in ready_queue

  INV:
    - Any subsequent ack from the original worker is rejected
    - Reclaim does not modify the attempt counter
```

### What Contract Writing Revealed

Writing these four contracts exposed a gap that the L0 protocol did not catch directly:

The postcondition of `dlq_retry` says `job.attempt = 0`. The postcondition of `ack_failure` says `IF attempt >= max_retries: DLQ`. If `dlq_retry` resets the counter, the first failure after retry triggers `attempt < max_retries` (0 < 3), so the job retries normally. If `dlq_retry` does *not* reset the counter — a plausible implementation error — the first failure triggers `attempt >= max_retries` (3 >= 3) and the job immediately re-enters the DLQ. The contract made this interaction precise in a way the natural-language constraint did not.

This is the flywheel in action. The contract revealed a boundary worth questioning further, which prompted a return to the L0 protocol.

## Writing Contracts from L0 Output

### For Each Raw Constraint from L0

1. **Identify the boundary.** Which two components does the constraint sit between? Which operation does it constrain? If the constraint spans multiple boundaries, write a contract for each.

2. **Classify the constraint.** Is it a precondition (must be true before), postcondition (must be true after), or invariant (must hold throughout)? Some constraints decompose into multiple clauses across categories.

3. **State the contract in concrete terms.** Replace vague references with state references. "The job should be handled correctly" becomes `job.state == DEAD_LETTER AND job_id in dlq`. If you cannot make it concrete, the L0 constraint may be underspecified — return to the protocol.

4. **Check for conditional outcomes.** Most postconditions have at least two branches (success and failure, or normal and edge case). If you write a single-branch postcondition, ask: what happens in the other case?

### LLM-Assisted Contract Generation

When using an LLM to generate contracts from L0 output, provide:

1. The raw L0 constraints (numbered, as produced by the protocol)
2. The component boundary list (which components interact and through which operations)
3. This template

Prompt pattern:

```
Given these raw constraints from L0 elicitation:
[paste numbered constraints]

And these component boundaries:
[list boundaries: Component A ↔ Component B (operation)]

Write a PRE/POST/INV contract for each boundary using the template
format. For each contract clause, note which L0 constraint(s) it
derives from. Flag any L0 constraints that don't map cleanly to a
boundary — these may indicate a missing boundary.
```

The LLM will generate fluent contracts. Review them for:

- **Completeness:** Every L0 constraint maps to at least one contract clause. If a constraint is orphaned (no boundary), either a boundary is missing or the constraint is architectural rather than interface-level.
- **Consistency:** Boundary A's postcondition must be compatible with Boundary B's precondition, when A's output feeds B's input. Contradictions indicate a design conflict, not a contract-writing error.
- **Asymmetry:** Check who bears the obligation. If one side of every boundary has all the preconditions and the other side has none, confirm this is intentional (e.g., one component is ephemeral and trusted to do nothing).

### Flywheel Check

After writing all contracts, ask:

- Did any contract clause surprise you? (Indicates an underexplored boundary.)
- Are there component interactions with no contract? (Indicates a missing boundary.)
- Does any postcondition reference state that no precondition establishes? (Indicates a gap in the chain.)

If yes to any of these, return to the L0 protocol for the affected boundary before proceeding to PSDH extraction.

## Output

A set of boundary contracts in the format above. These feed into:

- **PSDH extraction:** Generalize contract clauses into plain-language heuristics
- **Enforcement assignment:** Determine which contracts become rules, tests, review criteria, or heuristics
- **The PSDH catalog:** Contracts are recorded alongside their plain-language PSDH statements as the authoritative reference
