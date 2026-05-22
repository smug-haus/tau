---
description: >
  Run the blocking critic+reviewer gate against the step's existing draft
  PR. Aborts if either gate fails. Verdicts are recorded in the solution
  tree and the PR body. Does not create or merge the PR.
allowed-tools: Read, Bash(git diff *), Bash(git log *), Bash(git status), Bash(git branch *), Bash(gh pr view *), Bash(gh pr edit *), Bash(gh pr diff *), Bash(gh issue view *), Bash(jq *), Bash(cat *), Bash(mkdir *), Bash(echo *), Bash(date *), Edit, Write, Task
---

Run the blocking PR gate against the step's **existing draft PR** — opened
at factory-cycle step 4, before the implementer was spawned. `/pr` does
**not** create the PR and does **not** merge it. Both `critic` and
`reviewer` MUST return `{"ok": true}` before the PR may be marked ready and
merged by the factory cycle. Either gate failing aborts — the
coordinator then chooses **refine** or **pivot**.

Steps in order — **do not skip**.

## Step 1 — Verify the branch is rebased onto `origin/main`

Before the gate runs, the PR branch MUST sit on top of current
`origin/main` so that `git diff main...HEAD` reflects only this PR's own
changes — not unrelated work merged to `main` since the branch forked.

```sh
git fetch origin
git merge-base --is-ancestor origin/main HEAD
```

If `git merge-base --is-ancestor` exits non-zero, the branch is behind
or diverged. Rebase it (`git rebase origin/main`) and re-run the check;
if the rebase cannot complete cleanly, **abort** with a clear message
naming the conflict — do not proceed to the gate on a stale branch.

## Step 2 — Compute the diff

Determine the base branch (default `main`):

```sh
git diff main...HEAD
git log main..HEAD --oneline
```

Fail loudly if `HEAD` has no commits ahead of `main`.

## Step 3 — Read the draft PR and its linked issue(s)

The branch has an open **draft PR** (factory-cycle step 4). Read it:
`gh pr view <n> --json number,body,isDraft`. The PR body's **Closes** line
names the issue(s) it closes; read each issue body via `gh issue view <N>`
to recover the spec. If the branch has no draft PR, or the PR body names
no issue, **abort** — the factory cycle requires the draft PR to exist,
with its plan-of-record body, before the gate runs.

## Step 4 — Spawn `critic` (design veto)

NOTE: `.claude/agents/critic.md` cannot be auto-registered by Claude Code from
a project-local path. Invoke via the Task tool **without** `subagent_type`.

**Compose the Task prompt as follows — strictly in order:**

1. Read `.claude/agents/critic.md`.
2. Skip the first two standalone `---` lines (YAML frontmatter delimiters) and
   take all remaining text (the full body beginning with "You are a senior systems
   architect…"). Paste it **verbatim** as the opening of the Task prompt. Do NOT
   paraphrase or summarise.
3. Append this context block after the verbatim body:

> Diff: <full output of `git diff main...HEAD`>
> Linked issue: #N — <title from `gh issue view`>
> Files changed: <list>

The critic's `## When invoked by /pr` section already contains the review
instructions and structured-findings schema. Do not duplicate or override them.

Parse `ok` from the JSON object on the agent's **last line** (`{"ok": true}` or
`{"ok": false, "reason": "..."}`). The critic does not emit a `verdict` field —
use `ok` only.

## Step 5 — On `critic` veto

If `critic` returned `{"ok": false, ...}`:

1. Print the full reason to the user.
2. **Abort.** Do not proceed to step 6; do not mark the draft PR ready.

The veto and its evidence live in the conversation; refine attempts
reference prior critic findings by recall, not by a separate log.

## Step 6 — Spawn `reviewer` (quality veto)

NOTE: `.claude/agents/reviewer.md` cannot be auto-registered by Claude Code from
a project-local path. Invoke via the Task tool **without** `subagent_type`.

**Compose the Task prompt as follows — strictly in order:**

1. Read `.claude/agents/reviewer.md`.
2. Skip the first two standalone `---` lines (YAML frontmatter delimiters) and
   take all remaining text (the full body beginning with "You are a post-completion
   evaluator…"). Paste it **verbatim** as the opening of the Task prompt. Do NOT
   paraphrase or summarise.
3. Append this context block after the verbatim body:

> Diff: <full output of `git diff main...HEAD`>
> Linked issue: #N — <title>
> Original spec excerpt: <issue body>

The reviewer's `## When invoked by /pr` section already contains the evaluation
steps and structured-verdict schema. Do not duplicate or override them.

Parse `ok` from the JSON object on the agent's **last line** (`{"ok": true}` or
`{"ok": false, "reason": "..."}`). The reviewer also emits a fenced `json` block
immediately before the final line containing a `"verdict": "PASS|FAIL|PARTIAL"`
field — extract that for the solution tree and PR body.

## Step 7 — On `reviewer` veto

Same as step 5 — print the full reason and abort.

## Step 8 — Both passed

Update the **existing draft PR body's Gate-verdicts section** in place — read the current body (`gh pr view <n> --json body`),
fill the section, and write it back with `gh pr edit <n> --body-file <tmpfile>`:

```
## Gate verdicts
- critic: PASS (`ok: true`) — <one-line summary from critic's findings, if any>
- reviewer: PASS (`verdict: PASS`) — <one-line summary from reviewer's verdict, if any>
```

`/pr` stops here, gate green. It does **not** mark the PR ready and does
**not** merge — the factory cycle step 8 does that (pre-merge freshness
re-check → `gh pr ready` → `gh pr merge` → post-merge `main` health check).
Report the green verdict to the coordinator.

## Recovery

`/pr` is idempotent across attempts — re-running it on a refined branch
re-runs both gates from scratch. After **3 consecutive** veto-failures
on the same task, the harness's mandatory meta-restart kicks in:
compress all attempt history to ≤1000 tokens and restart the
coordinator. This is not optional.

The gate **cannot be bypassed.** If you find yourself wanting to skip
`critic` or `reviewer`, that is the signal that something is wrong with
the change, not with the gate.
