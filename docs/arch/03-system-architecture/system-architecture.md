# tau — System architecture (synthesized, verified shape)

This is the canonical **implementation-agnostic** system shape, synthesized from
the four candidate shapes (`candidate-*.md`) after adversarial verification
(`../05-verification/`). It keeps the 7-component skeleton all four candidates
converged on, and bakes in the nine hole-resolutions (HR-1..HR-9) the verifiers
forced. The concrete Elixir/OTP mapping is the next layer
(`../04-software-architecture/`); nothing here names a runtime, so the shape is
verifiable independent of OTP.

Notation per `solution-shaping/references/notation.md`: a component is
`(S, E_in, E_out, δ, Inv)` — state space, input events, output events,
transition relation, locally-enforced invariants.

---

## 1. Components

Seven authorities + one extension seam (Toolchain) + one data plane (Policy).
Boundaries are drawn around invariants (not nouns); each component's existence is
justified by the distinct invariant(s) it structurally enforces.

### L — Durable Ledger (system-of-record)
- **S:** the append-only decision log + materialized state: solution tree
  (units, attempts, gate verdicts, challenges, kill reasons, escalations),
  budget ledger, cost attribution. Single logical writer per datum, co-located
  (HR-9).
- **E_in:** `record(decision)`, `append_verdict(hash,run,status)`,
  `revoke_verdict(hash,run)`, `debit(budget,owner,amount)`, `reconcile(tracker)`.
- **E_out:** `committed(decision)`, `verdict_status(hash)→latest`,
  `budget_state→(spent,remaining)`.
- **δ:** every write is WAL-committed before its `*.committed` ack; verdicts are
  immutable per `(hash,run)` — a revoke appends a superseding record (HR-2).
- **Inv:** INV-16 (durable, RPO=0), INV-19 (attempt count durable), INV-21
  (budget ceiling read), CON-1..7 (single-writer accounting), CON-6 (verdict
  conservation via append-only).

### K — Coordinator / Escalation FSM
- **S:** loop mode ∈ {running, halting, halted}; the active escalation set.
- **E_in:** `unit_terminal(u,outcome)`, `halt_signal` (kill switch),
  `escalation(e)`, `milestone_state`.
- **E_out:** `select_next`, `report(operator)`, `halt`.
- **δ:** no reachable non-progress state without emitting exactly one `e∈E`
  (totality; HR via catch-all E-UNCLASSIFIED). Kill checked at unit boundaries.
- **Inv:** INV-18 (total escalation — sole enforcer), INV-22 (clean kill),
  INV-20 (routes destructive→E-DESTRUCTIVE), LIV-1..5 (liveness driver), CON-7
  (escalation delivery).

### S — Scheduler / Admission
- **S:** in-flight set `F`; per-unit declared file+gating-test path sets;
  policy-version pins.
- **E_in:** `candidate(unit, declared_scope, declared_paths)`,
  `unit_terminal(u)`, `budget_state`, `fleet_pressure`.
- **E_out:** `admit(unit)`, `defer(unit)`, back-pressure to fleet.
- **δ:** admit `u` iff the **five-clause conflict check clears against every
  v∈F** using *declared* sets (HR-4), AND budget pre-check passes, AND fleet
  headroom exists. Admission is monotone (a deferred unit keeps its place).
- **Inv:** INV-13 (conflict-gated concurrency — sole enforcer), INV-21
  (pre-admission budget check), FR-7.3 (admission-controlled concurrency),
  LIV-4 (monotone serialization).

### G — Gate
- **S:** per-(unit,hash) verdict assembly: {AC-linkage, masking, mutation}
  mechanical + {critic, reviewer} judgement + SPEC-membership + lint/compile.
- **E_in:** `gate(unit, diff, frozen_paths, policy_pin)`,
  `challenge(unit, test, spec_clause)`, `finding(unit, hash)`.
- **E_out:** `verdict(hash,run,PASS|FAIL)` → L (append-only), `revoke(hash,run)`
  → L, `challenge_ruling`.
