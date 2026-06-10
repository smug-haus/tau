# Traceability — invariant → D-NNN → enforcer → detection test

This is the keystone that makes the spec *enforceable*: every safety invariant,
conservation law, and liveness property from `../02-requirements/` is mapped to
(1) a proposed runtime-invariant identifier in the project's `D-NNN` namespace,
(2) the concrete OTP module/process that structurally enforces it, and (3) a
**detection method** — the test or mechanical check that would catch a
violation. This is the Appendix-B source-map of the proposed `SPEC-FACTORY-*`
(see `../06-roadmap/spec-factory.md`).

> **D-NNN allocation is PROVISIONAL.** This document uses a fenced block
> **D-300 … D-360** for the factory. Per the project's `D-NNN` discipline
> (`docs/MISSION.md`), before adoption each identifier MUST be verified free
> across the whole repo and all branches (`git log --all --grep`, plus
> `grep -rn` over `lib test docs .claude`). Renumber on collision.

## Module index (component → modules)

| Comp | Modules (proposed `Tau.Factory.*`) |
|------|-------------------------------------|
| L | `Ledger.Writer` (GenServer/Ecto), `Budget.Owner` (ETS owner), `Tau.Repo`, `Oban` |
| K | `Coordinator` (gen_statem), `Escalation` (pure `classify/1`), `KillSwitch` |
| S | `Scheduler` (GenServer), `ConflictCheck` (pure) |
| U | `Unit` (gen_statem), `UnitSupervisor` (DynamicSupervisor), `UnitRegistry` |
| G | `Gate` (+ `GateTasks` Task.Supervisor), `Gate.{AcLinkage,Masking,Mutation,SpecMembership}` (pure), `Toolchain` (behaviour) |
| W | `WorkerSupervisor` (DynamicSupervisor), `WorkerRegistry`, `WorkspaceJanitor` (monitor), agent `Port` |
| M | `MergeAuthority` (gen_statem: `:idle/:integrating/:committing`) |
| Gov | `Egress`, `Policy` (+ `Policy.Owner`), `ActionClassifier`; reuse `CircuitBreaker.Store`, `RateLimiter`, `Cost.Tracker`, `OtelReporter` |

## Safety invariants

| D-NNN | Invariant | Enforcer (module / OTP mechanism) | Detection method |
|-------|-----------|-----------------------------------|------------------|
| D-300 | INV-1 gate-before-merge | `MergeAuthority` CAS reads latest PASS verdict before push | property: no `main` commit lacks a PASS verdict@hash; mutation: drop the verdict read ⇒ test fails |
| D-301 | INV-2 freshness | `MergeAuthority` `git push --force-with-lease=<expected-old-oid>` | integration: advance origin/main mid-gate ⇒ push rejected, no merge |
| D-302 | INV-3 serialized merge | `MergeAuthority` single `gen_statem`; INV-3 holds because at most one `:integrating` train at a time and the commit is serialized in the one M process | property: ≤1 concurrent integration; concurrency stress test |
| D-303 | INV-4 main health | `MergeAuthority` post-batch health → E-RED-MAIN; no merge while red | integration: red batch tip ⇒ halt + no further push |
| D-304 | INV-5 oracle separation | `WorkerSupervisor` spawn-order + recorded author identity (HR-7) | property: `author(test) ≠ author(impl)`; reject same-identity |
| D-305 | INV-6 gating-test immutability | `Gate.Masking` path-scan of diff vs frozen `paths_g` | unit: implementer diff touching `paths_g` ⇒ flagged |
| D-306 | INV-7 non-vacuous (mutation) | `Gate.Mutation` engine-executed revert+run (HR-3) | the mutation check itself; cross-check failing id passes in green run |
| D-307 | INV-8 user-path oracle ◐ | `Gate` entry-symbol assert (partial) + critic | **residual** — see §residual; entry-symbol presence check only |
| D-308 | INV-9 incomplete-fix | `Gate` mechanical AC-falsification test | unit: finding falsifying a named AC ⇒ reopen, not follow-up |
| D-309 | INV-10 resource isolation | `WorkerSupervisor` per-worker checkout + declared resource namespace | concurrency: two workers share no declared mutable path (Burrito XDG race repro) |
| D-310 | INV-11 no shared tree | worker-private fork; `MergeAuthority` sole `main` writer | invariant: no worker mutates parent HEAD |
| D-311 | INV-12 verified position | worker self-verifies pwd/HEAD/branch in `init/1`, aborts in parent root | unit: spawn in parent root ⇒ abort |
| D-312 | INV-13 conflict-gated concurrency | `Scheduler` admits only if `ConflictCheck` clears on declared sets (HR-4) | properties P-CC1..5 on `ConflictCheck` |
| D-313 | INV-14 capture-before-destroy | `WorkspaceJanitor` monitor captures staged+unstaged+untracked on `:DOWN` | unit: `:kill` a worker with an untracked file ⇒ file recovered |
| D-314 | INV-15 reclaim | linked workspace + janitor reclaim on every exit path | property: terminated worker ⇒ no leaked worktree/namespace |
| D-315 | INV-16 durable state, RPO=0 | `Ledger.Writer` WAL-before-ack; SQLite/Exqlite (WAL, `synchronous=FULL`); Oban-Lite/hand-rolled backlog | crash test: kill coordinator post-decision ⇒ decision survives, not re-applied |
| D-316 | INV-17 crash containment | per-worker process; no try/rescue across boundary | property: worker crash blast-radius = {worker} |
| D-317 | INV-18 total escalation | `Coordinator` + `Escalation.classify/1` total catch-all | property: `classify/1` total over `term()`; no non-progress state without `e` |
| D-318 | INV-19 bounded retry | `Unit` gen_statem refine≤N (Policy-clamped) → pivot → escalate | property: attempts ≤ N_refine+N_pivot; durable count |
| D-319 | INV-20 no unilateral destruction | `ActionClassifier` denylist → E-DESTRUCTIVE | unit: classified destructive action ⇒ denied + escalated |
| D-320 | INV-21 budget ceiling | `Scheduler`/`Budget.Owner` pre-admission check | property: spend ≤ budget; overrun ≤ 1 action |
| D-321 | INV-22 clean kill | `KillSwitch` + `Coordinator` between-unit guard | integration: kill mid-step ⇒ halt after unit, main synced, not mid-merge |
| D-322 | INV-23 spec-before-code | `Gate.SpecMembership` mechanical source-map check (HR-6) | unit: diff touches SPEC'd boundary w/o D-NNN ⇒ FAIL |
| D-323 | INV-24 OTP non-negotiables | `Gate` lint/compile/credo/dialyzer via Toolchain (HR-6) | CI: warnings-as-errors + credo --strict + dialyzer |

