# Safety invariants — "what must never happen"

These are the load-bearing requirements. Under **D-S1 (escalation-only
autonomy)** there is no human backstop in the per-step loop, so every invariant
here must be enforced **structurally** — by a process boundary, a supervisor
lifecycle, a precondition a process cannot skip, or a mechanical gate — *not* by
an agent choosing to obey prose. The current repo's failure modes (research:
`tau-current-analysis.md` §3) are the evidence that prose enforcement fails.

## Notation

- `□P` — P holds in every reachable state (safety).
- `◇P` — P eventually holds (liveness; see `liveness.md`).
- `X ↝ Y` — X leads to Y.
- `A ⫫ B` — A and B are isolated (no shared mutable state, no observation).
- Sets/predicates per `solution-shaping/references/notation.md`.
- `merge(d)` — diff `d` lands on `main`. `green(d)` — full gate PASS on exactly
  `d`. `fresh(d)` — `base(d) = head(origin/main)` at merge time.

Each invariant: **predicate** · **falsification test** (what observation would
prove it violated) · **structural enforcer** (the mechanism, named abstractly —
concrete OTP mapping in `04-software-architecture/`).

---

## Cluster A — Integration safety (the merge boundary)

**INV-1 Gate-before-merge.**
`□ ( merge(d) → green(d) )` — nothing reaches `main` without BOTH judgement
oracles (critic, reviewer) and ALL mechanical gates PASS on exactly that diff.
*Falsify:* a commit on `main` whose diff was never gated, or gated at a
different revision. *Enforcer:* a single merge-authority component for which
`green(d)` is an unskippable precondition; the gate verdict is keyed to the
content hash of `d`.

**INV-2 Freshness.**
`□ ( merge(d) → fresh(d) )` — a gate-green verdict covers only the diff it ran
against; if `origin/main` advanced, re-gate the rebased diff before merge.
*Falsify:* a merge whose base ≠ `head(origin/main)` at merge instant.
*Enforcer:* merge-authority re-reads `head(origin/main)` inside the same
critical section as the merge; mismatch ⇒ reject + re-gate.

**INV-3 Serialized merge.**
`□ ( |{d : merging(d)}| ≤ 1 )` — at most one merge in flight, regardless of how
many work units run concurrently. *Falsify:* two overlapping merge operations.
*Enforcer:* merge authority is a single-concurrency owner (mutual exclusion by
construction, not by lock discipline).

**INV-4 Main health.**
`□ ( red(main) → ¬∃ d. merge(d) )` — once the post-merge health check fails,
no further merge occurs until the red is cleared (by escalation/decision).
*Falsify:* a merge applied while `main` is known-red. *Enforcer:* health verdict
is merge-authority state; `red` gates the merge precondition closed and raises
escalation E-RED-MAIN.

## Cluster B — Oracle integrity (anti-gaming)

Evidence (research `prior-art.md` §3): frontier models reward-hack at up to
~76% on impossible tasks and cheat *more* as they strengthen; an LLM judge alone
is insufficient. Treat the implementer as adversarial.

**INV-5 Oracle separation.**
`□ ( author(test_g) ≠ author(impl) )` — the party that writes the acceptance
oracle (gating tests) is distinct from the party that writes the implementation.
*Falsify:* a gating test whose authoring agent is the implementing agent.
*Enforcer:* the test-author role runs and freezes a declared gating-test **path
set** before any implementer is spawned.

**INV-6 Gating-test immutability.**
`□ ( ∀ p ∈ paths_g. ¬ implementer_writes(p) )` — the implementer may not write,
weaken, or delete any declared gating-test path; doing so is a protocol
violation even with no assertion deleted. *Falsify:* a diff from an implementer
touching `paths_g`. *Enforcer:* path-based diff scan (masking gate) + the merge
precondition; the boundary is the frozen path set, not commit attribution.

**INV-7 Non-vacuous acceptance.**
`□ ( ∀ ac ∈ AC. ∃ t. fails_before(t) ∧ passes_after(t) )` — every acceptance
criterion has a test that fails against the pre-implementation tree and passes
after; a passing gating suite is provably bound to the implementation.
*Falsify:* revert production to merge-base, run gating tests, none fail.
*Enforcer:* mutation check (revert-everything-but-`paths_g` to merge-base,
assert ≥1 gating test fails).

