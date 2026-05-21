# Factory-Loop Rule

This rule is the authoritative operating procedure for the coordinator running
as a continuous autonomous factory: it spawns implementer teams, gates every PR,
and merges — with no per-step human checkpoints. The prior failure mode that
this rule exists to correct is a **discretionary, half-run gate**: the
coordinator chose whether and when to run each gate half and routinely completed
only the reviewer half before handing work back. Under continuous operation the
gate is not optional and not partial.

## Using this document

Read this document once at the start of a factory run; it then lives in the
coordinator's context. Do **not** reread it mid-run. The urge to reread is a
signal of context pollution — and pollution is itself the cue to **compact or
clear**, after which this document is read fresh as part of the reset. Reread
only on a deliberate reset, never as a mid-run reflex.

## The objective — complete the assigned milestone

The factory loop has no hardcoded objective. Its job is to drive the
**currently assigned milestone** to completion: take each open issue in that
milestone from open to a gate-passed, merged PR, and continue — with no
per-step human checkpoints — until the milestone has zero open issues. Unless
the user directs otherwise, a running loop is a loop completing its assigned
milestone.

**The assigned milestone** is whichever milestone the user named for the
current run. If no milestone has been assigned, the loop does not guess — it
asks the user which milestone to work, then proceeds.

**Finding the work.** Milestones and their issues live in GitHub, which is the
source of truth:

- `gh api repos/<owner>/<repo>/milestones --jq '.[] | "\(.number) \(.title) — open:\(.open_issues) closed:\(.closed_issues)"'`
  — list milestones with their open/closed issue counts.
- `gh issue list --milestone "<title>" --state open` — the assigned milestone's
  remaining open issues.

**Tracking progress.** `.claude/logs/solution-tree.json` records every factory
step and its outcome for the current run. The assigned milestone's **open-issue
count** is the completion signal — the milestone is done when it reaches zero
open issues. Reconcile the solution tree against `gh issue list --milestone` so
no step is lost or double-counted.

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

**The PR is the atomic unit of the factory.** One factory step opens, drives,
and merges exactly one PR. The gate, the N = 3 refine bound, incomplete-fix
detection, and revert all operate on **the PR**.

A PR closes one or more GitHub issues and is sized as **one coherent shippable
increment** — the coordinator groups issues that cohere (same area / SPEC /
feature; ship-and-revert as one unit). There is no lower bound: one issue per
PR is fine and common. Take issues as filed — by humans or agents, at whatever
granularity — and never reshape, split, or defer them; the only issue-management
action is to *file* a missing prerequisite issue (`tau-github-workflow`).

Two guards bound PR scope — against opportunistic scope-growth, not toward
forced coupling:

- **Declared, frozen scope.** The draft-PR body (cycle step 4) fixes the issue
  set and plan before any implementer is spawned; that set is frozen for the
  PR's life. Mid-flight scope growth becomes a separate PR or a deliberate,
  logged re-plan of the draft-PR body — never a silent add. The `critic` gate
  flags diff content outside the declared issue set as scope creep.
- **Gateability ceiling.** A PR MUST stay reviewable by `critic` and `reviewer`
  in a single pass. If grouping makes it too large to gate thoroughly, split.
  This is the upper bound — a practical cap, not a coupling test.

A factory step runs the lifecycle below for one PR, end-to-end. Execute the
steps in order *for that PR* — but the loop is not single-track: multiple
factory steps SHOULD run **concurrently** whenever the conflict check clears
them (see "Parallel execution"). Never merge an ungated or stale diff.

1. **Select the work.** From the assigned milestone's open issues
   (`gh issue list --milestone "<title>" --state open`), select the next PR's
   issue — or the smallest inseparable issue set. Prefer the smallest coherent
   shippable increment and work that unblocks others; follow any stated priority
   order (e.g. from a tracking issue). If a prerequisite has no issue, file one
   first per `tau-github-workflow`.
2. **Confirm the issue(s).** Every issue the PR will close is open and correctly
   milestoned.
3. **Branch off fresh `main`.** `git fetch origin`, confirm the parent repo is
   on `main` at `origin/main` (per `worktree-discipline.md`), derive the feature
   branch from that fresh `main`. Never branch off stale state.
