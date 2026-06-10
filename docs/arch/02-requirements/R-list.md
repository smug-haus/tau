# R-list — functional requirements & master index

The falsifiable-predicate requirement set for tau, organised by the ten
decomposition axes (`00-problem/problem-statement.md`). Safety invariants,
conservation laws, liveness, and NFRs live in their own files and are indexed at
the bottom. Each functional requirement: **FR-id** · predicate · *falsify* ·
*authority* (writer-of-record) · *volatility* (stable / quarterly / weekly).

Imposed constraints (D-S1..S4) are in `00-problem/scope-decisions.md` and are
not repeated as requirements.

---

## Axis 1 — Intake & specification

**FR-1.1** The factory accepts intent as **issues in an external tracker** and
treats the tracker as the authority for *what* to build, the durable solution
tree as the authority for *what has been done*. *Falsify:* intent accepted from
a source the system cannot reconcile (CON-2 breaks). *Authority:* tracker (intent),
solution tree (progress). *Volatility:* stable.

**FR-1.2** Coordination-heavy intent (PSDH triage ≥ 2) is converted to a written
SPEC with named runtime invariants (D-NNN) and acceptance criteria (AC-N) before
implementation (INV-23). *Falsify:* a behaviour-changing PR on a coordination-
heavy component with no SPEC. *Authority:* the SPEC catalog. *Volatility:* stable.

**FR-1.3** Each work unit declares, before any implementer runs, a **frozen
scope**: the issue set, the plan, the in-scope SPEC AC-N/D-NNN, and (after the
oracle phase) the gating-test path set. *Falsify:* scope grown after an
implementer is spawned without a recorded re-plan. *Authority:* the per-unit
plan-of-record. *Volatility:* per-unit.

**FR-1.4** Acceptance criteria are expressed against the **user-facing entry
point** and carry an observable signal (exact command + expected output), not
"works" (research INV-F9). *Falsify:* an AC with no command/observable signal.
*Authority:* the SPEC §7. *Volatility:* stable.

## Axis 2 — Planning & decomposition

**FR-2.1** Work is selected as the **smallest shippable increment** that respects
declared dependencies and any stated priority order; a missing prerequisite is
**filed as an issue**, never silently created as code. *Falsify:* a merged change
implementing un-filed prerequisite work. *Authority:* the scheduler + tracker.
*Volatility:* weekly.

**FR-2.2** A work unit is **one coherent shippable increment** (one or more
cohering issues) bounded by two guards: declared-frozen scope (FR-1.3) and a
gateability ceiling (reviewable in a single pass). *Falsify:* a unit too large to
gate in one pass, or spanning incoherent issues. *Authority:* the scheduler.
*Volatility:* stable.

**FR-2.3** The scheduler admits a unit to concurrent execution only when the
**five-clause conflict check** clears against every in-flight unit (INV-13);
otherwise it serializes. Parallelism is the default, not the exception.
*Falsify:* two concurrent units failing a clause. *Authority:* the scheduler.
*Volatility:* stable.

## Axis 3 — Execution & isolation

**FR-3.1** Each work unit runs in a **supervised worker** owning a complete
isolation boundary (INV-10): private git checkout from a verified ref (INV-12)
plus a per-worker namespace for every mutable resource the **toolchain adapter**
declares (D-S2: per-language). *Falsify:* two workers sharing any declared
mutable resource. *Authority:* the worker supervisor. *Volatility:* stable.

**FR-3.2** Implementation is delegated to **agent processes** (LLM-driven) whose
lifecycle, structured I/O, and resource boundary are owned by the supervision
tree — not free-running subprocesses scraping stdout (research GAP-4). *Falsify:*
an agent whose crash is invisible to a supervisor, or whose output is screen-
scraped. *Authority:* the agent supervisor. *Volatility:* stable.

**FR-3.3** The **toolchain is a behaviour** with per-language adapters
(install-deps, build, test, lint, mutation-run, package/release). All gating,
isolation, and health checks are expressed against this behaviour, never against
a hardcoded runner. *Falsify:* a gate or health check that names `mix`/`pytest`/
etc. directly instead of dispatching through the toolchain behaviour. *Authority:*
the toolchain registry. *Volatility:* quarterly (new languages added).

**FR-3.4** The **self-hosting (Elixir/BEAM) toolchain adapter** is the bootstrap
/ proving adapter and the dogfood target (D-S2 note). *Falsify:* a release whose
self-hosting loop was never exercised. *Authority:* the toolchain registry.
*Volatility:* stable.

