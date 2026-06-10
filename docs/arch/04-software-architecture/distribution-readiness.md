# Distribution readiness — making D-S4 falsifiable

D-S4 (`../00-problem/scope-decisions.md`) commits the factory to **single-node
v1, distribution-ready**: one BEAM node now, with boundaries drawn so a later
multi-node move is *configuration + supervisor placement*, not a rearchitecture.
This file makes that claim **precise and falsifiable**. It states the consistency
posture per component, audits the location-transparency discipline against the
actual layer-04 design, shows the one execution-tier seam that scales out, names
what distribution **breaks if done naively**, lists the concrete v1→vN change
set, and closes with a falsifiable readiness checklist.

Grounding: `supervision-tree.md` Step 6, `../03-system-architecture/
system-architecture.md` (L/K/S/G/W/U/M), `worker-fleet.md` §8, and the research
ruling in `../01-research/otp-capabilities.md` §11. Tied to **NFR-CONTROL-AVAIL**
(`../02-requirements/nfrs.md`).

The framing throughout is Cesarini & Vinoski's consistency-posture axis:
**replicate-for-availability** (a component MAY have many instances; staleness or
partition is tolerable) vs **partition/route-for-consistency** (a component MUST
be a single authoritative instance; replicating it is a *consensus* problem, not
a scaling win). The whole of D-S4 reduces to keeping that axis honest.

---

## 1. Consistency posture per component (L/K/S/G/W/U/M)

| Comp | Posture | MUST stay single-instance? | Why | Enforcing invariant |
|---|---|---|---|---|
| **L** Ledger | **partition/route-for-consistency** | **YES — system-of-record** | Append-only single-writer-per-datum (HR-9); the durable truth every other component re-derives from. Two writers = two divergent solution trees = conservation-law (CON-1..7) violation. | INV-16, CON-1..7 |
| **M** Merge Authority | **partition/route-for-consistency** | **YES — the merge serialization point** | Concurrency-1 is INV-3 *by construction*; the merge CAS (HR-1/HR-2) is the one critical section that cannot tolerate split-brain. Two M instances under partition = two concurrent `origin/main` writers = the catastrophe D-S1's safety wall exists to forbid. | INV-1..4, INV-3 (sole enforcer) |
| **K** Coordinator | partition/route (single live) | YES (single *live* instance) | One loop authority; `gen_statem` resumes from L on restart (LIV-5). Two K = double work-selection. Stateless-on-restart (re-derives from L), so it is *recoverable*, not *replicable*. | INV-18, LIV-3/5 |
| **S** Scheduler | partition/route (single live) | YES (single *live* instance) | Admission decisions are monotone and serialized (LIV-4); the conflict check (INV-13) must see one authoritative in-flight set `F`. Two S = two admission authorities = conflict-check races. | INV-13, LIV-4 |
| **U** Unit FSM | per-entity, single-owner | One owner *per PR* (not global) | Each PR's lifecycle owned by exactly one FSM (the authority-split fatal flaw — `system-architecture.md` §7). Many U's coexist; each is singular for *its* unit. Co-resident with K/S today. | INV-19, LIV-1 |
| **G** Gate run | **replicate-for-availability** | **NO — MAY scale out** | A gate run is a bounded, stateless `Task.async_stream` fan-out over a *frozen* diff (`supervision-tree.md` Step 0). Verdicts are written append-only to L; the gate holds no authoritative state. Many gate runs may execute concurrently on many nodes. | INV-5..9 (verdicts land in L) |
| **W** Worker | **replicate-for-availability** | **NO — MAY scale out (the tier)** | The horizontally-scalable execution tier (`worker-fleet.md` §8). Workers are `:temporary`, idempotent, ref-correlated; their isolation boundary is node-local and self-contained. Losing one affects 0 peers (NFR-BLAST). | INV-10/14/15/17 |

### The consistency core — L and M

**L and M are the consistency core that MUST NOT be naively clustered.**