4. **Open the draft PR — before any implementer is spawned.** Seed the branch
   with one empty commit (`git commit --allow-empty`), push it, and
   `gh pr create --draft` with the body set to the full work plan (see "The
   draft-PR body" below). The draft PR is the durable, visible plan-of-record
   and the single source of the implementer brief.
5. **Spawn the implementer team.** One or more `implementer` agents, each with
   `isolation: worktree`, each briefed to check out the existing feature branch
   and work from the draft PR body. Briefs obey spawn-brief integrity and
   shared-resource isolation. If a `docs/spec/SPEC-*.md` is in scope,
   `spec-before-code.md` applies and is satisfied within this PR.
6. **Run the FULL gate.** When implementer work is committed and the branch is
   stable, run BOTH gate halves — `critic` and `reviewer` — on the draft PR's
   actual diff. See "The gate". One mandatory action, not two discretionary ones.
7. **Outcome.** Green (both PASS) → step 8. Red (either FAIL) →
   refine/pivot/escalate per "Outcomes".
8. **On green: freshness re-check, mark ready, merge, verify `main`.**
   a. **Pre-merge freshness re-check.** Re-fetch `origin/main`. If it has
      advanced since the gate ran, the gate-green verdict no longer covers what
      would land: rebase the branch onto current `origin/main` and re-run the
      FULL gate on the rebased diff. Only a gate-green diff current with
      `origin/main` may merge.
   b. **Mark ready and merge.** `gh pr ready <n>` to take the PR out of draft,
      then `gh pr merge <n> --merge --delete-branch`.
   c. **Sync local `main`.** In the same turn: `git fetch origin && git checkout
      main && git pull --ff-only origin main`; remove finished worktrees per
      `worktree-discipline.md`.
   d. **Post-merge `main` health check.** `mix compile --warnings-as-errors`
      and `mix test` on the synced `main`. The per-PR gate is stateless and
      cannot catch a subtly-wrong-but-gate-passing change accumulating across
      cycles; this is the standing backstop. A red `main` HALTS the loop — see
      "Stop / escalate conditions".
9. **Next PR.** Return to step 1. Do not pause for human input between steps.

### The draft-PR body

The draft PR body is the plan-of-record and the implementer brief — one source,
no brief/PR drift. It MUST state:

- **Closes** — the issue(s) this PR closes, in the order the work addresses
  them (`Closes #N`).
- **Scope & order** — the ordered breakdown of the work: the sub-steps / commits
  planned and their sequence.
- **Dependencies** — issues or PRs this is blocked-by or blocks.
- **SPECs** — every `docs/spec/SPEC-*.md` in scope, and whether this PR authors,
  amends, or merely conforms to each; the `AC-N` / `D-NNN` it advances.
- **Gate verdicts** — a section filled in at gate time (`critic`, `reviewer`).

A **refine** stays on the same draft PR. A **pivot** (materially different
approach) closes the draft PR and opens a fresh one.

## Parallel execution

The loop SHOULD maximise parallel work. Running issues one at a time is the
fallback for genuinely conflicting work — **not** the default. Before spawning a
step, run a **conflict check** against every step already in flight, and spawn
concurrently every step that clears it. Leaving safe parallelism unused is a
throughput failure the loop is required to avoid.

### The conflict check

Two (or more) issues may be worked concurrently only if ALL of these hold:

1. **No dependency.** Neither issue is blocked by the other. Sources: the issue
   body, its elaboration/critique comments ("depends on #X", "blocked by #Y"),
   and any sequencing note in the milestone's tracking issue.
2. **Disjoint files.** Their expected changed-file sets do not overlap — derive
   the sets from the issues' elaborations and the relevant `docs/spec/SPEC-*.md`
   Appendix-B source-maps; grep the cited modules when unsure.
3. **Disjoint codepoints.** They do not modify the same function. Elaboration
   briefs cite `file:line` — use them. The same file touched at clearly
   separate, stable regions MAY still parallelise, but the burden of proof is on
   the check; when in doubt, serialize.
4. **No shared SPEC or D-NNN block.** They do not both author or amend the same
   `docs/spec/SPEC-*.md`, nor draw new invariants from the same D-NNN block. Two
   steps authoring the same SPEC are always serialized.
5. **Shared-resource isolation is possible.** Any non-worktree resource both
   will touch (Burrito unpack cache, other `$HOME`-namespace caches) is
   isolatable per "Pre-spawn shared-resource isolation". If it cannot be
   isolated, serialize.

A set of issues that clears all five is a **parallel batch**: spawn its
implementers together, each `isolation: worktree`, each briefed per spawn-brief
integrity and shared-resource isolation.

### Gate and merge under concurrency

Concurrency applies to **implementation**. The gate and merge stay strict:

- Each PR's FULL gate runs against its own stable diff, after that PR's
  implementer has committed — never against a branch still being written
  (`worktree-discipline.md`).
- **Merges are serialized** — one PR at a time. After each merge, every other
  in-flight branch is behind `origin/main`: the freshness re-check (cycle step
  7a) fires for it — rebase onto current `origin/main` and re-run the FULL gate
  before that branch merges. Parallelism makes 7a fire more often; that is
  expected, not a reason to skip it.
- The post-merge `main` health check (step 7d) runs serially after every merge.
- The N = 3 refine bound and the safety circuit remain **per issue**.

### When to serialize

Serialize when the conflict check fails on any clause; when a step authors a
SPEC that a later step depends on (write → gate → merge the SPEC first, per
`spec-before-code.md`); or when the in-flight count would exceed what the
coordinator can gate and freshness-manage without losing track. Correctness and
the gate always win over throughput.

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

`/pr` runs the gate against the step's **existing draft PR** (the draft is
opened at cycle step 4, before the implementer is spawned — `/pr` does not
create it). On green the factory cycle marks the PR ready and adds the
freshness-recheck, merge, and post-merge health-check steps (step 8). Both
verdicts are recorded in the solution tree and in the PR body's gate-verdicts
section; a re-run gate replaces the prior verdicts for that PR.

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

