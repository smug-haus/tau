# PSDH Extraction Method

A structured process for extracting Project-Specific Design Heuristics from coordination-heavy software components. PSDHs are plain-language constraints that occupy the gap between architecture docs (too vague to enforce) and tests (too specific to design with). They are the rules a senior architect enforces in code review but has never written down.

## When to Use

Apply this method to components with coordination complexity: shared mutable state, temporal coupling, cross-process coordination, feedback loops, or state accumulation. The triage step (30 seconds) determines whether a component qualifies. Simple, stateless, or purely functional components are skipped.

## Process

```
FOR EACH COMPONENT:

  1. TRIAGE (30 seconds)                      → triage-checklist.md
     Score against 5 coordination properties.
     Score < 2: SKIP.  Score >= 2: PROCEED.

  2. ELICIT (10-15 minutes)                   → l0-protocol.md
     Apply 8 structured questions (L0 protocol)     elicitation-prompt.md
     to the architecture description.
     Record raw constraints.

  3. ENUMERATE (5-10 min, if triage >= 3)     → l0-protocol.md §Escalation
     State enumeration tables for highest-risk
     interactions. Optional L1 escalation.

  4. CONTRACT (5-10 minutes)                  → contract-template.md
     Express constraints as PRE/POST/INV
     per component boundary.
     FLYWHEEL CHECK: did contracts reveal gaps?

  5. EXTRACT PSDHs (5 minutes)                → psdh-catalog-template.md
     Generalize constraints to plain-language        psdh-schema.yaml
     heuristics. Record in catalog.

  6. ASSIGN ENFORCEMENT (5 minutes)           → enforcement-guide.md
     For each PSDH, assign mechanisms:
     agent rules, critic criteria, property
     tests, hook heuristics, or documentation.

  7. OPERATIONALIZE (10-20 minutes)           → property-test-patterns.md
     Write property tests for high-risk PSDHs.
     ~30-50% of PSDHs qualify.

  8. FLYWHEEL (5-10 minutes)
     Feed PSDHs back into L0. Look for
     PSDH-to-PSDH interactions. One cycle.

TOTAL: ~60-90 min for coordination-heavy components.
       ~30 sec for simple components (triage → skip).
```

## Documents in This Directory

| Document | Purpose |
|----------|---------|
| [l0-protocol.md](l0-protocol.md) | The 8 questions — core of the method |
| [triage-checklist.md](triage-checklist.md) | 5-property gateway — decides whether to apply L0 |
| [contract-template.md](contract-template.md) | PRE/POST/INV boundary contracts |
| [psdh-catalog-template.md](psdh-catalog-template.md) | PSDH catalog entry format (human authoring) |
| [psdh-schema.yaml](psdh-schema.yaml) | PSDH machine format (emitter input) |
| [enforcement-guide.md](enforcement-guide.md) | Which enforcement mechanism for which PSDH |
| [property-test-patterns.md](property-test-patterns.md) | PSDH → property test translation |
| [elicitation-prompt.md](elicitation-prompt.md) | System prompt for LLM-assisted sessions |

## Key Design Decisions

- **Selective, not universal.** The triage step prevents applying the method where it adds no value. This is the primary efficiency feature.
- **Questions, not notation.** The 8 L0 questions capture ~70% of constraint value. Formal methods were evaluated (10 approaches) and mostly dropped. The value is in asking the right questions.
- **LLMs as generation partners.** LLMs are competent at L0/L1 elicitation, risky at L2 formal verification. Use them for discovery, not as verification authorities.
- **30-50% property test coverage.** Not every PSDH needs a test. The enforcement guide helps you decide which ones do.
- **The flywheel converges.** Feeding PSDHs back into L0 surfaces additional constraints, but diminishing returns set in after 2 cycles.
