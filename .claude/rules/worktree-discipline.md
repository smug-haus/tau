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

**Capture-before-destroy.** Before removing a worktree that may hold uncommitted work — in particular before removing the worktree of an agent that was killed mid-run — capture its diff and status to a stable location, so the work can be inspected or replayed. The minimum sequence:

```sh
git -C <worktree> status --short > /tmp/wip-<agentId>.status
git -C <worktree> diff > /tmp/wip-<agentId>.patch
git worktree remove -f -f <worktree>
```

`git worktree remove -f -f` destroys uncommitted changes silently. A killed agent has often done substantial work (reads, decisions, in-progress edits) that lives only in the worktree's working tree; destroying it without capture is irrecoverable token spend. The capture is unconditional whenever the worktree may have changes — it is cheap and benign if the worktree is clean.

**Shared $HOME-namespace caches MUST be isolated per concurrent agent.** Several build/runtime caches live in the spawning user's `$HOME`, NOT inside the worktree. They survive worktree isolation. Concurrent agents that touch the same cache will race. The canonical offender today is **Burrito's unpack cache at `~/.local/share/.burrito/<tau_erts-version>/`** — two concurrent `mix tau.smoke` invocations from different worktrees collide there and produce intermittent `XZ/LZMA Decode Failed` errors at binary startup.

The fix is to isolate per agent. For Burrito specifically, set `XDG_DATA_HOME=<worktree>/.xdg-data` for every `mix release` and `mix tau.smoke` invocation in the agent's brief. Apply the same pattern to any other cache that lives outside the worktree (zig's `~/.cache/zig/` is content-addressable and benign; if a new cache surfaces and is not content-addressable, add it to the per-agent isolation list).

When briefing concurrent agents that will both build the Burrito binary, this isolation is MANDATORY, not optional.

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
- MUST NOT remove a worktree with `git worktree remove -f -f` without first capturing `git diff` and `git status` to a stable path. Destroying an in-progress agent's uncommitted work without capture is irrecoverable token spend.
- MUST NOT spawn concurrent agents that will both invoke `mix tau.smoke` or `mix release tau ...` without giving each agent a per-worktree `XDG_DATA_HOME` override in its brief. Shared `~/.local/share/.burrito/` cache races silently corrupt the smoke.

## Recovering from a stale parent

When the invariants have already been violated (untracked file leak, parent on a feature branch, locked finished worktrees blocking main):

1. Inventory: `git worktree list` to see all worktrees.
2. Identify the currently-running agents' worktrees by their reported `agentId`. Those MUST be preserved.
3. Remove all other (finished) agent worktrees: `for w in <ids>; do git worktree remove -f -f <path>; done`.
4. Clean any leaked untracked files in the parent: `diff -q` against `origin/main` to confirm they are byte-identical leaks, then `rm` them.
5. `git checkout main && git pull --ff-only origin main`.
6. `git branch | grep -v 'main\|<active-agent-branches>' | xargs -n1 git branch -D` to clear orphan local branches.
7. Verify final state: parent on main at origin/main; no untracked files; only currently-running agents' worktrees registered.

## Spawn-brief integrity

A spawn brief is an instruction set, not a trustworthy report of the worktree's git state. `isolation: worktree` always forks the new worktree from `main` — never from the spawning agent's current branch. A brief that asserts "you are forked from `feat/X`" or "you are at commit `<sha>`" is therefore unreliable and MUST NOT be relied upon.

- A spawn brief MUST NOT assert a fork-point or a "you are at commit/branch X" claim as fact. State the *task* (e.g. "review the changes on `feat/X`"); do not state the *position*.
- Every agent verifies its own position before doing any work — `pwd`, `git rev-parse HEAD`, `git branch --show-current` — and aborts if it finds itself in the parent repo root rather than an isolated worktree. The `implementer` and `reviewer` personas encode this as their first process step.
- An agent that must operate on a specific branch fetches and checks it out explicitly inside its worktree; it does not assume the spawn placed it there.
- PR branches are rebased onto current `origin/main` before the critic/reviewer gate runs, so `git diff main...HEAD` reflects only the PR's own changes. The `/pr` flow enforces this as a precondition.

## When to update this rule

When a new collision pattern surfaces that this rule does not cover, add an invariant. When `isolation: worktree` semantics change (e.g. Claude Code starts auto-syncing fork-points to origin/main), revise the parent-on-main invariant. When the spawn protocol changes such that one of these invariants becomes vacuous, document the change rather than silently dropping the invariant.
