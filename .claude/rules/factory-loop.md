# Factory-Loop Rule

This rule is the authoritative operating procedure for the coordinator running
as a continuous autonomous factory: it works the roadmap milestone-by-milestone,
spawning implementer teams, gating every PR, and merging — with no per-step human
checkpoints. The prior failure mode that this rule exists to correct is a
**discretionary, half-run gate**: the coordinator chose whether and when to run
each gate half and routinely completed only the reviewer half before handing
work back. Under continuous operation the gate is not optional and not partial.

This rule **inherits and does not override**:

- `worktree-discipline.md` — every spawn obeys the parent-on-`main` invariant,
  `isolation: worktree`, and same-turn worktree cleanup.
- The spawn-brief-integrity additions (#206/#207) — implementer spawn briefs are
  delivered intact and unaltered.
- `spec-before-code.md` — coordination-heavy components need a `docs/spec/SPEC-*.md`
  entry before an implementation PR; in-scope PRs name their `AC-N` / `D-xxx`.
- `otp-non-negotiables.md` — the runtime correctness invariants.

Where this rule and an inherited rule appear to conflict, the inherited rule
wins; this rule only sequences and gates work, it does not relax any other rule.

## The factory cycle

One **factory step** delivers one roadmap item end-to-end. Execute the steps in
order; do not reorder, skip, or batch.

1. **Select the next roadmap item.** Walk GitHub milestones in order — M0 first,
   then M1, and so on. Within the earliest milestone that has open work, pick an
   open issue (prefer the smallest shippable unit, and issues that unblock
   others). If the milestone has a clear next deliverable but no issue for it,
   file one first per `tau-github-workflow`.
2. **Ensure a GitHub issue exists.** Every factory step is anchored to exactly
   one issue. If you filed it in step 1, it already exists; otherwise confirm
   the chosen issue is open and correctly milestoned.
3. **Branch off fresh `main`.** Run `git fetch origin`, confirm the parent repo
   is on `main` at `origin/main` (per `worktree-discipline.md`), then derive the
   feature branch from that fresh `main`. Never branch off stale state.
4. **Spawn the implementer team.** Spawn one or more `implementer` agents, each
   with `isolation: worktree`, briefed per the spawn-brief-integrity additions.
   The work targets the issue's scope only; if a `docs/spec/SPEC-*.md` is in
   scope, `spec-before-code.md` applies and is satisfied within the same PR set.
5. **Run the FULL gate.** When implementer work is committed and the merge state
   is stable, run BOTH gate halves on the **actual PR diff** — see "The gate"
   below. This is a single mandatory action, not two discretionary ones.
6. **Outcome.** Green (both halves PASS) → merge. Red (either half FAIL) →
   refine/pivot/escalate per "Outcomes" below.
7. **On green: re-check freshness, merge, then verify `main` health.**
   a. **Pre-merge freshness re-check.** Immediately before merging, re-fetch
      `origin/main` (`git fetch origin`). The gate ran against a diff anchored
      at some `origin/main` commit; if `origin/main` has advanced since then,
      the gate-green verdict no longer covers what would actually land. In that
      case the branch MUST be rebased onto current `origin/main` and the FULL
      gate — BOTH `critic` and `reviewer` — MUST be re-run on the rebased diff
      (see "The gate"). Only a gate-green diff that is current with
      `origin/main` may merge. If `origin/main` is unchanged since the gate
      ran, proceed directly to (b).
   b. **Merge.** Merge the PR with the explicit command
      `gh pr merge <n> --merge --delete-branch`.
   c. **Sync local `main`.** Immediately in the same turn, sync local `main`
      (`git fetch origin && git checkout main && git pull --ff-only origin
      main`) and remove finished agent worktrees per `worktree-discipline.md`.
   d. **Post-merge `main` health check.** Run a full health check on the
      synced `main`: `mix compile --warnings-as-errors` and `mix test`. The
      per-PR gate is stateless and cannot catch a subtly-wrong-but-gate-passing
      change accumulating across many cycles; this check is the standing
      backstop. If `main` is red (failing compile or tests), the loop HALTS and
      surfaces to the user — see "Stop / escalate conditions".
8. **Next item.** Return to step 1. Do not pause for human input between steps.

## The gate

The gate is **mandatory and complete**. Every PR — without exception — MUST pass
BOTH `critic` and `reviewer` on the actual PR diff before it is merged.

- **No skipping either half.** Running only `reviewer` (or only `critic`) is not
  a gate; it is a gate bypass.
- **No override.** The coordinator may not declare a PR mergeable on its own
  judgement when a gate half has not returned PASS.
- **No partial gate.** Both halves run against the same final PR diff, not a
  draft, not an earlier revision.
- **No "promote later".** A PR is merged only after the gate is green now; there
  is no deferred-gate or merge-then-review path.
- **No stale-diff merge.** A gate-green verdict covers only the diff it ran
  against. If `origin/main` advances between the gate passing and the merge,
  the verdict is void: the branch is rebased onto current `origin/main` and the
  FULL gate is re-run on the rebased diff before merge (cycle step 7a).

`/pr` runs the gate and opens the PR; the factory cycle adds the
freshness-recheck, merge-on-green, and post-merge health-check steps (step 7).
Both verdicts are recorded in the solution tree, and a re-run gate replaces the
prior verdicts for that PR.

## Outcomes

- **Green** — both `critic` and `reviewer` return PASS on the PR diff. Merge to
  `main` (cycle step 7) and continue to the next item.
- **Red** — either half returns FAIL. Do not merge. Load the `retry-strategy`
  skill and **refine**: address the named gate findings and re-run the FULL gate
  on the updated diff. Refinement is bounded to **N = 3** attempts on one item.
- **After N failed refine attempts** — switch from refine to **pivot** per
  `retry-strategy`: choose a materially different approach to the same issue and
  restart the attempt count for the new approach.
- **If a pivot also fails to reach green within its bound** — **escalate**
  (see "Stop / escalate conditions").

### Reconciling N = 3 with the harness meta-restart

Two mechanisms key off the number 3 and must not be conflated. The
factory-loop refine bound (N = 3 refine attempts, then pivot, then escalate) is
a **product-level** policy: it governs how many times one roadmap item may be
reworked before the loop changes strategy or halts. The harness's
3-consecutive-failure rule (`CLAUDE.md` Hard Rules; `retry-strategy` §4
"Meta-Restart Protocol") is a **context-hygiene** mechanism: after three failed
attempts it compresses attempt history to ≤ 1000 tokens, clears the working
context, and restarts the coordinator from the archived solution-tree state.
The meta-restart changes *how the coordinator is run*; it does not change *what
the loop has decided*.

Precedence and interaction:

- The factory-loop safety circuit takes precedence over silent continuation.
  When the N = 3 refine budget is exhausted and a pivot has not reached green,
  the loop **escalates** — it HALTS and surfaces to the user (Stop / escalate
  condition 1). Escalation is a terminal state for that item; the harness
  meta-restart does NOT override it into another retry.
- A harness meta-restart is not a fourth attempt. If the meta-restart fires
  (e.g. mid-pivot, before the bound is reached), the coordinator resumes the
  factory loop **from the archived solution-tree state** — same item, same
  attempt count, same chosen strategy — rather than silently restarting the
  attempt count or re-attempting from scratch. The solution tree is the single
  source of truth across a meta-restart.
- If the meta-restart and the N = 3 escalation would fire on the same failure,
  the escalation wins: the loop halts and reports to the user. The compressed
  briefing the meta-restart would have produced is folded into the escalation
  report instead of seeding a fresh attempt.

## Stop / escalate conditions — the safety circuit

The loop MUST halt and surface to the user — it does not silently continue or
retry forever — on any of:

1. **N consecutive gate failures on one item** (N = 3). The bounded-refine
   budget for the item is exhausted and no pivot has reached green.
2. **An unresolvable merge conflict** — `main` has diverged in a way the
   coordinator cannot mechanically and safely reconcile.
3. **A destructive or irreversible action the gate cannot competently assess** —
   e.g. a force-push, history rewrite, data migration, or release that the
   `critic`/`reviewer` pair is not equipped to vet.
4. **Genuine spec or product ambiguity** — a decision that needs a human product
   judgement, not an engineering one. Do not guess; surface it.
5. **Budget exhaustion** — the loop's configured budget (time, token, or
   iteration) is spent.