- **M is the merge serialization point.** Its entire value is that a single
  concurrency-1 mailbox *is* INV-3 — no lock discipline, no distributed
  transaction. Cluster M and you replace a free, local, total order with a
  distributed consensus that can split-brain. Under partition, two M halves each
  believe they hold the critical section; each does a CAS against its view of
  `origin/main`; the loser's `--force-with-lease` may still race a stale read on
  the other node. The research ruling is explicit (otp-capabilities §11): global
  naming is "a consensus problem with split-brain behaviour you must choose, not
  a free upgrade from `Registry`." M is exactly where that choice must be
  declined.

- **L is the system-of-record.** Every recovery path (FC-1, FC-4, LIV-5) re-reads
  L. If L is replicated for availability and a partition lets two replicas accept
  writes, the solution tree forks — and *both forks look authoritative*. CON-1..7
  (single-writer accounting, verdict conservation) are unprovable across a
  multi-master L. The correct HA story for L is **single-writer with durable
  storage** — failover, not active-active. With the chosen **node-local SQLite**
  store (OQ-1), surviving *whole-node* loss additionally requires file-level
  replication (e.g. Litestream/LiteFS) or a deliberate store change — a further
  reason HA is deferred (§5 Stage b). This is precisely NFR-CONTROL-AVAIL's posture.

**K and S are single-*live*-instance but recoverable, not replicable.** They hold
no authoritative state of their own — they re-derive from L on restart. The
distinction matters: you make them *available* by fast restart against a durable
L (NFR-FACTORY-RTO, p95 ≤ 60 s), never by running two at once.

---

## 2. Location-transparency discipline — checklist audited against layer-04

The design is "distribution-ready" only if it already obeys the disciplines that
make a node move cheap. Each is **verified against the current layer-04 design**;
none is aspirational.

| Discipline | Requirement | Holds in layer-04? | Evidence |
|---|---|---|---|
| **Address by logical key, never pid** | Identity is a Registry key; no held pid in durable state. | ✅ HOLDS | `supervision-tree.md` Step 4: `{:via, Registry, {UnitRegistry, unit_id}}` / `WorkerRegistry`; anti-pattern review #7. A stored pid is "a dangling pointer after restart." |
| **Events via Phoenix.PubSub, never `:global`** | Cross-process events broadcast over PubSub; no `:global`, no `whereis \|> send`. | ✅ HOLDS | `supervision-tree.md` tree: `Tau.Factory.PubSub` high in the spine, "never :global"; OTP non-negotiable #4. |
| **No cross-node ETS reliance** | ETS is a *node-local hot projection* rebuilt from durable truth, never reached across a boundary. | ✅ HOLDS | Step 2: budget/policy/breaker ETS snapshots "rebuilt from durable source on owner restart"; `init/1` rehydrates from the SQLite store. Reads bypass the owner mailbox but never the node. |
| **Durable state survives node restart** | The system-of-record is on disk (the SQLite file), not BEAM memory. | ✅ HOLDS (restart) / ⚠ whole-node loss needs file replication | Step 2: solution tree + budget ledger durable in SQLite/Exqlite (INV-16, RPO=0). Surviving a node *restart* is by construction; surviving whole-*machine* loss needs Litestream/LiteFS (HA, §5 Stage b, deferred). |
| **No co-residency assumption** | No component assumes another shares its heap/ETS/filesystem. | ✅ HOLDS (W) / ⚠ NODE-LOCAL BY DESIGN (core) | `worker-fleet.md` §8: worker isolation boundary is "node-local and self-contained… no shared filesystem assumption." Core (L/M/K/S) is *intentionally* co-resident — see flag below. |

### Flags

- **No outright violation found.** The layer-04 design already obeys the four
  hard disciplines (key-addressing, PubSub, no cross-node ETS, durable truth).
- **One *intentional* co-residency to make explicit (not a bug):** L, M, K, S
  share a node *by design* (the consistency core, §1). This is not a
  location-transparency violation — it is the **deliberately node-local
  boundary** D-S4 marks and justifies. The discipline is satisfied because the
  co-residency is *named and justified*, per D-S4's standing constraint ("would
  this still be correct if the process lived on another node?" — for L/M the
  answer is *no, and that is the point*).
- **One latent dependency to watch:** `Phoenix.PubSub` default adapter is
  node-local. Going multi-node for *event fan-out to remote observers* (a
  dashboard on another node) requires opting into a distributed PubSub adapter —
  a **configuration** change, not a code change, and explicitly *not* on the
  control path (control coordination is `call`/CAS, not PubSub). Listed in §5.

