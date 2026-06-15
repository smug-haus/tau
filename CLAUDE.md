# tau — Claude Agent Harness

@TAU.md

## Mission

A working TUI is the priority. See `docs/MISSION.md` for the mission
statement and pointers to where state and design live. The user-turn
loop's contract is `docs/spec/SPEC-USER-TURN.md`.

The runtime-invariant namespace is **D-NNN**, partitioned across SPECs
per `docs/MISSION.md`. Before authoring a new D-NNN, verify the
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

**Persona dispatch (CORRECTED 2026-06-15):** Spawn `implementer` / `test-author` / `reviewer` / `critic` **via `subagent_type`** (they ARE registered/auto-discovered). This is **mandatory**: the `agent_type` it stamps into the PreToolUse payload is what `.claude/hooks/enforce-agent-paths.py` keys on to mechanically scope writes — **`implementer` may write ONLY `lib/**` (+ `web/lib/**`); `test-author` only `test/**`; `reviewer`/`critic` may not write at all.** Spawning these roles WITHOUT `subagent_type` (generic Agent + inlined persona) nulls `agent_type` and defeats the enforcement — do not do it. Specs/docs/`MISSION.md` are authored by a non-restricted role (shaper/`general-purpose`) BEFORE the implementer, never by the implementer. The prior "do not use subagent_type / inline personas" guidance was wrong and is retired.

Worktree isolation isolates git refs but **not** absolute-path writes — brief subagents to use relative paths. Detail in `tau-architecture`.

## Task Lifecycle

1. Invoke `critic` for coordination-heavy tasks (shared state, temporal coupling, cross-process boundaries).
2. Spawn `implementer`.
3. Outcome: `completed` → `reviewer` (pass = done, fail = refine); `killed` → read `.claude/logs/kill-signal.json`, load `heuristic-analysis`.
4. On retry, load `retry-strategy`; choose **refine** or **pivot**; record the rationale in the PR description.
5. Repeat to a sensible attempt cap (default 5).

## Hard Rules

- After 3 consecutive failures: compress attempt history to ≤ 1000 tokens and restart.
- Never implement directly.
- Kill signals are terminal; do not restart the same agent.
- Document branch decisions before acting.
- File a GitHub issue before any non-trivial code change; reference as `Closes #N`. See `tau-github-workflow`.
- Both `critic` and `reviewer` MUST PASS before any PR. See `/pr`.
- Every agent that reads or writes files MUST be spawned with `isolation: worktree`, and parent's HEAD MUST be on `main` at `origin/main` before every spawn. See `.claude/rules/worktree-discipline.md` for the full pre-spawn checklist, post-completion cleanup discipline, and recovery procedure.

## Compact Instructions

**Preserve:** task, attempt count, last kill reason, branch decision, last active subagent, GitHub issue / PR numbers, any ADR being drafted, gate verdicts on the active PR.
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