## Axis 4 — Verification & gating

**FR-4.1** Every work unit passes the **full gate** before merge: two judgement
oracles (critic, reviewer) + three mechanical gates (AC-linkage, masking-
detection, mutation), on the final diff (INV-1). No skip, override, partial, or
promote-later. *Falsify:* a merge with any gate half not PASS on the final diff.
*Authority:* the merge authority. *Volatility:* stable.

**FR-4.2** Gating tests are authored by a **separate test-author** before the
implementer, exercise the user path (INV-8), and their paths are frozen and
read-only to the implementer (INV-5, INV-6). *Falsify:* a gating test authored or
edited by the implementer. *Authority:* the test-author + masking gate.
*Volatility:* stable.

**FR-4.3** The mechanical gates are **path-based, not commit-attribution-based**,
so they survive refine-cycle rebases (INV-7). *Falsify:* a gate decision that
flips on rebase with no content change. *Authority:* the gate runner.
*Volatility:* stable.

**FR-4.4** An implementer may **challenge** a gating test only when it
contradicts a SPEC §4 contract; the challenge is adjudicated by an **independent
critic** (never the coordinator's own judgement); > 2 upheld challenges on one PR
escalates (E-CHALLENGE). *Falsify:* a challenge ruled by the coordinator, or a
3rd upheld challenge with no escalation. *Authority:* the critic + solution tree.
*Volatility:* stable.

## Axis 5 — Integration & delivery

**FR-5.1** Merges are performed by a **single serialized merge authority**
(INV-3) that enforces the freshness re-check (INV-2) and runs the post-merge
health check, halting on red (INV-4). *Falsify:* a merge outside the authority,
or a skipped freshness/health check. *Authority:* the merge authority.
*Volatility:* stable.

**FR-5.2** Every change lands as an **atomic, traceable commit/PR** linked to its
issue(s) and gate verdicts (NFR-AUDIT); the VCS is the audit log and rollback
mechanism (research: Aider lesson). *Falsify:* a `main` commit with no traceable
lineage. *Authority:* the VCS + solution tree. *Volatility:* stable.

**FR-5.3** Destructive/irreversible delivery actions (force-push, history
rewrite, release, external publish, data migration) are **never executed
autonomously** — each escalates (INV-20, E-DESTRUCTIVE). *Falsify:* an
autonomous destructive action. *Authority:* the action classifier. *Volatility:*
stable.

## Axis 6 — State, memory & knowledge

**FR-6.1** The **solution tree** is a durable, transactional, queryable store —
the single source of truth for steps, attempts, verdicts, challenges, kill
reasons, escalations (INV-16, RPO=0). It is **not** a context window or a file an
agent must remember to update (research GAP-1, GAP-5). *Falsify:* a decision that
exists only in agent context. *Authority:* the durable store. *Volatility:* stable.

**FR-6.2** The factory accumulates **durable knowledge** (failure taxonomies,
heuristics, prior solution trajectories) in a persistent, searchable memory
(reuse candidate: SQLite memory subsystem). *Falsify:* a recurring failure with
no captured heuristic after repeated occurrence. *Authority:* the memory store.
*Volatility:* weekly.

**FR-6.3** Factory decisions follow the **deterministic-orchestrator /
nondeterministic-activity** split (research: Temporal lesson): persist
*decisions and outcomes*, not LLM reasoning; the control loop is replayable from
the decision log. *Falsify:* a control decision unrecoverable without replaying
an LLM call. *Authority:* the decision log. *Volatility:* stable.

## Axis 7 — Resource governance

**FR-7.1** A **budget ledger** (token, cost, wall-time, iteration) is a single-
owner durable counter; every billable action debits it pre-admission (INV-21,
CON-3); exhaustion escalates (E-BUDGET). *Falsify:* an action admitted past the
ceiling. *Authority:* the budget ledger. *Volatility:* weekly.

**FR-7.2** Outbound provider load is governed by the composed chain **rate
limiter → circuit breaker → budget ledger** (NFR-EGRESS), in that load-bearing
order. *Falsify:* sustained 429/5xx-driven failures under documented limits.
*Authority:* the egress governor. *Volatility:* stable.

**FR-7.3** Concurrency is **admission-controlled** by budget and the conflict
check, not fixed fan-out; back-pressure bounds in-flight work to what the system
can absorb (research: Broadway lesson; governed by NFR-CONC). *Falsify:*
unbounded spawning that exhausts node resources. *Authority:* the scheduler.
*Volatility:* stable.

**FR-7.4** Model selection per role is **configurable** (e.g. cheaper models for
mechanical roles, stronger for adjudication); cost is attributed per model/role
(CON-4). *Falsify:* a role whose model is hardcoded with no override. *Authority:*
settings. *Volatility:* weekly.

## Axis 8 — Fault tolerance & recovery

**FR-8.1** Worker death (crash or kill) triggers **capture-before-destroy** of
all three dirty-state kinds (staged, unstaged, untracked) as a supervisor
responsibility, then resource reclaim (INV-14, INV-15, CON-5). *Falsify:* a
killed worker with an unrecoverable untracked file. *Authority:* the worker
supervisor. *Volatility:* stable.

**FR-8.2** Infrastructure failure (process crash) is recovered by **supervision**
(restart/escalate); **semantic** failure (gate FAIL, bad LLM output) is an
*outcome* handled by the FSM/retry ladder, **not** a crash to restart (research:
OTP §4 — the dominant BEAM-for-agents mistake). *Falsify:* a gate FAIL that
crash-loops a supervisor. *Authority:* the supervision tree vs the FSM (distinct
mechanisms). *Volatility:* stable.

**FR-8.3** Retry is **bounded and laddered**: refine (N=3, same PR) → pivot (new
approach, fresh PR, reset count) → escalate (INV-19); attempt count and rationale
are durable (FR-6.1). *Falsify:* unbounded refine. *Authority:* the PR FSM.
*Volatility:* stable.

## Axis 9 — Observability & control

**FR-9.1** Every user-visible/perf-sensitive event emits paired telemetry
(NFR-OBS-COVERAGE); a supervised reporter exports spans/metrics (reuse candidate:
OTEL reporter). *Falsify:* such an event with no span. *Authority:* telemetry.
*Volatility:* stable.

**FR-9.2** The factory reports to the operator **only** at milestone boundaries
and on escalation — no per-step human checkpoints (D-S1). Reports cite numbers
from their source (token counts, durations), never estimates (research:
substance-over-ceremony). *Falsify:* a per-step approval prompt in normal
operation, or a cited number with no source. *Authority:* the reporter.
*Volatility:* stable.

**FR-9.3** An **out-of-band kill switch** halts the loop between atomic units
with `main` synced, never mid-merge, with bounded latency (INV-22,
NFR-KILL-LATENCY); operator control state is separate from project state.
*Falsify:* a kill that interrupts a merge. *Authority:* the coordinator FSM.
*Volatility:* stable.

## Axis 10 — Safety & invariants (cross-cutting)

Axis 10 is the union of `invariants.md`, `conservation.md`, and the escalation
set in `liveness.md`. It has no separate FRs; it is the enforcement surface every
other axis is checked against. The proof obligation (INV-18 totality) is the
single most important whole-system property: **the loop can always either make
progress or name exactly why it cannot.**

---

## Master index

| Cluster | File | IDs |
|---------|------|-----|
| Imposed constraints | `00-problem/scope-decisions.md` | D-S1 … D-S4 |
| Safety invariants | `invariants.md` | INV-1 … INV-24 |
| Conservation laws | `conservation.md` | CON-1 … CON-7 |
| Liveness | `liveness.md` | LIV-1 … LIV-5 |
| Escalation set | `liveness.md` | E-AMBIGUITY … E-UNCLASSIFIED |
| Quantified NFRs | `nfrs.md` | NFR-CONC … NFR-GAME-RESISTANCE |
| Functional reqs | this file | FR-1.1 … FR-9.3 (10 axes) |

**Namespace note.** `INV-*`/`FR-*`/`CON-*`/`LIV-*`/`NFR-*`/`E-*` are the
*architecture-spec* namespace. The product runtime-invariant namespace is
`D-NNN` (inherited discipline, FR-1.2). When the factory is itself specified as
`SPEC-FACTORY-*`, each INV-* here maps to one or more enforcing `D-NNN`; that
mapping is built in `04-software-architecture/` (the source map).

## Traceability obligation

Every INV/CON/LIV must, by the end of `04-software-architecture/`, have a named
**structural enforcer** (a component, a supervisor lifecycle, a precondition, or
a mechanical gate). An invariant with no enforcer is an *orphan* and is the
primary target of adversarial verification (`05-verification/`, pattern V3). The
enforcement matrix (R × C) in `03-system-architecture/` is where this obligation
is discharged.
