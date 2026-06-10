# Quantified non-functional requirements

Method rule: an NFR is not a requirement until it is a tuple **(statistic,
threshold, window, load)**. "Fast", "scalable", "reliable" are demoted to
assumptions until quantified. Where the requester has given no number, a
**calibrated default** is proposed and marked `[ELICIT]` — it is a starting
interval to be confirmed, not invented fact. Several of these intervals decide
the architecture by themselves (e.g. the concurrency ceiling sets whether
back-pressure is warranted; the recovery RPO sets the durability mechanism).

Load envelope is anchored by **D-S4**: single BEAM node, 10³–10⁵ processes, v1.

| ID | Property | Statistic | Threshold | Window | Load condition |
|----|----------|-----------|-----------|--------|----------------|

---

## Concurrency & throughput

**NFR-CONC — concurrent work units.** `[ELICIT]`
The control plane sustains **C_max concurrent in-flight PRs** with bounded
re-gate cost. Proposed default: `p50 = 4`, `peak = 16` concurrent PRs on one
node, admission-controlled by budget and the conflict check.
*(statistic: concurrent-unit count; threshold: ≤ 16 peak; window: steady-state;
load: a milestone of ~50 open issues.)*
**Architectural consequence:** at peak 16, each serialized merge forces ≤ 15
freshness re-checks (Q-L2). If `peak` rises past ~32, re-gate cost goes
super-linear and a back-pressure / merge-batch boundary (GenStage) becomes
warranted; below it, `Task.async_stream`-bounded fan-out suffices (research:
OTP §6). **This single number decides whether Broadway is in the architecture.**

**NFR-AGENT-FLEET — agent process count.** The node hosts up to **A_max
concurrent agent processes** (implementers, test-authors, critics, reviewers,
researchers) across all in-flight PRs. Default: `≤ 128` live agent processes,
each a supervised crash domain. *(threshold: 128; window: peak; load: peak PRs ×
agents-per-PR.)* Well within BEAM's 10³–10⁵ envelope.

**NFR-MERGE-RATE — merge cadence.** Serialized merge + post-merge health check
completes at **p95 ≤ T_merge**. Default `[ELICIT]`: `T_merge = 8 min`
(dominated by the polyglot toolchain's `build + test` on the target repo).
*(statistic: p95 wall-time of merge+health; threshold: 8 min; window: per merge;
load: target repo of moderate size.)* This is the loop's throughput governor —
it is intentionally toolchain-bound, not control-plane-bound.

## Latency

**NFR-SPAWN — worker spawn latency.** A work unit's isolated workspace (git
checkout + per-worker resource namespace) is ready at **p95 ≤ 30 s**.
*(statistic: p95; threshold: 30 s incl. dependency warm-cache; window: per
spawn; load: peak concurrency.)* Sandbox/container cold-start for a new
polyglot toolchain may exceed this on first use — first-use cold start is
exempt and `[ELICIT]` (proposed `p95 ≤ 5 min` cold).

**NFR-KILL-LATENCY — kill-switch latency.** From kill signal to clean halt:
**≤ 1 atomic unit**, bounded above by `T_unit_max` `[ELICIT default 30 min]`.
Halt is between units, `main` synced, never mid-merge (INV-22). *(statistic:
worst-case; threshold: 1 unit; window: any; load: any.)*

## Reliability & recovery

**NFR-RPO — recovery point objective.** `RPO = 0` for committed factory
decisions: a coordinator crash/restart loses **no** persisted decision (INV-16).
*(statistic: data-loss window; threshold: 0; window: any crash; load: any.)*
**This number forces the durability mechanism**: RPO=0 means decisions are
write-ahead-committed to a transactional store before their effects are visible
— ruling out "context window as state" and "periodic snapshot". Mechanism
**decided (OQ-1): SQLite/Exqlite** in WAL mode (`synchronous=FULL`), which
`fsync`s before commit and meets RPO=0 single-node while preserving the
single-binary deployment (`04-software-architecture/durable-spine.md` §8).

**NFR-RTO — recovery time objective.** After coordinator restart, the loop
resumes driving in-flight PRs within **p95 ≤ 60 s** of process start.
*(statistic: p95; threshold: 60 s; window: per restart; load: peak in-flight.)*

