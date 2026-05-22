---
name: design-reasoning
description: >
  Structured design reasoning using the PSDH method. Use when analyzing
  coordination-heavy components, identifying non-obvious design constraints,
  or generating design heuristics for runtime enforcement. Provides the
  L0 elicitation protocol and 5-property triage checklist.
---

# Design Reasoning (PSDH Method)

Structured constraint elicitation for coordination-heavy components. Surfaces
implicit assumptions that code review and standard testing miss.

## When to Use

Apply PSDH reasoning when a component scores ≥2 on the triage checklist below.
Skip for simple CRUD, stateless operations, or single-actor pipelines — the method
adds nothing where coordination is absent.

Trigger cases: hook coordination, agent lifecycle management, shared-file state,
retry/escalation ladders, any component where two actors must agree on shared state.

## Triage Checklist

Score 1 for each property present. Score partial presence as 1.

| # | Property | Test question |
|---|----------|---------------|
| 1 | **Shared mutable state** | Can two or more independent actors write the same data? |
| 2 | **Temporal coupling** | Does correctness depend on unenforced ordering between operations? |
| 3 | **Cross-process coordination** | Must two independently executing components agree on something? |
| 4 | **Feedback loops** | Can this component's output feed back as input, with potential to amplify? |
| 5 | **State accumulation** | Does behaviour change based on accumulated history, not just current input? |

**Decision:**
- Score 0–1 → skip. Standard implementation.
- Score 2 → proceed with L0 protocol.
- Score 3 → L0 + L1 state enumeration (enumerate actor-state combinations for highest-risk interactions).
- Score 4–5 → L0 + L1 + consider L2 (formal state machine or Alloy for highest-risk subsystems).

## L0 Protocol — The 8 Questions

Apply each question to the component's architecture description (not code). For each:
1. Ask the question about the specific component — name concrete actors, state, and boundaries.
2. Record every constraint surfaced in natural language.
3. Mark non-obvious constraints (not visible from a normal-speed read). These are the most valuable.

| Q | Question | What it finds |
|---|----------|---------------|
| Q1 | What can be written by more than one actor? | Concurrent write conflicts, missing coordination |
| Q2 | What ordering assumptions are implicit? | Unenforced sequencing, timing-dependent correctness |
| Q3 | What happens if a component fails silently? | Partial failure, silent corruption, recovery gaps |
| Q4 | What information crosses a boundary, and what is lost in transit? | Information-loss boundaries, context truncation |
| Q5 | What feedback loops exist, and can they diverge? | Unbounded retry cycles, amplifying failure modes |
| Q6 | What must be true before and after each phase transition? | Implicit pre/postconditions, violated invariants |
| Q7 | What is the protocol between these components, and what happens if a message arrives out of order? | Protocol ordering violations, late-arrival semantics |
| Q8 | If you change component X, what properties of connected components Y and Z must be re-verified? | Cross-cutting parameter dependencies, cascade effects |

**Expected output:** 5–12 raw constraints per component. Fewer than 5 on a triage-positive component suggests incomplete application.

### After L0

Feed raw constraints into contract expression: normalize each as PRE/POST/INV statements per component boundary (see `reference/contract-template.md`). Contract writing reveals gaps — boundaries not questioned, missing postconditions — which prompt return to L0 for those boundaries.

## From PSDHs to Enforcement

After extracting and contracting constraints, classify each for enforcement:

**Hard constraints** (runtime invariants, silent failure modes) → D-xxx heuristic stubs
- Live in `.claude/hooks/heuristics/design/` alongside H-xxx heuristics
- Format: `D-NNN: description | detection_method | severity_score`

**Soft constraints** (design intent, parameter coupling, change-process rules) → `.claude/rules/*.md`
- Always-loaded context; write as MUST/MUST NOT imperatives
- Budget: 5–8 rules maximum before attention dilutes

**Testable invariants** (state-machine properties, boundary contracts) → property test skeletons
- Target: ~30–50% of PSDHs qualify; prioritise silent failure modes
- Emitter generates stubs; fill in with Hypothesis or equivalent

**All PSDHs** → review criteria checklist
- Every PSDH earns a checklist item regardless of other enforcement

See `reference/enforcement-guide.md` for the decision tree.

## Convergence

Feed D-xxx heuristic outputs back into L0 after 1–2 implementation cycles:
- Check for Q8 interactions: did implementing one constraint invalidate assumptions in connected components?
- Diminishing returns after iteration 2. Stop when new L0 passes produce ≤1 non-obvious constraint.

## Reference Files

Full protocol details are in `reference/`:

| File | Contents |
|------|----------|
| `l0-protocol.md` | Complete 8-question protocol with worked examples and escalation criteria |
| `triage-checklist.md` | 5-property checklist with scoring table and component examples |
| `contract-template.md` | PRE/POST/INV contract format with worked task-queue example |
| `psdh-catalog-template.md` | Catalog entry format, field instructions, maintenance guidance |
| `psdh-schema.yaml` | Machine-readable schema for emitter consumption |
| `enforcement-guide.md` | Decision tree for assigning enforcement mechanisms to each PSDH |
