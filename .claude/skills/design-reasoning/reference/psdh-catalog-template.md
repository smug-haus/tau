# PSDH Catalog Template

The PSDH catalog is the single source of truth for all project-specific design heuristics. Every other enforcement artifact — rules, tests, review criteria, heuristics — derives from catalog entries. When a PSDH is revised, the catalog updates first, then enforcement artifacts propagate.

## Representation Priority

The catalog sits at the top of a derivation hierarchy:

```
                ┌──────────────────────────────────────┐
                │        PSDH Catalog                   │
                │        (source of truth)              │
                └──────────────┬───────────────────────┘
                               │ derives
            ┌──────────────────┼──────────────────┐
            v                  v                  v
    ┌───────────────┐  ┌──────────────┐  ┌───────────────┐
    │ Rules         │  │ Property     │  │ Review        │
    │ (behavioral   │  │ Tests        │  │ Criteria      │
    │  constraints  │  │ (executable  │  │ (checklist    │
    │  for agents,  │  │  verification│  │  items for    │
    │  5-8 max)     │  │  of ~30-50%  │  │  all PSDHs)   │
    │               │  │  of PSDHs)   │  │               │
    └───────────────┘  └──────────────┘  └───────────────┘
            │                  │                  │
    Agent generation     CI / development    Review gates
    constraints          automation
            │                                     │
            └──────────────┬──────────────────────┘
                           v
                   ┌───────────────┐
                   │ Hook          │
                   │ Heuristics    │
                   │ (runtime      │
                   │  monitoring)  │
                   └───────────────┘
```

Not every PSDH maps to every enforcement mechanism. Rules are limited to 5-8 highest-priority items (attention dilution). Property tests cover only PSDHs with expressible runtime properties (~30-50%). Review criteria cover all PSDHs. Hook heuristics are the last line — runtime detection after a violation has already occurred.

## Blank Catalog Entry Template

Copy this for each PSDH in your catalog.

```markdown
## PSDH-[NNN]: [Short Descriptive Title]

**Plain language:**
[One to three sentences. Specific enough to violate. General enough to
reuse across implementations. A senior architect would enforce this in
code review but may never have written it down.]

**Contract:**
  PRE:  [precondition — what must be true for this heuristic to apply]
  POST: [postcondition — what must be true after the constrained operation]
  INV:  [invariant — what must hold throughout]

**Severity:** [critical | high | medium | low]

**Source questions:**
  - [Which L0 question(s) surfaced this constraint, e.g., "L0-Q3 (partial failure)"]
  - [If discovered via flywheel iteration, note the cycle]

**Enforcement:**
  - Rule: [Yes/No — if Yes, cite the rule ID or location]
  - Property test: [Yes/No — if Yes, cite the test name]
  - Review criterion: [Yes/No — if Yes, cite the checklist item]
  - Hook heuristic: [Yes/No — if Yes, cite the heuristic ID]

**History:**
  - v1 ([date]): [How it was discovered and initial formulation]
  - v2 ([date]): [What changed and why — e.g., "tightened after property
    test revealed ambiguity in 'exactly once' semantics"]
```

## Field Instructions

### id

Format: `PSDH-NNN` where NNN is a zero-padded sequential number. IDs are permanent — if a PSDH is retired, its ID is not reused. This prevents confusion in enforcement artifact references.

### plain_language

The core statement. Write it so that someone unfamiliar with the codebase can understand what the constraint means and why violating it is harmful. Avoid implementation-specific references (no function names, no file paths). The plain-language statement is what gets quoted in rules, review criteria, and documentation.

Test: can you describe a concrete scenario that violates this statement? If not, it is too vague.

### contract

The formal expression of the constraint as PRE/POST/INV. Uses the same format as the contract template (see `contract-template.md`). Not all PSDHs have all three clauses — some are purely invariants, some are pre/post pairs. Omit clauses that do not apply rather than writing trivial ones.

The contract serves two purposes:
1. Precision — it resolves ambiguities in the plain-language statement
2. Testability — property tests are derived from contract clauses

### severity

Indicates the consequence of violation:

| Level | Meaning |
|-------|---------|
| critical | Violation causes data loss, corruption, or safety failure. Must be enforced by rule AND property test. |
| high | Violation causes silent incorrect behavior. Should be enforced by property test. |
| medium | Violation degrades reliability or creates technical debt. Enforced by review criteria. |
| low | Violation is suboptimal but not incorrect. Documented for awareness. |

### source_questions

Traceability back to the L0 protocol. Record which question(s) surfaced the raw constraint that led to this PSDH. If the PSDH was discovered during contract writing (flywheel), note "contract review" as the source. If discovered during a flywheel iteration, note the cycle number.

