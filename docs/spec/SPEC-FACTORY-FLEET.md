# SPEC: Factory Worker Fleet (isolation · worker lifecycle · capture-before-destroy)

| | |
|---|---|
| **Status** | Draft |
| **Date** | 2026-06-10 |
| **Scope** | The `:tau_factory` worker fleet — component **W**: the horizontally-scalable execution tier. One supervised process per worker (implementer / test-author / critic / reviewer / researcher), each owning a *complete* isolation boundary (private git checkout from a verified ref + a per-worker namespace for every mutable resource the Toolchain adapter declares). Owns total-resource-isolation, no-shared-tree, verified-position, capture-before-destroy (all three dirty kinds), supervised reclaim, crash-containment, and artifact-conservation. Issues the worker death-certificate; runs the heartbeat watchdog that synthesizes the `worker_stalled` trigger SPEC-FACTORY-CORE depends on. Enforces the oracle-separation **spawn-order + author-identity mechanism** (the invariant is owned by SPEC-FACTORY-GATE). |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + boundary contracts. Derived from the verified architecture in `docs/arch/` (system-architecture §1 component W + §3 enforcement matrix; worker-fleet.md; invariants.md INV-10..12/14/15/17; conservation.md CON-5; tau-current-analysis.md §3 F-1..F-7). |
| **Issue** | TBD — file before the first implementation PR (`tau-github-workflow`); reference as `Closes #N`. |