- **δ:** PASS iff ALL halves pass on exactly `diff`; the gate-floor
  (mutation+critic+reviewer) is engine-fixed, non-shrinkable (HR-8). Mutation
  judgement is computed by the **engine** from the structured test artifact, not
  the toolchain adapter (HR-3). A challenge is ruled by an **independent critic**
  (FR-4.4). Mechanical gates are path-based (HR survives rebase).
- **Inv:** INV-1 (gate-before-merge contribution), INV-5 (author-identity check,
  HR-7), INV-6 (gating-test immutability scan), INV-7 (engine-judged mutation,
  HR-3), INV-8 (partial), INV-9 (incomplete-fix test), INV-23/24 (mechanized
  halves, HR-6), E-CHALLENGE, NFR-GAME-RESISTANCE.

### W — Worker Supervisor
- **S:** live workers; per-worker isolation boundary (private checkout +
  complete resource namespace declared by the Toolchain adapter).
- **E_in:** `spawn(role, brief, ref)`, `worker_exit(w, reason)`.
- **E_out:** `workspace_ready(w)`, `work_ready(w, branch, head_sha)`,
  `captured(w, dirty)`, `reclaimed(w)`, `worker_heartbeat(w)`,
  `worker_stalled(w)`, structured agent I/O events. `work_ready` is the
  **success** counterpart of `worker_exit` (the death certificate): an explicit
  *work-product-ready* signal carried **in-band over the agent `Port` before the
  agent exits**, keyed by `worker_id`. It is the sole trigger for the U
  `implementing ──request_gate──▶ gating` edge; clean Port exit (`:exit_status
  0`) alone is NOT treated as completion (D-326).
- **δ:** spawn allocates a *complete* isolation boundary (git + HOME/cache/XDG +
  network-cache namespace) and sets position; the worker verifies its own
  position before work (HR via INV-12). On exit (incl. crash): **capture all
  three dirty kinds (staged+unstaged+untracked) before reclaim** (HR via INV-14),
  then reclaim (INV-15). Test-author spawned and frozen *before* implementer
  (INV-5 ordering); identity recorded (HR-7).
- **Inv:** INV-10 (resource isolation — sole enforcer), INV-11 (no shared tree),
  INV-12 (verified position), INV-14 (capture-before-destroy), INV-15 (reclaim),
  INV-17 (crash containment), CON-5 (artifact conservation).

### U — Unit (PR) FSM
- **S:** `state ∈ {planned, oracle, implementing, gating, refine_k,
  awaiting_merge, merged, escalated}`; attempt count k; frozen scope; policy pin.
- **E_in:** `gate_outcome`, `worker_event`, `challenge_event`, `merge_result`.
  `worker_event` is the family of worker-originated triggers U consumes; it is
  the **disjoint sum** of three keyed-by-`worker_id` cases U must distinguish
  (D-326): `work_ready(w, branch, head_sha)` (success — the agent reported a
  stable diff; → `request_gate`), `worker_exit(w, reason)` (crash/death cert —
  infra-failure path, gate NOT called), and `worker_stalled(w)` (the watchdog's
  synthetic wedged-worker trigger). U tags the **current** worker by `worker_id`
  and discards events from a stale/superseded worker.
- **E_out:** `request_gate`, `request_merge`, `unit_terminal(u,outcome)`,
  `escalate(e)`.
