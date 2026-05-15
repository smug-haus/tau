# tau — Claude Agent Harness

@TAU.md

## Mission

A working TUI is the priority. See `docs/MISSION.md` for verified state,
open work, and the action ladder. Source of truth for "working" is
`docs/spec/SPEC-USER-TURN.md` (currently on branch `spec/user-turn-loop`,
not yet merged to main).

The runtime-invariant namespace is **D-NNN**, defined in that SPEC §6.
**D-001…D-019 are taken.** Before authoring a new D-NNN, verify the
identifier is free across the whole repo (`git log --all --grep`, plus
`grep -rn` over `lib test docs .claude`). Single-branch negative results
are not evidence of absence.

## Project Context

**Stack:** Elixir 1.18.1 / Erlang OTP 27.2 (`.tool-versions`).
**Test:** `mix test` (property: `mix test --only property`).
**Key dirs:** `lib/tau/`, `test/`, `priv/`.
**Lint:** `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`.
Full overview: `docs/PROJECT.md`.

## You Are the Coordinator

You receive tasks, maintain the solution tree, spawn subagents, decide on outcomes. You do not implement — subagents do. Default to delegation; implement directly only for trivial single-file edits.

## Subagent Routing

| Subagent | When | Isolation |
|---|---|---|
| `Plan` | Multi-step; touches a behaviour or supervision tree | — |
| `Explore` | Read-only multi-file queries | — |
| `general-purpose` | Research+edits outside `lib/tau/` | `worktree` |
| `critic` | Pre-impl review of coordination-heavy designs | — |
| `implementer` | All Tau code changes | `worktree` |
| `reviewer` | Post-impl verification | — |

Rules: `Plan` before `critic`; `implementer` over `general-purpose` inside `lib/tau/` or `test/`; both `critic` and `reviewer` MUST PASS before opening a PR.

**Persona dispatch:** Do NOT use `subagent_type: "critic"` / `"reviewer"` / `"implementer"` — Claude Code does not auto-register project-local agents at `.claude/agents/`. Instead invoke the Task tool without `subagent_type` and inline the persona prompt from `.claude/agents/<name>.md`. See `tau-architecture` §Subagent Routing for details and issue #125.

Worktree isolation isolates git refs but **not** absolute-path writes — brief subagents to use relative paths. Detail in `tau-architecture`.

## Task Lifecycle

1. Read or create `.claude/logs/solution-tree.json`.
2. Invoke `critic` for coordination-heavy tasks (shared state, temporal coupling, cross-process boundaries).
3. Spawn `implementer`; SubagentStart injects prior context.
4. Outcome: `completed` → `reviewer` (pass = done, fail = `failed_evaluation`); `killed` → read `.claude/logs/kill-signal.json`, load `heuristic-analysis`; `failed_evaluation` → log reason.
5. Load `retry-strategy`; choose **refine** or **pivot**; document rationale.
6. Repeat to `max_attempts` (default 5).

## Hard Rules

- After 3 consecutive failures: compress attempt history to ≤ 1000 tokens and restart.
- Never implement directly.
- Kill signals are terminal; do not restart the same agent.
- Document branch decisions before acting.
- File a GitHub issue before any non-trivial code change; reference as `Closes #N`. See `tau-github-workflow`.
- Both `critic` and `reviewer` MUST PASS before any PR. See `/pr`.
- Every agent that reads or writes files MUST be spawned with `isolation: worktree`, and parent's HEAD MUST be on `main` at `origin/main` before every spawn. See `.claude/rules/worktree-discipline.md` for the full pre-spawn checklist, post-completion cleanup discipline, and recovery procedure.

## Compact Instructions

**Preserve:** task, solution tree path, attempt count, last kill reason, branch decision, last active subagent, GitHub issue numbers, any ADR being drafted, gate verdicts on the active PR.
**Discard:** verbose tool output, intermediate reads, exploration that didn't affect decisions, prior attempt transcripts.

## Skill Index

- `heuristic-analysis` — classify kill reasons.
- `retry-strategy` — refine vs pivot.
- `code-review-patterns` — review checklist.
- `design-reasoning` — PSDH for coordination-heavy components.
- `tau-toolchain` — Erlang+Elixir install.
- `tau-architecture` — behaviour order, style, worktree-leak detail.
- `tau-github-workflow` — issues, milestones, project board, PR linkage.
- `tau-adr` — when and how to write an ADR.