## Conservation laws

| D-NNN | Law | Enforcer | Detection |
|-------|-----|----------|-----------|
| D-330 | CON-1 work conservation | `Ledger` single-writer; reconciliation pass | audit: accepted = merged ⊎ escalated ⊎ rejected ⊎ in_flight |
| D-331 | CON-2 issue reconciliation | reconciliation pass (tree vs tracker) | audit: `state_tree(i) ≡ state_tracker(i)`; |steps| match |
| D-332 | CON-3 budget conservation | `Budget.Owner` double-entry | audit: `spent + remaining = total` |
| D-333 | CON-4 cost attribution | `Cost.Tracker` per (model,role) | audit: `Σ attributed = total_spent` |
| D-334 | CON-5 artifact conservation | `WorkspaceJanitor` capture | audit: dirty = committed ⊎ captured ⊎ discarded-by-decision |
| D-335 | CON-6 verdict conservation | append-only `verdicts` table (HR-2); partial unique index | property: merged ⇒ fresh PASS verdict@hash for every required half |
| D-336 | CON-7 escalation conservation | `Coordinator` + `Ledger` escalation log + notify | audit: raised = delivered ∧ recorded |

## Liveness

| D-NNN | Property | Enforcer | Detection |
|-------|----------|----------|-----------|
| D-340 | LIV-1 unit termination | `Unit` retry ladder + escalation | model-check: every accepted unit ◇ terminal |
| D-341 | LIV-2 merge progress | `MergeAuthority` fair queue + aging | property: green+fresh ⇒ ◇ merge; no starvation under aging |
| D-342 | LIV-3 milestone termination | `Coordinator` + reconciliation | audit: milestone ◇ zero-open ∨ escalated |
| D-343 | LIV-4 no livelock | `Scheduler` monotone admission (HR-4) | property P-CC monotone; no admit→withdraw→re-admit cycle |
| D-344 | LIV-5 recovery progress | `Coordinator` resume from L; idempotent | crash test: restart ⇒ resume, no re-do of terminal work |

## Key NFRs with a structural enforcer

| D-NNN | NFR | Enforcer | Detection |
|-------|-----|----------|-----------|
| D-350 | NFR-RPO=0 | WAL-before-ack visibility rule | crash test (= D-315) |
| D-351 | NFR-EGRESS | `Egress` chain RateLimiter→CircuitBreaker→Budget | load test: 0 sustained 429/5xx failures |
| D-352 | NFR-OBS=100% | paired `[:tau,:factory,…]` telemetry | coverage scan: every user-visible event has a span |
| D-353 | NFR-AUDIT=100% | lineage records (commit→verdict→paths→AC→SPEC→issue) | query: every merge fully traceable (a join, not a grep) |
| D-354 | NFR-GAME-RESISTANCE | `Gate.Mutation` + HR-3 engine execution | mutation check; vacuous-test fraction = 0 |

## Residual (honestly unclosed)

- **D-307 / INV-8 (user-path oracle) — partial.** HR-3 guarantees the *engine*
  runs and judges tests (closing the vacuous + faked-mutation holes) and can
  assert the entry symbol *appears* in the test, but "appears in the test" ≠ "is
  the exercised path." **Under-asserting** tests (real path, too-weak assertions
  — still fail on the reverted tree, so they pass the mutation gate) and
  **wrong-path** tests (exercise a hand-built struct, not the user entry point)
  remain bounded only by **critic judgement**. This is the one cell the
  mechanical gates do not close; it is stated, not papered over (research
  GAP-7). Candidate future mechanization: coverage-delta on the user entry path,
  or assertion-density mutation — flagged, not designed.

## Coverage check

Every INV-1..24, CON-1..7, LIV-1..5 has a D-NNN, an enforcer, and a detection
method. The only `◐` is D-307. No invariant is an orphan (the verifier pattern
V3 obligation from `R-list.md` is discharged).
