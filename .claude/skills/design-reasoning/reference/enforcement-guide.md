# Enforcement Assignment Guide

How to choose which enforcement mechanism(s) to assign to each PSDH.

## Context

After extracting PSDHs and expressing them as contracts, you must decide how each PSDH will be enforced. This guide provides a decision framework for that assignment. The output of this step feeds directly into the emitter, which produces the enforcement artifacts.

The five enforcement mechanisms are **emitter targets** — the emitter takes your assignment decisions and generates the corresponding artifacts (markdown rules, checklist items, test stubs, hook functions, or catalog entries).

---

## The Five Enforcement Mechanisms

### 1. Agent Rules

**What:** Plain-language MUST/MUST NOT constraints injected into the agent's persistent context (e.g., CLAUDE.md or equivalent project-level instruction file).

**Effect:** Constrains the agent's generation behaviour at implementation time. The agent reads these rules before every action.

**Strengths:**
- Zero tooling — immediate deployment
- Prevents violations during generation, not just after

**Limitations:**
- Attention dilution — each rule costs ~30-50 tokens of permanent context
- Practical ceiling: 5-8 rules per project before LLM attention degrades
- Probabilistic enforcement — the agent may fail to attend to the rule under competing task instructions

**Emitter target:** `agent-rules` — produces a markdown rules block ready for insertion into agent context.

**Example (task queue domain):**
```
- The visibility timeout MUST be set on every job pull. If visibility
  fails to engage, at-least-once delivery becomes unbounded-duplicate.
- DLQ retry MUST reset the attempt counter. A retry without reset
  creates an immediate re-DLQ loop.
```

### 2. Critic Criteria

**What:** Checklist items added to a review agent's or human reviewer's evaluation criteria.

**Effect:** PSDHs are checked at review boundaries — design review, post-implementation review, PR review.

**Strengths:**
- Covers all PSDH types, including structural and cross-cutting constraints that resist automation
- Low integration cost — add items to an existing review checklist
- Human-readable — works for both LLM critics and human reviewers

**Limitations:**
- Judgment-based, not deterministic — a reviewer may miss or misapply a criterion
- Fires only at review gates, not continuously

**Emitter target:** `critic-checklist` — produces a checklist of review criteria.

**Example (task queue domain):**
```
- [ ] Does every state transition have an explicit handler for the
      "timeout while processing" case?
- [ ] Are attempt counters reset on all re-entry paths, not just
      the explicit retry path?
- [ ] Can a late acknowledgment from a dead worker corrupt the
      state of a job that has been reassigned?
```

### 3. Property Tests

**What:** Executable property-based tests (Hypothesis, fast-check, QuickCheck, etc.) that verify PSDH invariants against a design model or implementation.

**Effect:** Automated, deterministic, continuous verification. Runs in CI and during development.

**Strengths:**
- Strongest enforcement mechanism — catches violations that review misses
- Generative — random input exploration finds edge cases the author didn't anticipate
- The act of writing a property test often reveals ambiguities in the PSDH itself (a secondary discovery mechanism)

**Limitations:**
- Not all PSDHs are expressible as runtime properties — structural and process-level constraints resist operationalisation
- Requires a design model or testable interface
- Higher effort than other mechanisms

**Emitter target:** `property-tests` — produces test stubs with PSDH annotations.

**The 30-50% guideline:** Roughly 30-50% of PSDHs in a typical catalog are suitable for property test operationalisation. The rest are enforced through other mechanisms.

Selection criteria for property tests — see the decision tree below.

### 4. Hook Heuristics

**What:** Runtime detection functions that monitor system behaviour and flag PSDH-derived invariant violations.

**Effect:** Continuous runtime monitoring — the "airbag" layer. Detects violations after they occur, not before.

**Strengths:**
- Catches violations in production, not just in test
- Works for invariants that can be checked via observable system state
- Complements property tests (which check at development time) with runtime checks

**Limitations:**
- Detects symptoms, not causes — by the time the hook fires, the violation has already occurred
- Requires access to runtime state or event streams
- False positive risk if the heuristic is imprecise

**Emitter target:** `hook-heuristics` — produces detection function stubs.

**Example (task queue domain):**
```
D-001: design-invariant-violation
  Signal: Job pulled without visibility timeout set
  Detection: Check invisible_until > current_time after every pull
  Severity: 0.7+
```

### 5. Documentation Only

**What:** The PSDH is recorded in the living documentation catalog with its contract, but no automated enforcement artifact is generated.

**Effect:** Human reference. The PSDH exists as a constraint that reviewers and designers can consult, but no tooling checks it.

