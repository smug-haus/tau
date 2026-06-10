# Verification synthesis & hole resolutions

Four candidate shapes (`03-system-architecture/candidate-*.md`) were each
attacked by a fresh adversarial verifier (`verify-*.md`). This file records the
verdicts and the hole-resolutions carried into the synthesized architecture
(`03-system-architecture/system-architecture.md`).

## Verdicts

| Candidate | Verdict | Make-or-break finding |
|-----------|---------|-----------------------|
| minimal | HOLE-FOUND (salvageable) | Merge TOCTOU; re-gate amplification ~2× worse than estimated at peak=16; INV-13/LIV-4 ordering dilemma |
| authority-split | **FATAL** (partition salvageable) | **Verdict *value* staleness** — a verdict flips PASS→FAIL on the same hash; hash-keying closes content but not value staleness |
| volatility-split | HOLE-FOUND (salvageable) | **Malicious-toolchain-adapter** — engine's mutation judgement is computed from the adapter's own test run (circular under D-S2 polyglot) |
| rate-split | HOLE-FOUND (salvageable) | **`W*` is an upper bound, not a stable point** — `T_unit(W)` endogenous via re-gate feedback; `ρ_g → 1` |

**Convergence.** No verdict faulted the *boundary placement*: all four reconstruct
the same 7-component skeleton (V2 passed everywhere). The faults are at the level
of *mechanism* (how a boundary enforces its invariant) and *arithmetic* (the
throughput model). That convergence is the strongest evidence the skeleton is
right; the synthesis keeps it and fixes the mechanisms.

## The skeleton all four agree on

1. **Durable Ledger** — system-of-record (solution tree, budget, cost, verdicts).
2. **Coordinator / Escalation FSM** — total escalation, kill switch, reporting.
3. **Scheduler / Admission** — conflict check, admission/back-pressure, budget pre-check.
4. **Gate** — mechanical checks + oracle adjudication.
5. **Worker Supervisor** — isolation, agent lifecycle, capture-before-destroy.
6. **Unit (PR) FSM** — per-unit lifecycle, bounded retry, frozen scope.
7. **Merge Authority** — single serialized integrator; sole writer of `main`.

## Hole resolutions (carried into the synthesis)

**HR-1 — Merge atomicity (minimal V1.a + authority FATAL).**
The merge step is a true **compare-and-swap**: inside one critical section the
Merge Authority checks (a) the unit's gate verdict for `hash(d)` is *still*
`PASS` (see HR-2) and (b) `origin/main` is unchanged since the gate ran, then
applies via an **atomic conditional ref-update** (expected-old-oid; the VCS
primitive, not timing, closes the ref TOCTOU). The Merge Authority is the **sole
writer of `origin/main`**; any other writer (operator, bootstrap) must route
through it or trigger E-DESTRUCTIVE. *Enforces:* INV-1, INV-2, INV-3.

**HR-2 — Verdict immutability (authority FATAL crux).**
Gate verdicts are **append-only and immutable per (hash, run)**. A challenge or
a late masking/incomplete-fix finding does not mutate a verdict — it appends a
*superseding* revocation record. The merge precondition reads the **latest**
verdict status for `hash(d)` inside the CAS critical section; a revoked verdict
fails the precondition. Equivalent framing: the gate issues a **revocable merge
lease** on green; any later finding revokes it; merge requires a live lease.
*Closes:* value-staleness (PASS→FAIL on same hash). *Enforces:* INV-1, INV-9,
CON-6.

**HR-3 — Engine owns test execution (volatility headline; D-S2-critical).**
The toolchain behaviour is split so the adversary-suspect adapter never returns
a verdict:
- **Adapter → declarative descriptor only:** the runner invocation and the
  *machine-readable* report format it emits (e.g. JUnit/TAP-class structured
  output). No pass/fail judgement.
- **Engine → execution + parsing + judgement:** the trusted engine runs the
  subprocess in a host-allocated isolated workspace and parses the structured
  artifact itself. The mutation check (INV-7) additionally cross-checks that the
  *specific* test id which failed on the reverted tree appears *passing* in the
  green run.
*Closes:* the malicious/buggy adapter faking a mutation PASS. *Enforces:* INV-7,
INV-8 (partial), NFR-GAME-RESISTANCE.

**HR-4 — Declared-scope conflict check (minimal INV-13/LIV-4 dilemma).**
The conflict check operates on the **declared expected** file set *and*
gating-test path set from the plan-of-record (fixed at scope-freeze, FR-1.3),
**not** on post-hoc actual paths. The test-author must stay within the declared
gating-test path set; exceeding it is a **scope amendment** that re-enters
admission. Admission is therefore evaluable at unit entry with no post-oracle
re-litigation → LIV-4 monotonicity preserved. *Enforces:* INV-13, LIV-4.

**HR-5 — Merge-train / batch integration (rate-split headline + minimal V6).**
The serialized merge stage does **not** merge one PR and re-stale `W−1` peers.
It assembles a **batch** of green units, rebases them as a train, runs **one**
combined gate + health cycle on the batch tip, and integrates the batch
atomically (bisecting on batch failure). This amortizes the freshness re-check
across the batch, breaking the `(W−1):1` re-gate amplification. Back-pressure is
routed to the **running fleet** (pause/slow in-flight implementers), not only to
admission. The concurrency cap is derived from gate-stage utilization
`ρ_g < 1` with margin, modeling `T_unit(W)` endogenously — **not** from the
naïve `W*`. *Enforces:* LIV-2, NFR-CONC stability; preserves INV-1..3 (the batch
tip is gated as one diff).

