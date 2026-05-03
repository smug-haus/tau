---
description: >
  Run the blocking critic+reviewer gate, then open a PR. Aborts if either
  gate fails. Both verdicts are recorded in the solution tree.
allowed-tools: Read, Bash(git diff *), Bash(git log *), Bash(git status), Bash(git branch *), Bash(gh pr view *), Bash(gh pr create *), Bash(gh issue view *), Bash(jq *), Bash(cat *), Bash(mkdir *), Bash(echo *), Bash(date *), Edit, Write
---

Run the blocking PR gate. Both `critic` and `reviewer` MUST return
`{"ok": true}` before `gh pr create` is invoked. Either gate failing
appends a `failed_evaluation` attempt to the solution tree and aborts —
the coordinator then chooses **refine** or **pivot** per the standard
task lifecycle.

Steps in order — **do not skip**.

## Step 1 — Compute the diff

Determine the base branch (default `main`):

```sh
git diff main...HEAD
git log main..HEAD --oneline
```

Fail loudly if `HEAD` has no commits ahead of `main`.

## Step 2 — Identify the linked issue

Scan commit messages for `Closes #N` / `Refs #N`. Read the issue body via
`gh issue view <N>` to recover the original spec. If no issue is linked,
**abort** — the `tau-github-workflow` rule requires every non-trivial
change to be issue-driven.

## Step 3 — Spawn `critic` (design veto)

Use the Task tool with `subagent_type: "critic"`. Brief:

> Review the diff against `main` for coordination-correctness violations.
> Read `.claude/rules/otp-non-negotiables.md`. Apply the PSDH triage
> checklist via the `design-reasoning` skill. The last line of your
> response must be exactly `{"ok": true}` or
> `{"ok": false, "reason": "..."}`.
>
> Diff: <full output of `git diff main...HEAD`>
> Linked issue: #N — <title from `gh issue view`>
> Files changed: <list>

Parse the JSON verdict from the agent's last line.

## Step 4 — On `critic` veto

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
3. **Abort.** Do not proceed to step 5; do not run `gh pr create`.

## Step 5 — Spawn `reviewer` (quality veto)

Use the Task tool with `subagent_type: "reviewer"`. Brief:

> Run `mix test`, `mix format --check-formatted`, `mix credo --strict`
> against the working tree. Inspect the diff for silent failures,
> hardcoded values, missing `@spec`, missing telemetry on user-visible
> operations, missing property tests on invariant-bearing modules. The
> last line of your response must be exactly `{"ok": true}` or
> `{"ok": false, "reason": "..."}`.
>
> Diff: <full output of `git diff main...HEAD`>
> Linked issue: #N — <title>
> Original spec excerpt: <issue body>

Parse the JSON verdict.

## Step 6 — On `reviewer` veto

Same as step 4, but with `kill_reason: "reviewer_blocked: <reason>"`.

## Step 7 — Both passed

Append to the solution tree with `outcome: "pr_gates_passed"` and the
two verdicts. Compose the PR body:

```
## Summary
<derived from commits>

## Linked issues
Closes #N

## Gate verdicts
- critic: PASS — <one-line summary if any>
- reviewer: PASS — <one-line summary if any>

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
