# tau — Autonomous Agentic Coding Factory: Architecture Specification

**Status:** in progress (solution-shaping, multi-turn)
**Method:** `/solution-shaping` — invariant-first decomposition, parallel
candidate shaping, adversarial verification.

This folder holds the complete specification for **tau**: a fully autonomous
agentic coding software factory built on Elixir / Erlang-OTP. It is produced
by recursive problem decomposition; each layer is split across cross-referenced
files.

## Imposed constraint

The runtime is **Elixir / Erlang-OTP (BEAM)** *(imposed by requester)*. Unlike
a pure solution-shaping pass, the software-architecture layer is intentionally
concrete: it maps requirements onto OTP primitives (supervision trees,
`gen_statem`, `GenServer`, `Registry`, `DynamicSupervisor`, `Phoenix.PubSub`,
GenStage/Broadway, ETS, telemetry, distribution) because the requester asked
for a design that *leverages the BEAM's unique capabilities*.

## Executive summary

**tau** is a fully autonomous agentic coding software factory: it drives software
from issue to gate-passed, merged code with **no human in the per-step loop** — a
human is consulted only at a closed, total set of named escalation boundaries
(D-S1). It is built on Elixir/Erlang-OTP and is the design's central correction
that the factory must be its **own supervised OTP application**, not a
prompt-driven loop whose state is a degrading context window.

The architecture is organised around **24 safety invariants**, enforced
*structurally* (process boundaries, supervisor lifecycles, unskippable
preconditions, mechanical gates) rather than by prose an agent must remember.
Seven components carry it: a durable **Ledger** (system-of-record, RPO=0), a
**Coordinator** (total-escalation loop), a **Scheduler** (conflict-gated
admission), a **Gate** (two oracles + three mechanical checks), a **Worker
fleet** (complete per-worker isolation), per-PR **Unit** FSMs (bounded retry),
and a single serialized **Merge Authority** (the sole writer of `main`).

Four design findings the adversarial passes forced, and that most shape the
result:

1. **Gate-gaming is the #1 risk** (frontier models reward-hack up to ~76% and
   cheat *more* as they strengthen). The defence is oracle separation + read-only
   gating tests + a mutation check, and — because the factory is **polyglot** —
   the engine (not the toolchain adapter) must execute and judge the tests, or a
   malicious adapter games the gate from inside (HR-3).
2. **A gate verdict can flip PASS→FAIL on the same diff hash** (a late challenge
   or finding), so verdicts are append-only-immutable and the merge re-reads the
   *latest* inside a compare-and-swap (HR-1/HR-2) — closing a FATAL the first
   verification pass caught.
3. **The serialized merge is the throughput governor**, and the naïve cap
   `T_unit/T_merge` is an optimistic *upper bound* eroded by a re-gate feedback
   loop; the structural fix is a **merge-train** (gate a batch once, not re-stale
   every peer per merge), making toolchain build/test speed the highest-leverage
   performance lever (HR-5).
4. **Supervision recovers infrastructure; the FSM + durable ledger recover
   semantics** — a gate FAIL is an outcome, never a crash to restart. Conflating
   them is the dominant BEAM-for-agents mistake.

The biggest discriminating decision, **OQ-1**, is **resolved: the durable store
is SQLite/Exqlite** — it preserves tau's single-binary (Burrito) deployment and
reuses the Exqlite substrate the current `memory/` subsystem already ships. See
`06-roadmap/open-questions.md`.

## Layout

