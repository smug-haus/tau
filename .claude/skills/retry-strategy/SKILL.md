---
name: retry-strategy
description: >
  Structured retry decision-making for failed agent attempts. Use when
  an implementation attempt has been killed or failed evaluation and
  you need to decide next steps (refine, pivot, or escalate). The
  decision logic maps to the factory's bounded refine→pivot→escalate
  ladder (SPEC-FACTORY-CORE D-318).
---

# Retry Strategy

Use this skill immediately after an attempt is killed or fails the gate. The
goal is to decide: **refine, pivot, or escalate** — and to set up the next
attempt correctly.

> **State-store note (#410 / 2026-06).** `.claude/logs/solution-tree.json` was
> deleted (ADR-0023, #401); it is no longer the source of truth. Cross-attempt
> state now lives in:
> - **Interim (current Claude-harness factory):** the **draft PR** — its body is
>   the plan-of-record and attempt log; `gh pr comment` / `gh issue comment`
>   carry per-attempt findings. Query with `gh`, not a JSON file.
> - **Target (the supervised OTP factory):** the **durable Ledger (L)** — the
>   per-PR `Tau.Factory.Unit` FSM holds `attempt_count` and the verdict/challenge
>   history durably (`SPEC-FACTORY-CORE` D-315/D-318), and the Coordinator resumes
>   from it on crash. The "solution tree" is that Ledger, not a hand-curated file.
>
> The **decision logic below is unchanged** — only where the record lives moved.

---

## 1. Branch selection (the refine → pivot → escalate ladder)

This is the product-level retry ladder (`SPEC-FACTORY-CORE` §3.3, D-318): bounded
at **N refines**, then one **pivot**, then **escalate**.

### Refine
The approach was directionally correct but execution failed.

**When to refine**:
- Tactical kill/gate reason (wrong file path, specific test failure, minor logic
  error, syntax error).
- Gate FAIL on a specific, identifiable finding.
- Errors are different each attempt (forward progress).

**How to refine**:
1. Identify the exact finding from the kill reason or gate verdict.
2. Record it on the **draft PR** (body attempt-log entry + a `gh pr comment`) —
   interim; the FSM records it durably in the target.
3. Inject the correction as targeted guidance for the next attempt; stay on the
   **same draft PR / same diff base**.
4. Do not change the overall approach.

### Pivot
The approach is wrong. A different strategy is needed.

**When to pivot**:
- Strategic kill reason (wrong architecture, design-constraint violation).
- Same error class recurring across the refine bound (N).
- Cascading failures — fixing one thing breaks another.
- The approach contradicts a fundamental project constraint (an OTP
  non-negotiable, a SPEC §4 contract).

**How to pivot**:
1. Summarize what was tried and the core reason it failed (on the PR).
2. Identify the wrong assumption.
3. Choose a materially different approach on a **fresh diff** — do not iterate
   the same strategy. (In the target, a pivot opens a fresh draft PR and resets
   the refine count.)

### Escalate (was "give up")
The retry ladder is exhausted, or a blocker needs a human.

**When to escalate**:
- N refines + a failed pivot with no green gate (`E-RETRY-EXHAUSTED`).
- A blocker the agent cannot resolve: needs human product judgement, an external
  dependency, or a SPEC change (`E-AMBIGUITY`).
- See the full, total escalation set `E` in `heuristic-analysis` and
  `docs/arch/02-requirements/liveness.md`.

**How to escalate**:
1. Summarize all attempts: what was tried, why each failed.
2. Name the specific blocker and the exact human action needed to unblock.
3. Record the escalation reason + state to the PR (interim) / Ledger (target);
   halting on a safety condition is **correct**, not failure.

---

## 2. Where retry state lives (replaces "Solution Tree Management")

Record, before launching the next attempt, the minimum that lets a fresh agent
resume — but **in the PR / Ledger, never a context-window-held tree**:

**Per-attempt record** (keep terse; on the draft PR body + a `gh` comment):
- `approach_summary` — the strategy (1–2 sentences).
- `outcome` — `killed` | `gated_fail` | `merged`.
- `kill_reason` / `gate_finding` — the exact string (or null).
- `files_touched` — the changed-file set (the gating-test paths are frozen and
  off-limits to the implementer).
- `key_decisions` — 2–3 constraints chosen this attempt.

**Do not record**: full error output (summarize the insight), tool transcripts
(those are logs), intermediate states (final only).

In the **target factory** this record is the `Tau.Factory.Unit` FSM's
per-transition snapshot to L (`durable-spine.md`); you do not hand-maintain it.

---

## 3. Cross-attempt context (replaces hook-injected preamble)

The previous mechanism — a `SubagentStart` hook reading the JSON tree to build a
preamble — is **retired** with the tree. Cross-attempt context now comes from the
**durable plan-of-record**:

- **Interim:** the next implementer is briefed from the **draft-PR body** (the
  single source of brief + plan — no brief/PR drift) plus the prior attempts'
  `gh` comments. `inject-retry-context.py` already degrades gracefully when the
  tree is absent; treat its output as best-effort, the PR as authoritative.
- **Target:** the implementer worker is spawned with the Unit FSM's durable
  state as its brief; there is no context-window tree to inject.

Give the new agent situational awareness (what was tried, the avoidance list, the
chosen branch + rationale) **without** the failed agent's reasoning chains.

---

## 4. The 3-failure rule is context hygiene, NOT a product retry mechanism

> **Deprecated as a state mechanism.** The old "meta-restart: compress history to
> ≤1000 tokens, clear context, restart from the solution tree" existed *only
> because* factory state was a degrading context window. With durable state
> (interim: the PR; target: the Ledger, RPO=0) there is **no volatile tree to
> rehydrate** — the Coordinator resumes from L. Do not port the meta-restart as a
> product mechanism (`docs/arch/.../migration.md` §7).

What remains: the harness **3-consecutive-failure** rule (`CLAUDE.md` Hard Rules)
is a *context-hygiene* reset of the **coordinator's working context** — it
changes *how the coordinator is run*, never *what the loop decided*. It is
orthogonal to the product retry bound (N), and **escalation always wins over a
restart** (`factory-loop.md` "Reconciling N = 3 with the harness meta-restart").
On a hygiene reset, resume from the PR/Ledger — the durable record is the single
source of truth across the reset.

---

## 5. Reference

For detailed decision examples with worked scenarios:
→ Read `reference/decision-framework.md`

For the kill-reason → escalation-reason taxonomy:
→ Use the `heuristic-analysis` skill.

For the durable-state model that supersedes the JSON tree:
→ `docs/spec/SPEC-FACTORY-CORE.md` (the Unit FSM, the Ledger, D-318/D-315) and
   `docs/arch/04-software-architecture/{control-plane,durable-spine}.md`.