---

## 3. The explicit execution-tier queue boundary (W moves off-node)

The only tier that scales out is **W (and the G runs it hosts)**. The seam is an
**explicit pull queue (Oban)**, not distributed-BEAM magic.

```
   single node (control plane)                 │   node N (execution tier, later)
                                               │
   K → S → U  ──enqueue(work, ref)──▶ Oban ◀───┼── pull(work) via API ── WorkerSupervisor
                              (SQLite, node-local) │         │ (DynamicSupervisor, :temporary)
                                       ▲        │         ▼
                                       │        │      Worker (private worktree + complete
   M ◀── request_merge(unit, hash) ────┼────────┼──────  resource namespace, node-local)
   L ◀── verdict/debit (append-only) ──┘        │         │
                                               │      Gate run (Task.async_stream, local)
```

**How a worker moves off-node — what changes and what does not:**

- **The isolation MODEL is unchanged.** A worker's worktree, resource namespace
  (`XDG_DATA_HOME`/`MIX_HOME`/`HEX_HOME`/… per-worker, `worker-fleet.md` §2b),
  agent `Port`, and `WorkspaceJanitor` monitor are **node-local and
  self-contained** (`worker-fleet.md` §8). The same `init/1` allocation, the same
  `:DOWN`-monitor capture-before-destroy (INV-14), and the same per-worker
  namespace apply unchanged on the remote node. Nothing in INV-10/14/15/17 spans
  a node.
- **The ONLY thing that changes is *placement*:** the `WorkerSupervisor`'s
  children (and the `GateTasks` fan-out) are started on a remote node instead of
  the control node. In supervision-tree terms, `Tau.Factory.WorkerSupervisor`
  (and `Task.Supervisor GateTasks`) become **node-placed** children driven by an
  Oban queue rather than co-resident `DynamicSupervisor` children.
