# Final adversarial validation — layer-04 concretization

**Validator role.** Independent fresh-eyes read of the fully-concretized
Elixir/OTP software architecture (layer 04) against the requirements (layer 02),
the verified system shape (layer 03), and the nine hole-resolutions
(`synthesis.md` HR-1..HR-9). The mandate is to find where the concrete design
*fails to enforce* an invariant it claims, *drifts* from layer 03, *commits an
OTP anti-pattern*, or *papers over a real tension*. A hole found is the success
condition.

**Scope read.** `02-requirements/{invariants,conservation,liveness}.md`;
`03-system-architecture/system-architecture.md`;
`04-software-architecture/{supervision-tree,durable-spine,control-plane,merge-and-integration,worker-fleet,gate-and-toolchain,governance,traceability}.md`;
`05-verification/synthesis.md`.

**Overall verdict: HOLE-FOUND.** The skeleton, the durable spine, the gate, and
the worker fleet are sound and faithfully concretized. **One genuine OTP flaw is
load-bearing and confirmed: the merge-train post-batch health check runs
*inside* `MergeAuthority`'s `handle_call`, serializing a multi-minute toolchain
build on the single merge mailbox (head-of-line blocking).** Two further holes
(a totality gap in INV-18 for a wedged-but-not-crashed worker, and an
under-specified verdict-revoke→CAS ordering window) are real but lower severity.
The Postgres/Oban-vs-single-binary tension is surfaced honestly, not papered
over — that axis is a PASS.

---

## Axis 1 — HR survival (HR-1 … HR-9)

| HR | Survives in layer 04? | Evidence / residual |
|----|-----------------------|---------------------|
| HR-1 merge atomicity (ref TOCTOU) | **PASS** | `merge-and-integration.md` §2b: `git push --force-with-lease=<ref>:<expected-oid>`; the VCS primitive (not M-side timing) closes the ref TOCTOU. The merge-train tip is what is pushed, and `EXPECTED_OLD_OID = base(d)` the gate ran against — see HR-5 sub-finding below for the *train-tip* nuance. |
| HR-2 verdict value-staleness | **PASS (with a narrow ordering caveat — H-3)** | Append-only `verdicts` table, `latest_verdict/1` greatest-run-not-superseded query (`durable-spine.md` §3); CAS reads latest *inside* `handle_call`. Caveat in H-3: the revoke and the CAS-read are in *different processes* (G appends, M reads) and the "inside the critical section" claim only covers M's read, not the G-append→M-read happens-before. |
| HR-3 engine owns test execution | **PASS** | `gate-and-toolchain.md` §3: adapter returns a descriptor only; `Engine.TestRun.execute/2` runs the `Port`, the engine selects the parser by format tag, and the cross-check (step 7) binds the reverted-run failing ids to the green-run passing ids. The adapter cannot choose the parser, assert pass, or see the green ids. Airtightness of the cross-check examined below — **PASS** with one stated assumption. |
| HR-4 declared-scope conflict check | **PASS** | `control-plane.md` §2.3–2.4: `ConflictCheck.clear?/2` over declared sets; P-CC-3 monotonicity; scope-amendment→re-admission escape valve. LIV-4 preserved. |
| HR-5 merge-train / batch integration | **PASS on throughput, HOLE on execution locus (H-1)** | The amortization arithmetic is correct and INV-1..3 hold over the batch tip (one diff, one verdict, one CAS). **But** the *health check that the train requires* is executed inside M's mailbox — the central flaw, H-1. The throughput model HR-5 fixes is undermined by the very stage HR-5 introduces. |
| HR-6 mechanize INV-23/24 | **PASS** | `gate-and-toolchain.md` §5: `Gate.SpecMembership` (pure) + `Toolchain.lint/1` engine-executed; critic owns only the residual. |
| HR-7 author identity not ordering | **PASS** | `worker-fleet.md` §5 step 3: recorded authoring identity + `author(test_g) ≠ author(impl)` predicate asserted at gate time; D-304. |
| HR-8 pin manifest, clamp safety policy | **PASS** | `governance.md` §3: `clamp/1` pure, `N = min(policy, ceiling)`, gate-floor `MapSet.subset?` enforced, ∞-budget rejected, conflict predicate floor-AND-composed. Manifest in the per-unit pin set. |
| HR-9 co-locate decision writers | **PASS** | `durable-spine.md` §2: single `Ledger.Writer` GenServer, one-writer-per-datum, no distributed transaction; budget ledger optionally separate (conservation holds either way). |

