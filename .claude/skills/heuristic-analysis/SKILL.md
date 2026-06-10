---
name: heuristic-analysis
description: >
  Analyze agent failure patterns and classify kill reasons. Use when
  reviewing failed attempts, deciding between refine and pivot strategies,
  or interpreting heuristic monitor output. Provides failure taxonomy
  and detection pattern reference.
---

# Heuristic Analysis

Use this skill when an attempt has been killed or has failed and you need to determine next steps.

## 1. Failure Classification

**Tactical failures** — fixable with targeted corrections → **Refine**
- Wrong file path
- Specific test failure (one test, clear cause)
- Minor logic error
- Syntax error
- Wrong import or missing dependency

**Strategic failures** — approach is fundamentally wrong → **Pivot**
- Wrong architecture or design choice
- Same error class recurring across 3+ attempts
- Cascading failures (fix A breaks B, fix B breaks C)
- Fundamental misunderstanding of requirements
- Multiple heuristics triggering simultaneously

The distinction is directional: tactical failures mean *progress is happening but execution slipped*; strategic failures mean *the approach cannot converge*.

---

## 2. Reading Kill Reasons

Each heuristic produces a kill reason string. Interpret them as follows:

**H-001 — Edit-undo cycle**
> Agent is oscillating between two states of the same file.

Signal: the agent is confused about requirements, or is fighting a constraint it hasn't identified. Ask: is the stated approach actually achievable given the project constraints? If yes → clarify requirements and refine. If no → pivot.

**H-003 — Repeated identical calls**
> Same tool+arguments executed 3+ times without progress.

Signal: the agent is stuck. Either the command cannot succeed in the current state (environment problem), or the agent lacks a strategy to proceed differently. Check whether the environment is the problem first. If not → the agent needs a different approach. Likely pivot.

**H-004 — Test failure plateau**
> Test failure count is not decreasing across 3+ consecutive runs.

Signal: the current fix strategy is not working. Either the root cause is misidentified, or the fix is addressing a symptom rather than the cause. Different error each run → possibly refine with better diagnosis. Same error each run → pivot.

**H-005 — Context burn**
> 50+ tool calls with no writes or test improvement.

Signal: the agent is reading without acting. Likely lost in the codebase or overwhelmed by task scope. Indicates task decomposition is wrong — the subtask is too large or too ambiguous. Pivot to a simpler decomposition.

**H-008 — Error echo**
> Stderr content appears verbatim in a subsequent write.

Signal: the agent is copying error output into source files rather than fixing the underlying issue. Superficial fix attempt, not genuine understanding. Refine with explicit instruction to fix the root cause, not the error message.

**D-xxx — Design constraint violation**
> Project-specific structural rule has been violated.

Signal: the PSDH constraint catalog flagged a violation. These are harder to fix than tactical errors because they usually require rethinking the local design. Check the PSDH catalog for the specific constraint. Typically → pivot.

---

## 3. Decision Framework

Work through this checklist before choosing refine or pivot:

| Question | Yes → | No → |
|---|---|---|
| Same error class 3+ times across attempts? | Pivot | Continue checklist |
| Different errors each attempt? | Refine | Continue checklist |
| Kill reason involves architecture or design? | Pivot | Continue checklist |
| Kill reason involves a specific file or test? | Refine | Continue checklist |
| Two or more heuristics triggered simultaneously? | Pivot | Refine |

When the checklist is ambiguous, default to **Refine** for attempt 1–2, **Pivot** for attempt 3+.

---

## 4. The escalation tier — mapping to the total set `E`

Refine and pivot are the first two rungs; the third is **escalate**. When the
retry ladder is exhausted or a blocker needs a human, the kill reason maps to
**exactly one** reason in the factory's *total* escalation set `E`
(`SPEC-FACTORY-CORE` §5 / `docs/arch/02-requirements/liveness.md`). This replaces
the v1 "give up" with a structured, total taxonomy — every non-progress state
names exactly why it cannot proceed (the D-317 totality property).

| Condition / kill reason | Escalation reason `e ∈ E` |
|---|---|
| Retry ladder exhausted (N refines + a failed pivot, still red) | `E-RETRY-EXHAUSTED` |
| Design-constraint / spec ambiguity needing human product judgement | `E-AMBIGUITY` |
| > 2 upheld implementer challenges on one PR | `E-CHALLENGE` |
| Destructive / irreversible action requested | `E-DESTRUCTIVE` |
| Budget (token/cost/time/iteration) exhausted | `E-BUDGET` |
| Post-merge `main` health check red | `E-RED-MAIN` |
| Unresolvable merge conflict | `E-CONFLICT` |
| A non-progress state matching none of the above (a defect signal) | `E-UNCLASSIFIED` |

In the target factory the Coordinator performs this mapping with the pure
`Tau.Factory.Escalation.classify/1` (D-317); halting on a safety condition is
**correct** behaviour, not failure. Use the `retry-strategy` skill for the
refine/pivot/escalate decision itself.

---

## 5. Reference

For the full heuristic catalog with detection logic, confidence levels, and kill reason templates:

→ Read `reference/heuristic-catalog.md`
