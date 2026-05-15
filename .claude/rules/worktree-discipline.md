---
description: Mandatory invariants for spawning agents in isolated git worktrees
---

# Worktree Discipline

Parallel agents driving Elixir builds, gh CLI operations, and git checkouts share a single repository's working tree by default. Without strict isolation discipline, concurrent agents corrupt each other's state: reviewer A's `gh pr checkout` mutates the parent's HEAD while implementer B is mid-write; main ref drifts behind origin; subsequent worktree spawns fork from stale state and never see merged work; locked finished worktrees accumulate and block future checkouts. **Every one of these has happened in this project.** Apply these rules without exception.

## Mandatory invariants

**The parent repo's HEAD is always on `main`, and `main` is always at `origin/main`.** Before every Agent spawn, verify: `git fetch origin && git rev-parse main` must equal `git rev-parse origin/main`, and the parent must be checked out to `main`. If not, fix before spawn. Never spawn an isolated-worktree agent on top of a stale parent — the worktree will inherit the staleness.

**`isolation: worktree` is non-negotiable for every agent that reads or writes files.** This includes implementers, reviewers, fix-up agents, and exploration agents that need to run `mix test` or `gh pr checkout`. The only agents that may run without it are pure-conversation agents with no file or shell tool access. Reviewers without `isolation: worktree` are the dominant cause of mid-task collisions.

**Never `gh pr checkout` or `git checkout <feature-branch>` on the parent repo.** If you need to inspect a PR locally, use `git worktree add <throwaway-path> <branch>` and clean up after. The parent's HEAD belongs to `main` only.

**After every PR merge: sync local main immediately, in the same turn.** Run `git fetch origin && git checkout main && git pull --ff-only origin main`. If the checkout is blocked because a locked worktree holds the `main` ref, remove the blocking worktree first (`git worktree remove -f -f <path>`) rather than forcing the ref via `git update-ref` — the worktree must go away before its branch hold can be released.

**After every agent completion: remove its worktree in the same turn.** `git worktree remove -f -f <path>` for the finished agent's worktree, then `git branch -D <its-spawn-branch>` if no longer referenced. Locked-finished worktrees accumulating is the symptom that hides every other failure mode in this rule.

## Pre-spawn checklist

Before every Agent invocation with `isolation: worktree`, mentally run:

1. Is the parent repo on `main`? (`git branch --show-current`)
2. Is local `main` at `origin/main`? (`git fetch origin && git rev-parse main`)
3. Are there leaked untracked files in the parent from prior reviewer collisions? (`git status --short` — empty means clean)
4. Are there active agent worktrees whose work the new agent might disturb? (`git worktree list` — note the locked ones)

If any answer is wrong, fix it before spawning. Cost of fixing is bounded; cost of an open-ended collision is not.

## What this rule forbids

- MUST NOT spawn a reviewer agent without `isolation: worktree`.
- MUST NOT `gh pr checkout` on the parent repo to "quickly look at" a PR. Use a throwaway worktree.
- MUST NOT use `git update-ref refs/heads/main origin/main` as a routine sync mechanism. That is a recovery move, not a sync move; if you need it, a stale-main bug already happened.
- MUST NOT leave finished agent worktrees registered. Remove them in the same turn the agent reports completion.
- MUST NOT spawn parallel reviewers before the implementers they review have committed and the merge state is stable. Reviewers running while implementers are mid-write is the failure mode this rule exists to prevent.

## Recovering from a stale parent

When the invariants have already been violated (untracked file leak, parent on a feature branch, locked finished worktrees blocking main):

1. Inventory: `git worktree list` to see all worktrees.
2. Identify the currently-running agents' worktrees by their reported `agentId`. Those MUST be preserved.
3. Remove all other (finished) agent worktrees: `for w in <ids>; do git worktree remove -f -f <path>; done`.
4. Clean any leaked untracked files in the parent: `diff -q` against `origin/main` to confirm they are byte-identical leaks, then `rm` them.
5. `git checkout main && git pull --ff-only origin main`.
6. `git branch | grep -v 'main\|<active-agent-branches>' | xargs -n1 git branch -D` to clear orphan local branches.
7. Verify final state: parent on main at origin/main; no untracked files; only currently-running agents' worktrees registered.

## When to update this rule

When a new collision pattern surfaces that this rule does not cover, add an invariant. When `isolation: worktree` semantics change (e.g. Claude Code starts auto-syncing fork-points to origin/main), revise the parent-on-main invariant. When the spawn protocol changes such that one of these invariants becomes vacuous, document the change rather than silently dropping the invariant.
