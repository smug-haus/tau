---
description: >
  Run the blocking critic+reviewer gate, then open a PR. Aborts if either
  gate fails. Both verdicts are recorded in the solution tree.
allowed-tools: Read, Bash(git diff *), Bash(git log *), Bash(git status), Bash(git branch *), Bash(gh pr view *), Bash(gh pr create *), Bash(gh issue view *), Bash(jq *), Bash(cat *), Bash(mkdir *), Bash(echo *), Bash(date *), Edit, Write, Task
---

Run the blocking PR gate. Both `critic` and `reviewer` MUST return
`{"ok": true}` before `gh pr create` is invoked. Either gate failing
appends a `failed_evaluation` attempt to the solution tree and aborts —
the coordinator then chooses **refine** or **pivot** per the standard
task lifecycle.

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

## Step 3 — Identify the linked issue

Scan commit messages for `Closes #N` / `Refs #N`. Read the issue body via
`gh issue view <N>` to recover the original spec. If no issue is linked,
**abort** — the `tau-github-workflow` rule requires every non-trivial
change to be issue-driven.

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

1. Append an attempt to `.claude/logs/solution-tree.json`:
   ```json
   {
     "attempt_id": <n>,
     "approach_summary": "<one-line summary of the diff>",
     "outcome": "failed_evaluation",
     "kill_reason": "critic_blocked: <reason from JSON>",
     "files_modified": [<list>]
   }
   ```
   Initialise the file with `{"task_id": "<branch-name>", "attempts": []}` if it does not exist.
2. Print the full reason to the user.
3. **Abort.** Do not proceed to step 6; do not run `gh pr create`.

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

Same as step 5, but with `kill_reason: "reviewer_blocked: <reason>"`.

## Step 8 — Both passed

Append to the solution tree with `outcome: "pr_gates_passed"` and the
two verdicts. Compose the PR body:

```
## Summary
<derived from commits>

## Linked issues
Closes #N

## Gate verdicts
- critic: PASS (`ok: true`) — <one-line summary from critic's structured findings, if any>
- reviewer: PASS (`verdict: PASS`) — <one-line summary from reviewer's structured verdict, if any>

## Test plan
<derived from the implementer's reported smoke test, if any>
```

Run `gh pr create --title "<title>" --body-file <tmpfile>` (use a
heredoc-equivalent). Append the resulting PR URL to the solution tree.

## Recovery

`/pr` is idempotent across attempts — every invocation appends a new
attempt to the solution tree. After **3 consecutive** veto-failures on
the same task, the harness's mandatory meta-restart kicks in: compress
all attempt history to ≤1000 tokens and restart the coordinator. This is
not optional.

The gate **cannot be bypassed.** If you find yourself wanting to skip
`critic` or `reviewer`, that is the signal that something is wrong with
the change, not with the gate.