6. **A red `main` after merge** — the post-merge health check (cycle step 7d)
   reports failing `mix compile --warnings-as-errors` or `mix test` on the
   synced `main`. The per-PR gate is stateless and cannot detect a
   subtly-wrong-but-gate-passing change that only surfaces once integrated;
   this condition is the standing backstop for that. The loop halts with
   `main` left in its current (red) state, the failing check named, so the
   user can decide whether to revert the offending merge or fix forward.

On any condition, write the reason and current state to the solution tree and
report to the user. Halting on a safety condition is correct behaviour, not a
failure.

## Reporting cadence

In normal operation there are **no human checkpoints**. The coordinator does not
ask for approval between factory steps. It reports to the user only:

- at **milestone boundaries** — when a milestone's issues are all closed and the
  loop advances to the next milestone; and
- on **escalation** — whenever a safety-circuit condition fires.

## Continuity and the kill switch

The factory loop is **driven by a recurring driver** — the `/loop` skill —
re-invoking the factory step on an interval so operation continues across idle
periods. The driver re-runs "execute one factory step" until stopped.

**Kill switch.** The user stops the loop by either:

- cancelling the `/loop` (or cron) job that drives re-invocation; or
- placing a sentinel file at `.claude/STOP-FACTORY` — the coordinator MUST check
  for this sentinel at the start of every factory step and, if present, finish
  no new work, report current state, and halt.