```
docs/arch/
  README.md                       ← this file (index + executive summary)
  00-problem/
    problem-statement.md           ← A/O/B framing, interpretation readings
    scope-decisions.md             ← the four imposed decisions D-S1..S4
  01-research/
    prior-art.md                   ← existing autonomous coding factories (web)
    otp-capabilities.md            ← BEAM/OTP patterns for agent orchestration
    tau-current-analysis.md        ← what the current repo teaches (evidence)
  02-requirements/
    invariants.md                  ← 24 safety invariants ("must never happen")
    conservation.md                ← 7 conservation laws (no work/cost lost)
    liveness.md                    ← 5 progress guarantees + the escalation set E
    nfrs.md                        ← quantified NFRs (+ the [ELICIT] discriminators)
    R-list.md                      ← functional reqs (10 axes) + master index
  03-system-architecture/
    candidate-{minimal,rate-split,volatility-split,authority-split}.md
    system-architecture.md         ← the VERIFIED synthesized shape (canonical)
  04-software-architecture/
    README.md                      ← layer-04 index + the 5 carrying decisions
    supervision-tree.md            ← authoritative OTP topology (read first)
    durable-spine.md               ← L: SQLite/Exqlite ledger, RPO=0, the schema
    control-plane.md               ← K · S · U (loop, admission, per-PR FSM)
    merge-and-integration.md       ← M: the crux (CAS + merge-train)
    worker-fleet.md                ← W: isolation, capture-before-destroy
    gate-and-toolchain.md          ← G + the polyglot Toolchain behaviour (HR-3)
    governance.md                  ← egress, policy/clamp, observability, kill
    traceability.md                ← INV/CON/LIV → D-NNN → module → test
    migration.md                   ← current-repo subsystems → new components
    distribution-readiness.md      ← the single-node / dist-ready analysis
  05-verification/
    verify-{minimal,rate-split,volatility-split,authority-split}.md
    synthesis.md                   ← verdicts + HR-1..HR-9 + post-validation fixes
    final-validation.md            ← independent end-to-end re-verification
  06-roadmap/
    spec-factory.md                ← converting this design into enforced SPEC-FACTORY-*
    open-questions.md              ← the 8 discriminating decisions + recommendations
```

## Reading order

1. `00-problem/problem-statement.md`
2. `00-problem/scope-decisions.md`
3. `02-requirements/` (invariants → conservation → liveness → nfrs → R-list)
4. `03-system-architecture/`
5. `04-software-architecture/`
6. `05-verification/`

## Progress log

- **T1** — problem framing; research fan-out (prior-art, OTP, current-repo);
  discriminating questions posed.
- **T1 (cont.)** — scope decisions recorded (D-S1 escalation-only, D-S2
  polyglot, D-S3 greenfield+migration, D-S4 single-node/dist-ready). All three
  research files landed. Requirements layer authored: 24 safety invariants, 7
  conservation laws, 5 liveness + total escalation set, quantified NFRs, and the
  functional R-list across 10 axes. Look-back passed.
- **T2** — four candidate shapes authored; four fresh adversarial verifiers
  attacked them (one FATAL: authority-split's value-stale verdict read; three
  HOLE-FOUND, all salvageable). All four reconstruct the same 7-component
  skeleton (V2 passed everywhere) → boundaries sound, mechanisms needed fixing.
- **T2 (cont.)** — verification synthesis (`05-verification/synthesis.md`): nine
  hole-resolutions HR-1..HR-9 (merge CAS, immutable-per-hash verdicts,
  engine-owns-test-execution, declared-scope conflict check, merge-train,
  mechanize INV-23/24, author-identity, policy-clamp, co-locate decision
  writers). Canonical verified shape written
  (`03-system-architecture/system-architecture.md`): components, composition
  graph, full R×C enforcement matrix (no orphan rows), failure cuts, corrected
  path arithmetic (W* is an upper bound, not a stable point; merge-train fixes
  it), rejected-alternatives log.
- **T3** — layer 04 (Elixir/OTP). `otp-architecture` skill invoked; authoritative
  `supervision-tree.md` + six subsystem files authored (durable-spine,
  control-plane, merge-and-integration, worker-fleet, gate-and-toolchain,
  governance), plus traceability (every INV/CON/LIV → provisional D-NNN → module →
  detection test), migration appendix, distribution-readiness.
- **T3 (cont.)** — independent end-to-end re-verification (`final-validation.md`):
  found H-1 (merge build blocking the mailbox), H-2 (totality proven over the
  classifier, not reachable states), H-3 (verdict read pre-build). All three
  **fixed in place** (M → `gen_statem` with off-mailbox build + re-validating
  commit; mandatory per-state timeouts + worker watchdog); recorded in
  `05-verification/synthesis.md` §post-validation. Roadmap authored
  (`06-roadmap/`: SPEC-FACTORY proposal + open-questions register). **Spec
  complete** through requirements + verified system architecture + concrete OTP
  software architecture, with a discharged no-orphan-invariant traceability
  matrix and an independent validation trail.