- **The contract that makes this safe:** remote workers **PULL** work from Oban;
  every job is **idempotent** (re-delivery after a timeout is benign) and
  **ref-correlated** (the result message carries the unit/worker ref, so a
  late/duplicate reply is matchable and discardable). This is an honest API
  boundary, exactly the research recommendation (otp-capabilities §11: "an
  HTTP/queue boundary between a control node and stateless executor nodes is the
  honest design").
- **SQLite consequence (OQ-1).** Because the durable store is a **node-local
  SQLite file**, the off-node tier does **not** connect to the queue's database
  directly. The control node **serves the queue over an API/RPC**; remote workers
  pull through that endpoint. This is *more* honest than a shared Postgres
  connection — it forces the API boundary the design wants anyway — and it keeps
  every SQLite access node-local (the single-writer model is never contended
  across the wire). The Oban-Lite-vs-hand-rolled choice (`durable-spine.md` §8)
  is behind this API and does not change the contract.

Cross-reference: `worker-fleet.md` §8 (node-local isolation), `durable-spine.md`
(Oban as the backlog system-of-record), `supervision-tree.md` Step 6.

---

## 4. What distribution BREAKS if done naively

Distribution is *configuration* **only because** the core was kept off the wire.
Cross a node boundary in the wrong place and these BEAM semantics change. Each is
mapped to the component it would endanger.

| Naive move | What breaks | Endangered component | Mitigation already in design |
|---|---|---|---|
| Node-crossing `call` on the control path | A `call` timeout no longer means "didn't happen" — the work may have completed remotely. Exactly-once is gone; idempotency becomes mandatory. | **M** (the merge CAS must be local — a timed-out remote CAS could leave `origin/main` ambiguously advanced) | **Keep the merge CAS node-local** (M concurrency-1, single mailbox = the lock; HR-1). Only *idempotent, ref-correlated* work crosses (W via Oban). |
| Monitors across a partition | `Process.monitor` fires `:DOWN` on **suspicion** (network partition), not just death. A live remote worker looks dead; capture-before-destroy may fire on a worker still writing. | **W** (false `:DOWN` → premature reclaim) / **U** (acts on a phantom worker_exit) | Worker isolation + capture is **node-local** (`worker-fleet.md` §8); the queue (Oban) is the liveness authority for off-node work (job lease/heartbeat), not a raw distributed monitor. |
| `:global`/Horde to register the core | Cluster-wide naming is a **consensus problem with a split-brain choice** — not a free `Registry` upgrade. Under partition, two registrations of M or L can both win. | **M, L, K, S** (the entire consistency core) | Forbidden by OTP non-negotiable #4 and §1: the core is **single-node**, addressed by node-local `Registry`. `:global` is never used. |
| Spread the FSM population over distributed Erlang full-mesh | Distributed Erlang is full-mesh, one TCP per node pair → **head-of-line blocking** on large messages (diffs, agent transcripts); the cluster degrades under exactly the payloads the factory sends. | **All** (control-path latency), worst for **G/W** large-diff traffic | Don't cluster the FSMs. W/G scale via a **queue** (Oban over the node-local SQLite, served to executors via API), not raw distributed message passing; large payloads go through durable storage, not the wire. |

**The single load-bearing rule:** *the merge CAS (M) and the system-of-record (L)
must remain node-local*, because a node-crossing call timeout cannot be
interpreted as "didn't happen" at the one point where that interpretation is
load-bearing for correctness (INV-2/INV-3).

---

## 5. Concrete v1→vN change list

Tied to **NFR-CONTROL-AVAIL** (`../02-requirements/nfrs.md`: single-node
v1; node-process crash recovered by supervision + durable reload within RTO;
whole-node HA deferred).

### Stage (a) — control-plane-single-node + distributed execution

The supported, low-risk move. Control plane stays exactly as v1; only W/G fan out.

1. **Provision executor node(s).** Reachable control-node **queue API** (Oban
   over the node-local SQLite, exposed via an endpoint — workers never open the
   SQLite file directly) + the per-language toolchain installed; no BEAM
   clustering of the control plane required.
2. **Place `WorkerSupervisor` (and `GateTasks`) on the executor node.** A
   supervisor-placement change: the `DynamicSupervisor` for W and the
   `Task.Supervisor` for gate runs start on the remote node, driven by Oban
   pulls. No change to W's `init/1` isolation allocation (`worker-fleet.md` §2/§8).
3. **Define the Oban pull queue + job schema** for `spawn(role, brief, ref)`.
   Configuration + one Oban worker module; the brief and ref already exist.
4. **Assert idempotency + ref-correlation on the worker job** (re-delivery
   benign; result carries the ref). Already a design property (anti-pattern
   review #10); here it becomes load-bearing.
5. **Opt into a distributed `Phoenix.PubSub` adapter** *only if* remote observers
   (a dashboard on another node) must receive `[:tau, :factory, …]` events.
   Configuration, off the control path. Skip if observers are control-node-local.
6. **Per-node resource-namespace isolation stays unchanged** — it was always
   node-local; concurrency isolation now happens to be *across* nodes too, for
   free.

**What does NOT change in Stage (a):** L, M, K, S, U placement; the merge CAS; the
isolation model; every invariant INV-1..24; the conflict check; the escalation
set. This is the whole point of D-S4.

### Stage (b) — HA control plane (deferred / discouraged)

Only if NFR-CONTROL-AVAIL is later upgraded from "single-node-recoverable" to
"survive whole-node loss with hot failover."

7. **Stand up a standby control node** with replicated durable L. With node-local
   SQLite (OQ-1) this means **streaming file replication** (Litestream/LiteFS) or
   a deliberate migration to a networked store — a larger move than Postgres
   primary/replica would have been, and the main reason HA is discouraged here.
8. **Add a single-active-leader election for K/S/M** (leader lease via the
   durable store, e.g. an advisory lock / `unique` Oban leader row) — **NOT**
   `:global`/Horde active-active. Exactly one M holds the merge critical section
   cluster-wide, ever.
9. **Fence the old leader before promoting the standby** (`--force-with-lease`
   plus a durable epoch/fence token on the merge ref) so a partitioned old M
   cannot complete a CAS after a new M is elected.

**Why (b) is deferred and discouraged.** HA-ing the control plane imports
*split-brain risk into the merge point* — the one place §1/§4 say must never
have two authorities. Even leader-election HA only *reduces* the window; it adds
fencing complexity and a consensus dependency to a component whose v1 value is
that it needs *none*. NFR-CONTROL-AVAIL therefore **recommends single-node-
recoverable v1, durable store survives node loss, true HA deferred**
(`../02-requirements/nfrs.md` §"discriminating questions" #4). Stage (b) is
listed for completeness, not as roadmap — pursue only on an explicit elicited
HA requirement, and even then prefer fast failover (RTO) over active-active.

**Change-list length:** **6 itemized steps** to reach distributed execution
(Stage a); **3 further steps** (7–9) for HA control plane, gated behind an
explicit requirement and carrying the split-brain caveat.

---

## 6. Falsifiable readiness criteria

D-S4's claim — "distribution is config, not rearchitecture" — holds **iff every
property below holds**. Each is a falsifiable check against the layer-04 design,
not a vibe. A single failing row falsifies distribution-readiness and names the
fix.

| # | Property (falsifiable) | How to falsify | Status in layer-04 |
|---|---|---|---|
| R1 | **No module resolves a pid across what would become a node boundary.** All cross-component addressing is by Registry key or durable id. | Grep for held pids in durable state or in cross-component messages; any pid-as-identity falsifies. | ✅ Step 4 (keys only); review #7 |
| R2 | **Every cross-component message that could cross a node boundary is idempotent or ref-correlated.** | Find a W/G-bound message whose re-delivery would double-act and carries no ref. | ✅ review #10; §3 queue contract |
| R3 | **M and L are never assumed co-resident with a worker.** No worker reads M's or L's ETS/heap directly; it goes through the queue / append-only API. | Find a worker code path reaching M/L state in-process. | ✅ worker-fleet §8 (node-local, self-contained) |
| R4 | **No `:global` and no cross-node ETS on any path.** | Find a `:global` registration or an ETS table read by a non-owner across a node. | ✅ non-negotiable #4; Step 2 (ETS = node-local projection) |
| R5 | **The merge CAS (M) is node-local and single-instance.** Concurrency-1; no distributed lock. | Find a design path that runs two M instances or a node-crossing CAS. | ✅ INV-3 by construction; §4 mitigation |
| R6 | **All authoritative state is durable off-heap (survives node loss); ETS is rebuildable projection only.** | Find authoritative state that exists only in a process heap or only in ETS. | ✅ INV-16, RPO=0; Step 2 litmus |
| R7 | **The execution tier (W/G) holds no authoritative state** — verdicts/decisions land in L append-only. | Find a worker/gate that is the sole holder of a decision. | ✅ §1; G writes verdicts to L |
| R8 | **The move to distributed execution touches only placement + config** (WorkerSupervisor/GateTasks placement, an Oban queue, optional PubSub adapter) — no invariant, no FSM, no contract changes. | Find an invariant/contract change required by Stage (a) §5 steps 1–6. | ✅ §5 Stage (a) |
| R9 | **HA control plane is the *only* thing that imports split-brain**, is explicitly deferred, and is gated behind an elicited NFR-CONTROL-AVAIL upgrade. | Find a v1/Stage-(a) requirement that needs leader election or active-active L/M. | ✅ §5 Stage (b) caveat; NFR-CONTROL-AVAIL |

**If R1–R8 all hold, distribution to a control-plane-single-node +
distributed-execution topology is configuration and supervisor placement, not a
rearchitecture — D-S4 verified.** R9 holds the line that HA control plane (the
one rearchitecture-shaped move) stays deferred and consciously chosen.

---

## Cross-references

- D-S4 — `../00-problem/scope-decisions.md`
- NFR-CONTROL-AVAIL — `../02-requirements/nfrs.md`
- 7-component shape (L/K/S/G/W/U/M) — `../03-system-architecture/system-architecture.md`
- Distribution boundary (Step 6) & supervision tree — `supervision-tree.md`
- Worker isolation = node-local & self-contained (§8) — `worker-fleet.md`
- Durable spine (Oban-as-system-of-record) — `durable-spine.md`
- Merge CAS / serialization — `merge-and-integration.md`
- Research ruling (keep control plane single-node; `:pg`/Horde as consensus) —
  `../01-research/otp-capabilities.md` §11