**When appropriate:**
- The PSDH describes a process constraint ("changing parameter X requires re-verifying parameter Y") rather than a runtime invariant
- The PSDH is about architectural intent rather than behaviour
- Automated enforcement is technically possible but the cost-benefit doesn't justify it

**Emitter target:** `catalog` — the PSDH appears only in the living documentation catalog.

---

## Decision Framework

### Decision Tree

For each PSDH in your catalog, walk through this tree:

```
START
  │
  ▼
Is the PSDH about runtime behaviour?
(State transitions, invariants, protocol ordering)
  │
  ├── NO ──► Is it about the change process?
  │          (Parameter coupling, design intent,
  │           architectural boundaries)
  │            │
  │            ├── YES ──► Critic Criteria + Documentation Only
  │            │
  │            └── NO ──► Critic Criteria
  │                       (review for structural compliance)
  │
  └── YES
        │
        ▼
  Can the violation be detected at generation time?
  (Would an agent following the rule avoid the violation?)
        │
        ├── YES ──► Agent Rule (if within budget)
        │            + Critic Criteria (always)
        │            │
        │            ▼
        │          Does the PSDH have silent failure modes?
        │          (Violation produces no error, test passes,
        │           but correctness is compromised)
        │            │
        │            ├── YES ──► Property Test (high priority)
        │            └── NO  ──► Property Test (low priority)
        │
        └── NO
              │
              ▼
        Can the violation be detected at runtime?
        (Observable in system state or event streams)
              │
              ├── YES ──► Hook Heuristic
              │            + Critic Criteria
              │            + Property Test (if testable)
              │
              └── NO  ──► Critic Criteria
                           + Documentation Only
```

### Agent Rule Budget

You have a budget of 5-8 agent rules per project. Allocate them to PSDHs that:

1. **Guard the highest-risk failure modes.** If the violation is catastrophic or silent, it earns a rule.
2. **Are enforceable during generation.** The agent must be able to follow the rule while writing code. "Don't introduce race conditions" is too vague. "Set visibility timeout on every pull" is actionable.
3. **Are concise.** Each rule adds ~30-50 tokens. A rule that requires a paragraph of context is better suited as a critic criterion.

When you have more candidate rules than budget slots, rank by risk and promote the top 5-8. The rest become critic criteria.

### Property Test Selection Criteria

A PSDH is a good candidate for property test operationalisation when:

1. **Silent failure mode.** Violating the PSDH produces no error, exception, or test failure — the system continues operating but correctness is compromised. This is the strongest indicator.
   - Example: DLQ retry without counter reset — the job silently re-enters the DLQ after one attempt. No error is thrown.

2. **Expressible against available interfaces.** The property can be checked by calling the component's public API or by observing its state transitions. If the property requires inspecting internal implementation details that aren't exposed, the test is fragile.
   - Example: "After DLQ retry, `job.attempt == 0`" — directly checkable.
   - Counter-example: "The implementation uses a mutex for job state transitions" — not a property of the interface.

3. **State-machine structure.** The PSDH describes invariants over sequences of state transitions. This maps directly to PBT's strength: generating random event sequences and checking invariants.
   - Example: "No job exists in both ready_queue and dlq simultaneously" — an invariant over the state machine.

4. **Cost of failure justifies cost of testing.** Property tests require more effort than a checklist item. Reserve them for PSDHs where the failure mode is expensive, hard to detect in review, or has happened before.

**Inversion — when NOT to write a property test:**

- The PSDH is about architectural structure, not runtime behaviour
- The PSDH is about the change process ("re-verify when parameter X changes")
- The violation would be caught by a standard unit test or integration test
- The failure mode is loud (throws an exception, crashes the system)

### Assignment Table Template

Record your assignments in the PSDH catalog using this format:

| PSDH | Agent Rule | Critic | Property Test | Hook | Doc Only |
|------|:----------:|:------:|:-------------:|:----:|:--------:|
| PSDH-1: [name] | | | | | |
| PSDH-2: [name] | | | | | |

Mark each cell with one of:
- **Yes** — this mechanism is assigned
- **--** — this mechanism is not applicable or not justified

Every PSDH should have at least two marks: critic criteria (always) and one other mechanism.

---

## Worked Example: Task Queue PSDHs

Applying the decision tree to the five PSDHs extracted from the distributed task queue prototype:

**PSDH-1: Retry Exhaustion -> Terminal State**
"A job that exhausts its retries must reach exactly one terminal state (DLQ)."

- Runtime behaviour? **Yes** — state transition invariant.
- Detectable at generation time? **Yes** — an agent can follow "always move to DLQ after max retries."
- Agent rule budget? **Include** — high risk, concise, actionable.
- Silent failure? **Yes** — a job stuck in a retry loop produces no error.
- Assignment: **Agent Rule + Critic + Property Test**