**Changelog:** Initial draft — §0–§7 + Appendix B. Introduces D-309, D-310,
D-311, D-313, D-314, D-316, D-334. Cites (does not own) D-304/D-305/D-306
(SPEC-FACTORY-GATE — the worker enforces only the spawn-order + author-identity
*mechanism* of D-304, HR-7; the invariant is GATE's), D-300–D-303
(SPEC-FACTORY-MERGE — sole `origin/main` writer, the other half of INV-11),
D-315/D-330/D-336 (SPEC-FACTORY-CORE — the durable Ledger that records each
capture disposition and the `worker_stalled` consumer). Resource-namespace
declaration is supplied by the **Toolchain adapter** (SPEC-FACTORY-GATE / D-S2),
making isolation total and polyglot.

## 0. Why this spec exists

The factory's worker fleet is where every prose `MUST` of
`.claude/rules/worktree-discipline.md` is converted into a process boundary, an
OS namespace, or a supervised lifecycle. The prior attempt enforced isolation as
prose an agent had to obey, and on file (`docs/arch/01-research/tau-current-analysis.md`
§3) **seven distinct worktree failure modes were each observed and tagged "this
has happened"** — F-1 parent-HEAD drift, F-2 reviewer collisions, F-3 leaked
locked worktrees, F-4 naïve capture losing staged/untracked work, F-5
`$HOME`-cache races, F-6 trusted spawn-brief position, F-7 a stale-parent
*recovery procedure* whose mere existence is evidence the invariants were
routinely violated.

This spec makes each of those seven structurally **unreachable** by drawing the
boundary around the invariant, not the noun:

| # | Observed failure | Structural closure | Owned invariant |
|---|------------------|--------------------|-----------------|
| F-1 | parent-HEAD drift | no shared mutable tree; every checkout a worker-private fork from a verified ref (§2a) | **D-310** (INV-11) |
| F-2 | reviewer collisions (missing `isolation` flag) | isolation is a property of `init/1`, not an opt-in flag (§2a) | **D-309/D-310** (INV-10/11) |
| F-3 | leaked locked worktrees | `:DOWN`-monitor reclaim on *every* exit path incl. `:kill` (§3) | **D-314** (INV-15) |
| F-4 | naïve capture loses staged/untracked | all-three-kinds capture; **untracked** via `ls-files \| tar` (§3) | **D-313 / D-334** (INV-14 / CON-5) |
| F-5 | `$HOME`-cache races (`XZ/LZMA Decode Failed`) | adapter-declared per-worker namespace **inside** the worktree (§2b) | **D-309** (INV-10) |
| F-6 | trusted spawn-brief position | position set by system, **verified** by worker, abort on mismatch (§2a) | **D-311** (INV-12) |
| F-7 | stale-parent recovery procedure | no leaked state to recover ⇒ the recovery checklist is unreachable (§3) | **D-314** (INV-15) |

A wedged-but-not-crashed agent (Port alive, no `:exit_status`, no `:DOWN`) emits
**no trigger**, so the fleet also owns the heartbeat watchdog that synthesizes
the `worker_stalled` event — the source SPEC-FACTORY-CORE's totality argument
(D-317) depends on. The component is maximally coordination-heavy (triage 5/5;
§1) and therefore requires this spec before any implementation PR modifies the
fleet boundary, per `.claude/rules/spec-before-code.md`.

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | The thing the design *removes* is shared mutable state — but every `$HOME`-namespace cache (`~/.local/share/.burrito/`, `~/.cache/zig/`, `~/.mix/`, Hex/GitHub-release caches) is shared by default and leaks through worktree isolation; making each worker-private is the load-bearing job. |
| 2 | Temporal coupling | 1 | The test-author must be spawned **and its gating-test path set frozen before** any implementer (INV-5 ordering); capture of dirty state must happen **before** reclaim, on every exit path; position must be verified **before** any work. Each is a strict before/after. |
| 3 | Cross-process coordination | 1 | `WorkerSupervisor` (DynamicSupervisor), N× `Worker` (GenServer), `WorkerRegistry`, an independent `WorkspaceJanitor` monitor, the agent `Port`, and monitored refs/heartbeats back to the owning Unit FSM — coordination spans many processes with no shared mailbox. |
| 4 | Feedback loops | 1 | Heartbeat absence → `worker_stalled` → Unit retry ladder → (refine ⇒ a fresh worker spawn); worker `:DOWN` → capture → reclaim → Unit decides outcome → possible re-spawn. Fleet behaviour feeds back into its own spawn load. |
| 5 | State accumulation | 1 | Per-worker isolation resources (worktree + every namespaced cache dir) accumulate for the worker's life and **must** be reclaimed on termination including crash; an un-reclaimed resource is exactly F-3 (the symptom that hides every other failure mode). |

**Triage score: 5/5. L0 + boundary contracts indicated.**

## 2. Component decomposition

Naming is precise so §4 contracts attach to specific operations. All modules are
under `Tau.Factory.*` and supervised within `Tau.Factory.Supervisor`'s W subtree
(arch `supervision-tree.md`).

| # | Component | Role |
|---|-----------|------|
| C1 | `Tau.Factory.WorkerSupervisor` | **W root.** `DynamicSupervisor` (`one_for_one`), starts `0..W_cap` workers each `restart: :temporary`. The **death-certificate issuer**: a worker crash surfaces a `worker_exit` outcome the owning Unit FSM decides — it **never** auto-resurrects a crashed worker onto a fresh worktree mid-flight. Supervision recovers *infrastructure*; the Unit FSM + Ledger recover *semantics*. |
| C2 | `Tau.Factory.Worker` | The per-worker `GenServer` (`restart: :temporary`). Addressed by **logical key** `{:via, Registry, {WorkerRegistry, worker_id}}`, never by pid. `init/1` allocates AND owns the *complete* isolation boundary (§2a + §2b) and self-verifies position (INV-12). `role ∈ {:implementer,:test_author,:critic,:reviewer,:researcher}` is a data field, not a subclass. Emits heartbeats (§3b). |
| C3 | `Tau.Factory.WorkerRegistry` | `Registry` mapping `worker_id → pid` (+ role/meta). The single source of worker identity; no pid is stored in any durable record (a stored pid is a dangling pointer after restart — resolved by key on resume). |
| C4 | `Tau.Factory.WorkspaceJanitor` | An **independent monitoring `GenServer`** high in the W subtree. `Process.monitor/1`s every worker at spawn; on `:DOWN` (for **every** exit reason incl. `:kill`/`:shutdown`) captures all three dirty kinds, records the disposition to the Ledger (CON-5), then reclaims the worktree + namespace. Lives **outside** the worker crash domain (a monitor, not a link), so a worker crash cannot defeat its own capture. **NOT `terminate/2`** — which does not run on `:kill` or a linked/owner crash, the exact deaths a killed worker dies. |
| C5 | `Tau.Factory.Worker.Isolation` | Pure helper module: `resolve_namespace/2` (Toolchain decls → `{env_var → abs_dir}` map under the worktree), `verify_position/2` (pwd/HEAD/branch check), capture-command construction. No process. Properties before examples (the namespace-totality property). |
| C6 | `Tau.Factory.Fleet.Watchdog` | Supervised `GenServer` consuming worker heartbeats; on heartbeat absence past `heartbeat_timeout` it synthesizes a `worker_stalled` event to the owning Unit (the trigger SPEC-FACTORY-CORE D-317(b) requires). A *liveness* signal distinct from the *crash* signal (`:DOWN`). |

Boundaries (B-N attach contracts in §4):

| # | Boundary | Operation |
|---|----------|-----------|
| B1 | **U** (SPEC-FACTORY-CORE) ↔ C1 WorkerSupervisor | `spawn(role, brief, base_ref)` → `{:ok, worker_id}`; async `worker_exit(worker_id, reason)`. **Cited owner: CORE (B8).** |
| B2 | C2 Worker ↔ git checkout | private worktree fork from a *system-established* `base_ref`; self-verify pwd/HEAD/branch, abort on mismatch. |
| B3 | C2 Worker ↔ C5 Isolation (resource namespace) | `resolve_namespace(ws, Toolchain.resource_namespace(tc))` → total `env` map of per-worker dirs **inside** the worktree. |
| B4 | C2 Worker ↔ agent `Port` | length-framed structured I/O (`{:packet,4}`, `:exit_status`); launched with `env: ns`, `cd: ws`; linked into the worker (agent crash domain ⊆ worker crash domain). |
| B5 | C4 WorkspaceJanitor ↔ C2 Worker (`:DOWN`) | on every exit reason: capture {staged+unstaged, untracked, status}, record disposition, reclaim worktree+namespace. |
| B6 | C4 WorkspaceJanitor ↔ **L** (SPEC-FACTORY-CORE) | `record_decision`/capture-disposition write (WAL-before-ack). **Cited owner: CORE (B3 / D-315).** |
| B7 | C6 Watchdog ↔ **U** (SPEC-FACTORY-CORE) | `worker_stalled(worker_id)` synthetic event on heartbeat absence (feeds D-317(b)). **Cited consumer: CORE.** |
| B8 | C1/C2 fleet ↔ **G** (SPEC-FACTORY-GATE) | spawn-order (`:test_author` first, freeze path set) + recorded **author identity** per worker (HR-7). The fleet enforces the *mechanism*; G owns the INV-5 *invariant* (D-304). **Cited boundary.** |

## 3. L0 constraints

Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious.

### Q1: What can be written by more than one actor?

- **★ [C200-B3]** Every mutable resource a worker touches **outside** the git
  checkout — Burrito's unpack cache, `~/.cache/zig/`, `~/.mix/`, the Hex mirror,
  GitHub-release downloads, any per-language cache — is shared in the spawning
  user's `$HOME` and **leaks through worktree isolation** (worktree isolates git
  refs ONLY). Two concurrent workers writing the same `$HOME` cache race — the
  documented `XZ/LZMA Decode Failed` corruption (F-5). The worker MUST allocate a
  per-worker namespace for **every** such path, declared by the Toolchain adapter
  (not hardcoded), with each target **inside** the worktree. After namespacing,
  no two workers share any declared mutable path (D-309).