## Coordinator discipline — substance over ceremony

The factory cycle is form. Substance is "does the user-visible thing actually work?" These rules exist because the cycle has been completed multiple times in this project on PRs whose user-visible outcome was still broken. The pattern: each fix follows the form (file issue → spawn agent → gate → merge), then the coordinator moves to the next without verifying the substance, and a "follow-up" issue is filed when substance fails to surface. That displaces the gate's responsibility onto the user. These rules forbid that pattern.

### Incomplete-fix detection (don't move to follow-up)

A critic/reviewer finding is "out of scope" only if it does NOT falsify any **acceptance criterion (AC-N) or D-NNN invariant** named in any issue the PR closes, or their linked SPECs. Otherwise the merge is **incomplete**: reopen the affected issue, do NOT merge, refine.

The test is mechanical, not editorial:

- List the AC-N entries the issue claims to advance (from the issue body and from the SPEC entries it links).
- For each, ask: does the finding describe a state that falsifies this AC? If yes for any AC, the finding is in scope of the issue's headline and the merge is incomplete.
- Only if every named AC remains true after the finding is the finding a follow-up.

Concrete example: an issue says "AC: `tau run --system-prompt-file <persona>` honours the persona's `allowed-tools:` whitelist." The critic flags "the headless path drops the frontmatter, so all builtins are exposed regardless of the file." That finding **falsifies the AC**. The fix is incomplete; reopen.

Tests must exercise the same code path the user invokes (e.g. `Tau.CLI.main(["run", ...])` with realistic argv), not a hand-built struct that bypasses the parser the CLI invocation triggers. A gate that passes a test which short-circuits the user-facing path is a false positive.

"Follow-up issue" is reserved for findings that are **outside every named AC's scope**, not for findings that falsify one.

A critic finding of severity `info` or `suggestion` does NOT lower this bar. AC falsification is the criterion, not severity.

### Reporting precision

When reporting work to the user:

- **Cite the source for numbers.** Token counts come from the task notification's `total_tokens` field (or `usage.total_tokens` on the agent's result). Wall times from the notification's `duration_ms`. Do not estimate; do not round in your own favor.
- **Do not call anything "working" without naming the exact command and the observable signal.** "Boots and runs a replay smoke" is a true and bounded statement; "works" is not, when the user-visible path the issue was about hasn't been exercised. Use the bounded statement.
- **Bounded "exact stdout."** Verbatim: the exit code AND the line(s) carrying the user-visible signal (e.g. the expected smoke token, the failing assertion, the line containing the asserted-on string). Elision is permitted for surrounding output, marked with `[...elided N lines...]`. The point is to prove the signal was observed, not to paste thousand-line transcripts.
- **Distinguish "the form ran clean" from "the substance landed."** "Gate green, merged" is the form. "User can run `<exact command>` and observe `<exact signal>`" is the substance.