- **δ:** the per-unit lifecycle is owned by **one** component (not smeared —
  the authority-split's fatal flaw). Bounded retry: refine ≤ N (HR-8 clamped),
  then pivot (fresh diff), then E-RETRY-EXHAUSTED. Semantic failure (gate FAIL)
  is an *outcome transition here*, NOT a crash to restart (FR-8.2).
- **Inv:** INV-19 (bounded retry — sole enforcer), FR-1.3 (frozen scope),
  E-CHALLENGE (>2 upheld), LIV-1 (per-unit termination).

### M — Merge Authority
- **S:** a single serialized integrator; the **sole writer of `origin/main`**;
  the current merge-train batch; the fair wait-queue.
- **E_in:** `request_merge(unit, hash)`, `head(origin/main)`.
- **E_out:** `merged(batch)`, `merge_rejected(unit, reason)`, `main_health`,
  `E-RED-MAIN`, `E-CONFLICT`.
- **δ:** assembles a **merge-train batch** of green units (HR-5); within one
  critical section per integration it performs a **compare-and-swap**: assert
  every batch member's latest verdict is `PASS` (HR-2) AND `origin/main`
  unchanged, then apply via **atomic conditional ref-update** (HR-1); run ONE
  combined post-integration health check on the batch tip; red ⇒ bisect +
  E-RED-MAIN, no further merge while red (INV-4). Serial by construction
  (concurrency 1). Fair queue with aging (Q-L1).
- **Inv:** INV-1 (gate-before-merge — final enforcer), INV-2 (freshness via CAS),
  INV-3 (serialized — sole enforcer), INV-4 (main health), INV-20 (destructive
  push routes to escalation), LIV-2 (merge progress), CON-6 (reads verdict).

### Toolchain (extension seam — Σ_T)
- **Contract:** per-language adapter supplies a **declarative descriptor** only —
  the operations {install_deps, build, test, lint, mutation_run, package} as
  *invocation recipes* + the *machine-readable report format* each emits, + the
  *resource-namespace declaration* (which mutable paths it touches, for W to
  isolate). The adapter returns **no verdict** (HR-3). The host (G + W) executes
  the recipe in an isolated workspace and judges the structured artifact itself.
- **Inv (host-enforced for ALL adapters):** a buggy/adversarial adapter cannot
  bypass the gate floor, the merge serialization, or the isolation boundary —
  its outputs are advisory data, never control.

### Policy (data plane — Π)
- Versioned data interpreted by the stable engine: model-per-role, retry bound
  N, budget, priority order, conflict predicate, gate manifest, escalation
  thresholds. **Pinned per unit at admission** (HR-8). Safety-relevant values are
  **engine-clamped** (gate-floor non-shrinkable; `N=min(policy,ceiling)`; ∞
  rejected; conflict predicate floor only tightened). No safety invariant's
  *enforcement* lives in Π — only its *parameters*, and only where the invariant
  holds for all admissible values.

---

## 2. Composition graph (contracts + failure clauses)

```
 tracker ──intent──▶ K ──select──▶ S ──admit──▶ U ──spawn──▶ W ──agents──▶ (impl/test/critic/reviewer)
    ▲                  │              ▲           │            │
    │reconcile         │escalate      │defer      │request_gate│structured I/O
    │                  ▼              │           ▼            ▼
    └──────────────── L ◀─record/verdict/debit── G ◀──gate──── U
                       ▲                          │
                       │verdict_status(latest)    │verdict/revoke (append-only)
                       │                          ▼
                       └──────────── M ◀─request_merge── U
                                     │ (CAS: verdict PASS ∧ ref unchanged)
                                     ▼ conditional ref-update
                                 origin/main ──health──▶ M ──E-RED-MAIN──▶ K
```

| Edge | Contract (event, ordering) | Failure clause |
|------|----------------------------|----------------|
| K→S select | one candidate at a time; FIFO+priority | K crash ⇒ resume from L (INV-16); no double-select (idempotent on L) |
| S→U admit | only after conflict-check clears on *declared* sets | admit denied ⇒ defer, monotone (LIV-4) |
| U→W spawn | test-author frozen *before* implementer; identity recorded; on normal completion the agent emits `work_ready(w, branch, head_sha)` in-band, keyed by `worker_id` (D-326) ⇒ U fires `request_gate` | worker crash ⇒ W captures dirty + reclaims (INV-14/15/17); U sees `worker_exit`, decides outcome (not a restart); wedged worker ⇒ watchdog `worker_stalled` (no `work_ready`, no `:DOWN`) |
| W→agents | structured I/O, isolated workspace | agent crash blast-radius = {agent} (INV-17) |
| U→G gate | full gate on exact `diff`; floor non-shrinkable | gate FAIL ⇒ U refine/pivot (FR-8.2), not a crash |
| G→L verdict | append-only, immutable per (hash,run) | a later finding ⇒ G appends revoke; never mutates (HR-2) |
| U→M request_merge | carries (unit,hash) | M rejects on stale/revoked verdict or ref move; U re-gates |
| M→origin/main | CAS conditional ref-update; sole writer | ref moved since gate ⇒ CAS fails ⇒ rebase into next train (HR-1/5) |
| M→K E-RED-MAIN | post-integration health red | loop halts globally (INV-4); main left red, named |
| *→L record/debit | WAL before ack | L briefly unavailable ⇒ caller blocks on that datum only; no guess past it |

---

## 3. Enforcement matrix (R × C)

Every safety invariant, conservation law, and liveness property maps to a named
structural enforcer. `●` primary, `○` contributing.

| Requirement | L | K | S | G | W | U | M | Toolchain/Policy |
|---|---|---|---|---|---|---|---|---|
| INV-1 gate-before-merge | ○ verdict | | | ○ produce | | | ● CAS | floor non-shrinkable |
| INV-2 freshness | | | | | | | ● CAS ref | |
| INV-3 serialized merge | | | | | | | ● concur=1 | |
| INV-4 main health | ○ | ○ halt | | | | | ● | |
| INV-5 oracle separation | ○ identity | | | ● author≠impl | ● spawn order | | | |
| INV-6 gating-test immut. | | | | ● path scan | ○ frozen set | | | |
| INV-7 non-vacuous (mutation) | | | | ● engine-judged | ○ runs in iso | | | engine owns exec (HR-3) |
| INV-8 user-path oracle | | | | ◐ partial | | | | residual (GAP-7) |
| INV-9 incomplete-fix | ○ | | | ● test | | ○ | | |
| INV-10 resource isolation | | | | | ● namespace | | | adapter declares NS |
| INV-11 no shared tree | | | | | ● private fork | | ● sole main writer | |
| INV-12 verified position | | | | | ● set+verify | | | |
| INV-13 conflict-gated | | | ● declared sets | | | | | predicate floor |
| INV-14 capture-before-destroy | | | | | ● terminate | | | |
| INV-15 reclaim | | | | | ● lifecycle | | | |
| INV-16 durable state | ● WAL | | | | | | | |
| INV-17 crash containment | | | | | ● per-proc | ○ | | |
| INV-18 total escalation | | ● FSM | | | | | | |
| INV-19 bounded retry | ○ count | | | | | ● ladder | N clamped |
| INV-20 no unilateral destruction | | ○ route | | | | | ● push gate | classifier |
| INV-21 budget ceiling | ● ledger | | ○ pre-check | | | | | ∞ rejected |
| INV-22 clean kill | | ● boundary | | | | | | |
| INV-23 spec-before-code | ○ | | | ● membership | | | | |
| INV-24 OTP non-negotiables | | | | ● lint/compile | | | | |
| CON-1..7 conservation | ● single-writer | ○ esc | | ○ verdict | ○ artifact | | ○ | |
| LIV-1 unit termination | | ○ | | | | ● | | |
| LIV-2 merge progress | | | | | | | ● fair+train | |
| LIV-3 milestone term. | ○ | ● | | | | | | |
| LIV-4 no livelock | | | ● monotone | | | | | |
| LIV-5 recovery progress | ● durable | ○ resume | | | | | | |

No empty row. Columns L/K/S/G/W/U/M each enforce ≥1 distinct invariant (none
collapsible). `◐ INV-8` is the one honestly-partial cell (residual, stated).

---

## 4. Failure cuts

- **FC-1 Coordinator dies mid-loop.** L holds all committed decisions (INV-16);
  K resumes from L within RTO (LIV-5); no unit double-processed (idempotent
  select). In-flight U/W are supervised independently — they continue or are
  recaptured.
- **FC-2 Worker crashes mid-write.** W captures staged+unstaged+untracked, then
  reclaims (INV-14/15); blast radius = {worker} (INV-17); U receives
  `worker_exit` and chooses refine/pivot — **not** an infrastructure restart
  (FR-8.2). No other worker affected (INV-10).
- **FC-3 origin/main advances during a gate.** The CAS at M fails the freshness
  check (INV-2); the unit rebases into the next merge-train and re-gates the
  batch tip (HR-1/5). No stale merge.
- **FC-4 Verdict flips PASS→FAIL after green (challenge/late finding).** G
  appends a revoke (HR-2); M's CAS reads the *latest* verdict and rejects;
  INV-1 holds despite value-staleness — the authority-split FATAL is closed.
- **FC-5 Malicious/buggy toolchain adapter.** Adapter output is advisory; the
  engine runs tests and judges the structured artifact (HR-3); mutation
  cross-checks the failing-test id; the gate floor is non-shrinkable (HR-8). The
  adapter cannot fake a pass or bypass isolation. INV-7 holds.
- **FC-6 Budget exhausts mid-fan-out.** Admission pre-check denies new billable
  actions at the ceiling (INV-21); in-flight units run to a clean checkpoint;
  E-BUDGET halts the loop (CON-3 balanced).
- **FC-7 Destructive action requested.** Action classifier denies; routes
  E-DESTRUCTIVE (INV-20); M never force-pushes autonomously.
- **FC-8 L briefly unavailable.** Callers block on the *specific* datum; the
  system never guesses past an authority (fail-closed). No conservation drift.

---

## 5. Path arithmetic (corrected)

The naïve cap `W* = T_unit/T_merge` is an **upper bound, not a stable point**
(rate-split verifier): `T_unit` is endogenous in `W` via the re-gate feedback
loop, so single-PR serial merging drives gate utilization `ρ_g=(W−1)/W → 1` and
effective merge rate *falls* as `W` rises.

**The merge-train breaks the loop (HR-5).** Integrating a batch of `B` green
units in one rebase+gate+health cycle makes the re-stale cost `O(1)` per *batch*
rather than `O(W)` per *unit*. With batch size `B` and per-integration cost
`T_int ≈ T_gate + T_health`, merge throughput is `B / T_int` instead of
`1 / T_merge` degraded by amplification. Stability condition becomes
`arrival_rate ≤ B / T_int`, with `B` tunable to the offered concurrency — the
amplification term is amortized away.

**Sizing rule:** derive `W_cap` from `ρ_g < 1 − margin` with `T_unit(W)` modeled
endogenously; set `B` to the steady-state count of simultaneously-green units.
Both depend on the measured `T_unit / T_int` ratio on the bootstrap toolchain
(Q-1) — **measure before sizing**. Until measured, operate conservatively
(small `W_cap`, `B≥2`) rather than at the optimistic `W*`.

**Bottleneck:** the serialized integration stage (M) — intentionally, since it
is the only place INV-1..4 can be enforced. Its service time is toolchain-bound
(`T_int`), making *toolchain build/test speed the highest-leverage throughput
lever* in the entire factory (rate-split finding).

---

## 6. Open discriminating questions

Carried to `../05-verification/synthesis.md` Q-1..Q-3 and `nfrs.md`:

1. **T_unit / T_int on the bootstrap toolchain** — binding input to `W_cap` and
   `B`; measure on the self-hosting (Elixir) adapter first. Cost asymmetry:
   guessing high ⇒ re-gate storms + merge starvation; guessing low ⇒ idle
   capacity. *Recommendation:* instrument from day one; start conservative.
2. **Merge-train batch size & failure-bisection policy** — larger `B` amortizes
   more but raises batch-failure (bisection) cost. Resolve empirically post-Q-1.
3. **Budget-ledger co-location** — share L or stand alone. Correctness-neutral
   (HR-9); a performance/availability call. *Recommendation:* co-locate in L for
   v1 simplicity; split only if budget-write contention is measured.

---

## 7. What was rejected (one line each)

- **Authority-split into ~15 writers** — FATAL: distributed transaction across
  decision writers + value-stale verdict read on the merge path. Kept the
  single-writer *discipline*, co-located the decision writers (HR-9).
- **Hash-keyed verdict freshness alone** — closes content but not *value*
  staleness; replaced by append-only immutable-per-(hash,run) verdicts (HR-2).
- **Adapter-returns-verdict toolchain** — lets a polyglot adapter fake the
  mutation gate; replaced by engine-owns-execution (HR-3).
- **Single-PR serial merge with per-unit re-stale** — `ρ_g→1` instability;
  replaced by the merge-train (HR-5).
- **Post-hoc conflict check on actual paths** — breaks LIV-4 monotonicity;
  replaced by declared-scope check at admission (HR-4).
- **Plain read of origin/main before merge** — TOCTOU; replaced by CAS
  conditional ref-update (HR-1).
