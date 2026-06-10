---
template_version: 1
template_name: problem
node_kind: leaf
mode: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Operability and hygiene — factory state observability and worktree/branch invariants

## Statement

The factory's runtime state — what gates are wired, which gates have
run on which PRs with what verdict, what orphan worktrees and stale
branches exist, whether `parent-on-main` holds, what coherence checks
last ran on `main`, what audit findings are open / waived — must be
observable from a single query surface, and the worktree-discipline
invariants must be mechanically enforced rather than relying on
agents reading the rule. v1 fails on both: 63-571 orphan worktrees
(root #8), `parent-on-main` invariant ignored, and no view of factory
state exists outside reading git logs and `.claude/logs/` by hand.
The problem is solved when (a) a single dashboard or queryable
endpoint shows factory state and (b) `parent-on-main` and worktree
cleanup are enforced by hooks/CI rather than by rule prose.

## Context

- Root §Hypothesis #8 — worktree branches leak (63-571 orphans);
  `parent-on-main` invariant ignored.
- Root §Acceptance E (Operability) — "The factory's state … is
  observable from a single dashboard or query, not reconstructed by
  reading git logs."
- `.claude/rules/worktree-discipline.md` — the prose source-of-truth
  rule; today enforced only by agent self-discipline.
- `.claude/settings.json` — the place hooks (`PreToolUse`,
  `PostToolUse`, `SessionStart`) can run pre-commit / pre-spawn
  invariant checks.
- v1 has `.claude/logs/solution-tree.json` and per-PR gate verdicts
  recorded in PR bodies, but no aggregation surface.
- Existing ecosystem: GitHub's `actions/runs` API, GitHub Projects
  v2 for backlog state, the Tau project's own `:tau_web` poncho
  package (SPEC-WEB-DASHBOARD) which already plans a dashboard
  surface, observability backends with OpenTelemetry export, simple
  Grafana / Datasette dashboards over a SQLite view of repo state.

## Failure classes addressed (from root §Hypothesis)

- **#8** (primary) — worktree leaks, `parent-on-main` violation; the
  full enforcement of `worktree-discipline.md` invariants by hooks
  and CI rather than by prose.
- Operability dimension of all classes (#1–#10 cumulative) — without
  a state surface, no class' real-world fix rate can be measured.
  This leaf does not detect any class's *violations* (those are
  owned by their respective sibling leaves) but produces the surface
  that makes the verdicts visible and actionable.

## Complecting hypothesis

- "What the factory is doing" is complected with "where you happen
  to look" because state lives in `.claude/logs/`, GitHub PR bodies,
  GitHub Actions runs, ephemeral agent contexts, and human memory;
  unifying requires a single read model populated by gate verdicts
  and repo events.
- "Worktree hygiene" is complected with "agent discipline" because
  the only enforcement is rule prose that agents must read; making
  it mechanical requires either pre-spawn hooks (refuse to spawn
  with stale parent) or post-merge sweeps (auto-prune finished
  worktrees and stale branches).
- "`parent-on-main` invariant" is complected with "the coordinator's
  attention" because checking it is a multi-step git incantation; a
  hook or pre-spawn skill must run the check as a precondition with
  no opt-out.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The factory specification names mechanisms such that: (a) a single
dashboard or queryable endpoint (HTTP, Datasette over SQLite, or
the existing planned `:tau_web` LiveView) shows at minimum: gate
inventory (which gates exist, on which workflow / branch protection
rules); per-PR gate verdicts (pass/fail/skipped with reason) for
the last N PRs; orphan worktree count and list; stale-branch count
(remote branches with no open PR and no recent commits); last
`main`-coherence run timestamp and verdict; open audit-finding
count by surface; in-flight PRs by milestone; (b) the dashboard
data source is populated automatically — gate verdicts written by
the gates themselves (no manual entry); worktree / branch state
read live from `gh api` or `git for-each-ref`; the dashboard
itself cannot silent-fail (a dashboard component that cannot fetch
data shows an error state, not a blank panel); (c) a pre-spawn
hook (PreToolUse on Task tool, or a `SessionStart` hook) verifies
parent-on-main and aborts the spawn if violated, with the diagnostic
naming exactly which invariant failed and the recovery command;
(d) a `main`-merged hook (`PostToolUse` or a scheduled workflow)
runs the worktree-cleanup sequence and the parent-on-main sync,
and refuses to silently leave finished worktrees registered (alarms
the dashboard or opens an issue if cleanup is blocked); (e) the
design records reuse vs build per surface (existing `:tau_web`
poncho? GitHub Projects v2 view? Datasette over a periodically-
generated SQLite? OpenTelemetry exporter + Grafana?) per root
§Acceptance D; (f) the spec output identifies concrete artifacts:
the dashboard endpoint (LiveView module path, route, port), hook
script paths and `.claude/settings.json` entries, the scheduled
workflow for cleanup, the SQLite/Postgres schema (if any) for
verdict aggregation, the `gh` query commands or webhook receivers,
and the alarm channel (issue-opener Action, telemetry event).

## Out of scope

- Per-PR pre-merge code gates and their verdicts — owned by
  **pre-merge-code-gates** sibling (this leaf *displays* verdicts
  it does not produce them).
- The gate-execution substrate (silent-skip, evidence trust) —
  owned by **pre-merge-evidence-and-skip-integrity** sibling.
- AC-binding mechanics — owned by **intent-capture-and-ac-binding**
  sibling.
- Cross-document drift on `main` — owned by
  **post-merge-cross-artifact-coherence** sibling.
- Audit-finding ingestion and registration — owned by
  **knowledge-memory-and-audit-ingestion** sibling (this leaf
  surfaces "audit findings open count" but does not own the
  ingestion path).
- Documentation-only components; agent-discipline-only enforcement;
  workstream-2 corrective-actions catalogue.

## Amendment log

- (none yet)