### Pre-spawn shared-resource isolation

Before spawning a concurrent agent, identify every shared mutable resource it will touch outside its worktree — and isolate it in the agent's brief. Worktrees give per-agent **git** isolation. They do NOT isolate:

- the spawning user's `$HOME` (and everything under it: `~/.local/share/.burrito/`, `~/.cache/zig/`, `~/.mix/`, `~/.tau/`, `~/.config/...`);
- system-wide processes (long-running daemons, lockfiles);
- third-party caches accessed through the network (Hex mirror, GitHub release downloads).

For `mix tau.smoke` / `mix release tau ...`: set `XDG_DATA_HOME=<worktree>/.xdg-data` in every brief that may run concurrently with another agent doing the same. See `worktree-discipline.md` for the canonical list and the rule that forbids skipping this isolation when concurrent.

If a new shared-resource collision pattern surfaces, add it to `worktree-discipline.md` before continuing.

### Capture before destroy

When killing an agent (via TaskStop), the worktree's working tree may contain uncommitted work that represents non-trivial token spend. Before `git worktree remove -f -f` against the killed agent's worktree, run the capture sequence from `worktree-discipline.md`. This is unconditional: the cost of capturing on a clean worktree is zero; the cost of destroying a dirty one is everything the agent had done.

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

- at **milestone boundaries** — when the assigned milestone's issues are all
  closed; the loop reports completion and awaits the next milestone assignment
  (it does not auto-advance to another milestone unless told to); and
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
- MUST NOT run two factory steps concurrently unless the conflict check clears
  all five clauses; MUST NOT default to one-issue-at-a-time when the conflict
  check would clear a parallel batch.
- MUST NOT merge two PRs concurrently — merges are serialized, each followed by
  a freshness re-check (and rebase + full re-gate where needed) of every other
  in-flight branch.
- MUST NOT spawn an implementer before the step's draft PR is open — the draft
  PR body is the implementer brief and the plan-of-record.
- MUST NOT grow a PR beyond the issue set declared in its draft-PR body —
  mid-flight scope growth is a separate PR or a logged re-plan, never a silent
  add.
- MUST NOT reshape, split, or defer a filed issue to fit PR sizing; take issues
  as filed and decide grouping at PR-selection time.
- MUST NOT proceed when `.claude/STOP-FACTORY` is present.
- MUST NOT treat a critic/reviewer finding that names the linked issue's headline as a "follow-up." Reopen the issue, fix the headline, re-gate. "Follow-up" is for out-of-scope findings only.
- MUST NOT report work as "working" or "done" without naming the exact command run and the observable signal (exit code + signal line, with surrounding output optionally elided as `[...elided N lines...]`) against the user-visible path the issue named.
- MUST NOT cite token or wall-time numbers without sourcing them from the task notification's `total_tokens` / `duration_ms` (or equivalent). No estimating, no rounding in the coordinator's favor.
- MUST NOT spawn concurrent agents that touch the same $HOME-namespace cache (Burrito unpack, etc.) without per-agent isolation in their brief. See `worktree-discipline.md`.
- MUST NOT `git worktree remove -f -f` an agent's worktree without first running the full capture sequence — staged+unstaged (`git diff HEAD`), untracked (`ls-files --others --exclude-standard | tar`), and status. The canonical recipe is in `worktree-discipline.md`. Naïve `git diff` (no `HEAD`) silently omits staged changes; omitting the untracked tarball silently omits new files.

## When to update this rule

When the gate composition changes (a third gate half, a different pair),
update "The gate" and "What this rule forbids". When the roadmap structure
changes (milestones replaced by another ordering), update "The factory cycle"
step 1. When the driver mechanism changes (something other than `/loop`),
update "Continuity and the kill switch". When the parallelism model changes (the
conflict-check clauses, or how concurrent merges are sequenced), update "Parallel
execution". When a new escalation pattern surfaces that the safety circuit does
not cover, add a condition rather than letting the loop run through it.
