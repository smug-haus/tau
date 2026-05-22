# Factory-Loop Rule

The authoritative operating procedure for the coordinator running as a
continuous autonomous factory: it spawns implementer teams, gates every PR, and
merges — with no per-step human checkpoints. The gate is mandatory and complete;
it is never optional, partial, or deferred.

## Using this document

Read this document once at the start of a factory run; it then lives in the
coordinator's context. Do **not** reread it mid-run. The urge to reread is a
signal of context pollution — and pollution is itself the cue to **compact or
clear**, after which this document is read fresh as part of the reset. Reread
only on a deliberate reset, never as a mid-run reflex.

## Vocabulary

- **PR** — the atomic unit of the factory. One factory step opens, drives, and
  merges exactly one PR. The gate, the N = 3 refine bound, incomplete-fix
  detection, and revert all operate on the PR.
- **Issue** — a GitHub issue. A PR closes one or more issues.
- **Factory step** — one execution of the cycle below, for one PR.

## The objective — complete the assigned milestone

The factory loop has no hardcoded objective. Its job is to drive the **assigned
milestone** — the milestone the user named for the current run — to completion:
take each open issue in it from open to a gate-passed, merged PR, until the
milestone has zero open issues. If no milestone has been assigned, the loop does
not guess — it asks the user which milestone to work, then proceeds.

**Finding the work.** Milestones and issues live in GitHub, the source of truth:

- `gh api repos/<owner>/<repo>/milestones --jq '.[] | "\(.number) \(.title) — open:\(.open_issues) closed:\(.closed_issues)"'`
  — milestones with open/closed counts.
- `gh issue list --milestone "<title>" --state open` — the assigned milestone's
  remaining open issues.

**Tracking progress.** `.claude/logs/solution-tree.json` records every factory
step and its outcome. The assigned milestone's open-issue count is the
completion signal — done at zero. Reconcile the solution tree against
`gh issue list --milestone` so no step is lost or double-counted.

## Inherited rules

This rule **inherits and does not override**:

- `worktree-discipline.md` — parent-on-`main` invariant, `isolation: worktree`,
  same-turn worktree cleanup, spawn-brief integrity, and the capture-before-
  destroy sequence.
- `spec-before-code.md` — coordination-heavy components need a
  `docs/spec/SPEC-*.md` entry before an implementation PR; in-scope PRs name
  their `AC-N` / `D-NNN`.
- `otp-non-negotiables.md` — the runtime correctness invariants.

Where this rule and an inherited rule appear to conflict, the inherited rule
wins. This rule only sequences and gates work; it does not relax any other rule.

## The factory cycle

A factory step runs the lifecycle below for one PR, end-to-end. Execute the
steps in order *for that PR*. The loop is not single-track: the conflict check
(see "Parallel execution") may select a batch of PRs and run these steps for
them concurrently. Never merge an ungated or stale diff.

1. **Select the work.** From the assigned milestone's open issues
   (`gh issue list --milestone "<title>" --state open`), select the next PR's
   issue — or a coherent issue set (see "PR scope guards"). Prefer the smallest
   shippable increment and work that unblocks others; follow any stated priority
   order (e.g. from a tracking issue). If a prerequisite has no issue, file one
   first per `tau-github-workflow`. When other steps are in flight, run the
   conflict check (see "Parallel execution") and select a parallel batch where
   it clears.
2. **Confirm the issue(s).** Every issue the PR will close is open and correctly
   milestoned.
3. **Branch off fresh `main`.** `git fetch origin`, confirm the parent repo is
   on `main` at `origin/main`, derive the feature branch from that fresh `main`.
   Never branch off stale state.
