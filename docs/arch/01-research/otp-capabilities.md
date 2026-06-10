# BEAM/OTP Capability Surface → Autonomous Coding-Factory Control Plane

**Status:** research synthesis (01-research)
**Method:** map each OTP/BEAM primitive to a named factory concern; state the
right primitive, its concrete process/behaviour shape, and the anti-patterns.
**Grounding:** the live `Tau.Application` tree, `SPEC-CIRCUIT-BREAKER`,
`Tau.Providers.RateLimiter`, and `SPEC-USER-TURN` already exercise most of
these patterns; this file generalises them to the *factory* control plane
(PRs, agents, gates) rather than the *single-user session* runtime.

> **Reading note.** "Factory" here is the autonomous control plane: it turns
> intent into acceptance criteria, decomposes work, spawns many concurrent
> fallible coding agents on isolated git worktrees, gates every change, merges
> serially, recovers from partial failure, governs budgets, persists a solution
> tree + memory, emits telemetry, and escalates to a human only at defined
> boundaries. Each capability below is mapped to one or more of those concerns.

---

## 0. Capability → concern map (index)

| OTP/BEAM capability | Primary factory concern | Right-primitive verdict |
|---|---|---|
| Supervision trees + restart strategies | Fault containment of agents/gates; cascade vs isolation; capture-before-destroy fits restart semantics | **Core.** `rest_for_one` for the control-plane spine; `one_for_one` + `:temporary` for the agent population |
| `gen_statem` vs hand-rolled FSM | Per-PR lifecycle & per-agent lifecycle as explicit state machines | **`gen_statem`.** Illegal transitions unrepresentable; state-timeouts free |
| `GenServer` placement | Owned mutable state w/ serialized writes (solution tree, budget ledger) | **Yes, but only where a runtime property demands it.** Never to wrap pure logic |
| `DynamicSupervisor` + `Registry` | One process per PR / per agent, addressed by key | **Core.** Process-per-entity, lookup-or-start, pid-free identity |
| `Task` / `Task.Supervisor` | Bounded fan-out subtasks: parallel gate halves, research fan-out, tool dispatch | **Yes** for one-shot concurrent work with a result; always supervised |
| `Phoenix.PubSub` + monitored refs | Cross-process events: event stream, gate verdicts, escalation | **Core.** Never `:global`, never `whereis |> send` |
| GenStage / Broadway | Backpressure on *work intake* and bounded agent concurrency | **Conditional.** Warranted at the intake/throttle boundary; *not* for the gate pipeline |
| ETS / `:persistent_term` | Shared read-mostly state: command/skill catalogs, budget snapshots, breaker table | **Yes**, under a boring owner process; `:persistent_term` for write-rarely |
| `:telemetry` | Spans/metrics for everything user-visible or perf-sensitive | **Mandatory** (OTP non-negotiable #5) |
| Process isolation + "let it crash" | Per-agent fault domains; what must NOT cross a boundary | **Core**, with the durability caveat below (let-it-crash ≠ semantic-error handling) |
| Distribution / `:pg` / partitioning | Scaling the agent fleet across nodes | **Defer.** Single-node-many-processes first; distribution is a discriminating cost, not a free upgrade |
| Hot code reload / releases | Long-running factory uptime; deploy without losing in-flight PRs | **Releases yes; hot-reload no.** Drain + durable-resume instead |
| Durable execution (Oban / snapshot / event sourcing) | Coordinator restart resumes mid-flight; no PR/agent work lost | **The pivotal decision.** See §13 — Oban-as-spine vs gen_statem+snapshot |
| Backpressure / circuit breaking on LLM egress | Rate limits, provider 5xx storms, cost runaway | **Core.** Token-bucket pool + per-provider breaker (already specced) |

---

## 1. Supervision trees & restart strategies

**Capability.** A supervisor starts children in declared order and restarts
them per a *strategy* (`one_for_one`, `rest_for_one`, `one_for_all`) and a
per-child *restart type* (`:permanent`, `:transient`, `:temporary`), bounded by
restart intensity (`max_restarts`/`max_seconds`). The strategy is a declaration
of **shared fate**; the restart type is a declaration of **what "done" means**.

**Factory concern & why right.** The factory has two structurally different
populations that must NOT share one strategy:

1. **Control-plane spine** (telemetry → pubsub → registries → solution-tree
   store → budget ledger → gate infra → intake throttle). These have a strict
   dependency order: the budget ledger is useless without the store; the gate
   runners are useless without pubsub. This is the textbook case for
   **`rest_for_one`** — a crash in an earlier child cascades to *later*
   dependents only, and start order *is* dependency order. The live
   `Tau.Application` already uses exactly this (`strategy: :rest_for_one`); the
   factory spine extends the same chain.

2. **Agent / PR population** — many short-lived, independently-failing entities.
   These go under a **`DynamicSupervisor`** (its only strategy is
   `one_for_one`): one agent crashing must never touch a sibling agent. This is
   the error-kernel discipline — precious-state/simple-logic processes near the
   root; risky/complex/restartable work in the leaves.

**Restart types map directly onto factory semantics:**

| Type | Use for | Rationale |
|---|---|---|
| `:permanent` | Spine processes (store, ledger, pubsub, breaker store) | Always restart; their death is a system fault |
| `:transient` | A PR-lifecycle FSM | Restart only on *abnormal* exit; a PR that reaches `:merged` exits `:normal` and must NOT be restarted |
| `:temporary` | A spawned agent worker / a gate-half task | Never auto-restart; failure is *data* the PR FSM consumes and decides on (refine/pivot/escalate), not something to paper over |

**Capture-before-destroy fits restart semantics, not fights them.** A killed
agent's worktree may hold staged/unstaged/untracked work. Restart logic must
**not** auto-respawn a `:temporary` agent and clobber that worktree; instead the
agent's `:DOWN`/exit is delivered to its owning PR FSM (via monitor), which runs
the capture sequence (`git diff HEAD` + untracked tar, per
`worktree-discipline.md`) *before* deciding to refine on a fresh worktree. The
supervisor's job is to *not* restart; the FSM's job is to recover deliberately.
This is the key inversion: **for fallible agents, the supervisor is a
death-certificate issuer, not a resurrector.**

**Pitfalls / anti-patterns.**
- Defaulting the spine to `one_for_one` when children actually depend on each
  other → a mid-chain crash leaves the system half-initialised (e.g. breaker
  store gone but sessions still admitting provider calls).
- `:permanent` on agent workers → crash-loops that re-run a non-deterministically
  failing LLM step forever, burning tokens (the "let it crash misapplied to
  semantic errors" trap — see §10).
- Restart intensity set so high a crash loop spins silently; so low a transient
  blip kills the spine. Intensity *is* the escalation policy — tune it as one.
- Relying on `terminate/2` for worktree cleanup: it does **not** run on `:kill`
  or owner crash. Cleanup that must happen lives in a **monitor in another
  process** (the PR FSM), or the resource is crash-safe by construction.

---

## 2. `gen_statem` vs hand-rolled FSM

**Capability.** `gen_statem` (Erlang stdlib; Elixir via the thin `GenStateMachine`
wrapper or direct `:gen_statem`) is a behaviour whose **state is a named
callback context**, not a struct field. Two callback modes: `state_functions`
(one callback per state) and `handle_event_function` (one callback, match on
`{event, state}`). It gives **state timeouts**, **postponed events**, and
**insertable next-events** as first-class features.

**Factory concern & why right.** The two central lifecycles are genuine FSMs
with legal/illegal transitions:

- **Per-PR lifecycle** (from `factory-loop.md`): `:selected → :draft_open →
  :test_authoring → :implementing → :gating → {:green | :red} → :refining(n≤3)
  → :pivoting → :merging → :merged | :escalated`. Each transition is governed
  (e.g. the N=3 refine bound; "no merge before both gate halves PASS"; the
  pre-merge freshness re-check).
- **Per-agent lifecycle**: `:spawning → :working → :reporting → {:completed |
  :killed}`; killed is terminal (a hard rule).

`gen_statem` is the right primitive precisely because these constraints are
**transition legality**. Encoding "you cannot merge from `:red`" as a missing
callback clause makes the illegal transition *unrepresentable* — the process
crashes on an illegal event rather than silently merging an ungated diff. The
**state timeout** gives the refine bound, gate-runner deadlines, and
escalation-on-stall for free: `{:state_timeout, ms, :escalate}` armed on entry
to `:gating` needs no separate timer process. **Postponing** events models "a
freshness re-check arrived mid-gate; hold it until `:gating` completes."

A GenServer with a `:state` atom field and a `cond`/`case` ladder is the
canonical anti-pattern this replaces (review-checklist item #12): the legality
lives in branch logic a reviewer must read, not in the shape the runtime
enforces.

*Current-repo note:* `Tau.Session` and `Tau.CircuitBreaker.State` are FSMs
modelled today as a struct + pure transition functions (`record_failure/2`,
`check/2`) rather than `gen_statem`. That is a defensible **pure-core** choice
for the breaker (the *process* is `Store`, an ETS owner; the FSM is pure and
property-tested). The lesson for the factory: **separate the FSM logic
(pure, property-testable) from the FSM process (gen_statem or owner).** Use
`gen_statem` when you want the runtime to enforce transitions and own timeouts;
use a pure transition function + thin owner when you want CAS-into-ETS or
exhaustive property tests over the transition relation. The PR lifecycle wants
the former (long-lived, timeout-driven, one process per PR); the breaker wants
the latter (high-read, atomic, shared).

**Pitfalls.**
- Hand-rolling a `receive` loop "for control" — you lose sys-debug, state
  enter-calls, and timeout integration, and you'll reimplement them badly
  (anti-pattern: replacing `:gen_statem` with a bespoke loop is explicitly
  forbidden by the OTP non-negotiables).
- Stuffing side-effecting I/O (git, gh, LLM calls) *inside* a state callback so
  the FSM blocks. Long I/O belongs in a monitored `Task`; the FSM transitions on
  the task's result message. A blocked FSM can't process its own state timeout.
- `handle_event_function` mega-match when `state_functions` would read better —
  pick the mode per state-count, not by default.

---

## 3. `GenServer` placement (and the wrap-stateless anti-pattern)

**Capability.** `GenServer` = a process owning mutable state with serialized
request/reply (`call`) and fire-and-forget (`cast`) semantics. The mailbox
serializes writes; that serialization *is* the value.

**Factory concern & why right.** Use a GenServer *only* where a Step-0 runtime
property holds: concurrency, **serialization of writes to a shared resource**,
failure isolation, independent lifecycle, or a rate boundary. Legitimate
factory GenServers:

- **Solution-tree store** — every factory step appends an outcome; concurrent
  PR FSMs write; writes must be ordered and the read view consistent. Serialized
  writer = correct. (Reads of the tree, if hot, bypass via an ETS projection —
  see §8.)
- **Budget / cost ledger** — token/cost decrements must be atomic against a
  shared total; a single-writer GenServer (or ETS atomic counters under an
  owner) prevents two PRs double-spending the same headroom.
- **ETS-table owners** (breaker `Store`, catalog owner) — the GenServer exists to
  *own the table's lifecycle*, holding almost no logic itself.

**The anti-pattern (OTP non-negotiable #3).** Do **not** wrap stateless logic
in a GenServer. "Turn intent into acceptance criteria," "decompose a plan,"
"score a diff," "render a prompt" are **pure functions**. A `PlannerServer` or
`GateService` that just routes a call to a pure function adds a serialization
bottleneck and a failure domain for zero benefit, and invites a "Manager/Service
god-process." Keep the leaves pure; let callers (the PR FSM, a `Task`) decide
parallelism. Organizing code by process is the canonical process anti-pattern.

**Pitfalls.**
- Funneling **reads** through `GenServer.call` on a hot path (solution-tree
  reads, catalog lookups) → throughput cliff. Reads hit ETS directly.
- `cast` into a slower-than-its-producers process → mailbox time-bomb. Default
  to `call` even when the reply is unused; the reply *is* backpressure.
- Shipping whole structs in messages where an id + a fetch would do (copy storm;
  messages are share-nothing copies).

---

## 4. `DynamicSupervisor` + `Registry`

**Capability.** `DynamicSupervisor` starts children on demand (always
`one_for_one`). `Registry` provides race-safe key→pid lookup with
`{:via, Registry, {Reg, key}}` naming and a uniqueness guarantee.

**Factory concern & why right.** This is the backbone of **process-per-PR** and
**process-per-agent**. Each open PR is a `gen_statem` started under a
`DynamicSupervisor` and registered as `{:via, Registry, {Tau.Factory.PRRegistry,
pr_number}}`; each agent run likewise under an agent registry keyed by
`agent_id`. The factory addresses entities **by logical key** (PR number, agent
id) — never by a held pid, because **a pid is a dangling pointer after
restart** (review item #7). Lookup-or-start is race-safe via the registry's
uniqueness (handle `{:error, {:already_started, pid}}`).

This directly serves: concurrent parallel batches (each PR isolated), per-agent
fault domains, and clean lifecycle (a merged PR's FSM exits and deregisters;
same-turn worktree cleanup is triggered from its terminate path *plus* an
external monitor for the kill case). The live tree already uses this shape for
`Tau.Sessions.Supervisor` and `Tau.CodingAgent.Supervisor` (DynamicSupervisors)
plus `Tau.Registries`.

**Pitfalls.**
- Storing pids in the solution tree / DB as identity. Store the **key**;
  re-resolve through the registry. If you must hold a pid (to monitor),
  hold it *with* its `Process.monitor/1` ref and re-resolve on `:DOWN`.
- Letting a busy worker own the registry/ETS that everyone depends on — owner
  death takes the table with it. Owner = boring, near-root, near-logic-free.
- Treating `DynamicSupervisor` children as `:permanent` when they're really
  `:temporary`/`:transient` (see §1).

---

## 5. `Task` / `Task.Supervisor`

**Capability.** `Task` runs one-shot concurrent work returning a result;
`Task.Supervisor` makes it supervised and discoverable. `Task.async_stream/3`
caps concurrency over an enumerable (`max_concurrency`), giving simple bounded
fan-out without a full pipeline.

**Factory concern & why right.** Bounded concurrent subtasks *with a result and
a known, finite input set*:

- **Parallel gate halves** — `critic` and `reviewer` run concurrently against
  the same stable diff; spawn two monitored tasks under a `Task.Supervisor`, the
  PR FSM transitions to `:green` only when **both** return PASS. (Both-PASS is a
  hard gate; the FSM, not the task, enforces it.)
- **Research fan-out** — N concurrent web/source fetches with a join.
  `Task.async_stream` with a `max_concurrency` cap is exactly right: in-memory
  list of queries, bounded parallelism, no external broker, no need for
  demand-driven backpressure.
- **Tool dispatch** inside an agent turn (the live `Tau.Tools.TaskSupervisor`).

**Why Task and not GenStage here:** the input is a *bounded, already-known*
collection processed once. `Task.async_stream` is the simpler, correct tool when
you "just need to process data already in-memory in parallel" and don't need
demand signalling
([hexdocs.pm/elixir Task](https://hexdocs.pm/elixir/Task.html)).

**Pitfalls.**
- `Task.async` outside a `Task.Supervisor` in server code → an unsupervised
  long-lived process, invisible to shutdown ordering (official anti-pattern).
- Unbounded `Task.async_stream` (no `max_concurrency`) on a fan-out that hits a
  rate-limited API → you've moved the overload one layer down. Cap it, and route
  the actual LLM egress through the breaker/pool (§14).
- Linking (`async`) vs not (`Task.Supervisor.async_nolink`): a linked task crash
  propagates to the caller FSM. For a fallible gate/agent task, use
  `async_nolink` + monitor so failure is *data*, not a cascading crash.

---

## 6. `Phoenix.PubSub` & monitored refs

**Capability.** `Phoenix.PubSub` = topic-based broadcast across processes on one
node (and across nodes if you opt into a distributed adapter), decoupling
publishers from subscribers. `Process.monitor/1` gives a one-shot `:DOWN`
signal when a specific process dies — point-to-point liveness without linking.

**Factory concern & why right.** Two distinct cross-process needs:

- **Fan-out events** (the event stream the dashboard/log consumes; gate verdicts;
  escalation notices; merge events) → `Phoenix.PubSub` topics, e.g.
  `"factory:pr:#{n}"`, `"factory:escalation"`. Subscribers (web dashboard
  LiveViews, the OTel reporter, the solution-tree projector) join in `init/1`
  with no `whereis` guards — the live tree puts PubSub high precisely so
  `init/1` subscribe is safe (ADR-0004). This is OTP non-negotiable #4: cross-
  process events use PubSub, **never `:global`, never `Process.whereis |>
  send`.**
- **Point-to-point liveness** (the PR FSM watching its spawned agent; the
  coordinator watching a gate task) → `Process.monitor/1` + a `:DOWN` clause.
  The monitor ref is the right primitive for "tell me when *this specific*
  worktree agent dies so I can capture-before-destroy."

**Pitfalls.**
- Using PubSub for request/reply — it's broadcast; correlate with refs or use a
  `call`.
- Assuming PubSub delivery is guaranteed/ordered across a partition once you go
  multi-node (it isn't — see §11).
- Holding a monitored pid as *identity* (re-resolve by key; the monitor ref is
  for liveness only).

---

## 7. GenStage / Broadway — backpressure for intake & bounded agent concurrency

**Capability.** `GenStage` = demand-driven producer/consumer staging:
consumers *pull* by signalling demand, so the pipeline runs at the speed of its
slowest stage by construction. `Broadway` is a higher-level framework over
GenStage adding concurrent producers, batching, rate-limiting, automatic
acknowledgement, and connectors to external brokers (SQS/Kafka/RabbitMQ).

**Factory concern & where it IS warranted.** The single genuine speed-mismatch
in the factory is **work intake vs bounded execution capacity**: a backlog of
open issues / queued intents arrives faster than the factory can gate-and-merge
(merges are *serialized* by rule). A demand-driven intake stage that admits the
next issue only when an executor slot frees is the right shape — the consumer's
demand *is* the concurrency cap on live PRs. Broadway's built-in **rate-limiting
producer option** also cleanly bounds how fast new agent spawns are admitted.
This is the "ingress → processing" mismatch from the backpressure step:
architect it in, don't patch it on.

**Where it is NOT warranted (the honest scoping).**
- The **gate pipeline** (critic+reviewer per PR) is *not* a streaming data
  pipeline — it's a two-task join per entity. Use `Task` (§5), not Broadway.
- If the work source is a **bounded, already-known set** processed once
  (a milestone's open issues, enumerated up front), `Task.async_stream` with
  `max_concurrency` is sufficient and far simpler — Broadway earns its keep for
  *continuous, long-running* ingestion from an external broker, not a one-shot
  enumeration
  ([github.com/dashbitco/broadway](https://github.com/dashbitco/broadway)).
- A `DynamicSupervisor` with a hard child cap + a `Registry` count is itself a
  crude but effective concurrency limiter without any GenStage at all.

**Verdict:** introduce GenStage/Broadway **only** at the intake/throttle
boundary, and **only** once intake is genuinely continuous and unbounded (e.g. a
durable queue feeding the factory). Until then, bounded `Task.async_stream` +
DynamicSupervisor cap is the right, simpler primitive. "We'll add backpressure
later" = "we'll find the speed mismatch in production" — so *name* the intake
boundary now even if you implement it as a counter first.

**Pitfalls.** Reaching for Broadway to "look scalable" when the input is
bounded; coupling the gate logic into a Broadway processor (mixes a join into a
stream); forgetting that Broadway's fault-tolerance is per-message, not a
substitute for the PR FSM's refine/pivot semantics.

---

## 8. ETS / `:persistent_term`

**Capability.** ETS = in-memory term tables with concurrent access
(`read_concurrency`, atomic counters, match/select); the table **dies with its
owner process**. `:persistent_term` = ultra-fast global read store optimised for
**write-rarely/read-everywhere**, with a global GC pause on *update* (so never
for hot-write data).

**Factory concern & why right.** Shared **read-mostly** state under a boring
owner:

- **Catalogs** (command/skill/tool catalogs, the area-label canon, gate
  configuration) — read by every PR FSM and agent, written rarely →
  `:persistent_term` (the live `Settings.Cache` is exactly persistent_term-
  backed) or an ETS table with `read_concurrency: true` owned by a near-root
  process.
- **Budget snapshots / breaker state** — read on *every* provider call by many
  concurrent turns, written on each outcome → ETS with **atomic counters**
  (`:ets.update_counter`) and CAS-style guarded writes, owned by a dedicated
  lifecycle anchor. This is precisely `Tau.CircuitBreaker.Store` owning
  `:tau_circuit_breakers` (SPEC-CIRCUIT-BREAKER B2): the owner is a GenServer
  with almost no logic; the *reads* bypass its mailbox entirely. Funnelling
  these through a `GenServer.call` would serialize every provider call for no
  consistency gain.

**The ownership rule.** A hot table that must outlive worker crashes gets a
dedicated owner high in the tree (or `:ets.give_away`/heir). The live tree
places `CircuitBreaker.Store` deliberately *before* the task supervisors so the
table exists when the first turn calls a provider — start order encodes the
read-dependency.

**Pitfalls.**
- `:persistent_term` for anything written at runtime frequency → global GC pause
  per write stalls the whole node.
- Worker-owned hot tables → table vanishes on the first worker crash.
- ETS as a *durable* store — it's in-memory; a node restart loses it. Durable
  state (solution tree, budget ledger of record) needs disk/DB (§13). ETS is the
  *hot projection*, not the source of truth.
- `Application.put_env/3` for runtime state — forbidden (OTP non-negotiable #1);
  use ETS/persistent_term under an owner.

---

## 9. `:telemetry`

**Capability.** `:telemetry.execute/3` emits a named event with measurements +
metadata; `:telemetry.span/3` pairs `*.start`/`*.stop`/`*.exception`
automatically. Handlers are attached out-of-band (the OTel reporter, metrics,
logs) without the emitter knowing.

**Factory concern & why right.** OTP non-negotiable #5 makes this *mandatory*
for everything user-visible or perf-sensitive — which in the factory is almost
everything: PR open/gate/merge spans, agent spawn/complete/kill, gate-half
durations, token/cost per step, escalation events, queue depth. Telemetry is the
substrate for the reporting cadence (the factory reports at milestone boundaries
and on escalation) and for the **sourced numbers** discipline (token counts from
`total_tokens`, wall-times from `duration_ms` — measured, not estimated). The
live `SPEC-OTEL-REPORTER` already subscribes a supervised GenServer to
`[:tau, …]` events and exports OTLP; the factory adds a `[:tau, :factory, …]`
namespace.

**Pitfalls.**
- `IO.puts` for logging instead of telemetry/`Logger` (forbidden).
- Unpaired `*.start` without `*.stop`/`*.exception` → broken spans, leaked open
  spans on crash. Use `:telemetry.span/3`.
- Putting *control logic* in a telemetry handler — handlers are observers; a
  handler that crashes can detach itself. Decisions live in the FSM, not the
  handler.
- Measuring queue depth as a *fix* rather than a *signal* — `message_queue_len`
  in telemetry diagnoses a mailbox problem; the fix is backpressure (§7).

---

## 10. Process isolation & "let it crash"

**Capability.** Share-nothing processes with isolated heaps: one process
crashing cannot corrupt another's memory; supervisors turn crashes into clean
restarts. "Let it crash" = don't defensively code every error path; let the
process die and restart to a known-good state.

**Factory concern & why right.** Each agent runs in its own process (and its own
git worktree); a segfaulting tool, a crashed parser, an OOM in one agent is
**contained** — siblings and the spine survive. This is the whole reason the
factory can run *many concurrent fallible agents*. What must **NOT** cross a
process boundary: `try/rescue` and `catch :exit` (OTP non-negotiable #7).
Failure crosses boundaries as **messages** (`:DOWN`, exit reasons, tagged-tuple
results, `%Event.Error{}` stream items), never as a rescued exception reaching
into another process.

**The critical caveat — let-it-crash ≠ semantic-error recovery.** Restarting a
process re-runs the *same* LLM step and very often yields the *same* bad output
— "restarting a process yields identical garbage from an LLM"
([georgeguimaraes.com](https://georgeguimaraes.com/what-the-critics-got-right-about-elixir-and-ai-agents/)).
So:
- **Infrastructure faults** (HTTP socket drop, parser crash, OOM) → let it crash
  / supervise / restart. Correct.
- **Semantic failures** (gate FAIL, agent produced wrong code, model refused) →
  **not** a crash to restart; they are *outcomes* the PR FSM consumes and
  decides on (refine ≤3 → pivot → escalate). Encoding a gate FAIL as a process
  crash would crash-loop and burn tokens.

This is the single most important boundary in the design: **supervision recovers
infrastructure; the FSM + solution tree recover semantics.** Conflating them is
the dominant BEAM-for-agents mistake.

**The litmus test (Step-2 durability):** *if a crash destroys something
irreplaceable, the architecture is wrong.* An agent crash must lose only
ephemeral in-flight context (rebuildable from the durable PR record + worktree),
never the solution-tree decision, the budget ledger, or uncaptured worktree
work. Where that test fails, the data belonged in a durable store, or the
process was doing too much.

**Pitfalls.** `try/rescue` around a provider stream to "handle" a 5xx (the
breaker handles it, §14); catching `:exit` from a monitored agent (use the
`:DOWN` message); irreplaceable state on a process heap (review item #2).

---

## 11. Distribution (multi-node BEAM), `:pg`, partitioning

**Capability.** Distributed Erlang gives location-transparent message passing,
`:pg` (process groups) for distributed pub/sub-style membership, and global
registries (`:global`, `Horde`) for cluster-wide naming. Partitioning routes
keys to owning nodes.

**Factory concern.** Scaling the agent fleet *beyond one node's capacity*. The
honest assessment: a single BEAM node runs **hundreds of thousands of
processes**; an agent fleet is bounded far more by **external limits** (LLM API
rate limits, git/gh throughput, disk for worktrees, host CPU for `mix
test`/builds) than by process count. So the *first* scaling axis is
single-node-many-processes, not distribution.

**The discriminating cost of going distributed.** Location transparency is a
*programming* convenience, not a *design* license. The moment a message crosses
a node boundary, semantics change
([otp-architecture step 6](https://www.erlang.org/doc/system/distributed.html)):
- delivery is no longer guaranteed; a `call` timeout becomes a normal event and
  **does not mean the work didn't happen** (idempotency now mandatory);
- monitors fire on *suspicion* (partition), not just death — split-brain;
- distributed Erlang is full-mesh, single TCP per node pair → head-of-line
  blocking on big messages; the default cookie is not a security boundary;
- global naming (`:global`/`Horde`) is a **consensus problem with split-brain
  behaviour you must choose**, not a free upgrade from `Registry`.

**Verdict / recommended posture.** Stay single-node for the control plane
(coordinator, PR FSMs, solution tree, budget ledger) — these are precisely the
*consistency-posture* processes you do **not** want to replicate. Scale **agent
execution** horizontally only when host resources genuinely cap out, and do it
via an **explicit work-distribution boundary** (a durable queue — see §13 — that
remote *executor* nodes pull from), **not** by spreading the FSM population over
distributed Erlang. An HTTP/queue boundary between a control node and stateless
executor nodes is the honest design; full distributed-BEAM clustering buys
little here and imports split-brain risk into the one place (the solution
tree / merge serialization) that must stay consistent.

**Pitfalls.** `:global`/Horde for the solution-tree owner (split-brain → two
coordinators merge concurrently — catastrophic given "merges are serialized");
assuming node-crossing `call` is exactly-once; treating `:pg` membership as
strongly consistent.

---

## 12. Hot code reload / releases

**Capability.** The BEAM can hot-swap module code in a running node
(`code_change/3`, appup/relup) **without stopping processes**; OTP *releases*
(via `mix release`, here Burrito-packaged) bundle the system for clean
start/stop/upgrade.

**Factory concern & risk.** A factory is a **long-running** process with
**in-flight PRs and agents** that must survive a deploy. Two options:

- **Hot code reload (relup):** powerful but **high-risk and high-ceremony** —
  every stateful process needs a correct `code_change/3`; `gen_statem` state
  shape changes across versions are a known foot-gun; a botched relup corrupts
  live state. For an autonomous factory where the cost of corrupting the
  solution tree or a mid-merge PR is severe, this risk is **not** worth it.
- **Releases + drain + durable-resume (recommended):** deploy a new release by
  *draining* — stop admitting new PRs at the intake stage (§7), let in-flight
  PRs reach a safe checkpoint (or snapshot their FSM state, §13), stop, start the
  new release, and **resume from durable state**. This is exactly the
  kill-switch latency model in `factory-loop.md` (finish the current step, halt
  cleanly between steps) generalised to deploys.

**Verdict.** **Use releases; avoid hot-reload for the factory.** Durable FSM
state (§13) makes a stop/start deploy *resume mid-flight* anyway, which gives
hot-reload's benefit (no lost work) without its state-corruption risk. The
right primitive for "survive a deploy" is **persistence + clean restart**, not
in-place code swap.

**Pitfalls.** Relying on `code_change/3` correctness across many FSM versions;
hot-reloading a module whose process holds an open worktree/git operation
mid-flight; treating hot-reload as a substitute for durability (it isn't —
a full node restart still loses in-memory state).

---

## 13. Durable execution on BEAM — the pivotal decision

**The requirement.** A coordinator restart (crash, deploy, host reboot) MUST
**resume mid-flight**: every open PR's lifecycle state, its attempt count, its
chosen strategy, the solution tree, and the budget ledger survive and reload.
"Durable execution means state is saved to persistent storage after every
logical step, so a crash resumes from the last checkpoint — not the beginning."
The factory-loop rule already asserts this: *"the solution tree is the single
source of truth across a meta-restart."* The open question is the **mechanism**.

**BEAM's gap (the critics' valid point).** Process-level supervision recovers a
*crashed process*, but **not a crashed node / a deploy** — in-memory FSM state
"evaporates"
([georgeguimaraes.com](https://georgeguimaraes.com/what-the-critics-got-right-about-elixir-and-ai-agents/)).
There is no built-in Temporal-equivalent that records execution decisions as a
replayable append-only log. So durability must be *added*.

**Candidate mechanisms (BEAM-native):**

| Mechanism | What it gives | Cost / caveat |
|---|---|---|
| **`gen_statem` + state snapshot to disk/DB** | FSM persists its state on each transition; on restart, the PR-FSM supervisor re-reads the durable PR records and rehydrates each FSM at its saved state | You hand-roll the persist/rehydrate; snapshot must be transactional with the side-effect (the merge, the gate verdict) or you double-act |
| **Event sourcing** (append-only event log, e.g. `commanded`/EventStore) | Full replay; audit trail = the solution tree literally *is* the event log | Heaviest; replay must skip already-performed external effects (idempotency keys) |
| **Mnesia** (built-in distributed DB) | Disk-backed tables, BEAM-native, transactions | Operationally finicky at scale; split-brain recovery is manual; rarely the right default in 2026 |
| **`:dets` / ETS+disk** | Simple disk-backed term store | No transactions, size limits (`:dets` 2GB), no query — too primitive for the solution tree |
| **Oban (Postgres-backed durable jobs)** | Durable, retried, observable job execution; state lives in Postgres, not memory; Oban **Pro Workflows** add DAG dependencies (fan-out/fan-in), cumulative context, and recorded values | Requires Postgres; a *job* is not a *long-lived interactive FSM* — see the comparison |

**Oban-as-durable-workflow vs gen_statem+snapshot — the core trade-off.**

*Oban (esp. Pro Workflows):*
([oban.pro](https://oban.pro/), [github.com/oban-bg/oban](https://github.com/oban-bg/oban))
- **+** Durability is *free and battle-tested*: every step is a Postgres row,
  retried with backoff, visible in Oban Web; survives node death and deploys by
  construction; `unique`/`snooze`/`{:cancel,_}` give idempotency, polling, and
  terminal-failure semantics out of the box. Pro Workflows model the
  fan-out/fan-in *gate* and *parallel-batch* structure directly, with cumulative
  context (atoms preserved in cascade context, unlike JSON job args) and
  `recorded: true` outputs flowing downstream. The N≤3 refine bound maps to
  retry policy; `{:snooze, n}` maps to "poll the gate."
- **−** Oban's unit is a **discrete job**, not a **long-lived interactive
  process**. A PR lifecycle that must *react to live events* (an agent's `:DOWN`,
  a streaming gate verdict, a human escalation reply, a mid-flight freshness
  re-check) fits the *interactive process* model better than the *enqueue-and-run*
  job model. Forcing live reactivity into Oban means polling (`snooze`) and
  losing the FSM's timeout/postpone ergonomics.

*gen_statem + snapshot:*
- **+** Natural fit for the **interactive, timeout-driven, event-reactive** PR
  lifecycle; full `gen_statem` ergonomics (state timeouts, postpone, enter
  calls); the FSM *is* the live coordinator.
- **−** You **build the durability yourself**: transactional snapshot-on-
  transition, rehydrate-on-restart, idempotency for in-flight external effects
  (don't re-merge a PR that merged just before the crash). This is exactly the
  work `gen_persistence` exists to reduce — "events are stored to disk and
  replayed on restart, with optional state snapshots," and it ships
  `gen_statem` + `gen_server` persistence variants
  ([codesync.global/gen-persistence](https://codesync.global/media/gen-persistence-persist-the-state-of-your-processes/)).

**Recommended hybrid (the single biggest discriminating decision).** Split by
*reactivity*, not by taste:

- **The durable spine — solution tree, budget ledger, and the
  *queue of factory steps* — lives in Postgres via Oban.** Intake, the N≤3
  retry bound, serialized merges, and "resume the backlog after restart" are
  *durable job* concerns Oban already solves; this is where Oban's
  battle-tested durability is highest-leverage and where hand-rolled persistence
  would be pure liability.
- **The per-PR *live* lifecycle is a `gen_statem`** spawned for the duration of
  one active step, **snapshotting its state to that durable store on each
  transition**, so a restart rehydrates in-flight FSMs from the same Postgres
  rows. The FSM owns *live reactivity* (timeouts, agent `:DOWN`, escalation);
  Oban owns *durability and the backlog*. The solution tree is the
  transactional boundary both write through — making it, not memory, the single
  source of truth across any restart (consistent with the factory-loop rule).

This avoids the two failure modes: (a) all-Oban → fighting the job model for
live reactivity and losing FSM ergonomics; (b) all-gen_statem → re-inventing
Postgres-grade durability and idempotency by hand. **If forced to pick one:
prefer Oban as the durable system-of-record and keep the live FSM thin and
rehydratable** — durability is the harder property to retrofit, and a
control plane that loses its solution tree on a deploy has failed its central
conservation law.

**Pitfalls.**
- Snapshotting FSM state *non-transactionally* with the external effect →
  double-merge or lost-merge on a crash between act and snapshot. The merge's
  idempotency key (PR number + merge SHA) must be checked on resume.
- Treating Oban job args as atom-keyed (they're JSON — atoms become strings);
  cascade context *does* preserve atoms — don't conflate the two.
- Oban Pro Workflows for a *linear* chain (overkill); use them for the genuine
  DAG (gate fan-out/fan-in), not A→B→C.
- Replay (event sourcing) that re-performs already-done external side effects —
  guard every external effect with an idempotency check.

---

## 14. Backpressure & overload protection for outbound LLM API calls

**Capability.** BEAM gives the building blocks; the factory composes them:
- **Pool checkout as backpressure** — a bounded pool (here Finch's connection
  pool) where checkout *is* the throttle.
- **Token-bucket rate limiter** — meters request admission per provider.
- **Circuit breaker** — a `:closed/:open/:half_open` FSM that short-circuits a
  provider returning sustained hard errors.

**Factory concern & why right.** Many concurrent agents → many concurrent LLM
calls → three distinct overload risks, each with its right primitive:

1. **Provider rate limits (429s):** a per-provider **token-bucket limiter** that
   blocks/queues admission. Already built: `Tau.Providers.RateLimiter`
   (token-bucket + supervisor, ADR-0011), booted *before* the breaker. The
   limiter's blocking checkout propagates backpressure up to the calling agent —
   the agent waits rather than the provider rejecting.
2. **Provider hard-error storms (5xx):** a per-provider **circuit breaker** —
   `SPEC-CIRCUIT-BREAKER`'s `:closed/:open/:half_open` machine over an ETS table
   owned by `Tau.CircuitBreaker.Store`. After N consecutive failures it opens,
   short-circuits to `{:error, :circuit_open}` for `cooldown_ms`, admits a
   single half-open probe, and closes on success. This stops the
   "fail → fallback → retry → burn quota" feedback loop the spec was written to
   kill — directly serving **cost governance**, not just latency.
3. **Aggregate cost/token runaway:** the **budget ledger** (§3/§8) — atomic ETS
   counters decremented per call under a shared cap; a PR/agent that would
   exceed headroom is denied admission *before* the call. This is the factory-
   level overload control the per-provider primitives don't cover.

The composition order is load-bearing and already encoded in the live tree:
`RateLimiter.Supervisor` → `CircuitBreaker.Store` → task supervisors. Rate
limiting wraps Finch sends (lowest); the breaker wraps the provider call at a
higher level; the budget gate is checked highest, before admission. Each is a
**boundary**, architected in, not a patch.

**Pitfalls.**
- `try/rescue` around the provider stream to "handle" 5xx — the breaker handles
  it; rescuing across the boundary is forbidden (§10).
- An *unbounded* `Task.async_stream` of agent calls that bypasses the
  limiter/breaker → you re-created the overload one layer up. All egress routes
  through the limiter+breaker.
- Breaker state on a worker heap instead of an owned ETS table → state lost on
  worker crash, breaker amnesia (the spec's B2 owner exists for this).
- A token bucket whose refill clock isn't monotonic / consistently sourced —
  temporal coupling (`opened_at_ms` vs `now_ms`) is load-bearing; pass a
  consistent `now_ms`.

---

## Appendix — concrete factory supervision sketch (illustrative)

```
Tau.Factory.Supervisor            (:rest_for_one — spine; start order = deps)
├── Tau.Telemetry.Supervisor       (:permanent)   emits first
├── {Phoenix.PubSub, Tau.PubSub}    (:permanent)   events; init/1 subscribe-safe
├── Tau.Factory.Registries          (:permanent)   PRRegistry, AgentRegistry
├── Tau.Factory.SolutionTree.Store  (:permanent)   durable system-of-record owner
│                                                   (Oban/Postgres-backed; ETS hot projection)
├── Tau.Factory.Budget.Ledger       (:permanent)   atomic ETS counters under owner
├── Tau.Providers.RateLimiter.Sup   (:permanent)   token buckets per provider
├── Tau.CircuitBreaker.Store         (:permanent)   ETS owner :tau_circuit_breakers
├── Tau.Factory.GateSupervisor       (Task.Supervisor) critic/reviewer task halves
├── Tau.Factory.Intake               (GenStage/Broadway OR bounded counter)
│                                                   demand = live-PR concurrency cap
├── Tau.Factory.AgentSupervisor      (DynamicSupervisor, one_for_one)
│      └── Tau.Factory.Agent          (:temporary)  one per spawned coding agent
└── Tau.Factory.PRSupervisor         (DynamicSupervisor, one_for_one)
       └── Tau.Factory.PR             (:transient, gen_statem, snapshotting)
                                                    one per active PR lifecycle
```

Identity is by key (PR number / agent id) via the registries; pids are never
stored as identity. PR FSMs monitor their agents and gate tasks; failure
arrives as `:DOWN`/result messages, never as a rescued exception. Durable state
(solution tree, budget, backlog) is in Postgres/Oban; ETS holds only hot
projections; the FSM snapshots transitions so a restart rehydrates mid-flight.

---

## Uncertainty flags (do not over-trust)

- **Oban Pro Workflows API specifics** (`add_graft`, `recorded: true`,
  `apply_graft`, cascade-context atom preservation) are from current Oban Pro
  docs/skill material and a paid product; verify exact signatures against the
  installed Pro version before relying on them — they evolve across releases.
- **`gen_persistence`** is a third-party library presented at Code BEAM; maturity
  and maintenance status are not verified here — treat the `gen_statem`+snapshot
  pattern as the principle, the specific lib as a candidate, not a commitment.
- **The Oban-vs-gen_statem hybrid split** is a design recommendation, not a
  proven implementation in tau; it should be validated by a spike (a single PR
  FSM that survives a forced coordinator restart mid-gate) before being fixed in
  the architecture.
- I did **not** fabricate any API; where a signature mattered I cited the source
  or flagged it. `:gen_statem`, `Task.async_stream/3`, `Phoenix.PubSub`, ETS
  atomics, and the live `Tau.*` modules are verified against the repo / stdlib.

### Sources

- Oban / Oban Pro: <https://github.com/oban-bg/oban>, <https://oban.pro/>
- Broadway: <https://github.com/dashbitco/broadway>, <https://hexdocs.pm/broadway/Broadway.html>
- `gen_statem` behaviour: <https://www.erlang.org/doc/apps/stdlib/gen_statem.html>
- BEAM-for-agents durability critique: <https://georgeguimaraes.com/what-the-critics-got-right-about-elixir-and-ai-agents/>
- `gen_persistence` (snapshot/replay for `gen_statem`/`gen_server`): <https://codesync.global/media/gen-persistence-persist-the-state-of-your-processes/>
- Durable execution for agents (concept): <https://vadim.blog/durable-execution-agents-that-survive-failure-and-resume-where-they-left-off>
- Distributed Erlang semantics: <https://www.erlang.org/doc/system/distributed.html>
- Elixir `Task`: <https://hexdocs.pm/elixir/Task.html>
