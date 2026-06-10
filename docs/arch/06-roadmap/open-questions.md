# Open discriminating questions — consolidated register

Per the solution-shaping discipline: where the design is underdetermined, surface
the **discriminating question** with its **cost asymmetry** and a recommendation,
rather than picking by taste. These are the decisions a human (or a measurement)
should resolve before or during implementation. The four imposed scope decisions
(D-S1..S4) are already settled in `../00-problem/scope-decisions.md`; these are
the residual choices the analysis surfaced.

| ID | Question | Cost asymmetry | Recommendation |
|----|----------|----------------|----------------|
| **OQ-1** ✅ **RESOLVED** | **Durable store: Postgres+Oban vs SQLite/Exqlite single-binary?** | Postgres ⇒ best durability + free Oban backlog/retry/cron, but an operational dependency that forfeits single-binary deployment. SQLite/Exqlite ⇒ preserves single-binary (reuses the existing `memory/` Exqlite substrate) and meets RPO=0 single-node. | **DECIDED (operator): SQLite/Exqlite** — keep the single binary. RPO=0 via SQLite WAL (`synchronous=FULL`); reuses the `memory/` Repo/migration scaffolding. The durable **ledger** is plain Ecto-over-Exqlite. The only residual sub-decision is the *backlog mechanism* — **Oban's SQLite/Lite engine** (preferred, avoids hand-rolling) vs a minimal hand-rolled SQLite job table — resolvable by a spike; it touches no invariant or schema. Consequence: off-node execution reaches the control node's queue via an **API boundary** (no shared SQLite file); whole-node-loss HA would need file replication (Litestream/LiteFS), deferred. See `04-software-architecture/durable-spine.md` §8. |
| **OQ-2** | **`T_unit / T_int` ratio on the bootstrap toolchain** — the binding input to `W_cap` and merge-train batch size `B`. | Guess high ⇒ re-gate storms + merge starvation (the `ρ_g→1` instability). Guess low ⇒ idle capacity. The re-gate feedback loop makes a wrong guess actively harmful, not merely suboptimal. | **Instrument from day one** (the merge-authority telemetry already emits `T_int`). Operate conservatively (small `W_cap`, `B≥2`, never `B=1`) until measured on the self-hosting adapter; then size from `ρ_g < 1 − margin`. |
| **OQ-3** | **Merge-train batch size & failure-bisection policy** — larger `B` amortizes re-gating more but raises batch-failure (bisection) cost and the chance a batch combination breaks a test no individual PR did. | Large `B` ⇒ higher throughput, costlier and more frequent bisections. Small `B` ⇒ safer, less amortization. | Resolve empirically once OQ-2 is measured. Start `B≈2–4`; the batch **tip must be gated** (not just individual PRs) so INV-1 holds for the combination — see final-validation. |
| **OQ-4** | **Node-loss HA for the control plane** — is single-node-recoverable (durable state survives node loss, supervised restart) enough for v1, or is multi-node failover required? | Single-node-recoverable ⇒ cheap (durable store off-heap), but a node loss = downtime until restart. True HA ⇒ imports clustering + split-brain risk **into the merge-serialization point**, the one place that cannot tolerate it. | **Single-node-recoverable v1** (NFR-CONTROL-AVAIL). Defer/discourage HA control plane; if scale demands it, scale **execution** horizontally (OQ-5), never the merge authority. |
| **OQ-5** | **When to move worker execution off-node** — the execution tier is the horizontally-scalable part (pull via a queue boundary). When is the added distribution complexity worth it? | Off-node early ⇒ premature complexity (idempotency, ref-correlation, queue ops). Off-node never ⇒ single-node agent-fleet ceiling (NFR-AGENT-FLEET ~128 procs, well within one node). | Stay single-node until the agent fleet or toolchain CPU/IO genuinely saturates one node. The boundary is already drawn (Registry keys, PubSub, no cross-node ETS) so the move stays cheap. |
| **OQ-6** | **Merge fairness: FIFO vs aging** (Q-L1). Each merge re-stales in-flight branches, so an unlucky large branch can starve behind a stream of small ones. | FIFO ⇒ simpler but admits starvation (a real LIV-2 break). Aging ⇒ one comparator's cost prevents it. | **Aging** — the re-gate loop makes starvation a genuine liveness hazard, not a corner case; the cost is trivial. |
| **OQ-7** | **Budget-ledger co-location** — share the Ledger authority or stand alone? | Correctness-neutral (HR-9): conservation holds either way. Co-located ⇒ simpler; separate ⇒ isolates a different rate class (`λ_budget ≫ λ_decision`). | **Co-locate in L for v1**; split only if budget-write contention is measured. |
| **OQ-8** | **Policy surface scope** — which decisions are genuine policy (data) vs invariant (engine)? The volatility-split verifier flagged that mis-cutting the gate-floor is the one silent-bypass that defeats the whole anti-gaming design. | Treating an invariant as policy ⇒ a single config edit silently defeats a safety guarantee. Treating policy as invariant ⇒ rigidity, more re-verification on change. | The engine-clamp rule (HR-8) is the answer: gate-floor non-shrinkable, N/budget engine-clamped, conflict-predicate floor only-tightenable. **Audit any new policy field against "does the invariant hold for ALL admissible values?" before making it policy.** |

## How to use this register

**OQ-1 is now resolved (SQLite/Exqlite).** The remaining pre-implementation
decision is **OQ-2** (measure `T_unit/T_int` before sizing concurrency — the
throughput model is unstable without it). The rest can be deferred and resolved
empirically as the self-hosting dogfood loop produces real numbers. None blocks
writing `SPEC-FACTORY-CORE` and standing up the first single-Unit dogfood seam —
and OQ-1's resolution makes that seam concrete: the durable store is the existing
Exqlite substrate.