**INV-8 User-path oracle.**
`□ ( ∀ t ∈ test_g. exercises_user_entrypoint(t) )` — gating tests drive the
real user-facing entry point (e.g. the CLI/argv path), not a hand-built struct
that bypasses the parser. *Falsify:* a gating test that constructs internal
state directly and never invokes the user entry point. *Enforcer:* critic
judgement + (where mechanizable) an entry-point assertion; this is a known
residual seam (research: GAP-7) and is flagged, not claimed closed.

**INV-9 Incomplete-fix prohibition.**
`□ ( finding falsifies a named AC/D-NNN → reopen ∧ ¬merge )` — a critic/reviewer
finding that falsifies any acceptance criterion or invariant the PR claims is an
**incomplete fix**: reopen and refine; it may NOT be deflected to a follow-up,
regardless of severity. *Falsify:* a merged PR plus an open follow-up whose
content falsifies one of the merged PR's named ACs. *Enforcer:* the mechanical
incomplete-fix test (does the finding describe a state falsifying a named AC?)
is part of the gate verdict.

## Cluster C — Work isolation (concurrency safety)

Evidence: research `tau-current-analysis.md` §3, failure modes F-1..F-7, each
tagged "this has happened."

**INV-10 Resource isolation.**
`□ ( w₁ ≠ w₂ → workspace(w₁) ⫫ workspace(w₂) )` — each work unit owns a
**complete** isolation boundary: git checkout **and** every mutable resource
outside the checkout it touches (HOME-namespace build caches, XDG dirs,
per-language toolchain caches, network-download caches, sandbox FS). No worker
can observe or mutate another's working state. *Falsify:* two concurrent workers
sharing any mutable path (e.g. a shared unpack cache) producing a cross-worker
corruption. *Enforcer:* isolation is a property of the spawn mechanism, not an
opt-in flag; the boundary is allocated per worker and is total over the
resources the toolchain adapter declares (D-S2 makes this per-language).

**INV-11 No shared mutable tree.**
`□ ( ¬∃ w. mutates(w, HEAD(parent)) )` — no worker mutates the parent/coordinator
working tree or another worker's HEAD. *Falsify:* a worker operation that moves
the coordinator's checked-out ref. *Enforcer:* the coordinator holds no
mutable working tree that workers can reach; all checkouts are worker-private
forks from a known-good ref.

**INV-12 Verified position.**
`□ ( starts(w) → position(w) established_by_system ∧ verified_by(w) )` — a
worker's starting git position is set by the system and verified by the worker;
it is never trusted from an untrusted spawn brief. *Falsify:* a worker that
proceeds on a position asserted by its brief without verifying. *Enforcer:*
spawn mechanism sets position; worker's first action verifies and aborts on
mismatch.

**INV-13 Conflict-gated concurrency.**
`□ ( concurrent(w₁,w₂) → conflict_check(w₁,w₂) = clear )` — two work units run
concurrently only if all five clauses clear: no dependency, disjoint files
(incl. gating-test paths), disjoint codepoints, no shared SPEC/D-NNN block,
shared-resource isolation possible. *Falsify:* two concurrent units that fail
any clause (e.g. both edit the same function). *Enforcer:* the scheduler admits
a unit to the running set only after the check clears against every in-flight
unit.

## Cluster D — Durability & recovery

**INV-14 No lost work.**
`□ ( dies(w) → recoverable(committed(w) ∪ dirty(w)) )` — a worker's death
(crash or kill) loses no committed work and no captured dirty state; dirty state
is captured in **all three** kinds — staged, unstaged, **and untracked** (a
naïve `git diff` omits staged and untracked). *Falsify:* a killed worker whose
uncommitted new file is unrecoverable after reclaim. *Enforcer:* capture is a
supervisor `terminate`/monitor responsibility executed before resource reclaim;
ideally work streams to a durable log continuously rather than sitting in a
volatile tree.

**INV-15 Reclaimed isolation.**
`□ ( terminates(w) ↝ reclaimed(workspace(w)) )` — every isolation resource has a
supervised lifecycle: created on spawn, reclaimed on termination *including
crash*; nothing leaks. *Falsify:* a terminated worker whose workspace/cache
namespace remains registered and blocks future spawns. *Enforcer:* the resource
is owned by (linked to) the worker process; supervisor reclaim runs on exit.