4. **Open the draft PR — before any implementer is spawned.** Seed the branch
   with one empty commit (`git commit --allow-empty`), push it, and
   `gh pr create --draft` with the body set to the full work plan (see "The
   draft-PR body"). The draft PR is the durable plan-of-record and the single
   source of the implementer brief.
4b. **Spawn the test-author** (oracle-separation phase). Skipped for a PR that
    claims no `AC-N`/`D-NNN` (a typo fix, dep bump, or formatting-only PR —
    mirroring `spec-before-code.md`'s out-of-scope exemption). When the PR
    claims at least one `AC-N`/`D-NNN`:
    a. Spawn one `test-author` agent with `isolation: worktree`, briefed on the
       draft-PR body's `AC-N`/`D-NNN` set and the in-scope `SPEC-*.md` §4
       boundary contracts.
    b. The test-author writes one failing test per `AC-N`/`D-NNN` exercising
       the user-facing path, commits them, and reports the exact `test/...` file
       paths it owns.
    c. Update the draft-PR body's **Gating-test paths** section with those exact
       paths before spawning the implementer team. These paths (not commit
       attribution) define the test/production boundary all subsequent gates key
       on.
    d. If the test-author surfaces a **SPEC gap** (a §4 interface detail missing
       from the SPEC), land a §3 SPEC amendment in this PR via
       `spec-before-code.md`'s existing amendment path before re-spawning the
       test-author.
5. **Spawn the implementer team.** One or more `implementer` agents, each with
   `isolation: worktree`, each briefed to check out the existing feature branch
   and work from the draft PR body. Briefs obey spawn-brief integrity
   (`worktree-discipline.md`) and shared-resource isolation (see "Pre-spawn
   shared-resource isolation"). If a `docs/spec/SPEC-*.md` is in scope,
   `spec-before-code.md` is satisfied within this PR.
6. **Run the FULL gate.** When implementer work is committed and the branch is
   stable, run BOTH gate halves — `critic` and `reviewer` — on the draft PR's
   actual diff. See "The gate". One mandatory action, not two discretionary.
7. **Outcome.** Green (both PASS) → step 8. Red (either FAIL) →
   refine/pivot/escalate per "Outcomes".
8. **On green: freshness re-check, mark ready, merge, verify `main`.**
   a. **Pre-merge freshness re-check.** Re-fetch `origin/main`. If it has
      advanced since the gate ran, the gate-green verdict no longer covers what
      would land: rebase the branch onto current `origin/main` and re-run the
      FULL gate on the rebased diff. Only a gate-green diff current with
      `origin/main` may merge.
   b. **Mark ready and merge.** `gh pr ready <n>`, then
      `gh pr merge <n> --merge --delete-branch`.
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

- **Closes** — the issue(s) this PR closes, in work order (`Closes #N`).
- **Scope & order** — the ordered breakdown: sub-steps / commits and sequence.
- **Dependencies** — issues or PRs this is blocked-by or blocks.
- **SPECs** — every `docs/spec/SPEC-*.md` in scope, whether this PR authors,
  amends, or merely conforms to each, and the `AC-N` / `D-NNN` it advances.
- **Gating-test paths** — the exact `test/...` file paths the test-author owns
  for this PR (filled in at cycle step 4b; absent for PRs claiming no
  `AC-N`/`D-NNN`). This path set is the boundary the mechanical gates key on;
  it is frozen once declared and MAY NOT be changed without re-running the
  full gate.
- **Gate verdicts** — a section filled in at gate time (`critic`, `reviewer`).

A **refine** stays on the same draft PR. A **pivot** closes the draft PR and
opens a fresh one.

### PR scope guards

A PR is **one coherent shippable increment**: the coordinator may group issues
that cohere (same area / SPEC / feature; ship-and-revert as one unit). There is
no lower bound — one issue per PR is fine and common. Take issues as filed — by
humans or agents, at whatever granularity — and never reshape, split, or defer
them; the only issue-management action is to *file* a missing prerequisite issue.

Two guards bound PR scope — against opportunistic scope-growth, not toward
forced coupling:

- **Declared, frozen scope.** The draft-PR body fixes the issue set and plan
  before any implementer is spawned; that set is frozen for the PR's life.
  Mid-flight scope growth becomes a separate PR or a deliberate, logged re-plan
  of the draft-PR body — never a silent add. The `critic` gate flags diff
  content outside the declared issue set as scope creep.
- **Gateability ceiling.** A PR MUST stay reviewable by `critic` and `reviewer`
  in a single pass. If grouping makes it too large to gate thoroughly, split.

## Parallel execution

The loop SHOULD maximise parallel work. Running issues one at a time is the
fallback for genuinely conflicting work — not the default. Before spawning a
step, run the conflict check against every step already in flight, and spawn
concurrently every step that clears it.

### The conflict check

Two or more issues may be worked concurrently only if ALL of these hold:

1. **No dependency.** Neither is blocked by the other. Sources: the issue body,
   its elaboration/critique comments, and any sequencing note in the milestone's
   tracking issue.
2. **Disjoint files.** Their expected changed-file sets do not overlap — derive
   the sets from the issues' elaborations and the relevant `SPEC-*.md`
   Appendix-B source-maps; grep the cited modules when unsure. The changed-file
   set now also includes the **test-author's declared gating-test paths** (a new
   shared-`test/support` collision surface): two steps that would write to the
   same gating-test file or shared test-support module must serialize.
3. **Disjoint codepoints.** They do not modify the same function. Elaboration
   briefs cite `file:line` — use them. The same file touched at clearly
   separate, stable regions MAY still parallelise, but the burden of proof is on
   the check; when in doubt, serialize.
4. **No shared SPEC or D-NNN block.** They do not both author or amend the same
   `SPEC-*.md`, nor draw new invariants from the same D-NNN block. Two steps
   authoring the same SPEC are always serialized.
5. **Shared-resource isolation is possible.** Any non-worktree resource both
   will touch is isolatable per "Pre-spawn shared-resource isolation". If it
   cannot be isolated, serialize.

A set of issues that clears all five is a **parallel batch**: spawn its
implementers together, each `isolation: worktree`, each briefed per spawn-brief
integrity and shared-resource isolation.

### Gate and merge under concurrency

Concurrency applies to **implementation only**. The gate and merge stay strict:

- Each PR's FULL gate runs against its own stable diff, after that PR's
  implementer has committed — never against a branch still being written.
- **Merges are serialized** — one PR at a time. After each merge, every other
  in-flight branch is behind `origin/main`, so the freshness re-check (cycle
  step 8a) fires for it. Parallelism makes 8a fire more often; that is expected.
- The post-merge `main` health check (cycle step 8d) runs serially after every
  merge.
- The N = 3 refine bound and the safety circuit remain per PR.

### When to serialize

Serialize when the conflict check fails on any clause; when a step authors a
SPEC a later step depends on (write → gate → merge the SPEC first, per
`spec-before-code.md`); or when the in-flight count would exceed what the
coordinator can gate and freshness-manage without losing track. Correctness and
the gate always win over throughput.

### Pre-spawn shared-resource isolation

Before spawning a concurrent agent, identify every shared mutable resource it
will touch outside its worktree, and isolate it in the agent's brief. Worktrees
give per-agent **git** isolation only. They do NOT isolate:

- the spawning user's `$HOME` (`~/.local/share/.burrito/`, `~/.cache/zig/`,
  `~/.mix/`, `~/.tau/`, `~/.config/...`);
- system-wide processes (long-running daemons, lockfiles);
- network-accessed third-party caches (Hex mirror, GitHub release downloads).

For `mix tau.smoke` / `mix release tau ...`: set
`XDG_DATA_HOME=<worktree>/.xdg-data` in every brief that may run concurrently
with another agent doing the same. The canonical resource list and the rule
forbidding skipped isolation under concurrency live in `worktree-discipline.md`.
If a new shared-resource collision pattern surfaces, add it to
`worktree-discipline.md` before continuing.

## The gate

The gate is **mandatory and complete**. Every PR — without exception — MUST pass
BOTH `critic` and `reviewer` on the actual PR diff before it is merged.

- **No skipping either half.** Running only one half is a gate bypass.
- **No override.** The coordinator may not declare a PR mergeable on its own
  judgement when a gate half has not returned PASS.
- **No partial gate.** Both halves run against the same final PR diff, not a
  draft, not an earlier revision.
- **No "promote later".** A PR is merged only after the gate is green now; there
  is no deferred-gate or merge-then-review path.
- **No stale-diff merge.** A gate-green verdict covers only the diff it ran
  against. The freshness re-check (cycle step 8a) enforces this.

`/pr` runs the gate against the step's **existing draft PR** (opened at cycle
step 4 — `/pr` does not create it). On green the cycle marks the PR ready and
proceeds through step 8. Both verdicts are recorded in the solution tree and in
the PR body's gate-verdicts section; a re-run gate replaces the prior verdicts.