**HR-1 sub-finding (train tip vs single-diff expected-oid) — PASS, but note.**
The merge-train rebases B units onto a fresh tip and pushes the *tip*. The
`expected-old-oid` for that push is the `origin/main` head the **batch** was
rebased onto and gated against, not any individual unit's original base. This is
internally consistent (the batch tip is gated as one diff, `synthesis.md` HR-5),
so `--force-with-lease` against the batch's rebase-base correctly closes the
TOCTOU for the batch. No hole. The docs are consistent on this; flagged only
because the prompt asked whether the rebasing tip breaks HR-1 — it does not,
because the lease oid is the *batch* base, established inside the same M critical
section as the push.

---

## Axis 2 — Layer 03 → 04 drift (enforcement-matrix fidelity)

Walked every `●` cell of `system-architecture.md` §3 against the layer-04 module
claimed to enforce it.

| Matrix cell | Layer-04 enforcer | Drift? |
|-------------|-------------------|--------|
| INV-1 ● M CAS | `MergeAuthority` reads live verdict lease pre-push | none |
| INV-2 ● M CAS ref | `--force-with-lease` | none |
| INV-3 ● M concur=1 | single `gen_statem`; at most one `:integrating` train at a time, commit serialized in M | none |
| INV-4 ● M | pre-push batch health → E-RED-MAIN | **partial — see H-1** (the mechanism exists but its execution locus is the flaw) |
| INV-5 ● G author≠impl, ● W spawn order | identity predicate + spawn order | none |
| INV-7 ● G engine-judged | `Engine.TestRun` + `judge/1` | none |
| INV-10 ● W namespace | `init/1` allocate + adapter-declared NS | none |
| INV-13 ● S declared sets | `Scheduler` + `ConflictCheck` | none |
| INV-14 ● W terminate | **`WorkspaceJanitor` monitor, NOT `terminate`** | none — correctly an independent monitor (anti-pattern #11 honored) |
| INV-16 ● L WAL | `Ledger.Writer` Repo txn before ack | none |
| INV-18 ● K FSM | `Coordinator` + `Escalation.classify/1` | **HOLE — H-2**: totality is proven over `term()` *as a classifier function* but NOT over *reachable non-progress system states*; a wedged worker emits no trigger to classify. |
| INV-19 ● U ladder | `Retry.next/3` clamped | none |
| INV-20 ● M push gate | `ActionClassifier` before every push | none |
| INV-21 ● L ledger | `Budget.Owner` ETS + admission pre-check | none |
| INV-22 ● K boundary | `halt_pending` at unit boundary | none |

**Drift verdict: one material drift (H-2, INV-18).** The enforcement matrix
assigns INV-18 *totality* to K as "sole enforcer." Layer 04 discharges totality
of the **classifier** but the invariant is `□(¬progress(s) → ∃! e. escalates)`
over *states*, and a non-progress state that produces no event into K is outside
the classifier's domain. See H-2.

All other `●` cells map faithfully. INV-14's mapping is *better* than the matrix
text (matrix says "● W terminate"; layer 04 correctly uses a monitor, not
`terminate/2`) — an improvement, not a drift.

---

## Axis 3 — OTP anti-pattern walk (12-point checklist)

Applied `supervision-tree.md`'s own checklist plus the otp-non-negotiables to
every process.

| # | Check | Verdict |
|---|-------|---------|
| 1 | No process only to namespace functions | PASS — Gate/ConflictCheck/Retry/Escalation/Policy clamp are pure modules |
| 2 | No irreplaceable heap state | PASS — decisions WAL'd; WIP captured by monitor |
| 3 | No long-lived process outside tree | PASS |
| 4 | `rest_for_one` only where siblings depend | PASS — spine + Ledger sub-tree justified |
| 5 | Reads bypass owner mailboxes | PASS — budget/policy/circuit-breaker ETS hot-reads |
| 6 | No `cast` into slower processes on control path | PASS — `call` everywhere; reply = back-pressure |
| 7 | No pids as identity | PASS — Registry keys; monitor refs for liveness only |
| 8 | No selective receive on hot processes | PASS — `gen_statem`/`call` ref-correlated |
| 9 | Extract fields before send | PASS — ids over structs |
| 10 | Node-crossing idempotent + ref-correlated | PASS — Oban boundary |
| 11 | `terminate/2` NOT relied on for must-happen cleanup | PASS — `WorkspaceJanitor` monitor (the standout-correct decision) |
| 12 | State machines are `gen_statem` | PASS — K, U |
| — | **Long/blocking I/O on a serializing process's mailbox** | **FAIL — H-1.** `MergeAuthority`'s `handle_call` runs the toolchain health build synchronously (see Axis 4). This is checklist point 6's spirit (do not block the back-pressure mailbox) violated by the merge stage itself. |

**The single anti-pattern found is H-1.** Everything else on the checklist is not
merely asserted-clean but is *structurally* clean (pure modules really are pure;
the monitor really is outside the crash domain). The design's OTP hygiene is high
**except** at the one stage where it matters most.

---

## Axis 4 — The merge-train as a blocking bottleneck (H-1, the central flaw)

### The finding

`MergeAuthority` is concurrency-1 by construction — that IS INV-3, and is
correct. The problem is **what runs inside its single `handle_call`**.

Three documents place the batch health check inside M's critical section:

- `supervision-tree.md` Step 4: *"Within one handle_call it: (a) reads the latest
  verdict … (b) applies via git push … (c) **runs the batch health check.** No
  distributed lock; the single mailbox is the lock."*
- `merge-and-integration.md` §4 `integrate_train/1`: a single `with`-chain that
  calls `gate_batch_tip(tip)` then `health_check(tip)` then `cas_push(...)`
  **inline**, with no yield of the mailbox between them.
- `merge-and-integration.md` §5: *"M runs ONE combined health check on the batch
  tip"* and explicitly **pre-push** ("so a red tip never lands").

`merge-and-integration.md` §1 *attempts* to defuse this with a "deterministic
FSM / nondeterministic activity split (the Temporal split)": git ops and "the
health build" are called "activities … invoked from the deterministic core …
performs the ref-update and reports its result back." **But the document never
describes the activity running in a different process or the mailbox being
released while it runs.** A function called from inside `handle_call` —
"activity" or not — executes *on the GenServer's scheduler reduction budget,
inside the call, blocking the mailbox until it returns*. Naming the build an
"activity" is a *conceptual* split (decision vs effect), not a *concurrency*
split. There is no `handle_continue`, no `Task` + `noreply`, no reply-deferral
primitive anywhere in the M design.

### Why this is load-bearing, not cosmetic

`system-architecture.md` §5 establishes `T_int ≈ T_gate + T_health`, that
`T_health` for the bootstrap toolchain is `mix compile --warnings-as-errors +
mix test` (minutes), and that M is the **intended bottleneck** whose service time
is toolchain-bound. The architecture's own arithmetic therefore says M's
`handle_call` is held for `T_int` *minutes* per batch. During that entire window:

1. **No other merge can proceed** — correct and intended (INV-3).
2. **But also: no `request_merge` can even be *received and queued with
   back-pressure feedback*** — callers block on `GenServer.call` (the design uses
   `call`, `control-plane.md` §5 row "U → M `request_merge`"). A `call` blocked
   for minutes risks the **default 5-second `GenServer.call` timeout** firing in
   every waiting U FSM, each interpreting the timeout as a *crash/exit* of the
   call. The docs never raise the call-timeout to `T_int`-scale, nor mention an
   infinite timeout. This is a concrete latent bug: minutes-long `handle_call`
   under default-timeout `call` callers ⇒ spurious U-side `:exit`s.
3. **Verdict revocation during the window is unobservable to the in-flight
   integration.** The CAS read (2a) happens at the *start* of `integrate_train`;
   the health build then runs for minutes; the push happens at the *end*. A
   revoke appended *during* the health build (a late incomplete-fix finding on a
   batch member) is **not re-read before the push** — the design reads the
   verdict once, pre-build, not in a re-validate-on-return step. This is a
   genuine HR-2 regression *at the train granularity*: HR-2's "read latest inside
   the CAS" is satisfied for the pre-build read but the push is not adjacent to
   that read; minutes of health build separate them.

### The fix the design needs (and the prompt predicted)

The health check (and arguably the batch gate) MUST run **outside** the M
mailbox, with a **re-validate-on-return** before the push:

- M's `handle_call({:request_merge,…})` should **assemble the train, snapshot the
  expected-old-oid and the member verdict set, then return `{:noreply, …}`** (or
  reply `:accepted`) and dispatch the health build to a **`Task` under
  `GateTasks`** (or an Oban activity), monitored.
- On the task's `:DOWN`/result message, M re-enters a short *deterministic*
  critical section that: (a) **re-reads the latest verdicts** for every batch
  member (closing the during-build revoke window), (b) **re-checks
  `expected-old-oid` is still current** (origin/main may have moved via a *prior*
  train — though M is sole writer, so only M's own prior merge could move it; the
  re-check is still required because M processed other messages while the build
  ran), then (c) issues the `--force-with-lease` push. The push and the re-read
  are adjacent and fast — *that* is the real CAS critical section; the build is not.
- This keeps INV-3 (only M ever pushes; the push critical section is still
  serialized) while removing `T_health` from the mailbox, so other merges queue
  and other M messages (queue-depth telemetry, kill-flag observation) are served
  during the build.

This is exactly the "health check OUTSIDE the lock with a re-validate-on-return"
shape the prompt flagged. **The current design conflates the *decision* critical
section (must be serialized, microseconds) with the *build* (minutes, must NOT
hold the mailbox).** The "Temporal split" prose gestures at the right idea but
the concrete `integrate_train/1` code contradicts it by running the build inline.

**Severity: HIGH.** It defeats the throughput goal HR-5 exists to achieve (M
serialized on minutes-long builds is precisely the saturation HR-5 fights, now
relocated from re-gate amplification into the mailbox), and carries a concrete
`GenServer.call`-timeout bug and an HR-2 during-build revoke window.

---

## Axis 5 — Postgres/Oban vs single-binary tension

**PASS — surfaced as a discriminating decision, not assumed away.**

`durable-spine.md` §8 explicitly frames the fork: *"The actual fork is Oban.
Oban requires Postgres or SQLite."* It recommends Postgres+Ecto+Oban, gives a
**reasoned fallback** (SQLite/Exqlite + hand-rolled durable `jobs` table +
internal cron tick, reusing the memory subsystem's Exqlite scaffolding), names
the cost of each (extra operational dependency vs re-implementing the Oban slice
the factory uses), and ties it to the live constraint (Burrito single-binary
deployment, D-S4 single-node).

**On RPO=0 specifically:** the doc's claim that *both* SQLite-WAL and Postgres
satisfy RPO=0 on a single node is **correct** — both `fsync` the WAL before
commit; RPO=0 is a function of the WAL-before-ack ordering (`durable-spine.md` §6
proof sketch), not of which engine. **RPO=0 does NOT require external Postgres.**
The Exqlite fallback meets it. So the tension is honestly a *convenience/
operational-maturity* call (Oban's battle-tested retry/cron/uniqueness/Web),
**not** a correctness call — and the doc says exactly that. No hole.

One minor observation (not a hole): the recommendation (Postgres) and the live
product reality (Burrito single binary, `feedback` memory: self-hosting M1 is the
sole near-term objective) point in opposite directions. The doc resolves this by
making it a deployment-constraint switch ("pick SQLite only if a
zero-external-dependency single binary is a hard deployment constraint"). Given
M1 self-hosting ships as a single binary, the *fallback* is in practice the
likely path; the doc would be stronger if it said so, but it has not papered over
anything — the decision is explicit and correctly conditioned.

---

## Axis 6 — Totality of E (INV-18), hunting the missed livelock (H-2)

**HOLE-FOUND — the totality argument is over the classifier, not over reachable
states.**

`control-plane.md` §1.4 proves: *"`classify/1` is total over `term()` … there is
no trigger value for which K neither loops nor emits an `e`."* This is true and
well-argued **for any trigger that reaches K**. The invariant, however, is
`□(¬progress(s) → ∃! e. escalates(s,e))` over **reachable system states** — and
the gap is a state that *produces no trigger*.

**The escaping scenario: a wedged-but-not-crashed worker.** Consider an
`:implementer` worker whose agent `Port` subprocess is alive (no `:exit_status`,
so no `:DOWN`, so no `worker_exit` event to U) but making no progress — an LLM
provider stream that has stalled below the stream-idle threshold but not closed,
a subprocess spin-looping, or a network read blocked indefinitely. Trace the
events:

- **W:** no crash ⇒ no `:DOWN` ⇒ `WorkspaceJanitor` never fires ⇒ U receives no
  `worker_exit`.
- **U:** the `gating` state arms a `:state_timeout` (`control-plane.md` §3.2), but
  the worker is wedged in **`implementing`**, *before* `request_gate`. Is a state
  timeout armed on `implementing`? §3.2 says *"A `{:state_timeout, ms,
  :gate_stall}` is armed on entry to `gating` (**and to any state that waits on an
  external actor**)."* The parenthetical *intends* to cover `implementing`, but
  (a) no `implementing` timeout clause is shown (only `gating`'s is coded), and
  (b) the timeout it names is `:gate_stall`, semantically a gate event, not a
  worker-wedge event. The coverage of `implementing` is asserted in prose,
  **not encoded**, unlike `gating` which has an explicit clause. The "illegal
  transition is unrepresentable" discipline the design prides itself on is
  *absent* here — a missing timeout clause is silent, not a crash.
- **K:** receives nothing. K's totality only fires on a trigger; no trigger
  arrives. K sits in `running` with one unit neither progressing nor escalating.

This is a reachable `(¬progress ∧ ¬escalate)` state — exactly what INV-18
forbids — and it **escapes both** the per-unit retry ladder (no gate FAIL
occurred) and the classifier (no trigger emitted). The totality proof does not
cover it because the proof's domain is "triggers fed to `classify/1`," and the
wedged worker feeds none.

**Why this is the livelock the totality argument misses.** The design's own
liveness section (`liveness.md` LIV-1) assumes *"fair scheduling: an admitted
work unit eventually receives scheduler attention"* but says nothing about an
admitted unit whose *external actor* (the LLM/subprocess) wedges. BEAM fairness
guarantees the *FSM* runs; it does not guarantee the *Port subprocess* makes
progress. Without a **mandatory, encoded liveness timeout on every U state that
waits on an external actor (`implementing`, `oracle`, `awaiting_merge`)** plus a
**worker-level watchdog** (stream-idle / wall-clock deadline that converts a
wedge into a synthetic `worker_exit` or escalation), INV-18 is falsifiable.

**Severity: MEDIUM.** The mechanism to close it is small (encode the
`implementing`/`oracle` state timeouts that §3.2 already *claims*, plus a worker
watchdog feeding a trigger into K so the classifier's catch-all can fire). But as
written, the totality proof has a domain gap and a reachable non-progress state
exists. The `E-UNCLASSIFIED` catch-all cannot save it because the catch-all also
requires a *trigger* to classify.

---

## Additional finding — H-3 (verdict-revoke → CAS happens-before, narrow)

**HOLE-FOUND (LOW), independent of H-1's larger version.**

HR-2's correctness rests on the merge CAS reading the *latest* verdict "inside the
critical section." The append (G→`Ledger.Writer.revoke_verdict`) and the read
(M→`Ledger.verdict_status`) are in **different processes** hitting the same
Postgres-backed `Ledger.Writer`. `verdict_status/1` is a `GenServer.call` to the
Writer (`durable-spine.md` §2 read API), so reads and writes *are* serialized
through the Writer's mailbox — good. **But** M reads the verdict and *then*,
still believing the lease live, proceeds to push. If H-1 is fixed (build outside
the lock) the re-read closes this. If H-1 is *not* fixed, the read-then-minutes-
of-build-then-push sequence means the "inside the critical section" guarantee is
vacuous: the critical section is M's `handle_call`, which spans the whole build,
so a revoke appended at minute 2 of a 5-minute build is durably in L but M will
not re-read it before pushing at minute 5. **H-3 is therefore a corollary of H-1
and is fully closed by H-1's re-validate-on-return fix.** Listed separately
because it is the precise INV-1/HR-2 falsification (a revoked verdict's diff
reaching `main`) that H-1's performance problem also causes — the two are the
same root cause (read and push not adjacent) viewed through safety vs throughput.

---

## Required fixes

| ID | Severity | File | Fix |
|----|----------|------|-----|
| **H-1** | **HIGH** | `merge-and-integration.md` §1,§4,§5; `supervision-tree.md` Step 4 | Move the batch **health build (and batch gate)** OUT of M's `handle_call`: dispatch as a monitored `Task`/Oban activity; M replies `:accepted` / `{:noreply}`. On task completion re-enter a *short* deterministic critical section that **re-reads all member verdicts AND re-checks expected-old-oid**, then issues `--force-with-lease`. The push+re-read is the real CAS; the build must not hold the mailbox. |
| **H-1b** | **HIGH (corollary)** | `control-plane.md` §5 (U→M `call`) | Specify the `request_merge` `GenServer.call` timeout as `T_int`-scale or `:infinity`, OR convert it to an async request + monitored reply, so a minutes-long integration does not trip default 5s `call` timeouts in waiting U FSMs. (Subsumed if H-1 makes M reply fast.) |
| **H-2** | **MEDIUM** | `control-plane.md` §3.2; `worker-fleet.md` §4 | **Encode** (not just prose-assert) a mandatory liveness `:state_timeout` on every U state waiting on an external actor — `implementing`, `oracle`, `awaiting_merge` — each escalating via a classified trigger. Add a **worker watchdog** (stream-idle + wall-clock deadline) that converts a wedged Port into a synthetic `worker_exit`/escalation. Without it INV-18 totality has a reachable counterexample. |
| **H-3** | **LOW** | (closed by H-1) | The revoke-during-integration window is the safety face of H-1; the H-1 re-validate-on-return fix closes it. Add an explicit test (D-300/D-335): append a revoke mid-health-build, assert the push is rejected. |
| n-1 | INFO | `durable-spine.md` §8 | State plainly that M1 self-hosting ships as a Burrito single binary, so the SQLite/Exqlite fallback is the *expected* path, not merely a contingency. Not a correctness issue. |

---

## Verdict

**HOLE-FOUND.** Not FATAL: the boundary placement, the durable-spine RPO=0
proof, the gate's anti-gaming posture (HR-3 engine-owns-execution with the
failing-id cross-check), the worker-fleet isolation, and the HR-1/HR-2 *safety
mechanisms* are sound and faithfully concretized. The Postgres tension is honest.
But the **merge-train health check runs inside the merge mailbox (H-1)** — a
real, load-bearing OTP head-of-line-blocking flaw that defeats the throughput
HR-5 exists to deliver, carries a `GenServer.call`-timeout bug, and opens an
HR-2 verdict-revoke window (H-3); and **INV-18 totality has a reachable
counterexample (H-2)**: a wedged-but-not-crashed worker emits no trigger, so
neither the retry ladder nor the classifier catch-all fires. Both are fixable
without rearchitecture — H-1 by deferring the build off the mailbox with
re-validate-on-return, H-2 by encoding the liveness timeouts the design already
claims in prose. Fix H-1 and H-2 before treating the layer-04 design as
implementation-ready.
