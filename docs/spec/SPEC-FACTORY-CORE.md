# SPEC: Factory Core (control loop · ledger · scheduler · unit FSM)

| | |
|---|---|
| **Status** | Draft |
| **Date** | 2026-06-09 |
| **Scope** | The `:tau_factory` control core: the Coordinator loop (K), the durable Ledger (L), the Scheduler/admission authority (S), and the per-PR Unit FSM (U). Owns the total-escalation, durable-decision, conflict-gated-admission, and bounded-retry contracts. |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + boundary contracts. Derived from the verified architecture in `docs/arch/` (system-architecture §1; control-plane.md; durable-spine.md; traceability.md). |
| **Issue** | TBD — file before the first implementation PR (`tau-github-workflow`); reference as `Closes #N`. |

**Changelog:** Initial draft — §0–§7 + Appendix B. Introduces D-312, D-315,
D-317, D-318, D-320, D-321, D-330–D-333, D-335, D-336, D-340, D-342, D-343,
D-344. Cites (does not own) D-300–D-303 (SPEC-FACTORY-MERGE),
P5b amendment (PR #455): §4 B3 — adds precise contract for `snapshot_unit/2`
(WAL-before-ack, idempotency-keyed) and `latest_unit_snapshots/1` (resume-read
op, routed through Writer); §5 — adds Coordinator `:ledger` start option and
`init/1` resume semantics (D-344); §3 — adds [C113-B3] resume-read routing
constraint. D-344 is now fully specified and enforced by
`coordinator_recovery_test.exs`.
D-304–D-308/D-322/D-323 (SPEC-FACTORY-GATE),
D-309–D-311/D-313/D-314/D-316/**D-334**/**D-326** (SPEC-FACTORY-FLEET — D-334/CON-5
is owned by FLEET, whose capture mechanism is the enforcer, and **D-326** the
worker-completion `work_ready` contract; CORE only audits the disposition and
consumes the `worker_event` set at U's `implementing → gating` edge — §4 B8,
[C111b-B8]), D-319 (SPEC-FACTORY-GOV). Durable store decided:
**SQLite/Exqlite** (arch OQ-1).

**Amendment (2026-06-13, PR #477):** Introduces **D-356** (U's consume half of
the merge-result PubSub delivery; the emission half is owned by
SPEC-FACTORY-MERGE D-356 — one invariant, two enforcers). §4 B6: pins the
`:awaiting_merge` **subscribe-before-request** ordering (U subscribes to
`"factory:pr:#{unit_id}"` on entry **before** invoking `merge_fun` →
`request_merge`, closing the at-most-once-without-replay lost-event race), the
direct consume of `{:merge_result, :merged | :rejected}` from that topic, and the
**unsubscribe on leaving** `:awaiting_merge`. Adds the `:janitor` threading note
to the UnitDriver seam (§4 B6 / B8): the driver threads `:janitor` through
`worker_fun` → `WorkerSupervisor.spawn/5` and performs **zero** worktree reclaim
itself — reclaim is owned by `Tau.Factory.WorkspaceJanitor` (SPEC-FACTORY-FLEET
D-313/D-314, on every `:DOWN`, capture-before-destroy). Removes the driver-side
telemetry→Unit merge bridge (forbidden by MERGE D-356). Appendix B adds the
gating-test paths. Resolves the merge-bridge lifecycle arch gap and the
U-callback no-block gap; folds in #478.

**Amendment (2026-06-13, PR #480 — P5c-6 production supervision):** Records
(does not redesign) the **config-gating + seam-threading contract** for
`Tau.Factory.Supervisor`, conforming to the assembly in
`docs/arch/04-software-architecture/supervision-tree.md`. Introduces **D-357**
(factory OFF by default — a normal boot starts no factory subtree and drives no
uncontrolled work). §3 Q3: adds the `[C120-B11]` default-OFF safety constraint.
§4: adds boundary **B11** — the `Tau.Factory.Supervisor.start_link/1` option
surface, the `enabled`-gated full-subtree assembly (Coordinator-LAST), and the
seam-derivation rules (the supervisor derives per-child opts and wraps the
`select_fun`/`drive_fun` seams from its high-level opts; the caller does NOT
hand-thread per-child opts). §6: D-357. Appendix B lists
`factory_supervision_test.exs`. Closes the §4 gap the test-author surfaced for
#474.

**Amendment (2026-06-13, PR #481 — P5c-7 dogfood capstone, AC-12):** Completes
the P5c-6 §4 B11 `:gate_fun` / `:agent_bin` deferral (the #480 critic's note):
`:agent_bin` is the D-326 `{:packet,4}` agent path; `:gate_fun` is the **arity-1**
Unit seam (D-361 — the Unit supplies the coordinate `data.head_sha || data.hash`
at call time) wrapping `Tau.Factory.Gate.run/1` over a `%Gate.Request{}` built
at call time (records exactly where each Request field comes from). Adds the
`:unit_timeouts` opt (**D-358** — widen the per-state Unit `:state_timeout_ms`
past `T_unit` so a real agent run does not spuriously escalate; OQ-2). Records the
**dogfood harness** contract: a **deterministic scripted `agent_bin`** (the
control plane is proven end-to-end, not agent intelligence — the agent's
authorship is the only simulated part), a **local-bare-origin sandbox** with a
**hard-refuse-non-local guard** before boot (**D-359**, [C122-B11], V1), and the
one-unit-to-`:merged` autonomous flow. §3 Q3: adds [C122-B11] (D-359 safety) and
[C121-B11] (head-SHA-not-threaded recorded constraint). §6: D-358, D-359. §7:
sharpens **AC-12** observable assertions and adds **AC-13** (safety guard).
Appendix B adds `tau.factory.dogfood.ex`, the dogfood agent/seed helpers,
`dogfood_e2e_test.exs`, `dogfood_guard_test.exs`. Conforms to (does not redesign)
arch `control-plane.md`, `gate-and-toolchain.md`, `merge-and-integration.md`.

**Amendment (2026-06-13, PR #503 — C1 / `[C121-B11]` resolution: unit-coordinate
identity).** Closes the head-SHA coordinate gap recorded as `[C121-B11]`. The
Unit now **captures** `work_ready`'s asserted `branch`/`head_sha` into its data
at the `implementing → gating` (and `oracle → implementing`) transition, and the
gate/merge seams key on that **actual** coordinate, not the pre-declared
`work_item.hash`. §4 B6/B8 pin the capture and the coordinate-substitution; §6
adds **D-361** (the coordinate-identity invariant — gate/merge key on the
agent-asserted `head_sha`), **D-362** (capture-on-`work_ready`), and **D-363**
(back-compat: a deterministic agent whose declared hash == produced HEAD, and the
legacy `head_sha = nil` 2-tuple seam, both fall through unchanged). §3 Q3
promotes `[C121-B11]` from a recorded deferral to a **resolved** constraint.
Conforms to arch `control-plane.md` §3.2.1 (which already showed the capturing
clause) and `merge-and-integration.md`; resolves the `control-plane.md`
§3.2.1↔§7.2 contradiction in favour of capture.

**Amendment (2026-06-14, PR #515 — real-run integration: admission
self-exclusion + single admission authority; D-380).** The first
factory-driven *real-`claude`* run surfaced a coordination defect: `unit-N` is
admitted **twice** against the **one** Scheduler — once by the Coordinator's
`drive_unit/3` with an `@empty_scope` (`coordinator.ex`), then again by the Unit
FSM `planned` state with the **real** `declared_scope` (`unit.ex`). For an
unscopable seed issue (the D-371 `universal_conflict` sentinel), the Unit's
second admit runs `ConflictCheck.clear?/2` against an `F` that already holds the
unit's **own** first entry → the sentinel branch fires `{:conflict,
:no_dependency}` → `escalate(:E_SCHEDULER_DEFER)`. The unit self-conflicts and
the loop wedges before any work. There are **two** distinct defects: (1) a
**double admission** of one unit against one authority (the contract assumes one
admit per unit — §3 Q2 `admit→withdraw→re-admit` is forbidden absent a
`release`), and (2) a **soundness** bug — the Coordinator's `@empty_scope` admit
records the unit in `F` with an *empty* scope, blinding every *other* unit's
conflict check to the unit's real files. The fix pins **single admission
authority at the Unit FSM** (which holds the real `declared_scope`) and adds
**self-exclusion** in the Scheduler as the structural guarantee that a unit can
never conflict with its own `F` entry. §3 Q1/Q2/Q6 record the constraint; §4
B1 pins single-authority + the `admit/3` self-exclusion post-condition; §4 B2
pins that `ConflictCheck` stays unit-id-agnostic (P-CC-2 self-conflict on scope
is preserved — the exclusion lives in S, not C5); §6 adds **D-380**. Conforms
to arch `control-plane.md` §2.2 (the admission predicate) and §2.4
(scope-amendment re-admission, which now relies on self-exclusion to be idempotent).

## 0. Why this spec exists

The factory's control core is the brain of an autonomous loop that takes a
GitHub issue to a gate-passed, merged PR with **no human in the per-step loop**
(arch D-S1). The prior attempt ran this brain as a prompt-driven Claude session
whose state was a degrading context window plus a JSON file an agent had to
remember to update (arch `tau-current-analysis.md` GAP-1). The consequences on
file: the "compress-to-≤1000-tokens meta-restart" machinery exists *only*
because the state store is volatile, and every worktree-discipline rule that is
"prose an agent must obey" has been observed to fail.

This spec makes the control core a **supervised OTP application**: the
Coordinator is a `gen_statem`, the Unit lifecycle is a `gen_statem`-per-PR, the
Scheduler is a single-writer admission authority, and the solution tree is a
**durable transactional ledger** (SQLite/Exqlite, RPO=0) — not a context window.
The load-bearing properties are **total escalation** (the loop can always either
progress or name exactly why it cannot), **durable decisions** (a crash loses no
recorded decision), **conflict-gated admission** (concurrency never violates
isolation), and **bounded retry** (no infinite refine).

The component is maximally coordination-heavy (triage 5/5; §1) and therefore
requires this spec before any implementation PR modifies the control-core
boundary, per `.claude/rules/spec-before-code.md`.

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | The solution tree (units, attempts, verdicts, budget) is read by the loop and written on every decision; the Scheduler's in-flight set `F` is read/written on every admission. Both are concurrently consulted. |
| 2 | Temporal coupling | 1 | `select → admit → drive → unit_terminal` is strictly ordered; a decision is durable only *before* its effect is visible (WAL-before-ack); the kill switch acts only at a unit boundary. |
| 3 | Cross-process coordination | 1 | K (`gen_statem`), S (`GenServer`), N× U (`gen_statem`), L (`GenServer`/Exqlite), plus monitored refs to workers and PubSub to observers — coordination spans many processes with no shared mailbox. |
| 4 | Feedback loops | 1 | gate FAIL → refine/pivot → re-gate; a stall → timeout → retry ladder → escalation; budget spend → admission denial. The loop's behaviour feeds back into its own admission and retry decisions. |
| 5 | State accumulation | 1 | Attempt count `k` accumulates per PR until the N bound; the budget ledger accumulates spend until exhaustion; the solution tree accumulates the full decision history that survives restarts. |

**Triage score: 5/5. L0 + boundary contracts indicated.**

## 2. Component decomposition

Naming is precise so §4 contracts attach to specific operations. All modules are
under the `Tau.Factory.*` namespace and supervised by `Tau.Factory.Supervisor`
(arch `supervision-tree.md`).

| # | Component | Role |
|---|-----------|------|
| C1 | `Tau.Factory.Ledger.Writer` | **L.** Single durable-decision writer (`GenServer` over Ecto/Exqlite). WAL-before-ack; the append-only system of record for units, attempts, verdicts, challenges, escalations, budget, policy versions. Sole writer of every decision datum (arch HR-9). |
| C2 | `Tau.Factory.Budget.Owner` | **L (hot-read).** `GenServer` owning a `read_concurrency` ETS snapshot of remaining budget. Truth is in L (C1); the snapshot is a derived projection rebuilt in `init/1`. Admission reads bypass its mailbox. |
| C3 | `Tau.Factory.Coordinator` | **K.** `gen_statem` (`running`/`halting`/`halted`). Selects work, drives admitted units, classifies every non-progress trigger into exactly one escalation reason, runs the clean kill. |
| C4 | `Tau.Factory.Scheduler` | **S.** `GenServer` admission authority. Holds the in-flight set `F` and per-unit policy pins; admits a unit only when the conflict check clears and budget headroom exists; monotone. |
| C5 | `Tau.Factory.ConflictCheck` | Pure 5-clause admission predicate over **declared** scope (arch HR-4). No process. Properties before examples. |
| C6 | `Tau.Factory.Unit` | **U.** `gen_statem` per PR, `:temporary` under `UnitSupervisor`, keyed in `UnitRegistry`. Owns the *entire* PR lifecycle; bounded refine→pivot→escalate; snapshots each transition to L. |
| C7 | `Tau.Factory.Escalation` | Pure classifier `classify/1 → {e, scope}`; the total escalation set `E`. No process. |
| C8 | `Tau.Factory.Retry` | Pure retry-ladder decision `next/3 → {:refine,k} \| :pivot \| :exhausted`. No process. |
| C9 | `Tau.Factory.KillSwitch` | Supervised owner watching the operator sentinel/control channel; emits one PubSub event. The kill *mechanism*; K consumes it at a unit boundary. |

Boundaries (B-N attach contracts in §4):

| # | Boundary | Operation |
|---|----------|-----------|
| B1 | C3 Coordinator ↔ C4 Scheduler | `admit(unit, declared_scope)` → `:admit \| {:defer, reason}` (`call`). |
| B2 | C4 Scheduler ↔ C5 ConflictCheck | `clear?(declared, F)` pure call (five clauses). |
| B3 | {C3,C6} ↔ C1 Ledger.Writer | `record_decision` / `append_verdict` / `revoke_verdict` / `debit_budget` / `record_challenge` / `record_escalation` (`call`, WAL-before-ack). |
| B4 | C4 Scheduler ↔ C2 Budget.Owner | `budget_precheck/1` — ETS snapshot read, bypasses the mailbox. |
| B5 | C6 Unit ↔ C3 Coordinator | `unit_terminal(u, outcome)` / `escalate(e)` (the loop's progress + escalation feed). |
| B6 | C6 Unit ↔ **M** (SPEC-FACTORY-MERGE) | `request_merge(unit, hash)` — non-blocking submit; async `:merged`/`:rejected`. **Cited boundary.** |
| B7 | C6 Unit ↔ **G** (SPEC-FACTORY-GATE) | `request_gate(unit, diff, frozen_paths, pin)` / `gate_outcome`. **Cited boundary.** |
| B8 | C6 Unit ↔ **W** (SPEC-FACTORY-FLEET) | `spawn(role, brief, ref)` / `{:DOWN,…}` / `worker_stalled`. **Cited boundary.** |
| B9 | C9 KillSwitch ↔ C3 Coordinator | `:halt_requested` over PubSub `"factory:control"`. |
| B10 | C3 Coordinator ↔ external tracker | `select_next` / `reconcile` (issue source; reconciliation, CON-2). |
| B11 | `Tau.Factory.Supervisor` ↔ {`Tau.Application`, tests} | `start_link/1` — config-gated subtree assembly + seam-threading (P5c-6, #474). |

## 3. L0 constraints

Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious.

### Q1: What can be written by more than one actor?

- **★ [C100-B3]** Every durable decision datum has **exactly one writer**:
  `Ledger.Writer` (C1). The Coordinator, Units, and Gate all *request* writes;
  none writes the store directly. This single-writer discipline is what makes
  the conservation laws (D-330..D-336) hold by construction — no datum has two
  writers, so no update is lost or double-counted (arch HR-9). Splitting the
  decision writers (the rejected authority-split) reintroduces a distributed
  transaction across writers and is forbidden.
- **★ [C101-B4]** The budget *truth* is written only by `Ledger.Writer`
  (`debit_budget`); `Budget.Owner` (C2) holds a **derived** ETS snapshot. The
  snapshot is never the writer of record. A debit updates L first, then the
  snapshot write-through; a crash between them is healed by `init/1` rebuild
  from L (the snapshot is reconstructable, never authoritative).
- **[C102-B1]** The in-flight set `F` is written only by the Scheduler (C4) on
  admit/terminal. The Coordinator and Units *read* admission results; they never
  mutate `F`.
- **★ [C132-B1] One unit is admitted exactly once, by exactly one authority — the
  Unit FSM `planned` state — and the authority that admits is the one holding the
  unit's *real* `declared_scope` (D-380, V3).** The Coordinator (K) **selects and
  drives**; it MUST NOT call `Scheduler.admit/3`. An admit by K is unsound *and*
  redundant: K does not hold the real scope (it would admit with an `@empty_scope`
  placeholder), so the unit's `F` entry would carry an **empty** scope, blinding
  every *other* unit's `ConflictCheck` to the unit's real files (a missed-conflict
  corruption, the dual of [C130-B10] under-declaration). It is also a **second
  admit of the same `unit_id` against the same Scheduler**, which Q2's
  no-`admit→withdraw→re-admit` ordering forbids absent a prior `release`. Single
  authority = the Unit FSM, which holds `data.declared_scope` (the real elaborated
  scope, D-369..D-371). K's `drive_fun` invokes the unit driver directly; the
  admission gate lives once, in U's `planned → oracle` transition (§5 FSM; §4 B1).
- **★ [C133-B1] A unit can never conflict with its own in-flight entry — the
  Scheduler self-excludes the candidate from `F` before the conflict check (D-380,
  V3).** `Scheduler.admit(unit_id, scope)` MUST evaluate `ConflictCheck.clear?`
  over `F ∖ {unit_id}`, never over the raw `F`. Self-exclusion is the structural
  guarantee that makes admission **idempotent for a unit already in `F`** (a re-admit
  on the scope-amendment path, §4 B2 / arch §2.4, returns `:admit` against the
  unit's own prior entry rather than self-conflicting) and is the **sole** reason
  the D-371 `universal_conflict` sentinel does not make a single unscopable unit
  conflict with itself. The exclusion lives in **S** (which holds `F` keyed by
  `unit_id` and receives the candidate's `unit_id`), **not** in `ConflictCheck`
  (C5) — C5 stays unit-id-agnostic and keeps P-CC-2 (a non-trivial *scope* still
  self-conflicts when handed to itself; §4 B2, §6 D-312). One invariant
  ("no unit self-conflicts via its own `F` membership"), one enforcer (S).

### Q2: What ordering assumptions are implicit?

- **★ [C103-B3]** **WAL-before-ack.** `Ledger.Writer` MUST commit a decision to
  the SQLite WAL (`synchronous=FULL`, `fsync`) **before** replying `{:ok, ref}`,
  and the decision's external effect (a merge, a spawn, a report) MUST happen
  only *after* that reply. This ordering is the whole of RPO=0 (D-315): a
  decision is externally visible only once durable.
- **★ [C104-B1]** The conflict check runs over **declared** scope fixed at
  scope-freeze (arch FR-1.3), **not** post-hoc actual paths. Admission is
  therefore a pure function of pre-frozen declarations, which is what makes it
  *monotone* (D-343): a deferred unit keeps its place; no admit→withdraw→re-admit
  cycle. A post-hoc check on actual paths is non-monotone and forbidden.
- **★ [C105-B5]** A **semantic** failure (gate FAIL, bad model output) is an
  *outcome transition* inside U; an **infrastructure** failure (worker `:DOWN`)
  is an *event* U handles. These MUST NOT be conflated: encoding a gate FAIL as a
  process crash crash-loops the supervisor and burns budget (arch FR-8.2, the
  dominant BEAM-for-agents mistake). Supervision recovers infrastructure; the FSM
  + ledger recover semantics.
- **[C106-B9]** The kill switch is consumed by K **only at a unit boundary**
  (after `unit_terminal`), never mid-unit. Worst-case halt latency is one unit;
  the halt is clean (`main` synced, never mid-merge).

### Q3: What happens if a component fails silently?

- **★ [C107-B5]** A **wedged-but-not-crashed** worker (Port alive, no `:exit_status`,
  no `:DOWN`) emits **no trigger** — so K would idle with nothing to classify and
  the loop would silently livelock. Every U state that awaits an external actor
  (`oracle`, `implementing`, `gating`, `awaiting_merge`) MUST arm a mandatory
  `:state_timeout`, and the fleet MUST run a heartbeat watchdog that synthesizes
  a `worker_stalled` event on heartbeat absence. This is the only thing that
  makes total escalation hold over reachable *states*, not merely over the
  classifier's domain (D-317; arch final-validation H-2).
- **★ [C108-B3]** If `Ledger.Writer` is briefly unavailable, callers **block on
  that specific datum** (`call`, the reply is back-pressure); the system never
  guesses past the authority (fail-closed). A `cast` into L would risk losing a
  decision on crash and is forbidden.
- **[C109-B5]** A non-progress state with no foreseen cause MUST escalate
  `E-UNCLASSIFIED` (the catch-all), never spin. Its firing is logged as a defect
  signal.
- **★ [C120-B11]** **The factory is OFF by default.** The control subtree
  (Coordinator and everything that drives uncontrolled autonomous work) is gated
  on `config :tau, :factory` `:enabled`, whose **default is `false`**. A normal
  application boot — with no operator opt-in — MUST start **no** factory subtree:
  no `Coordinator`, no admitted units, no driven work. This is the
  "no-uncontrolled-work-on-normal-boot" safety property: an autonomous loop that
  merges to `main` must never start itself merely because the binary launched.
  The gate is read once at boot (mirroring the established
  `Tau.OtelReporter` `:enabled` precedent in `Tau.Application`); when disabled,
  `Tau.Factory.Supervisor` assembles only the durable-ledger-and-below children
  it needs for non-factory subsystems, never the Coordinator-bearing subtree
  (D-357).
- **★ [C122-B11]** **The dogfood harness MUST NOT push to a non-local origin.**
  The M10 dogfood (`mix tau.factory.dogfood`, P5c-7) drives the **real** control
  plane — Coordinator → UnitDriver → fleet → Gate → MergeAuthority → health — and
  MergeAuthority is the **sole writer of `origin/main`** (cited B6, MERGE §3),
  which it advances with a real `git push --force-with-lease`. In dogfood mode the
  sandbox `origin` MUST be a **local bare repo** (a `file://` / filesystem-path
  bare repository on the same host), **never** a network remote
  (`https://` / `git@` / `ssh://`). The mix task **hard-refuses** a non-local
  origin **before** booting the factory subtree — the guard is a precondition,
  not a runtime classification — so an autonomous force-pushing loop can never be
  pointed at a real GitHub remote by misconfiguration (V1: a network-remote push
  is an irreversible, gate-unassessable destructive action; the guard is the named
  mechanism that makes "the loop never force-pushes a real remote in dogfood
  mode" true by construction, not by trust). This is **D-359**. It complements
  [C120-B11] (off-by-default): even when the operator opts the factory *on* for a
  dogfood, the blast radius is confined to a throwaway local repo.
- **[C121-B11]** **The gate/merge coordinate is the agent-asserted `head_sha`,
  not the pre-declared `work_item.hash` (RESOLVED 2026-06-13, PR #503, D-361).**
  *Originally recorded (P5c-7) as a deliberate deferral; now resolved.* The Unit
  **captures** `work_ready`'s asserted `branch`/`head_sha` into `data` at the
  `oracle → implementing` and `implementing → gating` transitions, and substitutes
  that captured `head_sha` for `work_item.hash` as the **gate-Request `hash`** and
  the **merge-map `hash`/`branch`**. The agent is the sole authority for what it
  produced; pre-declaring the SHA of an unauthored commit is impossible for a
  non-deterministic agent (V1). Back-compat is total (D-363): the dogfood's
  deterministic scripted agent asserts `head_sha == declared hash`, so the captured
  and declared coordinates coincide and nothing observable changes; the legacy
  2-tuple `worker_fun` seam (no `worker_id`, `head_sha = nil`) retains the
  declared `work_item.hash` unchanged. Enforced by D-361/D-362; wiring spans
  `unit.ex`, `unit_driver.ex`, `gate/request.ex`, and the merge map (§4 B6/B8).
- **[C123-B8]** **`origin/<branch>` MUST exist at oracle-spawn time when
  `oracle_base_ref` is an `origin/`-qualified ref.** The oracle (test-author)
  Worker is spawned with a detached-HEAD checkout at `oracle_base_ref`; when the
  UnitDriver sets `oracle_base_ref` to `origin/<branch>`, the remote ref MUST
  already be pushed before `worker_fun` is called. In the real driver this is
  satisfied by the draft-PR seed push (factory cycle step 4); in the dogfood the
  Coordinator pushes the seeded branch to the local bare-repo origin before
  admitting the unit. Failure to satisfy this precondition causes the Worker's
  `git worktree add --detach origin/<branch>` to fail, which surfaces as
  `worker_exit(w, :error)` and enters the retry ladder.
- **★ [C130-B10]** **The conflict check is only as sound as the declared scope it
  is handed; an under-declared scope silently defeats it (I2; D-369/D-370/D-371).**
  `ConflictCheck.clear?/2` (the sole enforcer of conflict-gated admission) is a
  *pure function of declarations*. If `IssueSelector`'s elaboration of an issue
  *omits* a file/codepoint two units actually share, the predicate clears them as
  "disjoint" and the Scheduler admits both in parallel — they then collide on the
  omitted file (a corrupting defect, NOT a deferred-throughput cost). The
  soundness of the *check* is therefore conditional on the soundness of the
  *elaboration*, and free issue text cannot be turned into a provably-complete
  scope (the static-impact-analysis impossibility — V1). The constraint this SPEC
  pins is **directional soundness**: the elaborator MUST be **conservative** —
  over-declare under uncertainty, coarsen codepoints to whole files absent an
  explicit `file:line` citation, and **fall back to a serialize-against-everything
  sentinel scope** when it can extract no files/specs at all (admit only into an
  empty `F`). A false *over*-declaration costs only a needless `{:defer, …}`
  (reversible, cheap); a false *under*-declaration costs correctness (a missed
  conflict). The asymmetry is the load-bearing fact: bias every uncertain call
  toward *serialize*. The mechanism is the default `elaborate_fun` heuristic (§4
  B10 amendment, D-369); its conservative posture is D-369, the seam that lets a
  stronger elaborator be substituted without weakening the posture is D-370, and
  the serialize-on-empty fallback is D-371. The **discriminating question** —
  heuristic vs LLM vs required-template — is resolved by *who can be held to
  soundness*: an LLM elaboration is unsound by nature (it omits/hallucinates and
  cannot be audited on the admission path), a required-template field shifts the
  burden to the human author but is still unverifiable, and the citation-driven
  heuristic is the **cheapest-to-reverse** shape that makes incompleteness *safe*
  rather than *trusted*. The heuristic is therefore the default; the injected seam
  (D-370) keeps an LLM-assisted elaborator a *swap*, not a *rewrite*, if scope
  precision ever justifies its cost and an out-of-band verification step is added.

### Q4: What information crosses a boundary, and what is lost?

- **★ [C110-B7]** A gate verdict crossing from G to L is **append-only and
  immutable per `(hash, run)`** — a later challenge or finding appends a
  *superseding revocation*, never an in-place mutation (arch HR-2). "Latest
  status for a hash" is a query over the append-only rows. The merge boundary
  (B6, SPEC-FACTORY-MERGE) reads the *latest* inside its CAS; hash-keying alone
  closes content staleness but **not value staleness**, so immutability is
  load-bearing.
- **★ [C111-B5]** When U reports `unit_terminal`, the *outcome* (`merged` /
  `escalated` / `rejected`) is preserved with its full provenance (attempt count,
  last verdict hash, challenge log). No outcome is reduced to a bare boolean —
  the conservation laws need the full lineage (NFR-AUDIT).
- **★ [C111b-B8]** **Worker completion crosses as an asserted event, not an exit
  code (cited D-326, owned by FLEET).** The fact "the agent produced a stable
  diff" crosses to U **only** as `work_ready(worker_id, branch, head_sha)` — an
  in-band frame the agent emits before exit. A clean Port exit (`:exit_status 0`)
  carries one bit and **loses** the distinction between "did the work / pushed a
  real diff", "ran and pushed nothing", and "crashed but exited 0"; U must not
  infer completion from it. The `branch`/`head_sha` is the evidence U needs to
  confirm a non-empty diff before `request_gate`; exit-0-without-`work_ready`
  crosses as `worker_exit(w, :no_work_product)` and is routed to the retry
  ladder, never gated. The three worker-outcome events (`work_ready`,
  `worker_exit`, `worker_stalled`) are disjoint and keyed by `worker_id`.
- **[C112-B10]** The external tracker is the authority for *what to build*; L is
  the authority for *what has been done*. The reconciliation pass crosses this
  boundary read-only (the tracker is projected, never a second writer of L).
- **★ [C131-B8] The agent's task crosses to the Worker as an assembled prompt,
  not a bare issue title (A2, D-372/D-373).** The fact "here is the task to solve"
  crosses from intake (the `work_item`) to the agent (the shim's
  `Tau.CodingAgent.task.prompt`) through the Worker's `:brief`. Today the brief is
  set to the issue *title* alone (`supervisor.ex:to_unit_work_item/1`), and the
  scripted agent ignores it (`task.prompt = ""`). A real agent driven by the
  A1 shim (`Tau.CodingAgents.ClaudeCode`) has nothing to solve from a title. The
  information that MUST survive the crossing is the autonomous analogue of the
  human coordinator's draft-PR-body implementer brief (`factory-loop.md`): the
  **issue body**, the **linked SPEC/AC/D-NNN context**, the **declared scope**
  (`ConflictCheck.scope()`, B10/I2), the **gating-test paths**, and the **arch
  pointers** (`docs/arch/04-software-architecture/*` — per Tau memory
  `feedback_brief_implementers_with_arch`, NOT only SPEC §-refs). No component
  assembles this; the brief crossing *loses everything but the title*. The
  `BriefAssembler` (§4 B10 amendment below, D-372) is the intake component that
  composes the available inputs into `task.prompt`, mirroring how the
  `:elaborate_fun` seam composes the issue into `ConflictCheck.scope()`. The
  assembly is a pure function of inputs already present in the `work_item` plus
  static arch pointers — no LLM call on the assembly path (D-373).
- **★ [C113-B3]** **Resume-read routed through the writer process.** The
  resume-read op `Ledger.Reader.latest_unit_snapshots/1` is routed through
  the `Ledger.Writer` GenServer process via `GenServer.call/2` — NOT through a
  separate SQLite connection. This guarantees that the read sees all prior
  WAL-committed writes (visibility ⊐ commit, D-315). Opening a second
  connection for reads would require WAL-reader synchronisation and is
  forbidden for this low-frequency op.

### Q5: Where are the feedback loops, and are they bounded?

- **★ [C113-B5]** The refine loop (gate FAIL → refine_k → re-gate) is bounded at
  **N** refines (Policy-clamped, `N = min(policy, ceiling)`; ∞ rejected — arch
  HR-8), then one pivot, then `E-RETRY-EXHAUSTED`. The attempt count is durable
  PR state (D-318). Unbounded refine is forbidden (LIV-1).
- **★ [C114-B1]** The admission ↔ merge feedback (each merge re-stales in-flight
  branches, forcing re-gates) is bounded by `W_cap`, derived from gate-stage
  utilization `ρ_g < 1 − margin`, **not** the naïve `W*` (arch system-arch §5).
  The Scheduler MUST route back-pressure to the fleet, not only to intake.

### Q6: What are the pre/post-conditions at each boundary?

- **[C115-B1]** `admit/2` pre: `Store`/L running. Post: returns `:admit` only if
  the conflict check cleared against the *current* `F` and budget headroom holds;
  on `:admit`, the unit is added to `F` (a write) before the reply.
- **[C116-B3]** `append_verdict` pre: the `(hash, run)` coordinate is not already
  present (a partial unique index enforces one original per coordinate). Post: a
  later `revoke_verdict` is a *new* row with `supersedes_id`, never an update.

### Q7: What is the message-ordering protocol?

- **★ [C117]** The **control path is `call`** (the reply is back-pressure):
  K→S admit, U→L writes, U→M submit. The **observation plane is PubSub**
  (`"factory:report"`, `"factory:pr:#{id}"`, `"factory:escalation"`) — decoupled
  fan-out to observers, never the control path. **Liveness is monitored refs**
  (`:DOWN`). No `:global`, no `Process.whereis |> send` (OTP non-negotiable #4).
- **[C118]** Identity is a **Registry key**, never a pid. No pid is stored in any
  durable record (a stored pid is a dangling pointer after restart). On resume, U
  and worker refs are re-resolved by key.

### Q8: What is the change-impact (what else must move if this changes)?

- **[C119]** Adding a new escalation reason changes the **total set `E`** and the
  pure classifier (C7); the totality proof (D-317) MUST be re-discharged. Adding a
  new durable decision kind changes the Ledger schema and a conservation law
  (CON-*) — both in the same PR (no new state at a SPEC'd boundary without its §3
  constraint + §4 contract). Changing `W_cap` sizing is policy, engine-clamped,
  and never touches an invariant.

## 4. Boundary contracts

### B1: Coordinator (C3) ↔ Scheduler (C4)

- `admit/2 :: (unit_id, declared_scope) -> :admit | {:defer, reason}` (`call`;
  the implementation arity is `admit/3` — `(server, unit_id, declared_scope)`).
- Pre: Scheduler running; `Ledger.Writer` running.
- Post: `:admit` ⟺ `ConflictCheck.clear?(declared_scope, F ∖ {unit_id})` ∧
  `budget_precheck(unit) == :ok` ∧ `|F ∖ {unit_id}| < W_cap`; on `:admit`,
  `unit_id ↦ declared_scope` is **upserted** into `F` before the reply
  (single-writer of `F`).
- **Self-exclusion (D-380, [C133-B1]):** the conflict check and capacity check are
  evaluated over `F ∖ {unit_id}`, never the raw `F`. A unit therefore never
  conflicts with its own in-flight entry, and a re-admit of an already-present
  `unit_id` (the scope-amendment path, B2 / arch §2.4) is **idempotent** —
  it returns `:admit` and replaces the unit's scope, never `{:conflict, _}` against
  itself. The exclusion is by `unit_id` (S holds `F` keyed by it); `ConflictCheck`
  (C5) never sees the candidate's id (B2).
- **Single admission authority (D-380, [C132-B1]):** the **only** caller of
  `admit/3` is the Unit FSM `planned` state (§5), which holds the real
  `declared_scope`. The Coordinator (K) selects and drives but MUST NOT admit
  (an empty-scope K-admit is unsound — it blinds other units' checks — and is a
  forbidden double-admit of one unit against one Scheduler).
- Invariant (**D-343, monotone**): a `{:defer, _}` never demotes a unit's queue
  position; deferred units are served in arrival order with aging.

### B2: Scheduler (C4) ↔ ConflictCheck (C5)

- `clear?/2 :: (scope, %{unit_id => scope}) -> boolean()` — pure, total.
- `pairwise_clear?/2` is the conjunction of five clauses: no-dependency,
  disjoint-files (**including declared gating-test paths** — a shared
  `test/support` collision surface), disjoint-codepoints, no-shared-SPEC/D-NNN,
  resource-isolatable.
- Invariants (properties, §6 D-312): symmetry; non-trivial self-conflict;
  monotone-in-`F`; each clause necessary; gating-path collision blocks.
- **Unit-id-agnostic (D-380, [C133-B1]):** `clear?/2` receives only `(scope, F')`
  where the **Scheduler** has already excluded the candidate (`F' = F ∖ {unit_id}`).
  C5 has **no** knowledge of the candidate's id, so the self-exclusion fix MUST
  NOT be placed here. P-CC-2 (a non-trivial *scope* never clears against an equal
  *scope*) is **preserved unchanged** — it is a property of the pure predicate over
  *scopes*, not over *unit identities*. The "a unit never self-conflicts via its
  own `F` membership" guarantee is an S-level set operation (`F ∖ {unit_id}`),
  not a C5 change. The D-371 `universal_conflict` sentinel branch below operates
  over the already-excluded `F'`, so a single unscopable unit (its own entry
  excluded) sees an *empty* `F'` and clears.
- `scope()` type: `%{deps: [unit_id], files: MapSet.t(String.t()),
  codepoints: MapSet.t({String.t(), atom()}), specs: MapSet.t(atom()),
  resources: MapSet.t(atom()), optional(:universal_conflict) => boolean()}` —
  the `universal_conflict: true` sentinel (D-371) causes `clear?/2` to return
  `{:conflict, :no_dependency}` against any non-empty argument set, regardless of
  whether the sentinel is the candidate or an in-flight member (symmetric). Note
  the argument set `clear?/2` receives is the Scheduler's already-excluded
  `F ∖ {unit_id}` (D-380, [C133-B1]): a **single** unscopable unit sees an empty
  argument set and clears; the sentinel still serializes it against every *other*
  in-flight member.

### B3: {Coordinator, Unit} ↔ Ledger.Writer (C1)

- Write API (all `call`, WAL-before-ack): `record_decision/2`,
  `append_verdict/3`, `revoke_verdict/2`, `debit_budget/3`, `record_challenge/2`,
  `record_escalation/3`, `snapshot_unit/2`.
- Pre: `Repo` (Exqlite) up; an **idempotency key** (deterministic, e.g.
  `{unit_id, kind, coordinate}`) accompanies every write.
- Post: the SQLite WAL commit (`synchronous=FULL`) completes **before** the
  `{:ok, ref}` reply; a replayed write with the same idempotency key is a no-op.
- Invariant (**D-315, RPO=0**): visibility(effect) ⊐ commit(decision). A
  coordinator restart resumes from L with no decision lost or re-applied.
- **Verdict immutability (D-335, [C110-B7]):** `append_verdict`/`revoke_verdict`
  are **inserts only**; a partial unique index `(unit_hash, gate_run, gate_half)
  WHERE kind='verdict'` enforces one original per coordinate; a revoke is a new
  row with `supersedes_id`. No `update` changeset exists for verdicts.

#### B3 — `snapshot_unit/2` (durable unit-state write op, D-344 / P5b)

```
Ledger.Writer.snapshot_unit(server, attrs) :: {:ok, ref} | {:error, term}
  attrs :: %{
    unit_id:         String.t(),   # PR/unit identifier
    state:           atom(),       # Unit FSM state at this snapshot
                                   # (one of: planned | oracle | implementing |
                                   #  gating | refine_k | awaiting_merge |
                                   #  merged | escalated)
    idempotency_key: String.t()    # deterministic per {unit_id, kind, coordinate}
  }
```

Append-only (no UPDATE path); WAL-before-ack (D-315). A replay with the same
`idempotency_key` is a no-op: `INSERT OR IGNORE` returns the existing row id.
`{:ok, ref}` arrives only after the SQLite WAL commit is durable, so a snapshot
survives a Coordinator crash. `:merged` and `:escalated` are terminal sinks.

#### B3 — `latest_unit_snapshots/1` (resume-read op, D-344 / P5b)

```
Ledger.Reader.latest_unit_snapshots(server) :: %{unit_id => state_atom}
```

Returns the latest snapshotted state per `unit_id` (highest row `id` wins)
across the whole ledger. Routed through the `Ledger.Writer` process (sole
connection owner) to guarantee reads see all prior WAL-committed writes.
Used exclusively by `Coordinator.init/1` to rebuild the in-flight set on
resume (D-344). Terminal units (`:merged`/`:escalated`) appear in the map;
the Coordinator filters them. Returns `%{}` when no snapshots exist.

#### B3 — Unit `:ledger` start option (durable per-transition snapshotting, D-318 / P5c-1; D-355 merge-outcome reconcile / PR #465)

`Unit.start_link/1` accepts an optional `:ledger` key:

```
:ledger — GenServer.server() | nil
```

When `:ledger` is present and non-nil, the Unit calls
`Ledger.Writer.snapshot_unit(ledger, attrs)` on **each state entry**, before the
state's external effect (WAL-before-ack, D-315). This makes the Unit's FSM
state crash-durable and enables the Coordinator's D-344 resume to rehydrate
**real** units (not only the injected test seam).

**D-355 reconcile-on-entry amendment (PR #465):** additionally, when entering
`:awaiting_merge`, the Unit reads `Ledger.Reader.merge_outcome_for(ledger, unit_id)`
(routed via `Ledger.Writer`) **before** calling `merge_fun`:

- `{:merged, sha}` → the merge already landed; transition immediately to terminal
  `:merged` WITHOUT calling `merge_fun` (no double-submit, D-344).
- `{:rejected, reason}` → the merge was rejected; route back to `:gating`
  (re-gate, INV-2) WITHOUT calling `merge_fun`.
- `:none` → no prior outcome; call `merge_fun` (current behaviour, unchanged).

This composes with D-344: the Coordinator rehydrates the Unit at `:awaiting_merge`
and the Unit reconciles on re-entry — exactly-once on resume. When `:ledger` is
`nil` or absent, reconcile is a no-op (back-compat).

The `idempotency_key` coordinate is `"<unit_id>:snapshot:<entry_seq>"` —
per-entry-unique because `entry_seq` is a monotonic counter (initialised to 0
in `init/1`, incremented on every `snapshot_unit/2` call). Every state entry
— including backward-edge re-entries such as `:gating` after a merge-reject
or `:implementing` after a gate-fail refine — writes a **new row** with a
distinct key. `INSERT OR IGNORE` remains the writer contract: a genuine replay
of the same `entry_seq` (same coordinate) is still a no-op (D-315). The
highest row `id` per `unit_id` in `latest_unit_snapshots/1` therefore returns
the **genuinely-latest** FSM state, not the forward-stale state that a
per-state key would leave when a backward edge re-enters an already-visited
state.

When `:ledger` is `nil` or absent, snapshotting is a **no-op** — existing
callers that pass no `:ledger` opt are unaffected (back-compat).

### B4: Scheduler (C4) ↔ Budget.Owner (C2)

- `budget_precheck/1 :: (unit_id) -> :ok | {:exhausted, dimension}` — reads the
  ETS snapshot directly (bypasses the owner mailbox; reads are not serialized).
- Pre: snapshot rebuilt in `Budget.Owner.init/1` from L truth.
- Post: `:ok` only if every budget dimension (token/cost/wall-time/iteration) has
  headroom for the unit's admission.
- Invariant (**D-320**): admission is denied at the ceiling **before** the unit
  becomes billable; overrun ≤ one in-flight action.

### B5: Unit (C6) ↔ Coordinator (C3)

- `unit_terminal/2 :: (unit_id, outcome)` where `outcome ∈ {merged, escalated,
  rejected}` with full provenance ([C111]).
- `escalate/1 :: (trigger)` — routes to K, which classifies via C7.
- Invariant (**D-340**): every admitted unit ◇ reaches a terminal outcome
  (exhausting the retry ladder *is* a terminal `escalated`).

### B6: Unit (C6) ↔ Merge Authority (M) — *cited, SPEC-FACTORY-MERGE; consume half owned here (D-356)*

- `request_merge/2 :: (unit_id, hash) -> :queued` (non-blocking; the result
  `:merged`/`:rejected` arrives asynchronously via `"factory:pr:#{id}"`). A
  blocking `call` across a minutes-long merge build is forbidden (arch H-1b).
- **The merge coordinate is the captured `head_sha`, not the declared
  `work_item.hash` (D-361 / `[C121-B11]` resolution, PR #503).** When the Unit has
  a captured `data.head_sha` (the agent-asserted coordinate from `work_ready`, B8),
  `merge_fun` is invoked with that value as the `hash` argument, and `UnitDriver`
  builds the merge map `%{id: unit_id, hash: <captured head_sha>, run, branch:
  <captured branch>}`. The `hash` field is the **Ledger/CAS verdict coordinate**
  `(hash, run, half)` re-read by `assert_all_verdicts_live` at commit (SPEC-FACTORY-MERGE
  B9, `cas.ex`), NOT a content selector — the merge build already checks out
  `unit.branch` (`merge_authority.ex` `default_build`) and lands the branch tip.
  Coupling the verdict coordinate to the **same** `head_sha` the gate wrote its
  verdict under (B7 / Gate.Request) is what makes the live-verdict CAS a genuine
  guarantee about the commit actually pushed, rather than a check against a
  fiction. **Fallback (D-363):** when `data.head_sha` is `nil` (legacy 2-tuple
  seam or a back-compat caller), `merge_fun` receives the declared
  `work_item.hash` unchanged — the existing behaviour.
- M owns INV-1..4 / D-300..D-303 and the *emission* half of the result delivery
  (MERGE D-356 — broadcast to `"factory:pr:#{id}"`); U owns the *consume* half
  (**D-356**, this SPEC). U only submits and consumes the result; it never
  mutates the train.
- **Subscribe-before-request ordering (D-356, the load-bearing contract).**
  Phoenix.PubSub is **at-most-once with no replay**: a `{:merge_result, _}`
  broadcast that fires before U's subscription exists is **lost**, and U then
  hangs in `awaiting_merge` until `state_timeout` → spurious escalation. To
  eliminate the race, on entering `awaiting_merge` U MUST, **in this order**:
    1. `Phoenix.PubSub.subscribe(Tau.PubSub, "factory:pr:#{unit_id}")` — and only
       after this returns `:ok`;
    2. invoke `merge_fun` (→ `MergeAuthority.request_merge/2`).
  Because `subscribe/2` is a synchronous local-registry write that *completes
  before* `request_merge` is issued, and M's broadcast happens strictly later
  (after the minutes-long build, in `:committing`), the subscription provably
  exists at every possible publish instant. The single shared `Tau.PubSub`
  instance (no second pubsub — D-184 analog) guarantees publisher and subscriber
  share one registry. **Requesting the merge before subscribing is forbidden.**
  This ordering sits on the `:none` branch of the D-355 reconcile-on-entry (B3):
  reconcile reads the durable Ledger first; only when it returns `:none` (no
  prior outcome) does U subscribe-then-request. The `:merged`/`:rejected`
  reconcile branches never reach `merge_fun`, so they never subscribe.
- **Consume + unsubscribe-on-exit (D-356).** U consumes
  `{:merge_result, :merged}` (→ terminal `merged`) and `{:merge_result,
  :rejected}` (→ re-gate, INV-2) directly off its mailbox from the topic — **no
  driver-side telemetry→Unit bridge** (forbidden by MERGE D-356; it re-creates
  the very lost-event hazard the ordering above closes). U **unsubscribes** from
  `"factory:pr:#{unit_id}"` on **every** exit from `awaiting_merge` (to `merged`,
  to `gating` on `:rejected`, or to `escalated` on `state_timeout`). A late or
  duplicate broadcast arriving after unsubscribe is harmless — no subscriber, so
  PubSub drops it; this is what makes the re-gate → re-enter → re-subscribe cycle
  (INV-2) free of stale cross-excursion deliveries.

### B7: Unit (C6) ↔ Gate (G) — *cited, SPEC-FACTORY-GATE*

- `request_gate/4` / `gate_outcome` (`:pass` | `{:fail, findings}`). The gate is
  the only legal producer of a verdict (G appends to L per B3 / D-335). G owns
  D-304..D-308, D-322, D-323.
- **The gate keys on the captured `head_sha` (D-361 / `[C121-B11]`, PR #503).**
  The Unit's `:gate_fun` seam is **arity-1**: `(coordinate :: String.t() -> :pass |
  {:fail, findings})`. The Unit supplies the coordinate
  (`data.head_sha || data.hash`) at the `gating` state entry, symmetric with the
  merge coordinate in `awaiting_merge` (D-361). The closure MUST use the received
  coordinate as `Request.hash` — the agent-asserted `head_sha`, NOT the declared
  `work_item.hash`. `Request.hash` is the `(hash, run, half)` verdict coordinate
  the gate appends to L (Gate.Request docstring; SPEC-FACTORY-GATE B1); keying it
  on the actual commit is what makes the verdict refer to the agent's real work.
  The gate **content** is already the branch tip (the harness builds the gate
  workspace via `git worktree add --detach <branch>`, `dogfood/gate_fun.ex`), so
  this change aligns the verdict *label* with the content the gate already ran on.
  **Fallback (D-363):** when `data.head_sha` is `nil`, the Unit passes the declared
  `work_item.hash` as the coordinate (nil-fallback symmetric with merge).

### B8: Unit (C6) ↔ Worker fleet (W) — *cited, SPEC-FACTORY-FLEET*

- `spawn(role, brief, ref)`; U holds a `Process.monitor/1` ref for liveness. W
  surfaces the **disjoint** `worker_event` set, all keyed by `worker_id`, which U
  consumes (U `E_in`): `work_ready(w, branch, head_sha)` (**success** — the agent
  asserted a stable diff in-band; the sole trigger of `implementing → gating`),
  `worker_exit(w, reason)` (the `:DOWN` death certificate — infra path,
  gate NOT called), and `worker_stalled(w)` (the watchdog's synthetic
  heartbeat-absence trigger, [C107]). U tags the **current** `worker_id` and
  discards events from a superseded worker. Clean Port exit (`:exit_status 0`)
  without `work_ready` is NOT completion — it arrives as
  `worker_exit(w, :no_work_product)` (**D-326, cited owner: SPEC-FACTORY-FLEET**).
  W owns isolation/capture D-309..D-311, D-313, D-314, D-316 and the completion
  contract D-326.
- **Heartbeat-driven liveness — consume half (GOV4, D-377/D-378/D-379).** Beyond
  the three disjoint *outcome* events above, W forwards a fourth `worker_id`-keyed
  signal the Unit consumes: `worker_heartbeat(w)` — the live progress pulse the
  Worker forwards from D-366 shim frames. The Unit re-arms its waiting-state
  `:state_timeout` on every current-worker `worker_heartbeat(w)` (**D-377**), so a
  progressing real agent never trips the fixed cap; the cap becomes a *per-heartbeat
  inactivity deadline*, not an absolute run-duration cap. The Unit ALSO consumes
  the Watchdog's `worker_stalled(w)` (the heartbeat-absence trigger, D-317): the
  fleet wiring registers each spawned worker with the `Watchdog`, addressed to the
  owning Unit (**D-379**).
- **ONE symmetric worker-outcome rule for BOTH worker-awaiting states (GOV4
  re-shape, D-378).** `oracle` and `implementing` are the two states that await a
  worker, and they MUST handle the worker-outcome signal set **identically** —
  divergence between them is forbidden. The single rule table is:

  | signal (for the **current** `worker_id`) | outcome | re-enters |
  |---|---|---|
  | `work_ready(w, branch, head_sha)` | success: capture coord (D-362), advance | oracle→implementing; implementing→gating |
  | `worker_exit(w, reason)` (semantic death-cert: `:no_work_product` / `:error` / `{:exit_status, _}`) | **retry ladder** (gate NOT called) | **the originating waiting state** |
  | `worker_stalled(w)` (Watchdog heartbeat-absence) | **retry ladder** (gate NOT called) | **the originating waiting state** |
  | `worker_heartbeat(w)` | reset `:state_timeout`; stay (D-377) | — |
  | `:DOWN` with `worker_id == nil` (legacy 2-tuple seam only) | `escalate(E_WORKER_DOWN)` | — (terminal) |

  Plus two state-level rules, identical in both states:
  - Unit's **own** `:state_timeout` (real `gen_statem` timer; fires only on total
    heartbeat silence past the cap) → `escalate(E_WORKER_STALLED)` (the hard-stall
    path; gate NOT called; preserves #490/D-326).
  - Any of the above signals for a **superseded** `worker_id` (`_other_id`) →
    stale-worker discard (`keep_state`); advances nothing.

  The "originating waiting state" rule is load-bearing: a stalled/exited
  test-author re-enters **`oracle`** (re-runs the test-author), NOT `implementing`
  — re-spawning the wrong role would skip oracle-separation. The shared
  `advance_retry_ladder/2` therefore takes the originating state and re-enters it
  via `{:next_state, <that state>, …, [{:next_event, :internal, :on_enter}]}`,
  whose `:on_enter` already bumps `attempt_count` and writes a Ledger snapshot
  (D-315 RPO=0). There is **no separate `:deferred_spawn` / `do_spawn_worker`
  path** — the plain ladder's `:next_state` transition is the re-spawn (see D-378).

  **Collapse to exactly-one (D-378).** The Unit's own `:state_timeout`, the
  Watchdog's `worker_stalled`, and the dispatcher's `:inactivity_timeout_ms` →
  `worker_exit` collapse to **exactly one** outcome per worker per state: the first
  stall-class signal consumed clears `data.worker_id` (and `:demonitor`s), after
  which every other stall-class event for that superseded `worker_id` hits the
  stale-worker discard clause. The Watchdog's `heartbeat_timeout` and the Unit
  `state_timeout_ms` share one `:unit_timeouts`-derived threshold (D-358) so the
  two detectors cannot disagree.
- **Pinned Unit seam (D-326 / PR #468 amendment).** The `worker_fun` injectable
  returns `{:ok, worker_pid :: pid(), worker_id :: String.t()}` (3-tuple) for
  D-326-aware workers; the Unit stores `data.worker_id` (test-observable via
  `:sys.get_state/1`) and gates `implementing → gating` ONLY on
  `{:work_ready, ^worker_id, _, _}` — discarding `{:work_ready, other_id, _, _}`
  (stale-worker events, B8 invariant). The legacy 2-tuple `{:ok, worker_pid}`
  form is preserved for back-compat but does NOT carry a `worker_id` — the
  `data.worker_id` field is `nil` in that path and the Unit falls back to the
  `{:worker_done, ^worker_pid}` trigger.
- **Capture the asserted coordinate on `work_ready` (D-362 / `[C121-B11]`, PR #503).**
  On the matching `{:work_ready, ^worker_id, branch, head_sha}` transition (from
  BOTH `oracle → implementing` and `implementing → gating`), the Unit MUST write
  the asserted pair into its data: `%{data | branch: branch, head_sha: head_sha}`
  (the exact clause shown in arch `control-plane.md` §3.2.1). These fields are
  test-observable via `:sys.get_state/1`. The capture is on the **current**-worker
  clause only; the stale-worker discard clause (`{:work_ready, _other_id, _, _}`)
  captures nothing. `head_sha`/`branch` initialise to `nil` and are non-`nil` only
  after a `work_ready` from the current worker. The captured `head_sha` is the
  coordinate the gate (B7 / Gate.Request `hash`) and the merge (B6 / merge-map
  `hash`) key on — see D-361. **Back-compat (D-363):** the legacy 2-tuple
  `{:worker_done, ^worker_pid}` completion carries no `branch`/`head_sha`, so
  `data.head_sha` stays `nil` and both the gate and merge seams fall back to the
  declared `work_item.hash` exactly as before.
- **`:janitor` threading — reclaim is the Janitor's, not the driver's
  (PR #477 amendment; PR #479 cleanup; cross-refs SPEC-FACTORY-FLEET D-313/D-314).**
  The `UnitDriver.drive/2` seam threads `:janitor` into the `worker_fun`'s opts
  so it reaches `WorkerSupervisor.spawn/5` (the `:janitor` opt seam) and the
  spawned `Tau.Factory.Worker`, which **registers itself** with the janitor in
  `init/1` (passing its own `ws`, `ns_dirs`, `report_to`) before opening its
  Port. The janitor is resolved as `deps[:janitor] || Tau.Factory.WorkspaceJanitor`:
  the singleton `WorkspaceJanitor` (always registered under its module name) is
  the production default; the `:janitor` dep key is a **test-injection seam**
  (pass the running singleton module atom to name it explicitly in tests). The
  janitor `Process.monitor/1`s the worker (never links) and on the worker's
  `:DOWN` — for ANY exit reason — executes capture-before-destroy and reclaims
  the worktree (D-313/D-314). Consequently the UnitDriver performs **zero
  worktree reclaim of its own**: no driver-side worktree-path computation, no
  synchronous reclaim in `merge_fun`, no reclaim-on-`:DOWN` bridge. Driver-side
  reclaim is **forbidden** — it duplicates the janitor's sole ownership of the
  capture-before-destroy sequence and races it on the `:DOWN`.
- **Oracle detached-checkout — no branch lock (P5c-7 amendment; relates D-313/D-314).**
  The oracle (test-author) Worker is spawned at a **detached HEAD** checkout of
  `oracle_base_ref` (the `UnitDriver` opt; default: `work_item.base_ref`; the
  dogfood/real driver sets it to `"origin/<branch>"`). A detached checkout holds
  **no named-branch lock**, which allows the later implementing Worker to call
  `git worktree add … <branch>` without conflict (a named branch may be checked
  out in only one worktree at a time). The `oracle_base_ref` is threaded from
  `UnitDriver.drive/2` → `to_unit_work_item/3` → the worker spawn opts, making
  the checkout strategy a driver-injectable seam rather than a hard-coded
  worktree policy. The precondition on `origin/<branch>` existing is recorded in
  §3 [C123-B8].

### B9: KillSwitch (C9) ↔ Coordinator (C3)

- `:halt_requested` broadcast on PubSub `"factory:control"`; K sets
  `halt_pending` and acts at the next `unit_terminal` (**D-321**). The sentinel
  is operator state (git-ignored), never project state.

### B10: Coordinator (C3) ↔ external tracker

- `select_next` reads open issues (smallest shippable increment, arch FR-2.1);
  `reconcile` is a read-only projection used to discharge CON-2 (D-331). The
  tracker is never a second writer of L.

**Amendment (PR #470 / B10):** pins the `IssueSelector` contract that
implements `select_next`:

- **Entry point:** `Tau.Factory.IssueSelector.select(opts :: keyword()) ::
  work_item | nil`.
- **opts:** `:ledger` (`GenServer.server()` — running `Ledger.Writer`, read-only
  projection source); `:milestone` (`String.t()`); `:gh_fun`
  (`(String.t() -> {:ok, [issue_map]})` — stubbable read-only `gh` adapter;
  `issue_map` carries at minimum `"number"` and `"title"` keys; NO network in
  tests). Follows the codebase's canonical `*_fun` injection pattern.
- **`unit_id` derivation:** `"unit-<number>"` — a stable, issue-number-derived
  id ensuring the L-projection aligns with the ids the rest of the factory
  snapshots under (D-331 [C112-B10]).
- **`work_item` shape:** `{issue, scope, hash, branch}` — a 4-tuple where
  `scope` is a non-nil frozen declared scope string, `hash` is a non-empty
  content-hash string, and `branch` is a non-empty feature-branch name string.
  `issue` carries the issue number (at minimum as `"number"` key).
- **Return:** `work_item` when an open, non-terminal-in-L issue exists; `nil`
  when the milestone is drained or every open issue is terminal in L (D-342).
- **L is read-only:** the selector NEVER writes L; the tracker is not a second
  writer of L (D-331 [C112-B10]).

**Amendment (PR #505 / B10, I2 — issue → declared-scope elaboration; D-369, D-370, D-371).**
The PR #470 amendment above pins `work_item.scope` as a *non-nil frozen declared
scope string* — adequate for the stubbed-`gh_fun` idle path (P5c-6, D-357), but
**not** a `ConflictCheck.scope()` (`%{deps, files, codepoints, specs, resources}`
— §4 B2, `conflict_check.ex`). A real milestone issue must be *elaborated* into a
structured declared scope before `Scheduler.admit/3` can run the five-clause
check on it. This sub-section pins that elaboration contract; it is disjoint from
the B11 supervisor/seam contract that follows.

- **The shape gap being closed (a latent type error).** Today `IssueSelector`
  emits `scope` as the string `"#{number}: #{title}"`. `Scheduler.admit/3` passes
  it verbatim to `ConflictCheck.clear?/2`, whose clauses call
  `Map.fetch!(declared_scope, :files)` etc. A string therefore **crashes** the
  predicate — the seam is sound today only because no test wires a real
  string-`scope` work-item into a real Scheduler. The elaboration is what makes
  `IssueSelector → Scheduler → ConflictCheck` type-correct and admission-correct
  on a real issue. **[C124-B10]**

- **The elaboration function (the seam).** `IssueSelector` derives the structured
  scope through an injected, **pure** seam — the established `*_fun` pattern,
  mirroring `:gh_fun`:

  ```
  :elaborate_fun — (issue_map -> ConflictCheck.scope())   # default: the conservative heuristic below
  ```

  `select/1` builds `work_item = {issue, declared_scope, hash, branch}` where
  `declared_scope = elaborate_fun.(issue)` is a `ConflictCheck.scope()` map (no
  longer a string). The seam is injected so the soundness posture is testable
  with deterministic fixtures and so a future, stronger elaborator (LLM-assisted —
  see the discriminating question, §3 / D-370) can be swapped without touching the
  Scheduler or the conflict-check. **[C125-B10]**

- **The default elaborator is a CONSERVATIVE, citation-driven heuristic.** It
  reads only **machine-checkable** signals already present in the `issue_map`
  (`"title"`, `"body"`, `"labels"`) and the in-repo SPEC source-maps; it does NOT
  call an LLM on the admission path. Concretely it harvests:
  - **`files`** — file paths the issue body cites verbatim (paths matching a
    repo-relative `lib/…`, `test/…`, `web/…`, `docs/…` shape) **plus** every file
    named by the Appendix-B source-map of each SPEC the issue cites.
  - **`specs`** — `SPEC-*.md` ids cited in body/labels; the `no-shared-SPEC`
    clause already folds the shared-D-NNN-block check (§4 B2), so a cited SPEC
    covers both.
  - **`codepoints`** — `{path, region}` pairs only where the issue cites
    `file:line` / `file#function`; absent citations contribute **no** codepoint
    narrowing (see soundness, below).
  - **`resources`** — declared from labels / known-resource keywords (e.g. a
    `burrito` / `smoke` label ⇒ the shared-`$HOME` cache resource of
    `worktree-discipline.md`).
  - **`deps`** — in-flight unit-ids named by `blocked-by:` / `depends-on:`
    references in the body. **[C126-B10]**

- **Soundness posture — conservative over-declaration with serialize-on-uncertainty
  (the load-bearing decision, V1/V3).** The conflict-check's safety (D-312) holds
  **iff declared scopes are sound** — a scope that *omits* a file two units truly
  share lets the Scheduler admit them in parallel and corrupt each other (the V3
  orphan-invariant failure: `ConflictCheck` is the sole enforcer of conflict-gated
  admission, but it can only enforce over what it is *told*). No mechanism can
  derive a *provably complete* file/codepoint set from free issue text (V1 — that
  is the static-impact-analysis impossibility in disguise). The contract therefore
  does **not** assume completeness; it makes the *consequence of incompleteness*
  safe:
  - **Over-declare, never under-declare.** When the heuristic is uncertain whether
    a file/codepoint belongs in scope, it **includes** it. A false *inclusion*
    only costs throughput (an unnecessary `{:defer, …}` — two units serialize that
    could have run in parallel); a false *exclusion* costs *correctness* (two
    conflicting units run concurrently and corrupt shared files). The cost
    asymmetry is the whole argument: **throughput is cheap and reversible; a
    missed conflict is a corrupting, expensive defect.** **[C127-B10]**
  - **Coarsen codepoints to whole files when uncertain.** An issue that cites a
    file but no `file:line` yields a *whole-file* `files` entry, **not** a narrow
    `codepoints` entry. Codepoint-level narrowing (the parallel-on-disjoint-regions
    optimisation) is admitted **only** on explicit `file:line` citation, where the
    burden of proof is discharged by the human author. Absent that, the unit
    serialises against any other unit touching the file. **[C128-B10]**
  - **Fallback-to-serialize on an empty elaboration.** If the heuristic extracts
    **no** files and **no** specs (an issue too vague to scope), `elaborate_fun`
    returns the **universal-conflict sentinel scope** — a scope that
    `pairwise_clear?` rejects against *any* non-empty in-flight member — so the
    unit is admitted **only when `F` is empty** (it runs alone). It is never
    silently treated as disjoint-from-everything. This makes "we could not scope
    it" resolve to *serialize*, never to *risk a collision*. **[C129-B10]**

- **Coupling to #492 (real `gh issue list`).** This contract is **independent of**
  the `gh_fun` real-network adapter (#492): elaboration consumes the `issue_map`
  whatever its source (stub or real `gh --json number,title,body,labels`). #492
  only populates the `issue_map`'s real fields; the `body` / `labels` keys the
  heuristic reads are already in the §4 B10 `--json` projection. No ordering
  dependency in either direction — referenced, not implemented here.

**Amendment (PR #508 / B10, A2 — brief/issue → prompt assembler; D-372, D-373).**
The B10 amendment above turns the issue into a *declared scope*; this amendment
turns the issue (and its full context) into the *agent's prompt*. The two are
disjoint intake projections of the same `work_item`: the elaborator feeds the
Scheduler's admission predicate (a `ConflictCheck.scope()`); the assembler feeds
the agent's task (a `task.prompt :: String.t()`). This sub-section pins the
assembler contract.

- **The gap being closed.** `to_unit_work_item/1` (`lib/tau/factory/supervisor.ex`)
  sets `brief: title` — the brief carried to the Worker is only the issue title;
  the shim's `task.prompt` is the hardcoded empty string
  (`coding_agent_shim.ex` Runner: `task = %{prompt: "", workspace: ws, …}`). The
  scripted Replay agent ignores the prompt, so the dogfood "works" only because no
  real agent is in the loop. A real agent (A1, `Tau.CodingAgents.ClaudeCode`) needs
  a real prompt. **[C131-B8]**

- **The assembler component (the seam).** `Tau.Factory.BriefAssembler` is a plain
  pure functional module (no GenServer — OTP non-negotiable §3). It exposes the
  assembly through an injected, **pure** seam mirroring `:gh_fun` / `:elaborate_fun`:

  ```
  Tau.Factory.BriefAssembler.assemble(input :: map(), opts :: keyword()) :: String.t()

  input :: %{
    required(:issue)            => map(),                  # issue_map: "number","title","body","labels"
    required(:declared_scope)   => ConflictCheck.scope(),  # the B10/I2 elaborated scope
    optional(:gating_test_paths)=> [String.t()],           # test-author's declared paths (factory-loop 4b)
    optional(:spec_refs)        => [String.t()],           # cited SPEC ids / AC-N / D-NNN tokens
    optional(:arch_pointers)    => [String.t()]            # docs/arch/04-software-architecture/* paths
  }

  opts:
    :assemble_fun — ((input) -> String.t())   # default: the heuristic template assembler (D-372)
  ```

  The injected `:assemble_fun` (D-373) follows the established `*_fun` pattern so a
  stronger, LLM-assisted prompt author is a *substitution*, not a rewrite — exactly
  as `:elaborate_fun` (D-370) makes the scope elaborator swappable. The default
  assembler is pure and network-free: it composes a labelled, section-structured
  Markdown prompt from the inputs already in the `work_item` plus the static arch
  pointers; it does NOT call an LLM on the assembly path.

- **Invocation point.** `Tau.Factory.Supervisor.to_unit_work_item/1` is the single
  assembly site: it already receives `{issue, scope, hash, branch}` from
  `IssueSelector` and constructs the `work_item` map. It replaces `brief: title`
  with `brief: BriefAssembler.assemble(%{issue: issue, declared_scope: scope, …})`.
  The assembled brief then rides the *existing* path unchanged — `UnitDriver.drive/2`
  → `WorkerSupervisor.spawn/5` → `Worker.init/1` → the shim — so no new boundary is
  introduced. The shim contract is extended (A1 wiring, not A2) so the Runner sets
  `task.prompt = brief` instead of `""`; A2 owns the assembler and the contract that
  `task.prompt` equals the assembled brief; the transport of the brief into the
  shim's baked config is the A1 implementer's wiring, deliberately not over-pinned
  here.

- **Composition contract (D-372).** Every input field present in `input` is
  consumed — appears, labelled, in the assembled prompt (V3: no machinery that
  enforces nothing; no stated input silently dropped). The issue body, the declared
  scope, the gating-test paths, the SPEC/AC/D-NNN refs, and the arch pointers each
  occupy a distinct labelled section. The arch-pointer section is mandatory and
  non-empty (it carries at least the `docs/arch/04-software-architecture/` root),
  discharging `feedback_brief_implementers_with_arch`.

- **Graceful-degradation / failure posture (D-373).** The assembler does NOT assume
  the issue text is complete (V1 — there is no impossibility hidden here: it
  composes the inputs it *has*, it does not infer the inputs it lacks). An absent
  optional input degrades to an explicit "(none declared)" marker in its section,
  never a crash and never a silently-omitted section. For any non-empty issue (a
  `"number"` and a `"title"`) the assembler returns a non-empty `String.t()`; it
  never raises on partial input and never returns `""`. Pre: `input` carries at
  least `:issue` (with `"number"`/`"title"`) and `:declared_scope`. Post: a
  non-empty prompt whose section set is a superset of `{issue, scope, arch}` and
  includes every *present* optional input.

### B11: `Tau.Factory.Supervisor` ↔ {`Tau.Application`, tests} — config-gated assembly + seam-threading (P5c-6, #474; D-357)

This boundary records (does **not** redesign) the assembly that
`docs/arch/04-software-architecture/supervision-tree.md` §3 specifies; the arch
file is authoritative on the **composition and internal start-order**, this
contract on the **gating layer and the option surface** on top of it. The
implementer conforms to both.

**Config key + default.**

```
config :tau, :factory, enabled: false   # default; opt-in is operator action
```

The flag is read **once at boot** by `Tau.Application` (mirroring the
established `Tau.OtelReporter` `:enabled` precedent — `otel_reporter_spec/0`),
not per-message. Reading it from `config` (compile/runtime config, not
`Application.put_env/3` runtime mutation) keeps it out of the
"runtime mutable state" anti-pattern (OTP non-negotiable #1). Default `false` ⇒
no Coordinator-bearing subtree on a normal boot (D-357, [C120-B11]).

**`start_link/1` option surface.** The supervisor accepts a *high-level seam*
option set and **derives** every per-child option from it; the caller does NOT
hand-thread per-child opts (no `coordinator_opts:` / `budget_opts:` /
`scheduler_opts:` from the caller for the gated full-subtree path):

```
Tau.Factory.Supervisor.start_link(opts) :: Supervisor.on_start()
  opts (full-subtree, enabled path):
    :enabled    — boolean();    request the gated full-subtree assembly
                                (defaults to the config gate when absent)
    :db_path    — String.t();   Ledger DB file (test: tmp-dir DB). Exposed
                                as `--db <path>` CLI flag in the dogfood task.
    :name       — atom();       this supervisor's registered name (test isolation;
                                per-supervisor child names are derived from it)
    :repo_dir   — String.t();   the real (or throwaway, in tests) git repo —
                                threaded to MergeAuthority and the worker fleet
    :milestone  — String.t();   the assigned milestone (→ IssueSelector)
    :gh_fun     — (String.t() -> {:ok, [issue_map]});  issue source, stubbable;
                                NO network in tests (B10 IssueSelector contract)
    :select_fun — &IssueSelector.select/1  (arity-1, opts-taking — see wrapping)
    :drive_fun  — &UnitDriver.drive/2      (arity-2 — see wrapping)
    :agent_bin  — String.t();   path to the worker agent executable each Worker
                                runs (the {:packet,4} D-326 agent). Threaded into
                                the assembled drive_fun deps. (P5c-7, #475.)
    :gate_fun   — (coordinate :: String.t() -> :pass | {:fail, [finding]}) | nil;
                                the per-unit gate seam (arity-1; the Unit supplies
                                the coordinate `data.head_sha || data.hash` at call
                                time — see "gate_fun completion" below, D-361).
                                nil ⇒ no real gate wired (the P5c-6 idle path drove
                                no unit). Threaded into the assembled drive_fun deps.
                                (P5c-7, #475.)
    :unit_timeouts — keyword();  per-state Unit timeout overrides threaded into
                                every driven Unit's :timeouts opt (default
                                [state_timeout_ms: 30_000]). Real agent runs need
                                T_unit ≫ 30 s (OQ-2) → the dogfood widens this so
                                a live agent run does not spuriously escalate
                                (D-358; see "Unit timeout widening" below).
                                (P5c-7, #475.)
```

**Completing the P5c-6 `:gate_fun` / `:agent_bin` deferral (P5c-7, #475).** P5c-6
left `deps.agent_bin` and `deps.gate_fun` as `nil` on the idle path (no unit was
driven on boot — D-357), with the #480 critic noting the deferral. This contract
closes it.

- **`:agent_bin`.** Threaded verbatim into the assembled `drive_fun` deps map's
  `:agent_bin`, which `UnitDriver.drive/2` puts into the worker spawn opts. The
  agent is the D-326 `{:packet,4}` executable that emits a `work_ready` JSON
  frame (`%{"type" => "work_ready", "branch" => …, "head_sha" => …}`) over its
  `Port` (cited B8 / SPEC-FACTORY-FLEET; `lib/tau/factory/worker.ex`
  `decode_event/1`).

- **`:gate_fun` — the arity contract and how it wraps `Gate.run/1`.** The
  **Unit's** `:gate_fun` seam is **arity-1** returning `:pass | {:fail,
  findings}` (`unit.ex`; called as `data.gate_fun.(coordinate)` in `gating/3`
  where `coordinate = data.head_sha || data.hash`, symmetric with `awaiting_merge`,
  D-361). The **real** gate is `Tau.Factory.Gate.run/1`, which takes a fully-built
  `%Tau.Factory.Gate.Request{}` and returns a `%Tau.Factory.Gate.Verdict{}`
  (cited B7 / SPEC-FACTORY-GATE §4 B1; `lib/tau/factory/gate.ex`). The
  supervisor/dogfood therefore builds a **request-bearing arity-1 closure** that
  adapts `Gate.run/1`-over-`Request` to the Unit's arity-1 seam. The closure uses
  the received coordinate (the captured `head_sha`, or declared `work_item.hash`
  via nil-fallback, D-363) as `Gate.Request.hash`:

  ```
  gate_fun = fn coordinate ->
    req = %Gate.Request{
      unit:         unit_id,        # work_item.unit_id
      diff:         diff,            # merge_base..HEAD unified diff in the gate workspace
      frozen_paths: frozen_paths,    # the declared gating-test path set (D-304)
      policy_pin:   policy_pin,       # admission-pinned policy (HR-8); in the dogfood a hermetic oracle pin
      workspace:    gate_workspace,   # a host-isolated checkout the engine reverts in (D-309)
      merge_base:   merge_base,       # `git merge-base origin/main HEAD` in the workspace
      hash:         coordinate,        # the captured head_sha (or declared hash via fallback, D-361/D-363)
      run:          run,               # the run identifier (work_item.run)
      ledger:       ledger              # the started Ledger.Writer (WAL-before-ack, D-335)
    }
    case Gate.run(req) do
      %Gate.Verdict{status: :pass}                  -> :pass
      %Gate.Verdict{status: :fail, halves: halves}  -> {:fail, failing_halves(halves)}
    end
  end
  ```

  **Where each `Gate.Request` field comes from at drive time.** `:unit`, `:run`,
  `:branch` are `work_item` fields (B10 IssueSelector / B6 merge-map). `:hash`
  (= `coordinate`) is the Unit-supplied runtime value (`data.head_sha || data.hash`).
  `:frozen_paths` is the declared gating-test path set frozen at scope-freeze
  (cited B7 / SPEC-FACTORY-GATE D-304). `:merge_base` is computed in the gate
  `:workspace` (`git merge-base origin/main HEAD`). `:workspace` is a
  host-isolated checkout the engine reverts `tracked ∖ frozen_paths` in for the
  mutation half (SPEC-FACTORY-GATE §3 HR-3, D-306); it is **not** the worker's
  own writable worktree — a separate clean checkout, so the revert never disturbs
  the worker. `:policy_pin` and `:ledger` are admission-/supervisor-level values.
  `:diff` is the unified diff between `:merge_base` and `:hash` in the workspace.

  **Constraint RESOLVED — head-SHA threading ([C121-B11], C1, PR #503; D-361,
  D-362, D-363).** *Originally recorded (P5c-7) as out-of-scope; now resolved.*
  The Unit consumes `work_ready(worker_id, branch, head_sha)` and now **captures**
  `branch`/`head_sha` into its data (D-362; `unit.ex` `implementing/3` and
  `oracle/3` current-worker clauses write `%{data | branch: branch, head_sha:
  head_sha}`). Both `gate_fun` (the arity-1 closure above — the Unit passes
  `data.head_sha || data.hash` as the coordinate, which the closure sets as
  `Request.hash`) and `merge_fun` (via the merge-map `hash`/`branch`) key on that
  captured agent-asserted `head_sha`, not the unit's pre-declared `work_item.hash`
  (D-361).
  For the dogfood the change is observably a no-op (D-363): the scripted agent's
  asserted HEAD == the declared `hash` by construction, so the captured and
  declared coordinates coincide. The fix is the strict refinement a
  non-deterministic agent requires — its real HEAD (unknowable before authorship,
  V1) is the coordinate the gate verifies and the merge CAS lands. The
  `head_sha = nil` fallback (legacy 2-tuple seam) retains the declared
  `work_item.hash` unchanged (D-363).

**Unit timeout widening (`:unit_timeouts`, OQ-2 → D-358).** The Unit arms a
single `:state_timeout_ms` (default `30_000`) on every external-actor-awaiting
state — `oracle`, `implementing`, `awaiting_merge` (`unit.ex`; arch
`control-plane.md` §3.2). A **real** agent run (`T_unit`) routinely exceeds 30 s
(OQ-2: `T_unit ≫ T_merge`, the binding `W_cap`/`B` input), so the default makes a
genuinely-working live agent trip `:state_timeout → :stall → retry ladder →
E-RETRY-EXHAUSTED` — a **spurious** escalation that misclassifies "still working"
as "wedged". The supervisor's `:unit_timeouts` opt is threaded into the assembled
`drive_fun` deps and onto every driven Unit's `:timeouts` (`[state_timeout_ms:
…]`); the dogfood widens it well past the scripted agent's worst-case run so the
single unit reaches `:merged` without a spurious escalation (D-358). This widens a
liveness *bound*, not the liveness *guarantee*: the timeout still fires —
eventually — on a genuinely-wedged worker; it is set above `T_unit`, not removed.
**GOV4 refinement (D-377).** The per-state `:state_timeout` is additionally
**reset on every current-worker `{:worker_heartbeat, w}`** (the D-366 progress
pulse), so it is a *per-heartbeat inactivity deadline*, not an absolute
run-duration cap. With D-377 the cap need only exceed the *gap between two
progress pulses* (seconds), not the whole `T_unit` (minutes); a progressing real
agent never trips it, and a wedge (no pulses) trips it within one deadline window
— removing the D-358 tension where widening to avoid spurious kills also blunted
wedge detection.

**Gated assembly (enabled path).** When the gate is on, the supervisor assembles
the full control subtree in the `supervision-tree.md` §3 order — PubSub up first
(the shared `Tau.PubSub`, never a second instance), then
`Ledger.Writer → Budget.Owner → Scheduler → MergeAuthority → UnitRegistry /
UnitSupervisor → worker fleet (`WorkerSupervisor` / `WorkerRegistry` /
`WorkspaceJanitor` / fleet `Watchdog`) → KillSwitch → **Coordinator (LAST)**`.
The internal relative order of the spine children is the arch file's to fix; the
**Coordinator-LAST** placement is invariant in both this contract and the arch
(it depends on every sibling — D-344 resume reads the started Ledger; its
seams reference the started fleet/merge/registry processes). When the gate is
**off** (default), the supervisor assembles **no** Coordinator-bearing subtree
(today's ledger-and-below behaviour); `Process.whereis(Tau.Factory.Coordinator)`
is `nil` (D-357).

**Seam-derivation rules (the supervisor derives; the caller does not).**

- **Ledger threading (D-344).** The started `Ledger.Writer`'s (per-supervisor
  derived) name is threaded as the Coordinator's `:ledger` so `init/1` resumes
  from L, and into the assembled `drive_fun` deps (`:ledger`) so Units snapshot
  durable state (D-318/D-355).
- **`select_fun` wrapping.** The injected `&IssueSelector.select/1` is arity-1
  over `opts`, but the Coordinator's `:select_fun` is arity-0
  (`(-> work_item | nil)`). The supervisor wraps it into the arity-0 form,
  binding `IssueSelector.select(ledger: <writer>, milestone: <milestone>,
  gh_fun: <gh_fun>)` (B10 IssueSelector opts). In tests `gh_fun` returns
  `{:ok, []}`, so the wrapped selector yields `nil` and the Coordinator **idles**
  in `:running` — driving no uncontrolled work (D-357 idle property).
- **`drive_fun` wrapping.** The injected `&UnitDriver.drive/2` is arity-2
  (`work_item, deps`), but the Coordinator's `:drive_fun` is arity-1. The
  supervisor wraps it into the arity-1 form, binding the assembled `deps` map
  (the started `:unit_supervisor`, `:unit_registry`, `:scheduler`,
  `:worker_supervisor`, `:worker_registry`, `:janitor`, the shared `:pubsub`,
  `:repo_dir`, `:agent_bin`, `:gate_fun`, `:merge_authority`, `:ledger`, and
  `:report_to` = the Coordinator) — see the UnitDriver `deps` contract (§4 B6/B8).
- **MergeAuthority threading.** `MergeAuthority` is started against the real
  `:repo_dir` and the shared `:pubsub` (D-356 result delivery on
  `"factory:pr:#{id}"`).

- Pre: `Tau.Settings` `data_dir/0` resolvable (the ledger DB path); the shared
  `Tau.PubSub` running (started above this subtree in `Tau.Application`).
- Post (enabled): the subtree is assembled in arch order; the Coordinator is a
  child started LAST and reaches `:running`; with a no-issues `gh_fun` it idles
  (`select_fun → nil`), holding no in-flight unit and spawning no `Unit`.
- Post (disabled / default): no Coordinator child exists; no work is driven.
- Invariant (**D-357**): a default boot starts no factory subtree.

## 5. State enumeration

### Coordinator (K) — `gen_statem`, `state_functions`

| State | Meaning | Entry | Exit |
|-------|---------|-------|------|
| `running` | The loop: select → admit → drive → next | start (resume from L) | global `e` → `halting`; per-unit `e` → stay (unit→escalated) |
| `halting` | Drain in-flight units to a clean checkpoint | global escalation or kill at a unit boundary | all units quiesced, `main` synced, `¬mid_merge` → `halted` |
| `halted` | Terminal; awaits operator / next milestone | drain complete | operator resumes / assigns |

`running` is the **only** non-progress-capable state; the totality argument
(D-317) is discharged there.

#### Coordinator `:ledger` start option and `init/1` resume semantics (D-344 / P5b)

`Coordinator.start_link/1` accepts an optional `:ledger` key:

```
:ledger — GenServer.server() | nil
```

When `:ledger` is present and non-nil, `init/1` performs a **durable resume**:

1. Calls `Ledger.Reader.latest_unit_snapshots(ledger)` to read the snapshotted
   state per `unit_id` at crash time.
2. **Rehydrates** each NON-terminal unit (state ∉ {`:merged`, `:escalated`}) by
   driving it forward — these units resume the loop at their snapshotted state.
3. **Skips** every unit already at a terminal sink (`:merged` / `:escalated`) —
   no work is re-done; exactly-once on resume (D-344 crux).
4. After rehydration the loop falls through to `select_fun` as normal.

The `running` state entry text "start (resume from L)" refers to this path
(D-344, D-315 / RPO=0). The `data` map carries a `rehydrated` key that
records which unit_ids were resumed (observable via `:sys.get_state/1`).

### Unit (U) — `gen_statem`, one per PR

```
state ∈ {planned, oracle, implementing, gating, refine_k, awaiting_merge, merged, escalated}

 planned ─admit(S)→ oracle ─test-author frozen→ implementing ─work_ready(w,branch,head_sha) ⇒ request_gate→ gating
                                                            (D-326: in-band success event keyed by worker_id; NOT exit 0)
   gating + :pass            → awaiting_merge ─M :merged→ merged (terminal)
   gating + {:fail,f}        → refine_k        (k<N → implementing; k=N → pivot → implementing; pivot red → escalated [E-RETRY-EXHAUSTED])
   awaiting_merge + M reject → gating          (re-gate; INV-2)
   {oracle,implementing,gating,awaiting_merge} + :state_timeout/worker_stalled → refine/pivot/escalate
   {oracle,implementing} + worker_heartbeat(current w) → RESET :state_timeout (D-377; progressing agent never trips)
   any non-terminal + escalation(e) → escalated (terminal)
```

Illegal transitions are **unrepresentable** (no clause): e.g. `gating → merged`
directly cannot happen; an attempt crashes the FSM rather than merging an ungated
diff (INV-1). `merged` and `escalated` are terminal sinks. Every transition
`snapshot_unit/2`s durable state to L before its external effect (D-315, LIV-5).

### The total escalation set `E` (D-317)

| `e` | Trigger | Scope |
|-----|---------|-------|
| `E-AMBIGUITY` | irreducible spec/product ambiguity | per-unit |
| `E-RETRY-EXHAUSTED` | N refines + failed pivot | per-unit |
| `E-CONFLICT` | unresolvable merge conflict | per-unit |
| `E-DESTRUCTIVE` | destructive action requested (*cited, GOV/D-319*) | per-action |
| `E-BUDGET` | budget exhausted | global |
| `E-RED-MAIN` | post-merge health red (*cited, MERGE/D-303*) | global |
| `E-CHALLENGE` | > 2 upheld challenges on one PR | per-unit |
| `E-UNCLASSIFIED` | catch-all (any non-progress trigger) | global |

## 6. D-NNN invariants

> Owned by this SPEC. Each names its detection method. Cited D-NNN (merge/gate/
> fleet/gov) are enforced by their owner SPEC and only *consumed* here.

**D-312 — Conflict-gated admission is sound and monotone:**
`Scheduler` admits a unit iff `ConflictCheck.clear?/2` returns true over the
*declared* scope against the current `F`. The predicate is symmetric, self-
conflicting on non-trivial scope, **monotone in `F`** (adding to `F` only removes
admissions), every clause is necessary, and any shared gating-test path blocks.
Enforced by the property suite `conflict_check_property_test.exs` (properties
P-CC-1..5, tagged `:property`). A non-monotone or post-hoc-actual-path check
falsifies this and LIV-4.

**D-315 — Durable decisions, RPO=0:**
Every decision write commits to the SQLite WAL (`synchronous=FULL`) **before**
its `{:ok, ref}` reply, and its external effect happens only after the reply.
A coordinator killed immediately after a decision resumes from L with that
decision present exactly once (idempotency key) and no later decision lost.
Enforced by a crash test `ledger_durability_test.exs` (kill the writer between
commit and effect; assert exactly-once on resume) and the WAL-before-ack ordering
in `Ledger.Writer`.

**D-317 — Escalation is total over reachable states:**
(a) `Escalation.classify/1` is **total over `term()`** — its catch-all returns
`{:unclassified, :global}`; AND (b) every reachable non-progress state **emits a
trigger** within a bounded window — every U waiting state arms a mandatory
`:state_timeout` and a fleet watchdog synthesizes `worker_stalled` on heartbeat
absence. Together: no reachable state is both non-progress and unclassified.
Enforced by `escalation_property_test.exs` (classify totality, tagged
`:property`) **and** `unit_timeout_test.exs` (a wedged-worker simulation reaches
`escalated`, not a spin). Both halves are required — classifier totality alone is
insufficient (arch final-validation H-2).

**D-318 — Retry is bounded and laddered:**
`Retry.next/3` yields `{:refine,k}` only while `k < N` (`N = min(policy,
ceiling)`; ∞ rejected), then `:pivot` once, then `:exhausted`. The attempt count
is durable PR state; total attempts ≤ `N_refine + N_pivot`. Enforced by
`retry_property_test.exs` (no input sequence exceeds the bound; tagged
`:property`) and the durable `units.attempt_count` column.

**D-320 — Budget ceiling is a hard pre-admission gate:**
`budget_precheck/1` denies admission at the ceiling **before** the unit becomes
billable; recorded spend never exceeds budget by more than one in-flight action;
exhaustion raises `E-BUDGET`. Enforced by `budget_admission_test.exs` (drive
spend to the ceiling; assert the next admission is denied and `E-BUDGET` fires).

**D-321 — Clean kill at a unit boundary:**
A kill sets `halt_pending`; the loop transitions to `halting` only at the next
`unit_terminal`, completing that unit's terminal fold (incl. any merge + sync)
first; `halting → halted` fires only with `main` synced and `¬mid_merge`.
Worst-case latency is one unit. Enforced by `kill_switch_test.exs` (kill mid-unit;
assert halt occurs after the unit, `main` synced, never mid-merge).

**D-330 — Work conservation:** every accepted unit reaches exactly one terminal
state; `accepted = merged ⊎ escalated ⊎ rejected ⊎ in_flight`. Enforced by the
reconciliation pass `reconcile_test.exs` (no unit in zero or two terminal sets).

**D-331 — Issue reconciliation:** `state_tree(i) ≡ state_tracker(i)` for every
in-scope issue; `|steps_recorded| = |steps_executed|`. Enforced by
`reconcile_test.exs` against a tracker snapshot.

**D-332 — Budget conservation:** `Σ recorded_action_cost = total − remaining` at
all times (single-writer double-entry). Enforced by a ledger balance assertion in
`budget_admission_test.exs`.

**D-333 — Cost attribution:** every spend has exactly one owner (step/agent/gate
run); `Σ attributed = total_spent`. Enforced by `cost_attribution_test.exs`.

**D-334 — Artifact conservation (CITED — owned by SPEC-FACTORY-FLEET):** a
terminated worker's dirty state is `committed ⊎ captured ⊎ discarded-by-decision`
— never lost by omission. The **capture mechanism is FLEET's `WorkspaceJanitor`
(D-314)** and FLEET owns the CON-5 invariant; CORE's role is only that **the
Ledger records the disposition**, audited by the join in `reconcile_test.exs`.
Listed here as a consumed contract, not a CORE-owned D-NNN.

**D-335 — Verdict conservation (append-only):** a unit is `merged` only with a
fresh PASS verdict per required gate half for its exact `hash`; verdicts are
immutable per `(hash, run)`, a revoke is a superseding insert. Enforced by the
partial unique index migration and `verdict_append_only_test.exs` (attempt to
update a verdict ⇒ no update path exists; latest-status query returns the
superseding row).

**D-336 — Escalation conservation:** every raised escalation is delivered to the
operator and recorded with reason + state snapshot; none is raised-and-swallowed.
Enforced by `escalation_delivery_test.exs`.

**D-340 — Unit termination (liveness):** under fair scheduling every accepted
unit ◇ reaches `merged \| escalated \| rejected`. Discharged by D-318 (bounded
retry) + D-317 (total escalation). Enforced by a model-style test
`unit_termination_test.exs` driving each failure path to a terminal sink.

**D-342 — Milestone termination (liveness):** the assigned milestone ◇ reaches
zero open issues ∨ escalated. Discharged by D-340 per issue + D-331. Enforced by
an integration test over a synthetic milestone.

**D-343 — No livelock (liveness):** the Scheduler's admission is monotone (D-312
P-CC-3) and the scope-amendment path re-admits as a fresh monotone decision; no
reachable admit→withdraw→re-admit cycle. Enforced by `conflict_check_property_test.exs`
(monotonicity) + `scope_amendment_test.exs`.

**D-344 — Recovery progress (liveness):** after a coordinator crash the loop
resumes from L and continues; in-flight units rehydrate at their snapshotted
state; no terminal work is re-done. Enforced by `coordinator_recovery_test.exs`
(kill the Coordinator mid-drive; assert resume + idempotent rehydrate).

*Amendment (PR #465 / D-355):* a Unit resuming at `:awaiting_merge` reconciles
against the durable merge-outcome (via `Ledger.Reader.merge_outcome_for/2`) on
re-entry **before** calling `merge_fun` — so a merge that already landed is
never re-submitted on crash-resume. This closes the lone RPO=0 hole identified
by PR #465 (the ephemeral-telemetry-only outcome path). D-355 (owned by
SPEC-FACTORY-MERGE §6) is the invariant enforcing the write ordering; D-344
consumes it to guarantee no double-submit on resume.

**D-356 — Merge-result delivery, U's consume half (subscribe-before-request, no
lost event):** When U enters `awaiting_merge` and the D-355 reconcile returns
`:none`, U subscribes to `"factory:pr:#{unit_id}"` on the shared `Tau.PubSub`
**before** invoking `merge_fun` (→ `request_merge`), so the at-most-once,
no-replay broadcast M emits later (MERGE D-356) can never be lost to a
subscribe-after-publish gap; U consumes `{:merge_result, :merged | :rejected}`
directly off its mailbox (no driver telemetry bridge), and **unsubscribes on
every exit** from `awaiting_merge`. The emission half is MERGE D-356 (one
invariant, two enforcers; §4 B6). Enforced by `unit_merge_result_test.exs`
(oracle-separated): a `{:merge_result, _}` broadcast on `"factory:pr:#{id}"`
published immediately after — and even concurrently with — `request_merge`
reaches U and drives it to terminal, with no `state_timeout` escalation; and U
holds **no** subscription to the topic after leaving `awaiting_merge`.

**D-357 — Factory OFF by default (no uncontrolled work on normal boot):**
The factory control subtree is gated on `config :tau, :factory` `:enabled`
(default `false`, read once at boot — [C120-B11]). (a) On a default boot
`Tau.Application` starts **no** Coordinator-bearing subtree:
`Process.whereis(Tau.Factory.Coordinator)` is `nil` and no `Unit` is admitted.
(b) When `Tau.Factory.Supervisor.start_link/1` is invoked with the gated
full-subtree assembly (enabled), it assembles the subtree in the
`supervision-tree.md` §3 order with the Coordinator started LAST, threading the
started Ledger as `:ledger` (D-344) and wrapping the `select_fun`/`drive_fun`
seams (B11); a no-issues `gh_fun` keeps the Coordinator **idle** in `:running`
with no in-flight unit. Enforced by `factory_supervision_test.exs` — Test A
(enabled assembly + idle property) and Test B (default-OFF regression guard).

**D-358 — Unit timeout widening for real agent runs (OQ-2):** The Unit's single
per-state `:state_timeout_ms` (default `30_000`, armed on `oracle` /
`implementing` / `awaiting_merge` — arch `control-plane.md` §3.2) is **operator-
overridable** via `Tau.Factory.Supervisor.start_link/1`'s `:unit_timeouts` opt
(`[state_timeout_ms: …]`), threaded into the assembled `drive_fun` deps and onto
every driven Unit's `:timeouts`. Because a real agent run `T_unit` routinely
exceeds 30 s (OQ-2 — the binding `W_cap`/`B` input), the default would make a
genuinely-working live agent trip the stall path and escalate
`E-RETRY-EXHAUSTED` spuriously; the dogfood widens the bound well past the
scripted agent's worst-case run. This widens a liveness *bound* (the timeout
still fires on a genuinely-wedged worker, just above `T_unit`), never removes the
liveness *guarantee*. Enforced by `dogfood_e2e_test.exs` (a widened-timeout drive
reaches `:merged` with no `:state_timeout` escalation) — `@tag :integration`.

**D-359 — Dogfood sandbox origin MUST be local; the harness hard-refuses a
non-local origin (safety, [C122-B11], V1):** `mix tau.factory.dogfood` drives the
**real** control plane against a **THROWAWAY local sandbox**. Its `origin` MUST
be a **local bare repo** (a `file://` URL or a filesystem path to a bare git
repository on the same host). The task **hard-refuses** a non-local origin
(`https://` / `git@` / `ssh://` — any scheme implying a network remote) **before**
booting the factory subtree: it resolves the sandbox repo's `remote.origin.url`,
rejects (non-zero exit, no boot) any URL that is not a local bare-repo path/URL,
and only then assembles the (enabled) subtree against the local `:repo_dir`.
MergeAuthority — the **sole writer of `origin/main`** (cited B6, MERGE §3) — then
force-pushes only into that local bare repo. The guard is a **precondition**, not
a runtime classification, so a misconfiguration can never point the autonomous
force-pushing loop at a real GitHub remote. Enforced by the safety-guard unit
test (a non-local origin → hard refusal, factory not booted) and by
`dogfood_e2e_test.exs` driving against a local bare-repo sandbox.

**D-361 — Unit-coordinate identity: the gate/merge coordinate is the
agent-asserted `head_sha`, not the pre-declared `work_item.hash` ([C121-B11], C1,
PR #503):** The pre-declared `work_item.hash`
(`IssueSelector.content_hash/2 = sha256("N:title")`) is fixed **before** the agent
runs and is therefore unrelated to the commit the agent actually authors — for a
non-deterministic agent, no value computable before authorship can equal the
HEAD SHA of an unauthored commit (V1: assumes an impossibility). The agent is the
sole authority for its output, asserted in-band as `work_ready(w, branch,
head_sha)` (B8, D-326). Therefore, when the Unit holds a captured non-`nil`
`data.head_sha` (D-362), the **gate-Request `hash`** (B7) and the **merge-map
`hash`** (B6) MUST both be that captured `head_sha`, and the merge-map `branch`
MUST be the captured `branch`. The `(hash, run, half)` Ledger/CAS verdict
coordinate (B3; `assert_all_verdicts_live`, SPEC-FACTORY-MERGE B9) is thereby
keyed on the **same** commit the gate ran its verdict against — closing the
two-writers/one-truth gap (V4) in which the verdict label (declared hash) and the
landed content (branch tip) were decoupled, making the live-verdict CAS a check
against a fiction. Production **content** was already the branch tip on both the
gate (`git worktree add --detach <branch>`) and the merge build (`git checkout
unit.branch`) paths; D-361 aligns the *coordinate* with that content. Enforced by
an oracle-separated gating test asserting the gate-Request `hash` and the merge
map `hash`/`branch` equal the asserted `work_ready` `head_sha`/`branch`, not the
declared `work_item.hash`.

**D-362 — Capture the asserted coordinate on `work_ready` (the FSM-data
contract, PR #503):** On the matching `{:work_ready, ^worker_id, branch,
head_sha}` transition — from BOTH `oracle → implementing` and
`implementing → gating` — the Unit writes `%{data | branch: branch, head_sha:
head_sha}` into its data (the exact clause arch `control-plane.md` §3.2.1 shows).
`head_sha`/`branch` start `nil`, become non-`nil` only after a current-worker
`work_ready`, and are test-observable via `:sys.get_state/1`. The stale-worker
discard clause (`{:work_ready, _other_id, _, _}` → `keep_state`) captures nothing
(B8 invariant). This is the single producer of the coordinate D-361 consumes.
Enforced by an FSM-data assertion (`:sys.get_state` shows the captured pair after
a current-worker `work_ready`, and `nil`/unchanged after a stale-worker one).

**D-363 — Total back-compat for the declared-hash and legacy seams (PR #503):**
When `data.head_sha` is `nil` — the legacy 2-tuple `worker_fun` seam (no
`worker_id`, completion via `{:worker_done, ^worker_pid}`), or any caller that
never emits `work_ready` — the gate (B7) and merge (B6) seams fall back to the
declared `work_item.hash` and `work_item.branch` exactly as before D-361. For the
dogfood's **deterministic scripted agent**, the asserted `head_sha` equals the
declared `hash` by construction (arch §7.2), so the captured and declared
coordinates coincide and the AC-12 end-to-end flow is observably unchanged. D-361
is therefore a strict refinement: it changes the coordinate only when the agent
asserts one that differs, which is exactly the non-deterministic-agent case.
Enforced by the existing `dogfood_e2e_test.exs` continuing to reach `:merged`
green, and a unit test that the `head_sha = nil` path uses the declared hash.

**D-369 — Issue → declared-scope elaboration is conservative (I2, [C124-B10],
[C126-B10], [C127-B10], [C130-B10], V1/V3):** `IssueSelector.select/1` produces
`work_item.scope` as a `ConflictCheck.scope()` map (`%{deps, files, codepoints,
specs, resources}`), **never** a string, via the `:elaborate_fun` seam (D-370).
The default elaborator harvests scope only from machine-checkable issue signals
(cited `lib/…`/`test/…`/`web/…`/`docs/…` paths, cited `SPEC-*.md` Appendix-B
source-maps, `file:line`-cited codepoints, label-derived resources, `blocked-by:`
deps) and is **directionally sound**: it over-declares under uncertainty and
**coarsens a file-cited-but-not-line-cited reference to a whole-`files` entry**,
never a narrow `codepoints` entry. Enforced by `issue_elaboration_test.exs`: (a)
the returned `scope` is a map accepted by `ConflictCheck.clear?/2` without a
crash (closes the [C124-B10] latent type error); (b) a fixture issue citing a
file but no line yields that file in `files` and **no** narrowing
`codepoints` entry (over-declaration); (c) two fixture issues citing a shared
file elaborate to scopes that `ConflictCheck.pairwise_clear?/2` rejects (the V3
soundness witness — a real shared file is never elaborated apart).

**D-370 — Elaboration is an injected pure seam (I2, [C125-B10]):** the
issue→scope mapping is the injected `:elaborate_fun :: (issue_map ->
ConflictCheck.scope())` (defaulting to the D-369 heuristic), following the
codebase's `*_fun` injection pattern, so (a) the soundness posture is tested with
deterministic fixtures with no network/LLM call on the admission path, and (b) a
stronger (LLM-assisted, separately verified) elaborator is a *substitution*, not
a rewrite of `Scheduler`/`ConflictCheck`. Enforced by `issue_elaboration_test.exs`
(a stub `elaborate_fun` is honoured; the default is pure and network-free).

**D-371 — Serialize-on-unscopable fallback (I2, [C129-B10], [C130-B10]):** when
the default elaborator extracts **no** files and **no** specs from an issue, it
returns a **universal-conflict sentinel scope** that `ConflictCheck.pairwise_clear?/2`
rejects against every non-empty in-flight member, so an unscopable unit is
admitted **only into an empty `F`** (it runs alone) and is **never** treated as
disjoint-from-everything. This makes "could not scope it" resolve to *serialize*,
preserving D-312/D-343 monotonicity (the sentinel is still a fixed declaration —
no post-hoc actual-path check). Enforced by `issue_elaboration_test.exs` (an
empty-signal issue's scope clears against an empty `F` but defers against any
non-empty `F`).

**D-372 — Brief assembly is complete over its declared inputs (A2, [C131-B8]):**
`Tau.Factory.BriefAssembler.assemble/2` composes `task.prompt` from the
`work_item`'s inputs (issue body, declared `ConflictCheck.scope()`, gating-test
paths, SPEC/AC/D-NNN refs) **plus** the static `docs/arch/04-software-architecture`
pointers, and **every input present in `input` appears, labelled, in the assembled
prompt** — no stated input is silently dropped (V3) and the arch-pointer section is
mandatory and non-empty (`feedback_brief_implementers_with_arch`). Enforced by
`brief_assembler_test.exs` (an `input` carrying each field yields a prompt
containing each field's content under its labelled section, and the arch section is
present even when no other optional input is supplied).

**D-373 — Assembly is an injected pure seam that degrades, never crashes (A2,
[C131-B8]):** the issue→prompt mapping is the injected `:assemble_fun ::
(input -> String.t())` (defaulting to the D-372 heuristic template), following the
codebase's `*_fun` injection pattern, so (a) a stronger LLM-assisted prompt author
is a *substitution*, not a rewrite of `Supervisor`/`UnitDriver`/`Worker`, and (b)
the default is pure and network-free — no LLM call on the assembly path. The
assembler does not assume the issue text is complete: an absent optional input
degrades to an explicit placeholder in its section, and for any non-empty issue
(carrying `"number"`/`"title"`) the assembler returns a non-empty `String.t()`,
never raising on partial input and never returning `""`. Enforced by
`brief_assembler_test.exs` (a stub `assemble_fun` is honoured; the default is pure;
partial input degrades to placeholders without raising; output is always
non-empty).

**D-377 — Heartbeat-driven liveness: the Unit resets its `:state_timeout` on
every current-worker progress heartbeat (GOV4, OQ-2 refinement of D-358,
[C107-B5], V6):** Each Unit state that awaits a worker (`oracle`, `implementing`)
re-arms its `{:state_timeout, state_timeout_ms, :worker_stalled}` on every
`{:worker_heartbeat, worker_id}` received from the **current** worker (the `B8`
`worker_id`-keyed liveness pulse the Worker forwards from D-366 shim frames). A
heartbeat from a superseded `worker_id` is discarded (B8 stale-worker discard) and
does **not** re-arm. Consequently a genuinely-progressing real agent — which
pulses a heartbeat at least once per `state_timeout_ms` window (D-366 derives the
pulse from real stream progress) — NEVER trips `:state_timeout`, so the fixed
wall-clock ceases to bound a *healthy* run. The `state_timeout_ms` is thereby
re-interpreted as a **per-heartbeat inactivity deadline** (the maximum silence
between two progress pulses), not an absolute run-duration cap; D-358's
operator-overridable `:unit_timeouts` continues to set its value. This closes the
D-358 residual (a fixed cap either spuriously kills a slow-but-healthy agent or is
set so high it masks a wedge): the deadline now keys on *silence*, not *elapsed
time*. Enforced by an oracle-separated FSM test: a Unit fed `{:worker_heartbeat,
w}` at sub-`state_timeout_ms` intervals past the old fixed cap stays in
`implementing` and never escalates `E_WORKER_STALLED`; with no heartbeats it trips
at `state_timeout_ms` exactly as before.

**D-378 — Exactly one outcome per worker per state; ONE symmetric rule for
`oracle` and `implementing` (disjointness, [C107-B5], GOV4 re-shape, V3/V5/V6):**
Both worker-awaiting states (`oracle`, `implementing`) handle the worker-outcome
signal set **identically** — the §4 B8 rule table is the single source. The two
**event-message** stall-class signals — `{:worker_stalled, ^worker_id}` (Watchdog
heartbeat-absence) and `{:worker_exit, ^worker_id, reason}` (semantic death-cert) —
route to the **same retry ladder**, `advance_retry_ladder(state, data)`, which
re-enters the **originating waiting state** (`oracle → oracle`, `implementing →
implementing`) via `{:next_state, state, …, [{:next_event, :internal, :on_enter}]}`.
Re-entering the originating state (not always `implementing`) is mandatory so a
stalled/exited test-author re-runs the **test-author**, not the implementer.

Stall-class signals for a single wedged worker produce **exactly one** outcome via
`worker_id`-keyed disjointness: the first stall-class signal consumed clears
`data.worker_id` (sets it `nil` alongside `Process.demonitor(mref, [:flush])`) and
fires the `:next_state` ladder transition; every subsequent stall-class event for
that now-superseded `worker_id` matches the stale-worker discard clause
(`keep_state`) and advances nothing.

The Unit's **own** `:state_timeout` is a **separate, terminal** outcome (NOT the
ladder): it fires only on total heartbeat silence past the cap and
`escalate(:E_WORKER_STALLED)`s (the hard-stall path; gate NOT called; preserves
#490/D-326). This is the only place `E_WORKER_STALLED` arises; the event-message
`worker_stalled`/`worker_exit` signals never escalate directly — they retry,
escalating to `E_RETRY_EXHAUSTED` only after the ladder is spent.

**No `:deferred_spawn` (GOV4 re-shape — the deferred path is dropped, V5).** The
prior design routed `{:worker_stalled, w}` through a `:deferred_spawn` → mailbox
tail → `do_spawn_worker/1` dance whose stated purpose was to drain stale stall
signals for the old `worker_id` before re-spawning. That purpose is **vacuous**:
discrimination is by `worker_id`, not by mailbox-drain order. The re-spawn produces
a **fresh** `worker_id` (D-326), so any stale signal for the old id is discarded by
the `_other_id` clause regardless of when it is drained. Worse, a `gen_statem`
`{:next_event, :internal, :on_enter}` is processed **before** pending `:info`
messages already in the mailbox, so the plain ladder re-spawns *first* and the
queued stale signals then hit the new state instance where `worker_id` is the new
worker's id (or `nil` for the legacy seam) → all stale-discarded. Exactly-once and
D-315 durability therefore come for **free** from the plain ladder: its `:on_enter`
already bumps `attempt_count` and `snapshot_state`s before spawning. Dropping the
deferred path removes a state-machine surface (one fewer message form, one fewer
crash cut, V8) while *strengthening* the guarantee.

Enforced by symmetric FSM tests in **both** states: delivering `{:worker_stalled,
w}`, `{:worker_exit, w, …}`, and a second `{:worker_stalled, w}` for one worker in
close succession advances the combined (`refine_count + attempt_count`) metric by
exactly one (not three), and re-enters the originating state.

**D-379 — The Unit consumes the Watchdog `worker_stalled(w)` and the dispatcher
`worker_exit(w, reason)` triggers in BOTH waiting states; the fleet registers each
worker with the Watchdog (B8 wiring, [C107-B5], GOV4 re-shape, V3 orphan-invariant
closure):** B8 names `worker_stalled(w)` and `worker_exit(w, reason)` as disjoint
worker events the Unit consumes, and §3 Q3 mandates the heartbeat-absence watchdog
as the only thing that makes total escalation hold over reachable *states*. This
invariant pins the previously-orphaned wiring **symmetrically across `oracle` and
`implementing`**:

(a) **Producer.** The `UnitDriver.drive/2` `worker_fun` seam (or the
`WorkerSupervisor.spawn/5` path) registers **every** spawned worker — test-author
*and* implementer — with the fleet `Watchdog` (`Watchdog.register(watchdog,
worker_id, worker_pid, unit_pid, heartbeat_timeout: …)`), so the Watchdog's
`{:worker_stalled, worker_id}` is delivered to the **owning Unit** (its
`report_to`), not dropped.

(b) **Consumer — both states, identical clauses.** Each of `oracle` and
`implementing` carries `:info {:worker_stalled, ^worker_id}` AND `:info
{:worker_exit, ^worker_id, _reason}` current-worker clauses that clear `worker_id`,
demonitor, and call `advance_retry_ladder(<this state>, data)`; plus the matching
`_other_id` stale-worker discard clauses. **The run-#2 gap this closes: `oracle`
previously had NO `worker_exit` clause** — an oracle worker exiting
`:no_work_product` fell through to `handle_unexpected/4`, was ignored, and only the
300 s `:state_timeout` eventually fired `E_WORKER_STALLED` (a spurious hard-stall
for what was really a routine semantic retry). Both states now consume both
event-message stall signals identically. Without this wiring the `worker_stalled` /
`worker_exit` triggers named in B8 have **no producer reaching the Unit and/or no
consumer in one of the two states** — the orphan invariant V3 flags.

The Watchdog `heartbeat_timeout` and the Unit `state_timeout_ms` (D-377) are set
from the SAME `:unit_timeouts`-derived value so the two heartbeat-absence detectors
share one threshold and cannot disagree about liveness (V6 path-arithmetic: one
threshold, two detectors, one verdict). Enforced by a wiring test (a spawned worker
is registered with the Watchdog) and symmetric FSM tests (a Unit in **`oracle`**
*and* a Unit in **`implementing`** each receiving `{:worker_stalled,
current_worker_id}` or `{:worker_exit, current_worker_id, _}` advances the combined
metric by one and re-enters its originating state; a stale-worker variant is
ignored).

**D-380 — Single admission authority + admission self-exclusion (real-run
integration, [C132-B1], [C133-B1]):** one unit is admitted to `F` **exactly once,
by the Unit FSM `planned` state alone** (the authority holding the real
`declared_scope`); the Coordinator selects and drives but **never** calls
`Scheduler.admit/3`. The Scheduler evaluates `ConflictCheck.clear?` and the
capacity check over `F ∖ {unit_id}` — a unit **never** conflicts with its own
in-flight entry, so (a) a single unscopable unit (D-371 `universal_conflict`)
admits against its excluded-empty `F'` instead of self-conflicting, and (b)
re-admit of an already-present `unit_id` (the scope-amendment path) is idempotent
(returns `:admit`, replaces the scope). The exclusion is by `unit_id` in the
Scheduler; `ConflictCheck` (C5) stays unit-id-agnostic and P-CC-2 (scope
self-conflict) is preserved. Two defects are jointly closed: the
**double-admission self-conflict** (`unit.ex` admit sees the Coordinator's prior
empty-scope `F` entry → `escalate(:E_SCHEDULER_DEFER)`) and the **soundness** hole
(an empty-scope `F` entry blinds other units' conflict checks). Enforced by
`scheduler_self_exclusion_test.exs` (admit `unit-1` with a sentinel/non-trivial
scope; re-admit the **same** `unit_id` against an `F` already holding it →
`:admit`, not `{:conflict, _}`; and a single sentinel unit admits into the
excluded-empty `F'`) and by an integration assertion that the Coordinator's
`drive_unit` performs **no** `Scheduler.admit` call.

## 7. Acceptance criteria

Each is expressed against the user-facing path with an observable signal.
PR groupings are indicative.

- **AC-1 (PR-CORE-1):** `mix compile --warnings-as-errors` passes with the
  `Tau.Factory.{Ledger.Writer, Budget.Owner}` + Exqlite repo present; `Tau.Factory.Supervisor`
  starts them under `Tau.Application`. Signal: `mix test` boots the tree.
- **AC-2 (PR-CORE-1, D-315):** `mix test test/tau/factory/ledger_durability_test.exs`
  passes — a writer killed between WAL commit and effect resumes with the decision
  present exactly once. Signal: the test asserts exactly-once on resume.
- **AC-3 (PR-CORE-2, D-312/D-343):** `mix test --only property` passes including
  `conflict_check_property_test.exs` (P-CC-1..5, incl. monotonicity).
- **AC-4 (PR-CORE-2, D-320/D-332):** `budget_admission_test.exs` passes — spend
  driven to the ceiling denies the next admission and raises `E-BUDGET`; the
  ledger balance holds.
- **AC-5 (PR-CORE-3, D-318):** `mix test --only property` passes including
  `retry_property_test.exs` — no input sequence exceeds `N_refine + N_pivot`.
- **AC-6 (PR-CORE-3, D-317):** `escalation_property_test.exs` (classify totality)
  **and** `unit_timeout_test.exs` (a wedged-worker simulation reaches `escalated`)
  both pass. Both are required.
- **AC-7 (PR-CORE-4, D-321):** `kill_switch_test.exs` passes — a kill mid-unit
  halts *after* the unit with `main` synced and never mid-merge.
- **AC-8 (PR-CORE-4, D-344):** `coordinator_recovery_test.exs` passes — the
  Coordinator killed mid-drive resumes from L and re-does no terminal work.
- **AC-9 (PR-CORE-5, D-335):** `verdict_append_only_test.exs` passes — no update
  path exists for a verdict; the latest-status query returns the superseding row
  (the merge-CAS value-staleness contract this SPEC supplies to SPEC-FACTORY-MERGE).
- **AC-10 (PR-CORE-5, D-330/D-331/D-336):** `reconcile_test.exs` passes — no unit
  in zero or two terminal sets; tree ≡ tracker; every escalation recorded+delivered.
- **AC-11 (meta):** the gating tests above run in CI as a blocking job.
  *(meta — verified by CI wiring; exempt from the unit-test-linkage check.)*
- **AC-12 (PR-CORE-6 / P5c-7, end-to-end / substance):** the control core drives
  one real PR on the self-hosting Elixir toolchain from an open issue to a
  gate-passed, merged result with `main` health-checked, **no human in the loop**.
  `mix tau.factory.dogfood --repo <local-bare-sandbox> --issue <n> [--db <ledger-path>]`
  (the **deterministic** path; live LLM authorship is the only simulated part — the
  scripted `agent_bin` emits the D-326 `work_ready` frame and produces a **real**
  branch/commit solving the trivial seeded issue, whose **real gating test**
  genuinely exercises Gate 5.3 mutation) runs the **real** control plane
  (Coordinator → UnitDriver → fleet → `Gate.run` → MergeAuthority CAS → health) —
  the agent's authorship is the only thing simulated; the machinery is real.
  The optional `--db <path>` flag lets tests supply an isolated Ledger DB path
  (defaults to `Tau.Settings.data_dir()/factory_ledger.db` when absent).
  **Observable assertions (`dogfood_e2e_test.exs`, `@tag :integration`, not in
  normal CI):**
  1. a **merged commit on the sandbox `main`** — a real SHA reachable from
     `<local-bare-sandbox>/main` containing the seeded change;
  2. a **green `Merge.Health.check`** on the integrated tip (`:green`, not
     `{:red, _}`);
  3. the **verdict + per-state Unit snapshots durable in L** (the gate verdict
     row(s) and the Unit's terminal `:merged` snapshot);
  4. **zero human input** — the task enables the factory, the Coordinator drives
     the single unit to its terminal `unit_terminal(:merged)` autonomously, a
     second `select_fun → nil` terminates the milestone, and the task reports;
     no prompt, no checkpoint;
  5. **no spurious escalation** — with widened timeouts (D-358) the unit reaches
     `:merged` and the run records no `E-RETRY-EXHAUSTED` / `:state_timeout`.

  Signal: the exact command above + the observable merged SHA + the green health
  check (the dogfood proof; arch `06-roadmap/spec-factory.md` AC-10).
  *This AC depends on SPEC-FACTORY-{GATE,FLEET,MERGE} landing; it is the
  integration gate, not a CORE-only unit.*
- **AC-13 (P5c-7, safety, D-359):** `mix tau.factory.dogfood` with a sandbox whose
  `origin` is a **non-local** remote (`https://` / `git@` / `ssh://`)
  **hard-refuses** before booting the factory (non-zero exit, no Coordinator
  started); with a **local bare-repo** origin it proceeds. Signal: the safety-guard
  unit test asserts the refusal (and that no `Tau.Factory.Coordinator` is started)
  on a non-local origin, and acceptance on a local bare repo.
- **AC-P5c6 (PR #480, D-357):** `mix test test/tau/factory/factory_supervision_test.exs`
  passes — with the factory enabled, `Tau.Factory.Supervisor` assembles the full
  subtree and the Coordinator (started LAST) reaches `:running` and idles
  (`select_fun → nil`, no in-flight unit, no `Unit` spawned); and on a default
  boot (factory disabled) no `Tau.Factory.Coordinator` exists. Signal: both Test A
  (enabled assembly + idle) and Test B (default-OFF) assert it.
- **AC-D380 (PR #515, D-380):** `mix test test/tau/factory/scheduler_self_exclusion_test.exs`
  passes — re-admitting the **same** `unit_id` against an `F` already holding it
  returns `:admit` (not `{:conflict, _}`), a single `universal_conflict` unit
  admits into its excluded-empty `F'`, and the Coordinator's `drive_unit` issues
  **no** `Scheduler.admit` call (single authority = the Unit FSM). Signal: the
  test asserts the self-exclusion verdict and the absence of the K-side admit.

## Appendix B — Source map

Files that bring a PR into scope of this SPEC (`D-NNN`/`C-N` → file:symbol):

- `lib/tau/factory/ledger/writer.ex` (C1; D-315, D-330–D-333, D-335, D-336) — PR-CORE-1/5
- `lib/tau/factory/ledger/schema/*.ex` + `lib/tau/factory/ledger/migrations.ex` (Exqlite schema; D-335 partial unique index) — PR-CORE-1/5
- `lib/tau/factory/budget/owner.ex` (C2; D-320, D-332) — PR-CORE-2
- `lib/tau/factory/coordinator.ex` (C3; D-317, D-321, D-342, D-344, **D-380** `drive_unit/3` MUST NOT call `Scheduler.admit`; drop the `@empty_scope` admit — single admission authority is the Unit FSM) — PR-CORE-3/4 / PR #515
- `lib/tau/factory/escalation.ex` (C7; D-317) — PR-CORE-3
- `lib/tau/factory/scheduler.ex` (C4; D-312, D-320, D-343, **D-380** evaluate `ConflictCheck.clear?` + capacity over `F ∖ {unit_id}`; upsert on admit) — PR-CORE-2 / PR #515
- `lib/tau/factory/conflict_check.ex` (C5; D-312, D-343 — **unchanged for D-380**: stays unit-id-agnostic; the self-exclusion is an S-level set op, not a C5 change) — PR-CORE-2
- `lib/tau/factory/unit.ex` (C6; D-318, D-340, **D-356** awaiting_merge subscribe-before-request consume + unsubscribe-on-exit, **D-362** capture `work_ready` `branch`/`head_sha` into data, **D-361** key `merge_fun` on captured `head_sha`/`branch`, **D-377** reset `:state_timeout` on current-worker `{:worker_heartbeat, w}` in `oracle`/`implementing`, **D-378** one-outcome-per-worker collapse via `worker_id`-clear + stale-worker discard (ONE symmetric rule for both states; no `:deferred_spawn`), **D-379** both `oracle`/`implementing` consume `{:worker_stalled, ^worker_id}` AND `{:worker_exit, ^worker_id, _}` → `advance_retry_ladder(<originating state>, data)` (re-enters the originating waiting state; closes the run-#2 oracle-`worker_exit` gap), plus B6/B7/B8 cited edges) — PR-CORE-3/PR #477/PR #503/PR #513
- `lib/tau/factory/unit_driver.ex` (D-340, **D-356** `:janitor` threading + no driver-side merge bridge / no driver reclaim; **D-361** build the merge map `hash`/`branch` from the captured `head_sha`; **D-379** register each spawned worker with the fleet `Watchdog` (`report_to` = owning Unit) sharing the `:unit_timeouts`-derived `heartbeat_timeout`; the real `drive_fun` wiring Unit→fleet→gate→merge seams) — PR #477/PR #503/PR #513
- `lib/tau/factory/gate/request.ex` (**D-361** `Request.hash` is the captured `head_sha`, not the declared `work_item.hash`; the gate-closure construction site) — PR #503
- `lib/tau/factory/dogfood/gate_fun.ex` (**D-361/D-363** the arity-1 gate closure receives the coordinate (`head_sha || declared hash`) from the Unit and sets `Request.hash` to it) — PR #503
- `lib/tau/factory/brief_assembler.ex` (B10/A2; **D-372** complete-over-inputs composition, **D-373** injected `:assemble_fun` pure seam + graceful degradation; the issue→`task.prompt` intake projection, invoked at `supervisor.ex:to_unit_work_item/1`) — PR #508
- `lib/tau/factory/supervisor.ex` (**D-372** `to_unit_work_item/1` sets `brief:` via `BriefAssembler.assemble/2` instead of `brief: title`) — PR #508
- `lib/tau/factory/retry.ex` (C8; D-318) — PR-CORE-3
- `lib/tau/factory/kill_switch.ex` (C9; D-321) — PR-CORE-4
- `lib/tau/factory/supervisor.ex` + `lib/tau/application.ex` (tree; rest_for_one spine; **D-357** config-gated `start_link/1` assembly + seam-threading, B11; **D-358** `:unit_timeouts` thread; **gate_fun/agent_bin** thread completing the P5c-6 deferral, §4 B11) — PR-CORE-1 / PR #480 / PR #481
- `config/config.exs` + `config/runtime.exs` (`config :tau, :factory, enabled:` gate, default `false`; **D-357**) — PR #480
- `lib/mix/tasks/tau.factory.dogfood.ex` (P5c-7 dogfood harness; **D-359** local-bare-origin hard-refuse guard; builds the deterministic `agent_bin`, the gate_fun closure, widened `:unit_timeouts` (D-358); drives one unit to `:merged`; AC-12/AC-13) — PR #481
- `lib/tau/factory/dogfood/` (the scripted deterministic `agent_bin` and sandbox-seeding helpers — the seeded issue + its real gating test; emits the D-326 `work_ready` frame) — PR #481
- `test/tau/factory/ledger_durability_test.exs` (D-315) — PR-CORE-1
- `test/tau/factory/conflict_check_property_test.exs` (D-312, D-343) — PR-CORE-2
- `test/tau/factory/scheduler_self_exclusion_test.exs` (**D-380** self-exclusion + idempotent re-admit + Coordinator issues no admit — single authority) — PR #515
- `test/tau/factory/budget_admission_test.exs` (D-320, D-332) — PR-CORE-2
- `test/tau/factory/brief_assembler_test.exs` (**D-372** complete-over-inputs composition; **D-373** injected `:assemble_fun` seam, pure default, graceful degradation, non-empty output) — PR #508
- `test/tau/factory/retry_property_test.exs` (D-318) — PR-CORE-3
- `test/tau/factory/escalation_property_test.exs` + `unit_timeout_test.exs` (D-317) — PR-CORE-3
- `test/tau/factory/kill_switch_test.exs` (D-321) — PR-CORE-4
- `test/tau/factory/coordinator_recovery_test.exs` (D-344) — PR-CORE-4
- `test/tau/factory/verdict_append_only_test.exs` (D-335) — PR-CORE-5
- `test/tau/factory/cost_attribution_test.exs` (D-333) — PR-CORE-5
- `test/tau/factory/reconcile_test.exs` (D-330, D-331, D-336; audits D-334 disposition) — PR-CORE-5
- `test/tau/factory/unit_termination_test.exs` (D-340) + `scope_amendment_test.exs` (D-343) — PR-CORE-3/2
- `test/tau/factory/unit_driver_test.exs` (D-340; real drive_fun gating tests) — PR #477
- `test/tau/factory/unit_merge_result_test.exs` (**D-356** U subscribe-before-request consume + unsubscribe-on-exit) — PR #477
- `test/tau/factory/factory_supervision_test.exs` (**D-357** config-gated subtree assembly + default-OFF; AC-P5c6) — PR #480
- `test/tau/factory/dogfood_e2e_test.exs` (**AC-12** e2e: one real PR open-issue→merged→green-health, no human; **D-358** widened timeouts, no spurious escalation; `@tag :integration`) — PR #481
- `test/tau/factory/dogfood_guard_test.exs` (**AC-13 / D-359** non-local origin hard-refuse; local bare-repo acceptance) — PR #481
- `test/tau/factory/unit_heartbeat_liveness_test.exs` (**D-377** heartbeat resets `:state_timeout` — a Unit fed `{:worker_heartbeat, w}` at sub-`state_timeout_ms` intervals past the old cap never escalates `E_WORKER_STALLED`, no-heartbeat trips at the cap; **D-378** delivering `{:worker_stalled, w}` + `{:worker_exit, w, …}` + a second `{:worker_stalled, w}` for one worker advances the combined metric exactly once and re-enters the originating state — asserted **symmetrically in BOTH `oracle` and `implementing`**; **D-379** both states consume current-worker `{:worker_stalled, w}` AND `{:worker_exit, w, _}` → `advance_retry_ladder(<originating state>, _)`, ignore the stale-worker variants, and `UnitDriver` registers each spawned worker with the `Watchdog`; the deferred-spawn path is removed and D-315 durability is provided by the ladder's `:on_enter`) — PR #513

**Cross-SPEC boundaries (cited, not owned here):** B6 → `SPEC-FACTORY-MERGE`
(D-300–D-303, D-341); B7 → `SPEC-FACTORY-GATE` (D-304–D-308, D-322, D-323);
B8 → `SPEC-FACTORY-FLEET` (D-309–D-311, D-313, D-314, D-316); `E-DESTRUCTIVE` →
`SPEC-FACTORY-GOV` (D-319).

**Catalog registration required before first implementation PR:** add
`SPEC-FACTORY-CORE` to `.claude/rules/spec-before-code.md` (catalog) and the
`D-NNN` block table in `docs/MISSION.md` (D-312, D-315, D-317, D-318, D-320,
D-321, D-330–D-333, D-335, D-336, D-340, D-342–D-344, D-355–D-359,
D-361–D-363, D-369–D-373 → this SPEC).