This field enables audit: if someone questions why a PSDH exists, the source questions provide the reasoning chain back to the architecture analysis.

### enforcement

Which mechanisms enforce this PSDH. At minimum, every PSDH should have review criterion = Yes (all PSDHs are reviewable). The other mechanisms are selective:

- **Rule:** Reserved for the 5-8 highest-priority PSDHs. Rules are always-loaded constraints in the agent's context. Adding too many dilutes attention.
- **Property test:** For PSDHs with clear pre/post contracts and testable runtime behavior. Roughly 30-50% of PSDHs qualify.
- **Review criterion:** For all PSDHs. Checklist items for design review and post-implementation review.
- **Hook heuristic:** For PSDHs where violations can be detected at runtime from tool calls, diffs, or state inspection. This is the "airbag" — it detects after the fact, not before.

### history

A changelog for the PSDH entry. Each version records what changed and why. This is essential for the flywheel: as property tests reveal ambiguities, as implementations expose edge cases, and as the system evolves, PSDHs get refined. The history tracks that refinement.

Always record the discovery mechanism in v1 (which L0 question, which analysis step). This is distinct from `source_questions` — the history captures the narrative, the source_questions capture the traceability link.

## Example Catalog Entry

This example is from the distributed task queue prototype (Phase 3 research).

```markdown
## PSDH-3: Re-entry Must Reset Budget

**Plain language:**
Any operation that returns a terminated entity to the active pool must
reset the entity's exhaustion counter. Failure to reset creates an
immediate re-termination loop — the entity re-enters the terminal state
after one cycle, not after a full retry budget.

**Contract:**
  PRE:  entity.state == TERMINATED AND entity in terminal_pool
  POST: entity.state = ACTIVE; entity.attempt_counter = 0;
        entity in active_pool; entity NOT in terminal_pool
  INV:  after re-entry, entity has full budget (max_retries) available

**Severity:** high

**Source questions:**
  - L0-Q6 (phase invariants) — the DLQ-to-ready transition's postconditions
  - Contract review — contract writing made the counter-reset requirement
    precise; the natural-language constraint said "retry" without specifying
    whether the budget resets

**Enforcement:**
  - Rule: Yes (CLAUDE.md rule #3)
  - Property test: Yes (test_psdh3_dlq_retry_resets_counter)
  - Review criterion: Yes (DLQ review checklist item 2)
  - Hook heuristic: No (post-hoc detection not useful — the bug is silent
    until the entity re-enters the terminal state)

**History:**
  - v1 (2026-02-22): Discovered via L0-Q6. Initial formulation: "DLQ retry
    must reset the attempt counter."
  - v2 (2026-02-22): Generalized from task-queue-specific to any terminated-
    entity re-entry pattern. Contract tightened after property test revealed
    that "retry" was ambiguous — it could mean "re-enqueue without reset"
    (the bug) or "re-enqueue with full budget" (the intent). Violation test
    (test_psdh3_broken_dlq_retry_no_reset) confirmed: without reset, the job
    immediately re-enters DLQ after one failure.
```

## Starting a New Catalog

1. Create a file named `psdh-catalog.md` (or equivalent for your project) in your project's documentation directory.

2. Add a header:
   ```markdown
   # PSDH Catalog: [Project Name]

   **Component:** [Name of the component or subsystem analyzed]
   **Triage score:** [N/5 coordination properties]
   **Last updated:** [date]
   **Total PSDHs:** [count] (active: [count], retired: [count])
   ```

3. Add entries using the template above, one per PSDH, in ID order.

4. When retiring a PSDH (no longer applicable due to architectural change), do not delete it. Add a final history entry noting the retirement and reason. Change the severity to `retired`. This preserves the audit trail.

## Maintaining the Catalog

The catalog is a living document. It changes at two points:

- **During design phase:** Rapid iteration. L0 protocol surfaces constraints, contracts refine them, property tests sharpen them. Multiple revisions per session are normal.

- **After architectural changes:** When the system evolves, re-run the L0 protocol on affected components. New PSDHs may emerge; existing ones may need revision or retirement.

Between these phases, the catalog is stable. Enforcement artifacts (rules, tests, criteria) reference it. Do not modify enforcement artifacts without updating the catalog first — the catalog is upstream of everything.

## Machine-Readable Format

The catalog has a parallel YAML schema (see `psdh-schema.yaml`) for machine consumption. The markdown catalog is the human authoring format; the YAML schema defines the structure for the emitter and automated tooling. Keep them aligned — the YAML schema's fields correspond exactly to the template fields above.