**Kill-switch latency.** State this plainly: the `.claude/STOP-FACTORY`
sentinel is checked only at the **start** of each factory step. Creating the
sentinel mid-step does not interrupt the step in progress — the current step
runs to completion, including its merge and post-merge sync, and the loop halts
before the NEXT step. The kill switch therefore has a worst-case latency of one
full factory step; it never aborts a step partway and never interrupts a
mid-merge. A halt from the kill switch is consequently clean: it stops between
factory steps, never mid-merge, and leaves `main` synced.

The sentinel is operator state, never project state: `.claude/STOP-FACTORY` is
listed in the repo's `.gitignore` so it can never be accidentally committed.

## What this rule forbids

- MUST NOT merge a PR before BOTH `critic` and `reviewer` have returned PASS on
  the actual PR diff.
- MUST NOT run only one gate half and treat the PR as gated.
- MUST NOT override a FAIL verdict or self-certify a PR as mergeable.
- MUST NOT defer the gate ("merge now, review later") or run it on a stale diff.
- MUST NOT merge a PR whose gate ran against an `origin/main` older than the
  current `origin/main`; the branch is rebased and the FULL gate re-run first.
- MUST NOT skip the post-merge `main` health check, nor continue the loop when
  that check reports a red `main`.
- MUST NOT exceed N = 3 refine attempts on one item without pivoting, nor
  continue past a pivot's failure without escalating.
- MUST NOT treat a harness meta-restart as a fresh attempt or as an override of
  an N = 3 escalation; resume from the archived solution-tree state.
- MUST NOT continue the loop through a safety-circuit condition; it MUST halt
  and surface to the user.
- MUST NOT insert per-step human checkpoints in normal operation, nor skip the
  milestone-boundary and escalation reports.
- MUST NOT branch off stale `main`, skip same-turn worktree cleanup, or
  otherwise relax `worktree-discipline.md`.
- MUST NOT proceed when `.claude/STOP-FACTORY` is present.

## When to update this rule

When the gate composition changes (a third gate half, a different pair),
update "The gate" and "What this rule forbids". When the roadmap structure
changes (milestones replaced by another ordering), update "The factory cycle"
step 1. When the driver mechanism changes (something other than `/loop`),
update "Continuity and the kill switch". When a new escalation pattern surfaces
that the safety circuit does not cover, add a condition rather than letting the
loop run through it.