**HR-6 — Mechanize the mechanizable (minimal).**
The mechanizable halves of INV-23/INV-24 move into the mechanical gate:
SPEC-source-map membership (does the diff touch a SPEC'd boundary without a
SPEC/D-NNN?) and lint/compile/typecheck via the toolchain behaviour. The critic
judges only the genuinely-judgement residual. *Enforces:* INV-23, INV-24
structurally rather than as prose.

**HR-7 — Author identity, not ordering (minimal).**
INV-5 is enforced by recording the **authoring agent identity** of every gating
test and asserting `author(test) ≠ author(impl)`, not merely by spawn ordering.
*Enforces:* INV-5.

**HR-8 — Pin the gate-manifest; clamp safety policy (volatility).**
The gate composition (manifest) joins the per-unit **policy-version pin** set at
admission, so a mid-flight manifest change cannot de-gate an in-flight unit.
Safety-relevant policy is **engine-clamped**: the gate-floor (mutation + critic +
reviewer) is non-shrinkable; `N = min(policy, ceiling)`; infinite-budget
sentinels are rejected; the conflict predicate has an engine file+codepoint
disjointness floor that plugins may only *tighten*. *Enforces:* INV-1, INV-7,
INV-13, INV-19, INV-21 are independent of mutable policy.

**HR-9 — Co-locate decision writers (authority crux + V12).**
The single-writer-per-datum *discipline* of the authority split is kept, but the
*decision* writers (solution tree, verdicts, plan-of-record, escalation log) are
**co-located in one Durable Ledger authority** rather than split into ~15
independent authorities — because splitting them forces a distributed
transaction across writers (a verdict recorded without its tree step). The
budget ledger MAY be a separate authority (different rate class, reconciled by
audit, conservation holds either way). *Enforces:* CON-1..7 by single-writer
construction without distributed-transaction risk.

## Residual (honestly unclosed)

- **INV-8 user-path oracle** remains partially judgement-bound: HR-3 guarantees
  the *engine* runs and judges the tests, but whether a test exercises the
  *real user entry point* vs a hand-built struct is still partly critic
  judgement (the wrong-path/under-asserting residual, research GAP-7). HR-3
  narrows it (the engine can assert the entry symbol appears in the test) but
  does not fully mechanize it. Stated, not papered over.

## Open discriminating questions promoted from verification

- **Q-1 (binding):** the real `T_unit / T_merge` ratio on the bootstrap
  (self-hosting) toolchain — measure before sizing `W_cap`. The re-gate feedback
  loop makes a wrong guess expensive (merge-train sizing depends on it).
- **Q-2:** merge-train batch size & failure-bisection policy — larger batches
  amortize re-gating more but raise the cost of a batch-level failure
  (bisection). Cost asymmetry resolved empirically once Q-1 is measured.
- **Q-3:** does the budget ledger share the Ledger authority or stand alone?
  Correctness-neutral (HR-9); a performance/availability call.

## Post-validation revisions (after `final-validation.md`)

A second independent validator attacked the *concretized* layer-04 design (the
method's re-verify-after-synthesis step) and found three holes in the OTP
mapping, all now fixed in place:

- **H-1 (HIGH) — merge build inside the mailbox.** The merge-train build + gate +
  health ran inside `MergeAuthority`'s `handle_call`, blocking the concurrency-1
  mailbox for `T_int` (minutes) — relocating the saturation HR-5 fights into M
  itself and tripping `GenServer.call` timeouts. **Fix:** M is a `gen_statem`
  (`:idle`/`:integrating`/`:committing`); the build runs **off the mailbox** in a
  monitored `Task`; only the short **commit** (re-read verdicts + `cas_push`) is
  serialized. `request_merge` is non-blocking (async result via PubSub). Edited:
  `merge-and-integration.md` §1/§4/§5, `supervision-tree.md` Step 4.
- **H-3 (LOW, folded into H-1) — verdict read pre-build, pushed post-build.** A
  revoke landing *during* the build was missed. **Fix:** the `:committing` section
  **re-reads** the latest verdict for every train member *after* the build,
  adjacent to the push.
- **H-2 (MEDIUM) — totality proven over `classify/1`, not reachable states.** A
  wedged-but-not-crashed worker emits no trigger, so K could idle with nothing to
  classify. **Fix:** mandatory `:state_timeout` on every U waiting state
  (`oracle`/`implementing`/`gating`/`awaiting_merge`) + a worker-heartbeat
  watchdog that synthesizes a `worker_stalled` event. Edited: `control-plane.md`
  §3.2 and the §1.4 totality argument.
- **INFO — single-binary deployment.** Surfaced as the highest-stakes open
  decision (`../06-roadmap/open-questions.md` OQ-1), not silently assumed.

These are mechanism fixes within the verified boundaries; no boundary moved, so
no re-shape was needed. The final-validation verdict (HOLE-FOUND, not FATAL) and
its independent finding stand as written in `final-validation.md`.