- **★ [C201-B2]** The parent/coordinator holds **no** mutable working tree any
  worker can reach (INV-11). Every checkout is a worker-private fork; no worker
  can move another's HEAD or the parent's HEAD. `origin/main` has exactly one
  writer — the Merge Authority (M; SPEC-FACTORY-MERGE) — never a worker. Splitting
  the `main` writer (any worker pushing) reintroduces F-1 and is forbidden (D-310).
- **[C202-B5]** A terminated worker's dirty state has **exactly one** capturing
  writer: the `WorkspaceJanitor` monitor (C4). The dying worker does not capture
  itself (its `terminate/2` does not run on `:kill`); two capturers would
  double-count the CON-5 balance.

### Q2: What ordering assumptions are implicit?

- **★ [C203-B5]** **Capture-before-reclaim.** The janitor MUST capture all three
  dirty kinds **before** removing the worktree; reclaim after capture is
  irreversible. A naïve `git diff` (no `HEAD`) silently omits staged work; the
  **untracked** kind is caught by **no** `git diff` and needs a separate
  `ls-files --others --exclude-standard | tar`. Omitting either step silently
  loses exactly the work a *killed* worker holds — the most common end-state
  (D-313, D-334; F-4).
- **★ [C204-B2]** **Verify-before-work.** A worker's first action is to verify
  its position (`pwd`/HEAD/branch) and **abort** (`{:stop, :position_unverified}`)
  if it finds itself in the parent root or off the expected ref. Position is set
  by the *system* and verified by mechanism — **never** trusted from the spawn
  brief (`isolation: worktree` always forks from `main`, never the spawner's
  branch; a brief asserting "you are at commit X" is unreliable). No work
  proceeds on an asserted position (D-311; F-6).
- **★ [C205-B8]** **Test-author-before-implementer.** The `:test_author` worker is
  spawned and its gating-test **path set frozen** in the Unit's durable
  plan-of-record *before any* `:implementer` is spawned (INV-5 ordering). The
  author identity of every worker is recorded; same-agent authorship of an oracle
  and its subject is rejected at gate time even if the ordering looks correct
  (HR-7 — identity, not mere ordering). The fleet enforces this *mechanism*; G
  (D-304) owns the resulting invariant.

### Q3: What happens if a component fails silently?

- **★ [C206-B7]** A **wedged-but-not-crashed** worker — agent `Port` alive, no
  `:exit_status`, no `:DOWN` — emits **no trigger**. The owning Unit FSM would
  await it forever and the loop would silently livelock. Every worker MUST emit a
  heartbeat; the `Watchdog` (C6) synthesizes a `worker_stalled` event on
  heartbeat absence past `heartbeat_timeout`. This is the half of total
  escalation that totality-over-the-classifier alone cannot supply — it makes
  D-317 hold over *reachable states*, not merely over `classify/1`'s domain. The
  fleet owns the trigger source; CORE owns the consumer (D-317).
- **★ [C207-B5]** Capture MUST be a **monitor**, not `terminate/2`. `terminate/2`
  does not run on a brutal `:kill`, on a supervisor `:shutdown` to a non-trapping
  child, or on a linked/owner crash — precisely the deaths a killed worker dies.
  Relying on `terminate/2` silently loses the killed worker's work. The
  independent monitor catches `:DOWN` for **every** reason (D-313, F-4).