## Challenge protocol

An implementer may challenge a gating test — only if the test contradicts a
SPEC §4 contract, not merely because the test is hard to satisfy. The protocol:

1. The implementer STOPS and reports a **challenge** to the coordinator: names
   the test, the specific SPEC §4 clause it contradicts, and the contradiction.
   It MUST NOT edit the gating test.
2. The coordinator forwards the challenge to the `critic` (an independent
   read-only oracle — NOT the coordinator's own judgement).
3. The critic rules: **upheld** (the test contradicts the contract) or
   **rejected** (the implementer must comply with the test as written).
4. If upheld: the test-author corrects the test, the mutation check (gate 5.3)
   re-runs against the corrected test.
5. Every challenge is logged in the solution tree with the critic's verdict.
6. **More than 2 upheld challenges on one PR** is a safety-circuit escalation
   signal — the coordinator escalates (see "Stop / escalate conditions") rather
   than continuing. This indicates a weak test-author or an underspecified SPEC.

## The three mechanical gates

These gates are implemented as CI (PR-B / issue #370). `Tau.Factory.Gate`
provides the three pure functions; `mix tau.gate.ac_linkage`,
`mix tau.gate.masking`, and `mix tau.gate.mutation` are the CLI wrappers;
`.github/workflows/ci.yml` wires them into the `lint` and `mutation-check` jobs.

**Gate 5.1 — AC-to-test linkage.** Every `AC-N`/`D-NNN` the draft-PR body
claims MUST appear in a gating-test name or `@tag`. Verified by CI via
`mix tau.gate.ac_linkage` in the `lint` job (blocking).

**Gate 5.2 — Masking detection (detection-only).** The PR diff is scanned for
deleted or weakened assertions: any `-  assert` / `-  refute` line, or any
implementer edit to a declared gating-test path. There is **no self-authored
bypass tag** — every flagged deletion is surfaced to the `critic` as a mandatory
review item; the critic rules whether the deletion is legitimate or a weakening.
Path-based (uses the declared gating-test path set, not commit attribution).
Verified by CI via `mix tau.gate.masking` in the `lint` job (detection-only,
never hard-fails).

**Gate 5.3 — Mutation check (path-based).** Using the declared gating-test path
set: keep those paths at the test-author's committed state, revert every other
path to the PR's merge-base with `main` (`git merge-base origin/main HEAD`),
run the gating tests via `mix test`, and assert that ≥1 test fails. This
merge-base equals the conceptual "pre-implementer" state: the test-author
touches only the declared gating-test paths, which are snapshotted and
restored separately, so reverting "everything else" to the merge-base reverts
no test-author work. Path-based rather than commit-based so it survives
refine-cycle rebases. Verified by CI via `mix tau.gate.mutation` in the
dedicated `mutation-check` job (blocking).

### Residual — what these gates do NOT close

Oracle separation plus the mutation check (gate 5.3) closes the **vacuous test**
hole: a test that passes against absent or un-implemented code. It does NOT
mechanically catch an **under-asserting** test (e.g. checks `exit 0` but not
output) or a **wrong-path** test (exercises a hand-built struct rather than the
real entry point). Those remain covered only by the `critic`'s judgement (see
"Gating-test review" in `critic.md`). The three mechanical gates do not create
false confidence about under-asserting or wrong-path tests.

## Outcomes

- **Green** — both halves return PASS. Proceed to cycle step 8 (merge).
- **Red** — either half returns FAIL. Do not merge. Load the `retry-strategy`
  skill and **refine**: address the named gate findings, stay on the same draft
  PR, and re-run the FULL gate on the updated diff. Refinement is bounded to
  **N = 3** attempts per PR.
- **After N = 3 failed refines** — switch to **pivot** per `retry-strategy`:
  close the draft PR, choose a materially different approach to the same
  issue(s), open a fresh draft PR, and restart the attempt count for it.
- **If the pivot also fails to reach green within its bound** — **escalate**
  (see "Stop / escalate conditions").

### Incomplete-fix detection — do not deflect to a follow-up

A critic/reviewer finding is "out of scope" **only if** it does NOT falsify any
acceptance criterion (`AC-N`) or `D-NNN` invariant named in any issue the PR
closes, or in their linked SPECs. Otherwise the merge is **incomplete**: reopen
the affected issue, do NOT merge, refine.

The test is mechanical, not editorial:

- List the `AC-N` entries the issue claims to advance (from the issue body and
  its linked SPEC entries).
- For each, ask: does the finding describe a state that falsifies this AC? If
  yes for any AC, the finding is in scope of the issue's headline and the merge
  is incomplete.
- Only if every named AC remains true after the finding is it a follow-up.

Example: an issue's AC is "`tau run --system-prompt-file <persona>` honours the
persona's `allowed-tools:` whitelist." The critic flags "the headless path drops
the frontmatter, so all builtins are exposed regardless of the file." That
falsifies the AC — the fix is incomplete; reopen.

Tests MUST exercise the same code path the user invokes (e.g.
`Tau.CLI.main(["run", ...])` with realistic argv), not a hand-built struct that
bypasses the parser. A gate that passes a test short-circuiting the user-facing
path is a false positive.

A critic finding of severity `info` or `suggestion` does NOT lower this bar. AC
falsification is the criterion, not severity. "Follow-up issue" is reserved for
findings outside every named AC's scope.

### Reconciling N = 3 with the harness meta-restart

Two mechanisms key off the number 3 and must not be conflated:

- The **factory-loop refine bound** (N = 3 refines, then pivot, then escalate)
  is a *product-level* policy governing how many times one PR may be reworked.
- The **harness 3-consecutive-failure rule** (`CLAUDE.md` Hard Rules;
  `retry-strategy` §4) is a *context-hygiene* mechanism: after three failures it
  compresses attempt history to ≤ 1000 tokens, clears working context, and
  restarts the coordinator from the archived solution-tree state. It changes
  *how the coordinator is run*, not *what the loop has decided*.

Precedence:

- A meta-restart is **not** a fourth attempt. If it fires (e.g. mid-pivot), the
  coordinator resumes the factory loop from the archived solution-tree state —
  same PR, same attempt count, same chosen strategy. The solution tree is the
  single source of truth across a meta-restart.
- Escalation (N = 3 exhausted, pivot not green) is a terminal state for the PR.
  A meta-restart does NOT override it into another retry.
- If a meta-restart and an N = 3 escalation would fire on the same failure, the
  **escalation wins**: the loop halts and reports. The compressed briefing the
  meta-restart would have produced is folded into the escalation report.

## Stop / escalate conditions — the safety circuit

The loop MUST halt and surface to the user — never silently continue or retry
forever — on any of:

1. **N = 3 consecutive gate failures on one PR** and no pivot has reached green.
2. **An unresolvable merge conflict** — `main` has diverged in a way the
   coordinator cannot mechanically and safely reconcile.
3. **A destructive or irreversible action the gate cannot competently assess** —
   e.g. a force-push, history rewrite, data migration, or release the
   `critic`/`reviewer` pair is not equipped to vet.
4. **Genuine spec or product ambiguity** — a decision needing human product
   judgement, not an engineering one. Do not guess; surface it.
5. **Budget exhaustion** — the loop's configured time, token, or iteration
   budget is spent.
6. **A red `main` after merge** — the post-merge health check (cycle step 8d)
   reports failing `mix compile --warnings-as-errors` or `mix test`. The loop
   halts with `main` left red and the failing check named, so the user can
   decide whether to revert the offending merge or fix forward.
7. **More than 2 upheld implementer challenges on one PR** — indicates a weak
   test-author output or an underspecified SPEC. Escalate rather than continuing
   refine cycles; surface the challenge log to the user.

On any condition, write the reason and current state to the solution tree and
report to the user. Halting on a safety condition is correct behaviour.

## Reporting cadence

In normal operation there are **no human checkpoints** — the coordinator does
not ask for approval between factory steps. It reports to the user only:

- at **milestone boundaries** — when the assigned milestone's issues are all
  closed; the loop reports completion and awaits the next milestone assignment
  (it does not auto-advance unless told to); and
- on **escalation** — whenever any safety-circuit condition fires (including a
  red `main`).

## Coordinator discipline — substance over ceremony

The factory cycle is form. Substance is "does the user-visible thing actually
work?" Following the form (file issue → spawn → gate → merge) and then moving on
without verifying substance — filing a "follow-up" issue when substance fails to
surface — displaces the gate's responsibility onto the user. That pattern is
forbidden; incomplete-fix detection (above) is its mechanical guard.

When reporting work to the user:

- **Cite the source for numbers.** Token counts come from the task
  notification's `total_tokens` (or `usage.total_tokens` on the agent result);
  wall times from `duration_ms`. Do not estimate; do not round in your favor.
- **Do not call anything "working" without naming the exact command and the
  observable signal.** "Boots and runs a replay smoke" is a true, bounded
  statement; "works" is not, when the user-visible path the issue named has not
  been exercised.
- **Bounded "exact stdout."** Quote verbatim the exit code AND the line(s)
  carrying the user-visible signal. Surrounding output may be elided, marked
  `[...elided N lines...]`.
- **Distinguish form from substance.** "Gate green, merged" is the form. "User
  can run `<exact command>` and observe `<exact signal>`" is the substance.

## Continuity and the kill switch

The loop is **driven by a recurring driver** — the `/loop` skill — re-invoking
"execute one factory step" on an interval so operation continues across idle
periods, until stopped.

**Kill switch.** The user stops the loop by either:

- cancelling the `/loop` (or cron) job that drives re-invocation; or
- placing a sentinel file at `.claude/STOP-FACTORY`. The coordinator MUST check
  for this sentinel at the **start** of every factory step; if present, it does
  no new work, reports current state, and halts.

**Kill-switch latency.** The sentinel is checked only at the start of each step.
Creating it mid-step does not interrupt the step in progress — that step runs to
completion, including its merge and post-merge sync, and the loop halts before
the next step. Worst-case latency is one full factory step; the halt is clean —
between steps, never mid-merge, with `main` synced.

The sentinel is operator state, never project state: `.claude/STOP-FACTORY` is
in `.gitignore` so it can never be committed.

## What this rule forbids

A fast-scan index of the prohibitions established above; the body owns the
detail and rationale.

- MUST NOT merge a PR before BOTH `critic` and `reviewer` return PASS on the
  actual PR diff.
- MUST NOT run only one gate half, or override / self-certify a FAIL verdict.
- MUST NOT defer the gate, or run/merge against a stale diff (skip cycle 8a).
- MUST NOT skip the post-merge `main` health check, nor continue the loop on a
  red `main`.
- MUST NOT exceed N = 3 refine attempts on one PR without pivoting, nor continue
  past a failed pivot without escalating.
- MUST NOT treat a harness meta-restart as a fresh attempt or as an override of
  an N = 3 escalation; resume from the archived solution-tree state.
- MUST NOT continue the loop through a safety-circuit condition.
- MUST NOT insert per-step human checkpoints in normal operation, nor skip the
  milestone-boundary and escalation reports.
- MUST NOT branch off stale `main`, skip same-turn worktree cleanup, or
  otherwise relax `worktree-discipline.md` — including the capture-before-
  destroy sequence before any `git worktree remove -f -f`.
- MUST NOT run two factory steps concurrently unless the conflict check clears
  all five clauses; MUST NOT default to one-issue-at-a-time when it would clear
  a parallel batch.
- MUST NOT merge two PRs concurrently — merges are serialized.
- MUST NOT spawn concurrent agents touching the same `$HOME`-namespace cache
  without per-agent isolation in their brief.
- MUST NOT spawn an implementer before the step's draft PR is open.
- MUST NOT spawn an implementer before phase 4b is complete (or confirmed
  skipped) for a PR claiming `AC-N`/`D-NNN`.
- MUST NOT grow a PR beyond the issue set declared in its draft-PR body.
- MUST NOT reshape, split, or defer a filed issue to fit PR sizing.
- MUST NOT treat a finding that falsifies a named `AC-N` / `D-NNN` as a
  "follow-up"; reopen the issue, fix the headline, re-gate.
- MUST NOT report work as "working" / "done" without the exact command and
  observable signal against the user-visible path the issue named.
- MUST NOT cite token or wall-time numbers without sourcing them from the task
  notification (`total_tokens` / `duration_ms`).
- MUST NOT proceed when `.claude/STOP-FACTORY` is present.
- MUST NOT allow the implementer to edit a declared gating-test path; that is a
  challenge-protocol violation even if no deletion occurs.
- MUST NOT allow an implementer challenge to be adjudicated by the coordinator's
  own judgement; all challenges route to the `critic`.
- MUST NOT continue a PR past 2 upheld implementer challenges; escalate per
  safety-circuit condition 7.
- MUST NOT treat a PR's gating-test path set as frozen before the draft-PR body
  declares it (i.e. before phase 4b completes).
- MUST NOT use commit attribution to determine the test/production boundary; use
  the declared gating-test path set.

## When to update this rule

When the gate composition changes (a third half, a different pair), update "The
gate" and "What this rule forbids". When the roadmap structure changes
(milestones replaced by another ordering), update "The objective" and cycle
step 1. When the driver mechanism changes, update "Continuity and the kill
switch". When the parallelism model changes, update "Parallel execution". When a
new escalation pattern surfaces, add a condition to the safety circuit rather
than letting the loop run through it.
