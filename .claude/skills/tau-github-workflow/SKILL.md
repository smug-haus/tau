---
name: tau-github-workflow
description: >
  Use when filing a GitHub issue, opening a PR, writing a commit message,
  or scanning the backlog. Defines triage rules, the area-label canon, the
  PR-issue linkage convention, and the milestone + project-board structure.
---

# tau-github-workflow — issues, milestones, project board, PR linkage

## §1 Three primitives

GitHub is the backlog. Three primitives carry the work:

- **Issues** — the unit of work. One feature / bug / polish item /
  doc gap per issue.
- **Milestones** — see `gh api 'repos/{owner}/{repo}/milestones?state=all'`
  for the current set. The milestone **description** holds the milestone
  plan; issues are filed against the milestone.
- **`Tau` project board** — columns `Todo` / `In Progress` /
  `In Review` / `Done`, spanning all milestones. Issues and PRs are
  added to the board on creation.

## §2 No plan documents in source

Plans live on GitHub, not in the repo:

- No `*.md` files in `/root/.claude/plans/` (host-specific historic
  path; superseded).
- No `docs/plans/` directory.
- No scratch `*.md` files dropped in the repo root.

If the work is large enough to need a plan, write the plan as the
**milestone description** and break it into issues against that
milestone.

## §3 Triage on entry

A new finding becomes an issue with:

- **title:** `<type>: <one-liner>`, where `<type>` ∈ `bug | feature |
  polish | docs | chore | refactor | perf | test`.
- **labels:** a GitHub-built-in (`bug` / `enhancement` /
  `documentation`) **plus** at least one `area:<subsystem>` label
  (canon in §6).
- **milestone:** the relevant `M<n>` or named milestone.
- **project:** added to the `Tau` board, column `Todo`.
- **body:** problem statement, reproducer or evidence, optional fix
  direction. No design discussion in PR descriptions — link to the
  issue.

## §4 Plans start from milestones, then issues

When asked to implement something, the entry sequence is:

1. `gh api repos/smug-haus/tau/milestones/<n>` — read the milestone
   plan.
2. `gh issue list --milestone "M<n>"` — find candidate issues.
3. Pick one (or file a new one if the finding isn't covered).

`Explore` and `Plan` subagents must consult issue + milestone state
before proposing new design.

## §5 Commits and PRs reference issues

- Commit messages end with `Closes #N` (or `Refs #N` for partial
  work).
- PR descriptions enumerate every issue the PR closes so GitHub's
  auto-link populates.
- A PR that crosses milestones lists the milestones in its body.

## §6 Area labels (canon)

Use these consistently so filters like `is:open
label:area:session` work:

`area:session`, `area:cli`, `area:tui`, `area:tools`,
`area:providers`, `area:mcp`, `area:skills`, `area:extensions`,
`area:permissions`, `area:hooks`, `area:memory`, `area:settings`,
`area:persistence`, `area:telemetry`, `area:ci`, `area:docs`,
`area:onboarding`.

Until the labels are pre-created in the repo, embed them as a
`**Area:**` line in the issue body — issue search supports that too.

## §7 Sub-agent rules

`Explore` and `Plan` subagents must consult issue + milestone state
before proposing new design. If a finding doesn't have an issue yet,
the subagent files one (or returns a "needs to be filed" line so the
parent agent files it).

## §8 No `# TODO` comments in code

Don't park backlog items in source. File the issue and reference its
number from the source line:

```elixir
# See #42 — fail-closed behaviour pending design decision.
```

## Current Milestones

| ID | Title | Description |
|----|-------|-------------|
| M0 | Working TUI | AC-1..AC-7 pass; binary launches, completes a one-turn round-trip against a real provider, quits cleanly. |
| M1 | Self-hosting | tau replaces vendored claude-harness; coordinator runs end-to-end through `Tau.Tools.Builtin.Agent`. |
| M2 | Provider reliability | Multi-provider abstraction, fallback chain, per-resource circuit breakers, OpenTelemetry export. |
| M3 | Persistence + replay | Durable JSONL persistence, session resume, hash-anchored editing, audit-trail integration. |
| M4 | Sub-agents & coordination | Agent tool sub-session dispatch, inter-agent message passing, persona-pinned lifetime. |
| M5 | Settings & memory | SQLite-backed semantic memory, settings hot-reload everywhere, vault parity across macOS/Linux/Windows. |
| M6 | Skills & extensions | Skill activation paths (model + slash), MCP server orchestration, extension dynamic loading. |
| M7 | LiveView dashboard | Read-only LiveView session viewer, telemetry dashboard, auth gate, interactive driver. |
| M8 | Distribution & integration | Shareable session URLs, JSON-RPC transport, Gateway behaviour for Telegram/Discord/MCP-server-mode. |