- **[C208-B5]** If reclaim is skipped (the janitor itself crashes mid-handler),
  the leaked worktree is F-3 — "the symptom that hides every other failure mode."
  The janitor is supervised; on restart it re-monitors live workers and
  reconciles the worktree directory against the registry, reclaiming orphans
  (D-314).

### Q4: What information crosses a boundary, and what is lost?

- **★ [C209-B5]** The capture crossing from worker to Ledger carries **all three
  dirty kinds with their disposition** — `committed ⊎ captured ⊎
  discarded-by-decision` (CON-5). No dirty state is reduced to a bare "lost":
  staged+unstaged go to a `git diff HEAD` patch, **untracked** to a tar, and the
  disposition is durably recorded so the balance `dirty(w) = committed ⊎ captured
  ⊎ discarded_by_decision` holds by construction (D-334). The capture mechanism
  is W's; the *durable record* of the disposition is L's (cited, B6/D-315).
- **★ [C210-B4]** Agent I/O crosses as **structured, length-framed events**
  (`{:packet,4}` → decoded `%Tau.Provider.Event{}` / agent-event structs), never
  stdout screen-scraping. A tool result is structured `details`. Ad-hoc event
  formats and `IO`-scraping are forbidden (OTP non-negotiable; GAP-4). The
  per-worker namespace (`env: ns`) crosses into the `Port`'s subprocess so the
  sub-agent inherits isolation too.
- **[C211-B1]** A worker `:DOWN` crosses to the Unit FSM as `worker_exit(id,
  reason)` carrying the reason — an **outcome to decide**, never an instruction
  to auto-restart. A gate FAIL or bad LLM output is a *semantic* outcome (Unit
  retry ladder), **not** an infrastructure crash to restart (the dominant
  BEAM-for-agents mistake).

### Q5: Where are the feedback loops, and are they bounded?

- **★ [C212-B1]** The spawn↔outcome loop (worker exit → Unit decides → possible
  re-spawn) is bounded by the Unit's retry ladder (refine ≤ N → pivot →
  escalate), which is owned by SPEC-FACTORY-CORE (D-318). The fleet imposes no
  retry of its own: `restart: :temporary` means a crashed worker is **never**
  silently re-spawned by the supervisor. The only bound the fleet owns is
  `W_cap` on live worker count.
- **[C213-B7]** The heartbeat/watchdog loop fires at most one `worker_stalled`
  per worker per stall window; it does not retry — it hands the stall to the Unit
  FSM, which classifies it via the bounded retry ladder. No watchdog self-loop.

### Q6: What are the pre/post-conditions at each boundary?

- **[C214-B2]** Worker `init/1` pre: a system-established `base_ref` (the Unit's
  pinned base, derived from fresh `origin/main`). Post: a private worktree at
  `ws` whose verified pwd = `ws`, HEAD = `base_ref`, and `¬in_parent_root?`; on
  any verification failure, `{:stop, :position_unverified}` — the worker does
  **no** work (D-311).
- **[C215-B3]** `resolve_namespace/2` pre: the Toolchain adapter's
  resource-namespace declaration (a list of `{:env, VAR, :rel, sub}`). Post: a
  **total** map — every declared `VAR` maps to an existing dir under `ws`; a
  declaration with no allocated dir is a spawn error, not a warning. Concurrent
  builds without the namespace map are a **spawn error** (D-309; MANDATORY under
  concurrency).
- **[C216-B5]** Janitor `:DOWN` handler post: the Ledger holds the capture
  disposition (CON-5) **and** the worktree + every namespaced dir is gone (INV-15)
  — both in the same handler, or neither (no partial reclaim that leaves a leaked
  worktree).

### Q7: What is the message-ordering protocol?