**PSDH-2: Visibility as Sole Duplicate Guard**
"Visibility timeout is the sole mechanism preventing duplicate processing."

- Runtime behaviour? **Yes** — concurrency invariant.
- Detectable at generation time? **Yes** — "always set visibility timeout on pull."
- Agent rule budget? **Include** — high risk, concise.
- Silent failure? **Yes** — duplicate processing produces no error; both workers think they own the job.
- Detectable at runtime? **Yes** — a hook can check `invisible_until > now` after every pull.
- Assignment: **Agent Rule + Critic + Property Test + Hook Heuristic**

**PSDH-3: Re-entry Must Reset Budget**
"DLQ retry must reset the attempt counter."

- Runtime behaviour? **Yes** — state mutation constraint.
- Detectable at generation time? **Yes** — "always reset attempt counter in dlq_retry."
- Agent rule budget? **Include** — high risk, concise.
- Silent failure? **Yes** — the job immediately re-enters DLQ after one failure. No error.
- Assignment: **Agent Rule + Critic + Property Test**

**PSDH-4: Late Action After Reclaim Is Invalid**
"Any ack from the original worker must be rejected after visibility reclaim."

- Runtime behaviour? **Yes** — protocol ordering constraint.
- Detectable at generation time? **Yes** — "check worker ownership before accepting ack."
- Agent rule budget? **Include** — high risk, actionable.
- Silent failure? **Yes** — accepting a late ack corrupts state silently.
- Detectable at runtime? **Yes** — a hook can detect when an ack is accepted for a mismatched worker_id.
- Assignment: **Agent Rule + Critic + Property Test + Hook Heuristic**

**PSDH-5: Coupled Parameters Require Joint Verification**
"Changing timeout, max_retries, or DLQ retry policy requires re-verifying the others."

- Runtime behaviour? **No** — this is about the change process.
- Change process constraint? **Yes**.
- Assignment: **Critic + Documentation Only**

### Summary Assignment Table

| PSDH | Agent Rule | Critic | Property Test | Hook | Doc Only |
|------|:----------:|:------:|:-------------:|:----:|:--------:|
| PSDH-1: Retry exhaustion -> DLQ | Yes | Yes | Yes | -- | Yes |
| PSDH-2: Visibility as sole guard | Yes | Yes | Yes | Yes | Yes |
| PSDH-3: Re-entry must reset budget | Yes | Yes | Yes | -- | Yes |
| PSDH-4: Late action after reclaim | Yes | Yes | Yes | Yes | Yes |
| PSDH-5: Coupled parameters | -- | Yes | -- | -- | Yes |

Property test coverage: 4 of 5 PSDHs (80%). This is above the 30-50% guideline because the task queue is coordination-heavy with predominantly silent failure modes. For a typical project with a mix of coordination-heavy and structural PSDHs, expect 30-50%.

---

## Mechanism Layering

The mechanisms form a defence-in-depth stack:

```
                Generation Time          Review Time           Runtime
                ─────────────           ───────────           ───────
Strongest ──►   Agent Rules              Critic Criteria       Property Tests
                (prevent during          (catch at gates)      (catch in CI)
                 code writing)

Weakest ──►                                                    Hook Heuristics
                                                               (detect after
                                                                violation)

Always ──►                              Living Documentation
                                        (reference for all of the above)
```

Agent rules prevent at generation time. Critic criteria catch at review gates. Property tests catch in CI. Hook heuristics detect at runtime. Living documentation is the source of truth that all other mechanisms derive from.

No single mechanism is sufficient. The enforcement assignment should produce at least two layers per PSDH.

---

## Common Mistakes

**Over-assigning agent rules.** If every PSDH becomes an agent rule, you exceed the 5-8 rule budget and attention dilution degrades all of them. Be selective.

**Under-assigning property tests.** The 30-50% guideline is a floor, not a ceiling. If a PSDH has a silent failure mode and is testable, write the test. The investment in property tests pays for itself through the ambiguities the test-writing process reveals.

**Skipping critic criteria.** Every PSDH should be a critic criterion. This is the cheapest mechanism and the one most likely to catch violations that slip past other layers.

**Confusing hook heuristics with property tests.** Hook heuristics detect violations at runtime (after the fact). Property tests verify invariants during development (before deployment). They serve different purposes and are not interchangeable.

**Documentation-only as default.** If you find yourself assigning "documentation only" to most PSDHs, either the PSDHs are too abstract (re-examine them for specificity) or the decision tree was applied too conservatively.
