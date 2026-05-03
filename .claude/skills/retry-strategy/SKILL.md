---
name: retry-strategy
description: >
  Structured retry decision-making for failed agent attempts. Use when
  an implementation attempt has been killed or failed evaluation and
  you need to decide next steps (refine, pivot, or give up).
  Provides solution tree management guidance.
---

# Retry Strategy

Use this skill immediately after an attempt is killed or fails evaluation. The goal is to decide: refine, pivot, or give up — and to set up the next attempt correctly.

---

## 1. Branch Selection

### Refine
The approach was directionally correct but execution failed.

**When to refine**:
- Tactical kill reason (wrong file path, specific test failure, minor logic error, syntax error)
- Evaluation failure on a specific, identifiable issue
- Errors are different each attempt (indicating forward progress)

**How to refine**:
1. Identify the exact error from the kill reason or evaluation
2. Add it explicitly to the avoidance list in the solution tree
3. Inject the correction as targeted instructions in the next attempt's preamble
4. Do not change the overall approach

### Pivot
The approach is wrong. A different strategy is needed.

**When to pivot**:
- Strategic kill reason (wrong architecture, design constraint violation)
- Same error class recurring across 3+ attempts
- Cascading failures — fixing one thing breaks another
- Multiple heuristics triggered simultaneously
- The attempted approach contradicts a fundamental project constraint

**How to pivot**:
1. Summarize what was tried and the core reason it failed
2. Identify the fundamental assumption that was wrong
3. Choose a different approach — do not iterate on the same strategy
4. Record the failed approach in the solution tree so the next agent does not repeat it

### Give up
Max attempts exhausted or task is genuinely impossible.

**When to give up**:
- 5 attempts completed with no convergence
- A fundamental blocker has been identified that cannot be resolved by the agent (requires human decision, external dependency, spec change)

**How to give up**:
1. Summarize all attempts: what was tried, why each failed
2. Identify the specific blocker preventing progress
3. Recommend the specific human action needed to unblock
4. Do not attempt a sixth time

---

## 2. Solution Tree Management

The solution tree is the single source of truth for retry decisions. Every attempt must be recorded before launching the next.

**Per-attempt record** (keep under 500 tokens):
- `approach_summary`: What strategy was used (1-2 sentences)
- `outcome`: `killed`, `completed`, or `failed_evaluation`
- `kill_reason`: Exact kill reason string from the heuristic (or null)
- `evaluation`: Key finding from code review (or null)
- `files_modified`: List of files that were changed
- `key_decisions`: 2-3 decisions made during the attempt that constrained the approach

**What not to record**:
- Full error output — summarize the key insight instead
- Tool call transcripts — these belong in logs, not the solution tree
- Intermediate states — record final state only

The solution tree is read by the SubagentStart hook to generate the preamble for the next attempt. Keep it parseable and concise.

---

## 3. Context Injection Rules

The SubagentStart hook generates a preamble injected at the start of each new subagent's context. This prevents the new agent from inheriting the confusion of previous attempts.

**Preamble contains**:
- Task description (from solution tree)
- Summary of each previous attempt (from solution tree — one paragraph each)
- Explicit avoidance list: things tried that didn't work
- Chosen strategy: refine or pivot, with brief rationale

**Preamble constraints**:
- Maximum 500 tokens per attempt summary
- Total preamble should not exceed 1500 tokens (3 summaries × 500)
- Do not include raw error output
- Do not include file contents

The preamble's purpose is to give the new agent situational awareness without contaminating it with the failed agent's reasoning chains.

---

## 4. Meta-Restart Protocol

After 3 consecutive failed attempts: **mandatory meta-restart**.

This is a hard rule, not a judgment call.

**Steps**:
1. Compress all attempt history into a single briefing document (maximum 1000 tokens total)
   - What was tried (each approach in one sentence)
   - What failed (each failure in one sentence)
   - What to avoid (explicit list)
2. Clear the working context entirely
3. Restart with only:
   - The briefing document
   - The current solution tree
   - The original task description
4. Do not carry forward any reasoning, partial implementations, or intermediate conclusions from the failed attempts

**Rationale**: After 3 failures, the accumulated context is likely contributing to the problem. A fresh start with a compact summary is more productive than continuing with a contaminated context.

---

## 5. Reference

For the solution tree JSON schema and a complete example:
→ Read `reference/solution-tree-schema.md`

For detailed decision examples with worked scenarios:
→ Read `reference/decision-framework.md`