**NFR-BLAST — crash blast radius.** A single worker crash affects **0** other
workers and does not halt the coordinator (INV-17). *(statistic: count of
affected peers; threshold: 0; window: any crash; load: peak concurrency.)* This
is a categorical guarantee from process isolation, not a probability.

**NFR-CONTROL-AVAIL — control-plane availability (v1).** Single-node;
node-process crash is recovered by supervision + durable-state reload within
RTO. Whole-node loss is **out of scope for v1 HA**; the durable store survives a
node *restart* (state on disk in the SQLite file, not in BEAM memory), while
surviving whole-*machine* loss needs file replication (Litestream/LiteFS),
deferred with HA. `[ELICIT]` whether a
node-loss recovery target is required for v1.

## Resource governance

**NFR-BUDGET-PRECISION — budget enforcement.** Spend never exceeds budget by
more than **one in-flight action's cost** (admission is checked pre-action;
INV-21). *(statistic: overrun; threshold: ≤ 1 action; window: at exhaustion;
load: any.)*

**NFR-EGRESS — LLM egress overload control.** Outbound provider calls respect
per-provider rate limits with **0 sustained 429-driven failures** under the
documented compose order: token-bucket rate limiter → circuit breaker (5xx
storms) → budget ledger (research: OTP §5 — these exist in-repo and are reuse
candidates). *(statistic: sustained-failure count; threshold: 0; window: steady
state; load: peak concurrent provider calls.)*

## Observability

**NFR-OBS-COVERAGE — telemetry coverage.** **100%** of user-visible or
perf-sensitive factory events emit paired `[:tau, …]` telemetry spans
(`*.start` / `*.stop` / `*.exception`) (INV-24 #5). *(statistic: covered-event
fraction; threshold: 100%; window: continuous; load: any.)*

**NFR-AUDIT — decision traceability.** **100%** of merges are traceable from the
`main` commit back through gate verdicts → gating-test paths → AC/D-NNN → SPEC →
issue, with no missing link. *(statistic: traceable-merge fraction; threshold:
100%; window: continuous; load: any.)*

## Correctness-quality (the gate's job, quantified where possible)

**NFR-GAME-RESISTANCE — anti-gaming.** Under an adversarial-implementer
assumption, the fraction of vacuous tests (pass against reverted production)
reaching `main` is **0** (mechanically guaranteed by INV-7 mutation check).
Under-asserting/wrong-path tests are **not** mechanically bounded — a known
residual resting on critic judgement (research GAP-7); this NFR explicitly does
**not** claim a number for them, to avoid false confidence. *(statistic: vacuous
fraction; threshold: 0; window: per PR; load: any.)*

---

## NFRs that are really discriminating questions

These four `[ELICIT]` numbers each change the architecture; they are surfaced to
the operator rather than silently fixed:

1. **C_max / peak concurrency (NFR-CONC)** — decides Broadway-vs-`async_stream`.
   *Cost asymmetry:* over-provisioning back-pressure machinery for a 4-PR
   workload is wasted complexity; under-provisioning for a 64-PR workload causes
   re-gate storms and merge starvation. **Recommend default peak=16** (one node,
   moderate milestone), revisit if the milestone backlog is large.
2. **T_merge / merge cadence (NFR-MERGE-RATE)** — sets the loop's throughput and
   is mostly toolchain-bound (polyglot D-S2). *Cost asymmetry:* none to the
   design; it is a measured property, not a choice — listed so it is measured,
   not assumed.
3. **RPO (NFR-RPO)** — decided: **0** (forces durable spine), mechanism
   **decided (OQ-1): SQLite/Exqlite** WAL (`04-software-architecture/
   durable-spine.md` §8), preserving the single-binary deployment.
4. **Node-loss HA (NFR-CONTROL-AVAIL)** — is v1 single-node-recoverable
   sufficient, or is multi-node failover required? *Cost asymmetry:* designing
   single-node-recoverable now (durable state off-heap) keeps the door open
   cheaply (D-S4); requiring true HA now imports clustering/split-brain cost
   into the merge-serialization point. **Recommend: single-node-recoverable v1,
   durable store survives node loss, true HA deferred.**