- **★ [C217]** **Liveness is monitored refs and heartbeats**, never `:global` or
  `Process.whereis |> send`. Worker `:DOWN` is a `Process.monitor` callback; a
  stall is a heartbeat-absence inference; both reach the Unit/janitor via
  monitored refs / PubSub, never a shared mailbox (OTP non-negotiable #4). The
  agent `Port` is **linked** into its worker so an agent crash is contained to
  that one worker (INV-17).
- **[C218]** Identity is a **Registry key** (`worker_id`), never a pid. No pid is
  stored durably (a stored pid dangles after restart); on resume, worker and
  janitor-monitor refs are re-resolved by key.

### Q8: What is the change-impact (what else must move if this changes)?

- **[C219]** Adding a new isolated resource is a **Toolchain-adapter declaration**
  change (a new `{:env, VAR, :rel, sub}` row), **not** a change to W's code — that
  is the point of D-S2's resource-namespace declaration (total + polyglot). A new
  mutable resource that leaks through the worktree and is *not* declared is the
  bug class F-5 reappearing; the adapter contract MUST be extended in the same PR
  (no new leaking resource without its namespace declaration). Adding a worker
  role is a new atom in the `role` field, not a subclass (OTP non-negotiable #2).

## 4. Boundary contracts

### B1: Unit (U) ↔ WorkerSupervisor (C1) — *partly cited, SPEC-FACTORY-CORE B8*

- `spawn/3 :: (role, brief, base_ref) -> {:ok, worker_id}` — starts a
  `restart: :temporary` `Worker` under the `DynamicSupervisor`, keyed in
  `WorkerRegistry`. The Unit holds `worker_id`, never a pid.
- `worker_exit(worker_id, reason)` is surfaced asynchronously (the
  death-certificate). It is an **outcome the Unit decides**, never an auto-restart.
- Invariant (**D-316, crash containment**): `crashes(w) → blast_radius(w) = {w}`
  — the `:temporary` supervisor issues the certificate without disturbing other
  workers or the coordinator. No `try/rescue`/`:exit`-catch crosses the boundary.

### B2: Worker (C2) ↔ git checkout

- `init/1` allocates a **private worktree** at `ws` forked from the
  system-established `base_ref` (never the spawner's branch, never the parent
  root).
- Post: `verify_pwd(ws) == {:ok, ws}` ∧ `verify_head(ws, base_ref) == {:ok,
  base_ref}` ∧ `in_parent_root?(ws) == false`; otherwise `{:stop,
  {:position_unverified, ws, base_ref}}`.
- Invariant (**D-310, no shared tree**): no worker mutates the parent HEAD or
  another worker's HEAD; `origin/main` has exactly one writer (M, cited).
- Invariant (**D-311, verified position**): position is set by the system and
  verified by the worker before any work; a brief-asserted position is never
  trusted.

### B3: Worker (C2) ↔ Isolation namespace (C5)

- `resolve_namespace/2 :: (ws, [{:env, var, :rel, sub}]) -> %{var => abs_dir}` —
  pure; every declared `VAR` maps to an existing dir **inside** `ws`.
- Pre: the Toolchain adapter's `resource_namespace(tc)` declaration (data, not a
  verdict — HR-3).
- Post: the map is **total** over the declaration; the `Worker` passes it as
  `env:` to **every** `Port` it opens (build/test/agent), so subprocesses inherit
  the namespace. Because the dirs live inside `ws`, reclaiming `ws` reclaims them
  (no separate cleanup path).
- Invariant (**D-309, complete resource isolation**): `w₁ ≠ w₂ → workspace(w₁) ⫫
  workspace(w₂)` over **every** declared mutable resource; no two concurrent
  workers share any declared path. A concurrent-build worker spec lacking the
  namespace map is a **spawn error**.

### B4: Worker (C2) ↔ agent Port

- `Port.open({:spawn_executable, agent_bin}, [:binary, {:packet, 4},
  :exit_status, {:env, ns}, {:cd, ws}])` — length-framed structured I/O, linked
  into the worker.
- Inbound frames decode to typed `%Tau.Provider.Event{}` / agent-event structs;
  `{:exit_status, n}` is the agent terminal signal. **No** stdout scraping, **no**
  ad-hoc event format.
- Invariant (**D-316**): the agent's crash domain ⊆ the worker's crash domain — an
  agent crash is contained to one worker, never the fleet, never the coordinator.

### B5: WorkspaceJanitor (C4) ↔ Worker (C2) — the `:DOWN` capture

- `handle_info({:DOWN, ref, :process, pid, reason}, st)` fires for **every** exit
  reason (crash, `:kill`, `:shutdown`, normal). Sequence (capture-before-reclaim):
  1. `patch = git -C ws diff HEAD` (staged **and** unstaged).
  2. `untracked = git -C ws ls-files --others --exclude-standard`; if non-empty,
     `tar -C ws -czf <wip.tgz> -T -` over it (the kind caught by **no** `git diff`).
  3. `status = git -C ws status --short`.
  4. `Ledger.capture(worker_id, %{patch, untracked_tgz, status, disposition})`
     (WAL-before-ack; B6/D-315).
  5. `reclaim(ws, ns)` — worktree **and** every namespaced dir gone.
- Invariant (**D-313, capture-before-destroy**): all three dirty kinds are
  captured before reclaim; capture is a **monitor**, not `terminate/2`.
- Invariant (**D-314, reclaim**): `terminates(w) ↝ reclaimed(workspace(w))` on
  every exit path incl. `:kill`; nothing leaks (closes F-3).
- Invariant (**D-334, artifact conservation**): `dirty(w) = committed(w) ⊎
  captured(w) ⊎ discarded_by_decision(w)`; the disposition is durably recorded —
  nothing lost by omission (CON-5).

### B6: WorkspaceJanitor (C4) ↔ Ledger (L) — *cited, SPEC-FACTORY-CORE B3 / D-315*

- The capture disposition is written via the single Ledger writer
  (WAL-before-ack). W produces the capture artifact; L is the durable
  writer-of-record. Reclaim's external effect happens only after the capture
  write acks.

### B7: Watchdog (C6) ↔ Unit (U) — *cited consumer, SPEC-FACTORY-CORE D-317*

- Each `Worker` emits a heartbeat at `heartbeat_interval`. On absence past
  `heartbeat_timeout`, `Watchdog` synthesizes `worker_stalled(worker_id)` to the
  owning Unit. This is the **trigger source** D-317(b) requires (a wedged worker
  emits no `:DOWN`); CORE owns the totality consumer.
- A stall is distinct from a crash: `worker_stalled` ≠ `worker_exit`. Exactly one
  `worker_stalled` per stall window per worker; no watchdog retry.

### B8: Fleet ↔ Gate (G) — oracle-separation mechanism — *cited invariant, SPEC-FACTORY-GATE / D-304*

- The fleet enforces the **mechanism** of INV-5: spawn `:test_author` first,
  freeze its gating-test path set before any `:implementer`, and **record the
  author identity** of every worker in the Ledger (HR-7). The implementer's
  worktree makes the frozen gating-test paths read-only / scanned.
- The **invariant** `author(test_g) ≠ author(impl)` is asserted at gate time and
  owned by SPEC-FACTORY-GATE (D-304); the masking and mutation checks (D-305,
  D-306) key on the frozen path set, not commit attribution. This SPEC supplies
  the spawn-order + identity-recording mechanism only.

## 5. State enumeration

### Worker (C2) — `GenServer`, `restart: :temporary`

| State | Meaning | Entry | Exit |
|-------|---------|-------|------|
| (pre-init) | allocating boundary | `start_link` | position verified → `working`; verify fail → `{:stop, :position_unverified}` (no work done) |
| `working` | agent `Port` driving the role's brief; emitting heartbeats | position verified, namespace total | agent `{:exit_status, n}` → normal exit; crash/`:kill` → `:DOWN`; heartbeat absence → (no self-transition; `Watchdog` fires `worker_stalled`) |
| (terminated) | exited (any reason) | normal exit / crash / `:kill` / `:shutdown` | `WorkspaceJanitor` `:DOWN` handler captures + reclaims |

A worker is **`:temporary`**: it has no `restarting` state — a crash is a
death-certificate, not a resurrection. There is no representable transition that
re-spawns a crashed worker onto a fresh worktree mid-flight (that decision
belongs to the Unit FSM, U).

### WorkspaceJanitor (C4) — `GenServer`, independent monitor

| State | Meaning | Entry | Exit |
|-------|---------|-------|------|
| `monitoring` | holding `{worker_id → {ws, ns, monitor_ref}}` for live workers | start; each `spawn` adds a monitor | a worker `:DOWN` → run capture-before-reclaim, drop the worker |

The janitor never traps the worker's exit (it is a *monitor*, outside the
worker's crash domain — INV-17), so a worker crash cannot take the janitor with
it. On its own restart it reconciles the worktree directory against the registry
and reclaims orphans (the only recovery path; F-7's manual checklist is
unreachable).

### Capture disposition (CON-5 / D-334)

```
dirty(w) = committed(w) ⊎ captured(w) ⊎ discarded_by_decision(w)
  captured(w)            = {staged+unstaged (git diff HEAD), untracked (ls-files | tar)}
  discarded_by_decision  = a recorded Ledger decision (e.g. a pivot abandons the diff)
```

Every reachable worker termination resolves to exactly one disposition per dirty
hunk; none falls outside the three sets.

## 6. D-NNN invariants

> Owned by this SPEC. Each names its detection method. Cited D-NNN (gate / merge /
> core) are enforced by their owner SPEC and only *consumed* here.

**D-309 — Complete resource isolation (INV-10, closes F-5):**
For any two concurrent workers `w₁ ≠ w₂`, `workspace(w₁) ⫫ workspace(w₂)` over
**every** mutable resource the Toolchain adapter declares — git checkout AND every
`$HOME`/cache/XDG/network-download path. Isolation is a property of the spawn
mechanism (`init/1`), not an opt-in flag; the namespace map is **total** over the
declaration and each target lives inside the worktree. A concurrent-build spec
lacking the namespace map is a spawn error. Enforced by
`worker_isolation_property_test.exs` (the namespace map is total over an arbitrary
declaration; tagged `:property`) **and** the integration test
`burrito_xdg_race_test.exs` — two concurrent workers building the Burrito binary
with per-worker `XDG_DATA_HOME` complete with **zero** `XZ/LZMA Decode Failed`
(the canonical F-5 reproduction running clean).

**D-310 — No shared mutable tree (INV-11, closes F-1/F-2):**
No worker mutates the parent/coordinator HEAD or another worker's HEAD; every
checkout is a worker-private fork; `origin/main` has exactly one writer (M,
cited). Isolation is structural, not an opt-in `isolation: worktree` flag an
agent might omit. Enforced by `worker_no_shared_tree_test.exs` (spawn N workers;
assert the parent HEAD and each worker HEAD are independent and unmovable by any
other worker).

**D-311 — Verified position (INV-12, closes F-6):**
A worker's starting git position is set by the system and **verified by the
worker** (`pwd`/HEAD/branch) before any work; on mismatch the worker aborts
(`{:stop, :position_unverified}`) rather than proceeding on a brief-asserted
position. Enforced by `worker_verify_position_test.exs` (start a worker pointed at
the parent root or a wrong ref ⇒ it aborts with `:position_unverified` and does no
work).

**D-313 — Capture-before-destroy, all three dirty kinds (INV-14, closes F-4):**
On worker termination for **any** reason (crash, `:kill`, `:shutdown`, normal),
the `WorkspaceJanitor` **monitor** captures staged+unstaged (`git diff HEAD`)
**and untracked** (`ls-files --others --exclude-standard | tar`) **before**
reclaim. Capture is a monitor, never `terminate/2` (which does not run on `:kill`).
Enforced by `workspace_janitor_test.exs` — **`:kill` a worker holding an untracked
file ⇒ the file is recovered** from the capture artifact (the prompt's recovery
test); a companion case asserts a naïve `git diff` would have missed it.

**D-314 — Supervised reclaim (INV-15, closes F-3/F-7):**
Every isolation resource has a supervised lifecycle: created in `init/1` (linked
to the worker), reclaimed by the janitor on **every** exit path including crash;
nothing leaks. The janitor itself, on restart, reconciles the worktree directory
against the registry and reclaims orphans. No leaked-locked worktree accumulates;
the stale-parent recovery procedure (F-7) is unreachable. Enforced by
`worker_reclaim_test.exs` (terminate a worker by each exit reason ⇒ assert no
leaked worktree dir and no leaked namespaced cache dir remain).

**D-316 — Crash containment (INV-17):**
`crashes(w) → blast_radius(w) = {w}`. A per-worker process is a per-worker crash
domain; the agent `Port` is linked into its worker (agent crash ⊆ worker crash);
no `try/rescue`/`:exit`-catch crosses the worker boundary; the `:temporary`
supervisor issues a death-certificate without disturbing peers or the
coordinator; the janitor monitors (does not link) so it survives any worker crash.
Enforced by `worker_crash_containment_test.exs` (crash one of N concurrent
workers ⇒ assert the other N−1 and the supervisor are unaffected and the agent
crash did not escape its worker).

**D-334 — Artifact conservation (CON-5, the accounting form of D-313):**
A terminated worker's dirty state is `dirty(w) = committed(w) ⊎ captured(w) ⊎
discarded_by_decision(w)` — never lost by omission; the disposition is durably
recorded (the record is L's, cited B6/D-315; the capture mechanism is W's). The
untracked kind is conserved explicitly (a naïve `git diff` omits it). Enforced by
`artifact_conservation_test.exs` (drive a worker to hold one hunk of each dirty
kind, terminate it, and assert the join `committed ⊎ captured ⊎
discarded_by_decision` covers every hunk with no remainder).

## 7. Acceptance criteria

Each is expressed against the user-facing path with an observable signal. PR
groupings are indicative.

- **AC-1 (PR-FLEET-1):** `mix compile --warnings-as-errors` passes with
  `Tau.Factory.{WorkerSupervisor, Worker, WorkerRegistry, WorkspaceJanitor}`
  present; `Tau.Factory.Supervisor` starts the W subtree under `Tau.Application`.
  Signal: `mix test` boots the tree with the W subtree supervised.
- **AC-2 (PR-FLEET-1, D-311):** `mix test test/tau/factory/worker_verify_position_test.exs`
  passes — a worker started at the parent root or a wrong ref aborts with
  `:position_unverified` and does no work. Signal: the test asserts the abort and
  an unchanged tree.
- **AC-3 (PR-FLEET-2, D-309):** `mix test --only property` passes including
  `worker_isolation_property_test.exs` — the namespace map is total over an
  arbitrary Toolchain declaration; every declared `VAR` maps to a dir inside the
  worktree.
- **AC-4 (PR-FLEET-2, D-309 — F-5 reproduction):** `mix test
  test/tau/factory/burrito_xdg_race_test.exs` passes — **two concurrent workers
  building the Burrito binary with per-worker `XDG_DATA_HOME` produce zero
  `XZ/LZMA Decode Failed`** (the canonical race running clean). Signal: the exact
  two-worker concurrent build command exits 0 with no `XZ/LZMA Decode Failed` in
  either worker's structured output.
- **AC-5 (PR-FLEET-3, D-313/D-334 — the `:kill` recovery test):** `mix test
  test/tau/factory/workspace_janitor_test.exs` passes — **a worker holding an
  untracked file is `:kill`-ed and the untracked file is recovered** from the
  capture artifact; the companion assertion shows a naïve `git diff` would have
  missed it. Signal: the test reads the captured untracked file back byte-for-byte
  after reclaim.
- **AC-6 (PR-FLEET-3, D-334):** `artifact_conservation_test.exs` passes — the join
  `committed ⊎ captured ⊎ discarded_by_decision` covers every dirty hunk of a
  terminated worker with no remainder.
- **AC-7 (PR-FLEET-3, D-314):** `worker_reclaim_test.exs` passes — termination by
  each exit reason (normal, crash, `:kill`, `:shutdown`) leaves no leaked worktree
  dir and no leaked namespaced cache dir.
- **AC-8 (PR-FLEET-4, D-316):** `worker_crash_containment_test.exs` passes — one of
  N concurrent workers crashes (and an agent-`Port` crash is induced) with the
  other N−1 workers and the supervisor unaffected; the agent crash did not escape
  its worker.
- **AC-9 (PR-FLEET-4, D-310):** `worker_no_shared_tree_test.exs` passes — N workers'
  HEADs and the parent HEAD are mutually independent and unmovable across workers.
- **AC-10 (PR-FLEET-4, watchdog / feeds CORE D-317):** `worker_stalled_test.exs`
  passes — a wedged worker (Port alive, no `:exit_status`, no `:DOWN`, no
  heartbeat) yields exactly one synthetic `worker_stalled(worker_id)` to the
  owning Unit past `heartbeat_timeout` (the trigger SPEC-FACTORY-CORE D-317(b)
  consumes). Signal: the Unit observes `worker_stalled`, not a silent spin.
- **AC-11 (PR-FLEET-4, D-304 mechanism, cited):** `oracle_spawn_order_test.exs`
  passes — the `:test_author` worker is spawned and its path set frozen before any
  `:implementer`, and each worker's author identity is recorded; same-identity
  oracle/subject is rejected at the cited gate. (Mechanism here; the INV-5
  invariant is owned by SPEC-FACTORY-GATE.)
- **AC-12 (meta):** the gating tests above run in CI as a blocking job under a
  per-worker `XDG_DATA_HOME` so the F-5 reproduction (AC-4) is itself isolated.
  *(meta — verified by CI wiring; exempt from the unit-test-linkage check.)*

## Appendix B — Source map

Files that bring a PR into scope of this SPEC (`D-NNN`/`C-N` → file:symbol):

- `lib/tau/factory/worker_supervisor.ex` (C1; D-316, death-certificate) — PR-FLEET-1
- `lib/tau/factory/worker.ex` (C2; D-309, D-310, D-311, D-316 + heartbeat emission) — PR-FLEET-1/2
- `lib/tau/factory/worker_registry.ex` (C3; key-not-pid identity) — PR-FLEET-1
- `lib/tau/factory/worker/isolation.ex` (C5; D-309, D-311 — pure namespace/verify helpers) — PR-FLEET-2
- `lib/tau/factory/workspace_janitor.ex` (C4; D-313, D-314, D-334 — `:DOWN` monitor) — PR-FLEET-3
- `lib/tau/factory/fleet/watchdog.ex` (C6; heartbeat watchdog → `worker_stalled`, feeds CORE D-317) — PR-FLEET-4
- `lib/tau/factory/supervisor.ex` + `lib/tau/application.ex` (W subtree placement) — PR-FLEET-1
- `test/tau/factory/worker_verify_position_test.exs` (D-311) — PR-FLEET-1
- `test/tau/factory/worker_isolation_property_test.exs` (D-309) — PR-FLEET-2
- `test/tau/factory/burrito_xdg_race_test.exs` (D-309, F-5 repro) — PR-FLEET-2
- `test/tau/factory/workspace_janitor_test.exs` (D-313, `:kill`+untracked recovery) — PR-FLEET-3
- `test/tau/factory/artifact_conservation_test.exs` (D-334) — PR-FLEET-3
- `test/tau/factory/worker_reclaim_test.exs` (D-314) — PR-FLEET-3
- `test/tau/factory/worker_crash_containment_test.exs` (D-316) — PR-FLEET-4
- `test/tau/factory/worker_no_shared_tree_test.exs` (D-310) — PR-FLEET-4
- `test/tau/factory/worker_stalled_test.exs` (watchdog; feeds CORE D-317) — PR-FLEET-4
- `test/tau/factory/oracle_spawn_order_test.exs` (D-304 mechanism, cited) — PR-FLEET-4

**Cross-SPEC boundaries (cited, not owned here):** B1/B6/B7 → `SPEC-FACTORY-CORE`
(D-315 durable capture record, D-317 `worker_stalled` consumer, D-318 retry
ladder, D-330/D-336 conservation lineage); B8 → `SPEC-FACTORY-GATE` (D-304 oracle
separation invariant, D-305 masking, D-306 mutation — the fleet supplies only the
spawn-order + author-identity *mechanism*); the `origin/main` sole-writer half of
INV-11 → `SPEC-FACTORY-MERGE` (D-300–D-303). Resource-namespace declaration is
the Toolchain adapter's contract (D-S2 → `SPEC-FACTORY-GATE`).

**Catalog registration required before first implementation PR:** add
`SPEC-FACTORY-FLEET` to `.claude/rules/spec-before-code.md` (catalog) and the
`D-NNN` block table in `docs/MISSION.md` (D-309, D-310, D-311, D-313, D-314,
D-316, D-334 → this SPEC).
