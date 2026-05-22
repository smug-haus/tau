# ADR-0001: GitHub issues are the backlog

- **Status:** Accepted
- **Date:** 2026-04-30
- **Deciders:** @smug-haus
- **Related:**
  - `CLAUDE.md` § "Workflow: GitHub issues are the backlog"
  - `TAU.md` § "Workflow: issues are the backlog"

## Context

Tau is built by a mix of humans and agentic loops. Both need a
shared, queryable, durable record of what's known to be wrong, what
to work on next, and what was decided about a given finding. Local
TODO comments and out-of-tree plan files are not addressable from
outside a checkout, don't survive `git rm`, and silently rot.

We need a single source of truth for outstanding work, callable from
both humans (web UI) and agents (`mcp__github__list_issues`,
`search_issues`).

## Decision

Every feature, bug, polish item, and doc gap lives as a GitHub issue
on this repo. Plans live in issue comments; PRs link back to issues;
commits close them. Sub-agents must consult issue state before
proposing new design.

Specifics:

- New finding → issue, with `<type>: <one-liner>` title (`type ∈
  bug | feature | polish | docs | chore | refactor | perf | test`)
  and at least one `area:<subsystem>` label.
- Long-form plans (kept in milestone descriptions) reference issue
  numbers and call
  out which commits close which issues.
- Commits end with `Closes #N` (or `Refs #N` for partial work).
- PR descriptions enumerate every issue the PR closes so the
  auto-link populates.
- No `# TODO` comments — file the issue and reference it from the
  source line if needed (`# See #42`).

## Consequences

- Backlog state is queryable across machines and sessions; agents
  resume cleanly.
- Issue overhead per finding is small (~30s) but non-zero.
- The repo's issue list grows; we accept that and triage labels
  rather than closing speculative issues prematurely.
- Discussions about a fix happen on the issue, not in PR review,
  so the design rationale survives PR squash-merges.

## Alternatives considered

- **Tracking in `priv/backlog.md` or similar in-repo file.** Tried
  in early prototypes; merge conflicts when two branches both
  touch it, plus no ergonomic API for agents to read selectively.
- **Linear / Jira / external tool.** Forces a credential and a UI
  most contributors don't share. GitHub is already the source of
  truth for the code.
- **No backlog, decide at the moment.** Tried in the M0 push;
  resulted in repeat re-discoveries of the same gaps across
  sessions.

## Notes

Milestone-scale plans live in GitHub milestone descriptions. Smaller
decisions live in issue comments. ADRs (this directory) capture
_decisions_; issues capture _work_; milestones capture _sequencing_.
They're complementary.