**INV-16 Durable factory state.**
`□ ( decided(x) ↝ persisted(x) ∧ survives_restart(x) )` — every factory
decision (step, attempt count, gate verdict, challenge ruling, kill reason,
escalation) is persisted transactionally and is the single source of truth;
a coordinator restart resumes from it with **RPO = 0** (no committed decision
lost). *Falsify:* a coordinator restart that re-does or loses a recorded
decision. *Enforcer:* decisions are committed to a durable transactional store
before their effects are externally visible (write-ahead); the store, not a
context window, is the system of record.

**INV-17 Crash containment.**
`□ ( crashes(w) → blast_radius(w) = {w} )` — a crashing worker affects no other
worker and does not wedge the coordinator; no `try/rescue` or `:exit`-catching
crosses a process boundary. *Falsify:* one worker's crash that halts or corrupts
another. *Enforcer:* per-worker process + crash domain; supervision restarts or
escalates per strategy.

## Cluster E — Autonomous-control safety

**INV-18 Total escalation.**
`□ ( ¬progress(s) → ∃! e ∈ E. escalates(s,e) )` — every non-progress state maps
to **exactly one** escalation reason; the escalation set `E` is closed and
total. There is no silent livelock. *Falsify:* a reachable state in which the
loop neither progresses nor escalates. *Enforcer:* the coordinator FSM has no
terminal-without-classification state; the catch-all transition raises
E-UNCLASSIFIED rather than spinning. (`E` enumerated in `liveness.md` /
`R-list.md`.)

**INV-19 Bounded retry.**
`□ ( attempts(pr) ≤ N_refine + N_pivot )` — refinement is bounded (N=3), then
pivot, then escalate; no infinite refine/pivot. *Falsify:* a PR with > N
refine attempts and no pivot/escalation. *Enforcer:* attempt count is durable
PR-process state; the transition to refine is guarded by the bound.

**INV-20 No unilateral destruction.**
`□ ( destructive(a) → escalate(a) ∧ ¬auto_execute(a) )` — no
destructive/irreversible action (force-push, history rewrite, data migration,
production release, external publish) executes autonomously; each routes to
escalation. *Falsify:* an autonomously-executed force-push or release.
*Enforcer:* a classified action whitelist; destructive class is denied at the
action boundary and raises E-DESTRUCTIVE.

**INV-21 Budget ceiling.**
`□ ( spent ≤ budget )` — configured budgets (token, cost, wall-time, iteration)
are hard ceilings; on exhaustion the loop halts (E-BUDGET), it does not overrun.
*Falsify:* recorded spend exceeding the configured budget. *Enforcer:* spend is
checked against budget at every billable action admission; admission denied at
the ceiling.

**INV-22 Clean kill.**
`□ ( kill ↝ halt_between_units ∧ main_synced ∧ ¬mid_merge )` — the out-of-band
kill switch halts the loop between atomic units with `main` synced, never
mid-merge; latency ≤ one atomic unit. Operator control state is separate from
project state. *Falsify:* a kill that interrupts a merge or leaves `main`
desynced. *Enforcer:* kill is checked at unit boundaries; an in-flight unit
runs to its clean checkpoint before the loop halts.

## Cluster F — Process / spec discipline (inherited)

**INV-23 Spec-before-code.**
`□ ( changes_behaviour(c) ∧ coordination_heavy(c) → ∃ SPEC(c) ∧ named D-NNN )` —
no coordination-heavy component (PSDH triage ≥ 2) changes behaviour without a
written SPEC and named runtime invariant. *Enforcer:* gate question; merge
precondition. **INV-24 OTP non-negotiables.** The eight OTP invariants (research
§2.10) hold for the factory itself, not only the product. *Enforcer:* critic +
`mix compile --warnings-as-errors` + credo/dialyzer in the gate.

---

## Why ≥ 3 (sanity check per method)

A real autonomous factory yields **24** safety invariants across six clusters —
well past the "fewer than 3 means step 2 wasn't pushed hard enough" floor. The
density is concentrated in Clusters B (anti-gaming) and C (isolation), which is
correct: those are where the evidence (ImpossibleBench; seven observed worktree
failures) says the system actually breaks.
