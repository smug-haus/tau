# SPEC: Factory Worker Fleet (isolation · worker lifecycle · capture-before-destroy)

| | |
|---|---|
| **Status** | Draft |
| **Date** | 2026-06-10 |
| **Scope** | The `:tau_factory` worker fleet — component **W**: the horizontally-scalable execution tier. One supervised process per worker (implementer / test-author / critic / reviewer / researcher), each owning a *complete* isolation boundary (private git checkout from a verified ref + a per-worker namespace for every mutable resource the Toolchain adapter declares). Owns total-resource-isolation, no-shared-tree, verified-position, capture-before-destroy (all three dirty kinds), supervised reclaim, crash-containment, and artifact-conservation. Issues the worker death-certificate; runs the heartbeat watchdog that synthesizes the `worker_stalled` trigger SPEC-FACTORY-CORE depends on. Enforces the oracle-separation **spawn-order + author-identity mechanism** (the invariant is owned by SPEC-FACTORY-GATE). |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + boundary contracts. Derived from the verified architecture in `docs/arch/` (system-architecture §1 component W + §3 enforcement matrix; worker-fleet.md; invariants.md INV-10..12/14/15/17; conservation.md CON-5; tau-current-analysis.md §3 F-1..F-7). |
| **Issue** | TBD — file before the first implementation PR (`tau-github-workflow`); reference as `Closes #N`. |

**Changelog:** Initial draft — §0–§7 + Appendix B. Introduces D-309, D-310,
D-311, D-313, D-314, D-316, D-334.
ARCH-GAP #460 amendment — adds **D-326** (worker completion is an asserted
in-band `work_ready` event, the success counterpart of the `worker_exit` death
certificate; §3 C210b-B9, §4 B1/B4, §6). Cites (does not own) D-304/D-305/D-306
(SPEC-FACTORY-GATE — the worker enforces only the spawn-order + author-identity
*mechanism* of D-304, HR-7; the invariant is GATE's), D-300–D-303
(SPEC-FACTORY-MERGE — sole `origin/main` writer, the other half of INV-11),
D-315/D-330/D-336 (SPEC-FACTORY-CORE — the durable Ledger that records each
capture disposition and the `worker_stalled` consumer). Resource-namespace
declaration is supplied by the **Toolchain adapter** (SPEC-FACTORY-GATE / D-S2),
making isolation total and polyglot.
A1 (#487) amendment — adds **D-364..D-367**: the **Worker↔CodingAgent bridge**
contract that wires the *real* `Tau.CodingAgent` substrate (SPEC-CODING-AGENT) as
the worker's agent in place of the canned dogfood script, via an
`agent_bin`-shaped **CodingAgent shim** that preserves the existing §4 B4 Port
contract unchanged (§4 B4-A1, §6 D-364..D-367). Couples to #486 (the real
`head_sha` thread) which *consumes* the coordinate this bridge produces — cited,
not owned here.
#511 amendment — adds **D-376** (`AgentBin.resolve/1` config-gated selector; §4
B4-A1 extension, §6, Appendix B). Wires `mix tau.factory.dogfood` to use
`AgentBin.resolve/1`; default mode stays scripted so existing dogfood gates are
unaffected.
#515 amendment (real-run integration) — adds **D-381**: per-unit **prompt
delivery** across the Worker↔shim `Port` (§4 B4-A1, §6, Appendix B). A2/#488
(CORE D-372) *composes* the brief and threads it to the Worker's `:brief`, but the
brief stopped at the Worker state and never reached the shim — the real `claude`
ran as `claude -p ""`. D-381 pins the delivery seam: the Worker sets a
`TAU_AGENT_PROMPT` env var at `Port.open` and the shim reads it into
`task.prompt`. Orthogonal to the #509/D-374 metered-spend scrub (the prompt is
task data, never a credential).
#528 amendment (unified agent-boundary model) — **reaffirms D-364** and
cross-refs **D-388**. D-364 is unchanged: the shim uniformly owns the single
branch+commit step. Under the #528 model the `ClaudeCode` sub-agent runs with
git denied at the argv boundary (SPEC-CODING-AGENT D-387 — `--disallowedTools
"Bash(git:*)"`), so it CANNOT self-commit and always leaves an uncommitted tree
for the shim's single `git status --porcelain` detection to commit — exactly the
non-empty-diff branch of D-364. #528 also adds a **worker config-isolation
requirement** at the D-309/D-365 isolation boundary: the worker spawns the
`ClaudeCode` agent with an isolated `CLAUDE_CONFIG_DIR` (subscription credential
only, no operator hooks/plugins/skills/MCP/memory). The authoritative invariant
text is **SPEC-CODING-AGENT §6 D-388**; this SPEC cross-refs it as a property of
the worker's isolation boundary, it is not owned here.

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
| B1 | **U** (SPEC-FACTORY-CORE) ↔ C1 WorkerSupervisor | `spawn(role, brief, base_ref)` → `{:ok, worker_id}`; async `work_ready(worker_id, branch, head_sha)` (success, D-326) ∥ `worker_exit(worker_id, reason)` (death cert). **Cited owner: CORE (B8).** |
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
- **★ [C210b-B9]** **Normal completion is an explicit in-band event, not an exit
  status (D-326).** When the agent finishes successfully it emits a
  `work_ready(branch, head_sha)` frame over its `Port` *before* exiting; the
  worker decodes it (the same `decode_event` path as C210-B4) and surfaces
  `work_ready(worker_id, branch, head_sha)` to the owning Unit. Clean Port exit
  (`:exit_status 0`) is **not** completion: a single exit bit cannot distinguish
  "did the work, pushed a real diff" from "ran and pushed nothing" from "crashed
  but happened to exit 0". The `branch`/`head_sha` payload is the **evidence** U
  needs to confirm a non-empty diff before gating — without it the mutation gate
  (D-306) degenerates on an empty diff into a false-green. The success event and
  the death certificate are **disjoint**: `work_ready` ≠ `worker_exit`.
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
- `work_ready(worker_id, branch, head_sha)` is the **success** counterpart of
  `worker_exit`, surfaced asynchronously when the agent reports a stable diff
  (D-326). The two are **disjoint** worker-outcome events keyed by `worker_id`;
  together with the watchdog's `worker_stalled(worker_id)` (B7) they form the
  complete `worker_event` set the Unit FSM consumes. `work_ready` is the **only**
  trigger of U's `implementing → gating` edge.
- Invariant (**D-316, crash containment**): `crashes(w) → blast_radius(w) = {w}`
  — the `:temporary` supervisor issues the certificate without disturbing other
  workers or the coordinator. No `try/rescue`/`:exit`-catch crosses the boundary.
- Invariant (**D-326, completion is an asserted in-band event**): a worker's
  *normal completion* is signalled **only** by an in-band `work_ready` frame the
  agent emits over its `Port` (B4) before exit; clean Port exit (`:exit_status
  0`) is **never** by itself surfaced as completion. Formally, with
  `wire(w) ∈ {work_ready(w,b,h), exit_status(w,n), —}` the agent's last frame
  and exit:
  `□( surfaces_work_ready(w) ⇒ ∃ b,h. wire-frame work_ready(w,b,h) was received )`
  ∧ `□( exit_status(w,0) ∧ ¬received work_ready(w,_,_) ⇒ surfaces worker_exit(w,:no_work_product), NOT work_ready )`.
  The `branch`/`head_sha` payload lets U confirm a non-empty diff before
  `request_gate`; an exit-0-without-`work_ready` is a *no-op*, routed to the
  Unit's retry ladder as a semantic non-completion, never gated.

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
- **Completion frame (D-326).** Among the decoded event types is a terminal
  *work-product-ready* frame — modelled as a struct under the existing event
  taxonomy (extend `Tau.Provider.Event`, mirroring the in-band
  `%Tau.CodingAgent.Event.Done{}` already used by `Tau.Session`; **never** an
  ad-hoc format). On decoding it the worker emits `work_ready(worker_id, branch,
  head_sha)` to `report_to`. The worker forwarding this frame is the **only**
  source of a U completion trigger; `{:exit_status, 0}` arriving with no prior
  `work_ready` is surfaced as `worker_exit(worker_id, :no_work_product)`, not as
  a success. This is the success counterpart of the `worker_exit` death
  certificate (single-writer discipline: the worker is the sole forwarder of
  `work_ready`, just as the independent monitor is the sole writer of
  `worker_exit`).
- **Pinned wire encoding (D-326 / PR #468 amendment).** The `{:packet,4}` frame
  payload is a JSON object (stream-json-consistent; `Jason.decode/1`):
  ```
  {"type":"work_ready","branch":"<branch>","head_sha":"<sha>"}
  ```
  The BEAM strips the 4-byte big-endian length prefix; the Worker's
  `handle_info({port, {:data, frame}}, …)` receives the raw JSON bytes.
  Decoded into `%Tau.Provider.Event.WorkReady{branch: branch, head_sha: head_sha}`
  (the typed struct — never a raw map).
- **Pinned Worker→Unit message shapes (D-326 / PR #468 amendment).**
  - Success: `{:work_ready, worker_id :: String.t(), branch :: String.t(), head_sha :: String.t()}` — the sole `implementing → gating` trigger (B1/B8).
  - Fail-closed: `{:worker_exit, worker_id :: String.t(), :no_work_product}` — reuses the death-cert channel; exit-0 with no prior `work_ready` surfaces here, routed to the retry ladder, never gated.
- **Ordering (the V1-load-bearing fact).** A single `Port`'s `{:data, _}` frames
  and its `{:exit_status, n}` are delivered to the owning process **in order** —
  the BEAM flushes all buffered Port output to the worker mailbox *before* the
  `:exit_status` message. So a `work_ready` frame the agent writes before exit is
  observed by the worker *before* the exit, making the `work_ready_seen?`
  predicate well-defined at exit time. This holds **only within one Port**; it is
  NOT a cross-process ordering claim (no wall-clock, no cross-worker order — the
  ordering invariant is per-`worker_id`, V9-clean).

### B4-A1: Worker (C2) ↔ the **CodingAgent shim** (`agent_bin`) — the real-agent bridge (#487)

> **The gap this closes.** Today the Worker's `agent_bin` is the canned
> `Tau.Factory.Dogfood.Agent` script: a fixed `/bin/sh` that emits a hardcoded
> `lib/sandbox.ex` and a fixed `work_ready` frame (`lib/tau/factory/dogfood/agent.ex`).
> Real dogfooding needs a *real* coding agent that reads an issue, reasons, edits
> files, and commits a non-deterministic diff. The substrate already exists —
> `Tau.CodingAgent` (behaviour) + `Tau.CodingAgents.ClaudeCode` (subprocess
> adapter, SPEC-CODING-AGENT). The two speak **different execution models**: the
> Worker speaks a raw `{:packet,4}` `Port` emitting a `work_ready` frame (B4); the
> adapter speaks an Elixir `Enumerable.t()` of `%Tau.CodingAgent.Event{}`. This
> contract specifies the bridge.

**The discriminating question (Port-shim vs in-process Enumerable drive).** Two
shapes can meet the seam:

- **(i) `agent_bin`-shaped CodingAgent shim (recommended).** A small executable
  (a release task / escript, e.g. `Tau.Factory.CodingAgentShim`) the Worker
  `Port.open`s as `agent_bin` *exactly as today* (B4 unchanged). Inside its own
  BEAM the shim calls `adapter.start(task, ctx)` to obtain a lazy
  `Enumerable.t()` of `%Tau.CodingAgent.Event{}` and **consumes it lazily and
  directly** — treating each consumed event as a live D-366 heartbeat pulse —
  **commits** the agent's edits to the worktree on a successful terminal
  `%Event.Done{}`, and emits the D-326 `{:packet,4}` `work_ready` frame before
  exiting. Note: `Tau.CodingAgent.run/4` is a **blocking** convenience that
  drains the whole stream and returns only when complete — it is **unsuitable**
  for the shim because it cannot drive per-event live heartbeats (D-366). The
  shim MUST call `adapter.start/2` directly.
- **(ii) In-process drive.** The Worker GenServer calls `Tau.CodingAgent.run/4`
  directly (no `agent_bin` Port for the agent), mapping `%Event.Done{}` →
  `work_ready` in-process.

**Cost asymmetry — why (i).** The Worker's *entire* B2/B3/B4/§6 contract is built
around the agent being a **linked `Port` in the worker's crash domain**
(D-316, §4 B4, §6) launched with the per-worker `env: ns` namespace (D-309, §2b)
and `{:cd, ws}` (D-311). Option (ii) dissolves that boundary: the `ClaudeCode`
adapter opens its own `Port` (with `:line`, not `:packet,4`), spawns its own
dispatcher GenServer + drainer + tempfile janitor (SPEC-CODING-AGENT §5, the
`Tau.CodingAgent.Supervisor` subtree), and inherits the **host `$HOME`**
unless `ns` is re-threaded into *that* `Port.open` — re-homing the agent crash
domain and re-routing F-5 isolation through a second, differently-shaped boundary.
Reversing a wrong (ii) guess is a Worker rewrite touching six locked invariants;
reversing a wrong (i) guess deletes one executable, Worker untouched. **(i) is the
cheap-to-reverse, contract-preserving shape, and is selected.** It also keeps the
story polyglot — a Rust/Python worker's `agent_bin` is the same `{:packet,4}`
shape — and keeps the F-5 namespace injection at exactly one site (the Worker's
`Port.open`). The shim's *own* sub-subprocess (`claude`) inherits `env: ns`
transitively, because the Worker launched the shim with `env: ns` and the shim
passes its environment through (D-365).

**The shim contract (option (i), pinned):**

- **Transport unchanged.** The Worker opens `agent_bin` with the existing B4
  options — `[:binary, {:packet,4}, :exit_status, {:env, ns}, {:cd, ws}]`. The
  shim's stdout carries **only** `{:packet,4}` frames (its own diagnostics and the
  `claude` subprocess's stdout/stderr go to *its* stderr / a log, never the
  Worker's `{:packet,4}` stdout — mirroring the dogfood script's stderr discipline
  and `ClaudeCode`'s "stderr NOT redirected to stdout").
- **Prompt delivery — the per-unit brief reaches the per-unit shim's `task.prompt`
  (the load-bearing new logic — D-381).** A2/#488 (SPEC-FACTORY-CORE D-372)
  *composes* the brief and threads it as `work_item.brief` → `WorkerSupervisor.spawn/5`
  → the Worker's `:brief`. But the brief **stops at the Worker GenServer state**: it
  is never delivered to the shim subprocess, so the shim builds `task.prompt = ""`
  and the real `claude` runs as `claude -p ""` (the issue surfaced on the first
  real run). The structural cause is that `agent_bin` is **resolved once** at
  supervisor setup (`AgentBin.resolve/1`, D-376) — adapter + a static `branch`
  are baked into the shim before any unit exists, so the *per-unit* prompt cannot
  be a write-time bake. **Decision (cheapest-to-reverse, V3):** the **per-unit
  brief crosses the existing Worker↔shim `Port` boundary (B4) as an environment
  variable**, `TAU_AGENT_PROMPT`, set by the Worker at `Port.open` time (the Worker
  *is* per-unit; the env list it already builds is per-spawn) and read by the
  shim's `Runner.main/1` into `task.prompt`. Rejected alternative (b) — bake the
  brief into the shim per-unit by moving `AgentBin.resolve/1` to unit-spawn time —
  is a heavier change (a fresh shim executable written per unit) and re-homes the
  one-time `agent_bin` construction; reversing a wrong (b) guess touches the
  supervisor/UnitDriver wiring, whereas (a) is one env key added at one site and
  one `System.get_env` read. **(a) is selected.** Contract:
    - The Worker appends `{"TAU_AGENT_PROMPT", brief}` to the `Port.open` `:env`
      list (alongside `ns`, `extra_env`, and the D-374 metered-scrub). It is set
      for **every** agent_mode (Replay and `:claude_code`); the Replay shim
      ignores `task.prompt`, so the key is benign there.
    - The shim's `Runner.main/1` reads `System.get_env("TAU_AGENT_PROMPT")` and
      builds `task.prompt = it || ""`. Absent var → `""` (back-compat: existing
      Replay/dogfood paths that set no prompt are unchanged).
    - **#509 (D-374/D-375) interaction (pinned).** The metered-spend env scrub
      removes **only** `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` /
      `ANTHROPIC_BASE_URL`. `TAU_AGENT_PROMPT` is **not** a metered key and MUST
      NOT be added to the scrub list — the fence and the prompt-delivery channel
      are orthogonal. The prompt is task data, never a credential.
- **Drive.** The shim builds a `Tau.CodingAgent.task` (`%{prompt, workspace: ws,
  …}`) — the issue→prompt **composition** is **A2 (#488)/D-372, cited not owned
  here**; the brief→`task.prompt` **delivery** across the Port is **D-381, owned
  here** (see "Prompt delivery" above) — then
  calls `adapter.start(task, ctx)` to obtain a lazy `Enumerable.t()` of
  `%Tau.CodingAgent.Event{}` and **consumes it lazily, event by event**. Each
  consumed event that carries progress information (`AssistantText`, `ToolUse`,
  `ToolResult`, `FileEdit`) is treated as a **live D-366 heartbeat pulse** as it
  arrives, so heartbeats are derived from real agent progress rather than a
  self-clock timer.

  **Why `Tau.CodingAgent.run/4` is unsuitable here** (and must NOT be
  re-introduced): `run/4` is a *blocking* convenience that calls `drain/1`
  internally, consuming the whole stream and returning `{:ok, %{events, done}}`
  only when the adapter terminates. A blocking drain cannot emit per-event
  heartbeats during the run (D-366 requires live pulses *as events arrive*).
  The shim MUST call `adapter.start/2` directly.

  The shim relies on the **substrate's adapter-level guarantee** (SPEC-CODING-AGENT
  §4 B4: "every run terminates with exactly one `%Done{}`"): the adapter
  *manufactures* a terminal `%Done{}` (including the synthetic
  `exit_status ∈ {-1,-2}` sentinels for death/timeout/cancel), **not** on the
  agent always emitting a parseable completion of its own.

  The shim MUST also handle **stream-exhaustion-without-`%Done{}`** — an
  adapter stream that ends with no terminal event (e.g. a real `claude` binary
  dies mid-stream before the adapter can manufacture a synthetic Done). In this
  case the shim MUST exit non-zero and emit **no** `work_ready` (D-364/D-367).
  A wedged adapter stream (no events, never ends) stops pulsing heartbeats;
  the Worker watchdog then raises `worker_stalled` (D-366/B7).
- **Commit ownership (the load-bearing new logic — D-364).** `Tau.CodingAgents.ClaudeCode`
  edits files in `task.workspace` but **does not** `git commit`, **does not**
  create a branch, and **does not** produce a `head_sha`. The `%Event.Done{}`
  carries `{exit_status, final_message}` only. So the **shim owns the
  branch+commit step**: on a successful `%Done{}` (real `exit_status == 0`) over a
  **non-empty** working tree, the shim creates/uses the unit branch, `git add -A`,
  commits the agent's diff, resolves `head_sha = git rev-parse HEAD`, and emits
  `work_ready{branch, head_sha}`. This step has **no analogue in the CodingAgent
  substrate** and is the core of the bridge.
- **Mapping to D-326 completion.**
  - `%Done{exit_status: 0}` **with a non-empty post-commit diff** → emit
    `{"type":"work_ready","branch":<branch>,"head_sha":<real sha>}`, then exit 0.
    The `head_sha` is the **agent's actual HEAD**, the evidence #486 consumes.
  - `%Done{exit_status: 0}` **with an empty diff** (agent ran, changed nothing) →
    emit **no** `work_ready`; exit 0. The Worker's existing D-326 fail-closed maps
    this to `worker_exit(worker_id, :no_work_product)` — the false-green an empty
    diff would otherwise produce is structurally excluded (mirrors why D-326
    exists).
  - `%Done{exit_status: -1}` (death / inactivity timeout / unrecoverable
    `%Event.Error{}`) or `-2` (cancel), **or** a non-recoverable `%Event.Error{}` →
    emit **no** `work_ready`; exit **non-zero**. The Worker maps the non-zero exit
    to `{:exit_status, n}` → `worker_exit(worker_id, {:exit_status, n})`, routed to
    U's retry ladder, never gated. Auth failures (SPEC-CODING-AGENT C8/AC-6) reach
    the Ledger via this path with their user-actionable reason in diagnostics.
- **Isolation (D-365).** The shim and its `claude` sub-subprocess run **entirely
  inside the worker's private worktree** (`{:cd, ws}`) under the worker's resource
  namespace (`env: ns`). The shim MUST pass its environment through to `ClaudeCode`
  so the `claude` `Port` inherits the same `XDG_*`/`MIX_HOME`/`HEX_HOME` namespace
  (closing the GAP-4 un-namespaced-`$HOME` race the arch flags at worker-fleet §4).
  The shim MUST set `task.workspace = ws` and rely on no `~/.tau/worktrees/...`
  CodingAgent.Workspace backend — workspace isolation is the *Worker's* (D-309),
  not the adapter's; the shim selects `Tau.CodingAgent.Workspace.Cwd` (passthrough)
  so the adapter does **not** create a second nested worktree.
- **Liveness / heartbeat source (D-366).** The CodingAgent stream emits
  fine-grained progress events (`AssistantText`, `ToolUse`, `ToolResult`,
  `FileEdit`) throughout a run. The shim MUST treat *each consumed stream event* as
  a liveness pulse and emit a `{:packet,4}` **heartbeat frame** (a new typed event
  under the `Tau.Provider.Event` taxonomy — never an ad-hoc format) at most once
  per `heartbeat_interval`, so the Worker's heartbeat — and therefore the
  `Watchdog`'s `worker_stalled` inference (B7, C206) — is **derived from real agent
  progress**, not a self-clock timer that keeps beating while the agent is wedged.
  A wedged agent (no stream events past the dispatcher inactivity timeout) stops
  pulsing; the dispatcher's own inactivity timeout additionally manufactures a
  `%Done{exit_status: -1}`, so a wedge resolves as a death-cert even if the
  watchdog has not yet fired. This makes C206's "wedged-but-not-crashed" detection
  *real*, where today's self-clock timer (`worker.ex` `handle_info(:heartbeat, …)`)
  cannot distinguish a live agent from a wedged one.
- **Crash containment (D-367).** The shim is a `Port` linked into the Worker
  (D-316), so a shim crash propagates to the Worker exactly as the canned script's
  would; the Worker's death-cert + janitor capture (B5) are unchanged. The shim
  links/monitors its *own* `ClaudeCode` dispatcher so a `claude` crash surfaces
  in-stream as a non-recoverable `%Event.Error{}`/`%Done{-1}` (SPEC-CODING-AGENT
  D-035) rather than as a silent shim hang. No `try/rescue` crosses the
  Worker↔shim Port boundary (OTP non-negotiable 7).

**Scope note — this is a multi-PR bridge, and A1 alone is not self-sufficient.**
A1 (this contract + the shim) produces a *real commit with a real `head_sha`*, but
that coordinate is **discarded by the Unit FSM today** (`unit.ex` matches
`{:work_ready, _, _branch, _head_sha}` and keys gate/merge on the *pre-declared*
`data.hash`). Threading the real `head_sha` through gate+merge is **#486 (C1)** —
a separate ARCH GAP with its own D-NNN. Without #486 the shim's real `head_sha`
lands but is ignored, so a useful real-dogfood smoke needs **A1 ∧ #486** (and a
real prompt *composed* by **A2/#488/D-372** and *delivered* to the shim by
**D-381**, this contract). This contract therefore *produces* the coordinate
and *names its consumer*; it does not implement the consumption. (V2-clean: the
shape solves exactly A1 — replace the canned agent — and explicitly defers C1/A2.)

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

**D-326 — Worker completion is an asserted in-band event, not an exit status
(closes ARCH-GAP #460):**
A worker's *normal completion* crosses to the owning Unit FSM **only** as
`work_ready(worker_id, branch, head_sha)` — a typed frame the agent emits over
its `Port` (extending `Tau.Provider.Event`, mirroring
`%Tau.CodingAgent.Event.Done{}`) **before** it exits, decoded and forwarded by
the worker. `work_ready`, `worker_exit` (death certificate), and `worker_stalled`
(watchdog) are **disjoint** worker-outcome events, all keyed by `worker_id`; they
constitute the complete `worker_event` set U consumes, and `work_ready` is the
sole trigger of U's `implementing → gating` edge. Clean Port exit (`:exit_status
0`) without a prior `work_ready` is surfaced as
`worker_exit(worker_id, :no_work_product)` — a semantic non-completion routed to
U's retry ladder, **never** gated. The `branch`/`head_sha` payload is the
evidence U uses to confirm a non-empty diff before `request_gate` (without it the
mutation gate D-306 degenerates on an empty diff into a false-green). Enforced by
`worker_completion_event_test.exs`: (a) an agent that emits `work_ready` then
exits 0 surfaces `work_ready(id, branch, head_sha)` to its Unit and drives
`implementing → gating`; (b) an agent that exits 0 **without** emitting
`work_ready` surfaces `worker_exit(id, :no_work_product)` and does **not** reach
`gating`; (c) a `work_ready` from a superseded `worker_id` is discarded. The
boundary is the **typed event**, never the exit code.

**D-364 — The CodingAgent shim owns the branch+commit step and maps `%Done{}` →
`work_ready` (#487, A1):**
The worker's `agent_bin` for a real coding agent is the **CodingAgent shim**: an
`agent_bin`-shaped executable that drives `Tau.CodingAgent` (e.g.
`Tau.CodingAgents.ClaudeCode`) and bridges its `Enumerable.t()` of
`%Tau.CodingAgent.Event{}` to the §4 B4 `{:packet,4}` Port contract **unchanged**.
Because `Tau.CodingAgent` adapters edit `task.workspace` files but produce **no**
commit, **no** branch, and **no** `head_sha`, the shim — not the Worker, not the
adapter — owns the branch+commit step. On the dispatcher-guaranteed single
terminal `%Event.Done{}`:
`□( Done(exit_status=0) ∧ ¬empty(diff(ws)) ⇒ shim commits & emits work_ready{branch, head_sha=git rev-parse HEAD} )`
∧ `□( Done(exit_status=0) ∧ empty(diff(ws)) ⇒ shim emits NO work_ready ∧ exits 0 )`
[Worker maps → `worker_exit(:no_work_product)`, D-326]
∧ `□( Done(exit_status∈{-1,-2}) ∨ Error(recoverable=false) ⇒ shim emits NO work_ready ∧ exits non-zero )`
[Worker maps → `worker_exit({:exit_status,n})`, retry ladder].
The emitted `head_sha` is the agent's **actual** HEAD (the evidence #486 keys on;
this SPEC produces it, SPEC-FACTORY-CORE/#486 consumes it). V1-clean: the shim
depends on the dispatcher *manufacturing* exactly one `%Done{}` (SPEC-CODING-AGENT
§4 B4), never on the agent self-emitting a parseable completion. Detection:
`coding_agent_shim_bridge_test.exs` — a `ClaudeCode` Replay fixture ending in
`%Done{0}` over a non-empty tree yields a `work_ready{branch, real-sha}` frame the
Worker forwards as `{:work_ready, id, branch, sha}` (sha = the shim's commit);
an empty-tree `%Done{0}` yields **no** `work_ready` (→ `:no_work_product`); a
`%Done{-1}` / non-recoverable `%Error{}` yields a non-zero exit (→ retry ladder).

**D-365 — The shim and its sub-agent run inside the worker's isolation boundary
(#487, A1):**
The Worker launches the shim with the existing B4 options `{:env, ns}` (D-309) and
`{:cd, ws}` (D-311); the shim MUST set `task.workspace = ws`, select the
passthrough `Tau.CodingAgent.Workspace.Cwd` backend (so the adapter creates **no**
second nested worktree), and **pass its environment through** to the `claude`
subprocess so that sub-subprocess inherits the per-worker `XDG_*`/`MIX_HOME`/
`HEX_HOME` namespace transitively. This closes the GAP-4 un-namespaced-`$HOME`
race today's free-running `coding_agent/` shell-out exhibits (worker-fleet §4).
`□( resources(shim) ∪ resources(claude) ⊆ namespace(worker) )` — no host-`$HOME`
cache is touched. Detection: `coding_agent_shim_isolation_test.exs` — assert the
shim's effective `workspace`, cwd, and the propagated `XDG_DATA_HOME`/`MIX_HOME`
all resolve **inside** `ws`, and that no `~/.tau/worktrees/...` nested worktree is
created.

*Config-isolation cross-ref (#528, D-388):* the worker-side resource isolation
of D-365 is complemented by **per-worker `CLAUDE_CONFIG_DIR` isolation** — the
`ClaudeCode` agent is spawned with an isolated config dir holding the
subscription credential only (no operator hooks/plugins/skills/MCP/memory), so no
operator host config leaks into the sub-agent. The authoritative invariant is
**SPEC-CODING-AGENT §6 D-388**; it is cross-referenced here as a property of the
worker's isolation boundary, not owned by this SPEC.

**D-366 — Worker heartbeats are derived from agent-stream progress, not a
self-clock (#487, A1):**
The shim emits a `{:packet,4}` heartbeat frame (a typed `Tau.Provider.Event`
struct — never an ad-hoc format) derived from **consumed CodingAgent stream
events** (`AssistantText`/`ToolUse`/`ToolResult`/`FileEdit`), rate-limited to at
most one per `heartbeat_interval`. The Worker's liveness — and therefore the
`Watchdog`'s `worker_stalled` inference (B7, C206) — is thus a function of *real
agent progress*: a wedged agent emitting no stream events stops pulsing and the
watchdog can infer the stall, where a self-clock timer (today's
`worker.ex handle_info(:heartbeat,…)`) keeps beating regardless and cannot detect
a wedge (a V12 finding against the current heartbeat — the timer enforces nothing
about liveness). The dispatcher's inactivity timeout independently manufactures a
`%Done{-1}` on a wedge, so a stall resolves as a death-cert even before the
watchdog window elapses. `□( emits_heartbeat(t) ⇒ ∃ stream_event consumed in (t−interval, t] )`.
Detection: `coding_agent_shim_heartbeat_test.exs` — a Replay stream with a gap
longer than `heartbeat_interval` produces **no** heartbeat across the gap (the
self-clock counter-example fails), and resumes pulsing when events resume.

**D-376 — Config-gated `agent_bin` selector (`AgentBin.resolve/1`, #511):**
`Tau.Factory.AgentBin.resolve/1` is the sole site that maps the factory's
`:agent_mode` config key to an `agent_bin` executable + `spawn_opts` pair.

```
resolve(opts :: keyword()) :: {agent_bin_path :: String.t(), spawn_opts :: keyword()}
```

Three modes, exhaustive and mutually exclusive:

- **`:claude_code`** — writes a `CodingAgentShim` executable with
  `Tau.CodingAgents.ClaudeCode` baked as the adapter (D-364..D-367 bridge).
  Returns `spawn_opts = [agent_mode: :claude_code]` so the Worker's
  `open_port_and_finish/1` path fires the D-374 metered-API preflight +
  credential scrub (SPEC-FACTORY-GOV). The baked shim's config, when decoded
  from its Base64 blob, carries `adapter: Tau.CodingAgents.ClaudeCode`.

- **`:scripted` / `:replay`** — writes the `Tau.Factory.Dogfood.Agent` scripted
  binary. Returns `spawn_opts = []`; no D-374 preflight. Behaviour identical to
  today's dogfood path.

- **absent / any other atom** — defaults to the scripted path (D-357 gate: real
  agent mode is **off** by default). Returns `spawn_opts = []`.

Formally: `□( resolve(opts).spawn_opts contains agent_mode: :claude_code ⟺
opts[:agent_mode] == :claude_code )`.

The resolver is a **pure function** (write of the shim file is a required
side-effect for producing the executable, not hidden process state). It holds no
ETS, no GenServer, no `Application.put_env/3`. Detection:
`test/tau/factory/agent_bin_test.exs` — 7 gating tests covering all three mode
branches, the D-357 default-off invariant, and the end-to-end thread (#511 refine).

**D-376 thread contract (§4 B4-A1 seam, #511 refine):** The `spawn_opts`
returned by `resolve/1` (`[agent_mode: :claude_code]` for `:claude_code` mode)
MUST be threaded end-to-end to `WorkerSupervisor.spawn/5` opts so the Worker's
D-374 preflight fires. The mandated thread is:
`dogfood supervisor_opts` → `Supervisor.init_full_subtree deps` →
`UnitDriver.drive/2 deps` → `worker_fun opts` → `WorkerSupervisor.spawn/5`.
When `agent_mode` is absent or non-`:claude_code`, the key MUST NOT be added
to the spawn opts (unchanged behaviour). `creds_check_fun` follows the same
thread and defaults to the real `~/.claude/.credentials.json` check in the Worker
when not injected.

**D-367 — Shim crash containment preserves the Worker's crash domain (#487, A1):**
The shim Port is linked into the Worker (D-316), so a shim crash propagates to the
Worker exactly as the canned script's would and the janitor capture (B5) is
unchanged; the shim links/monitors its own `ClaudeCode` dispatcher so a `claude`
crash surfaces in-stream as `%Error{recoverable:false}`/`%Done{-1}`
(SPEC-CODING-AGENT D-035), never a silent shim hang. No `try/rescue` crosses the
Worker↔shim Port boundary. `□( crashes(claude) ⇒ surfaces in-stream Done/Error,
not silent-hang ) ∧ □( crashes(shim) ⇒ blast_radius ⊆ {worker} )`. Detection:
`coding_agent_shim_containment_test.exs` — inject a dispatcher/`claude` crash ⇒ the
shim emits a non-recoverable terminal event and exits non-zero (Worker observes a
death-cert), and a sibling worker is unaffected.

**D-381 — Per-unit prompt delivery across the Worker↔shim Port (#515, A1/A2
bridge):** the per-unit brief (`work_item.brief`, composed by CORE D-372)
reaches the per-unit shim's `Tau.CodingAgent.task.prompt`. Because `agent_bin` is
resolved **once** at supervisor setup (D-376), the per-unit prompt cannot be baked
at shim-write time; it crosses the existing B4 `Port` boundary as an **environment
variable**. Injection is **omit-on-empty**: when `brief` is non-empty the Worker
appends `{"TAU_AGENT_PROMPT", brief}` to the `Port.open` `:env` list
(per-spawn, alongside `ns`/`extra_env`/the D-374 scrub); when `brief == ""`
the key is **omitted entirely** — no `:os.putenv`/`:os.unsetenv` global-env
mutation (unsafe under concurrent `Worker.init` calls). The shim's
`Runner.main/1` reads `System.get_env("TAU_AGENT_PROMPT") || ""` — absent is
equivalent to `""` — and sets `task.prompt = it`. Holds for every agent_mode
(Replay ignores it; benign). `□( brief ≠ "" ⇒ shim builds task.prompt == brief )
∧ □( real :claude_code run ⇒ claude argv contains "-p", brief, NOT "-p", "" )`.
**Orthogonality (D-374):** the metered-spend scrub touches only the three
`ANTHROPIC_*` keys; `TAU_AGENT_PROMPT` is task data and MUST NOT be added to
the scrub. Detection: `coding_agent_shim_prompt_test.exs` — a Worker spawned
with a non-empty `:brief` and `agent_mode: :claude_code` (with `claude` stubbed
by a Replay/fixture source) produces an argv carrying the brief as `-p <brief>`;
a `""` brief yields `-p ""`; the `ANTHROPIC_*` scrub is unaffected.

**D-382 — Role-aware brief: role threaded worker→brief→TAU_AGENT_PROMPT (#517):**
`BriefAssembler.assemble/2` accepts a `:role` opt (`:test_author` | `:implementer`)
and appends a role-specific actionable instruction section:
- `:test_author` → instructs the agent to WRITE the gating test, names the expected
  `test/...` path (from `gating_test_paths`), and states the agent is in a fresh
  isolated worktree it must edit and commit.
- `:implementer` → instructs the agent to IMPLEMENT the issue to satisfy the gating
  test. Does NOT include the test-author write instruction.

Two roles produce DIFFERENT briefs for the same input (`brief_assembler_role_test.exs`,
tests D-382(a)–D-382(e)).

**End-to-end threading:** `Supervisor.build_unit_work_item/1` assembles all three
variants (`brief`, `test_author_brief`, `implementer_brief`) from the same input and
stores them in the work_item. `UnitDriver.worker_fun/1` selects the role-specific
brief (`test_author_brief` for `:test_author`, `implementer_brief` for `:implementer`)
at worker spawn time, injecting it as `TAU_AGENT_PROMPT` via the D-381 Port env
mechanism. This closes the gap where both oracle and implementing workers previously
received the same role-agnostic brief.

**Actionable seeded issue:** `Tau.Factory.Dogfood.Sandbox.issue_body/0` returns a
real, non-empty body string describing what the implementer must build and the
acceptance criteria, ensuring the assembled brief for the seeded dogfood issue is
actionable (not `(none declared)`).

`Tau.Factory.Supervisor.to_unit_work_item/2` is the public role-threading seam:
accepts a 4-tuple work_item and a `role:` keyword, returns a work_item with `:brief`
set to the role-specific assembled brief. Enforced by `brief_assembler_role_test.exs`
(D-382(a)–D-382(e), tagged `:d_382`).

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
- **AC-13 (PR-FLEET / P5c-3, D-326):** `worker_completion_event_test.exs` passes —
  an agent emitting `work_ready` then exiting 0 surfaces
  `work_ready(worker_id, branch, head_sha)` to its Unit (driving
  `implementing → gating`); an agent exiting 0 **without** `work_ready` surfaces
  `worker_exit(worker_id, :no_work_product)` and does **not** reach `gating`; a
  `work_ready` from a superseded `worker_id` is discarded. Signal: the Unit's
  observable state after each case matches the disjoint-outcome table.
- **AC-14 (PR-A1, D-364..D-367 — the real-agent bridge):** the **CodingAgent
  shim** drives `Tau.CodingAgents.ClaudeCode` (via a Replay fixture, no real
  `claude` needed in CI) as the worker's `agent_bin` and produces a real
  `work_ready{branch, head_sha}` on a non-empty `%Done{0}`. Signal:
  `mix test test/tau/factory/coding_agent_shim_bridge_test.exs` passes — the
  Worker forwards `{:work_ready, id, branch, sha}` where `sha` is the shim's
  actual commit; the empty-diff and `%Done{-1}` cases surface the correct
  no-completion/retry outcomes (D-364); the shim+sub-agent stay inside `ws` and
  the namespace (D-365); heartbeats track stream progress not a clock (D-366);
  a `claude`/dispatcher crash surfaces as a terminal event, not a hang (D-367).
- **AC-D381 (PR #515, D-381 — per-unit prompt delivery):** a Worker spawned with
  a non-empty `:brief` and `agent_mode: :claude_code` delivers that brief to the
  shim's `task.prompt`, so the resulting `claude` argv carries `-p <brief>` (not
  `-p ""`). Signal: `mix test test/tau/factory/coding_agent_shim_prompt_test.exs`
  passes — with `claude` stubbed by a fixture source, the captured argv contains
  the brief; a `""` brief yields `-p ""`; the `ANTHROPIC_*` metered scrub
  (D-374) is unaffected.
- **AC-D382 (PR #517, D-382 — role-aware brief threaded to TAU_AGENT_PROMPT):**
  `BriefAssembler.assemble/2` with `role: :test_author` produces a brief containing
  the test-author write instruction and the expected gating-test path; with
  `role: :implementer` it produces a brief containing the implementer instruction;
  the two briefs differ; a real issue body appears in the brief (not `(none
  declared)`); and `Supervisor.to_unit_work_item/2` with an explicit role produces
  a work_item where `:brief` carries the role-specific content.
  Signal: `mix test test/tau/factory/brief_assembler_role_test.exs` passes (all
  5 tests, D-382(a)–D-382(e), tagged `:d_382`).

## Appendix B — Source map

Files that bring a PR into scope of this SPEC (`D-NNN`/`C-N` → file:symbol):

- `lib/tau/factory/worker_supervisor.ex` (C1; D-316, death-certificate) — PR-FLEET-1
- `lib/tau/factory/worker.ex` (C2; D-309, D-310, D-311, D-316 + heartbeat emission; D-326 `work_ready` decode/forward in `handle_info({port,{:data,_}},…)`; **D-381** append `{"TAU_AGENT_PROMPT", brief}` to the `Port.open` `:env` list in `open_port_final/5`) — PR-FLEET-1/2; D-326 wiring is P5c-3; D-381 is PR #515
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
- `test/tau/factory/worker_completion_event_test.exs` (D-326 — `work_ready` vs exit-0 no-op vs stale `worker_id`) — P5c-3
- `test/tau/factory/oracle_spawn_order_test.exs` (D-304 mechanism, cited) — PR-FLEET-4
- `lib/tau/factory/coding_agent_shim.ex` (B4-A1; D-364..D-367 — drives `Tau.CodingAgent`, owns branch+commit, emits `work_ready`/heartbeat frames; **D-381** `Runner.main/1` reads `System.get_env("TAU_AGENT_PROMPT")` into `task.prompt` in `run_single_stream`/`run_phased_stream`) — PR-A1 (#487); D-381 is PR #515
- `lib/tau/factory/dogfood/agent.ex` (the canned script the shim replaces as the real-dogfood `agent_bin`; D-358 retained for the orchestration smoke) — PR-A1 (#487)
- `lib/tau/factory/agent_bin.ex` (D-376 — `AgentBin.resolve/1`; config-gated selector mapping `:agent_mode` → `{agent_bin_path, spawn_opts}`) — PR #512 (#511)
- `lib/mix/tasks/tau.factory.dogfood.ex` (D-376 — wired to `AgentBin.resolve/1`; default mode stays scripted/replay; existing dogfood gates unaffected) — PR #512 (#511)
- `test/tau/factory/agent_bin_test.exs` (D-376 — 6 gating tests; all three mode branches + D-357 default-off) — PR #512 (#511)
- `test/tau/factory/coding_agent_shim_bridge_test.exs` (D-364 — `%Done{}`→`work_ready` mapping over Replay) — PR-A1
- `test/tau/factory/coding_agent_shim_isolation_test.exs` (D-365 — shim+sub-agent inside `ws`/namespace) — PR-A1
- `test/tau/factory/coding_agent_shim_heartbeat_test.exs` (D-366 — heartbeat tracks stream progress) — PR-A1
- `test/tau/factory/coding_agent_shim_containment_test.exs` (D-367 — `claude`/dispatcher crash surfaces, not hang) — PR-A1
- `test/tau/factory/coding_agent_shim_prompt_test.exs` (**D-381** — per-unit brief delivered to `task.prompt` via `TAU_AGENT_PROMPT`; argv carries `-p <brief>`; `ANTHROPIC_*` scrub unaffected) — PR #515
- `lib/tau/factory/brief_assembler.ex` (**D-382** — `assemble/2` gains `:role` opt; role-specific instruction section; compact empty-section rendering for role briefs) — PR #517
- `lib/tau/factory/dogfood/sandbox.ex` (**D-382** — `issue_body/0` exposes the actionable seeded-issue body) — PR #517
- `lib/tau/factory/supervisor.ex` (**D-382** — `to_unit_work_item/2` public role-threading seam; `build_unit_work_item/1` stores `:test_author_brief`/`:implementer_brief`) — PR #517
- `lib/tau/factory/unit_driver.ex` (**D-382** — `worker_fun` selects role-specific brief at spawn time from work_item) — PR #517
- `test/tau/factory/brief_assembler_role_test.exs` (**D-382** — 5 gating tests; D-382(a)–D-382(e)) — PR #517

**Cross-SPEC boundaries (cited, not owned here):** B1/B6/B7 → `SPEC-FACTORY-CORE`
(D-315 durable capture record, D-317 `worker_stalled` consumer, D-318 retry
ladder, D-330/D-336 conservation lineage); B8 → `SPEC-FACTORY-GATE` (D-304 oracle
separation invariant, D-305 masking, D-306 mutation — the fleet supplies only the
spawn-order + author-identity *mechanism*); the `origin/main` sole-writer half of
INV-11 → `SPEC-FACTORY-MERGE` (D-300–D-303). Resource-namespace declaration is
the Toolchain adapter's contract (D-S2 → `SPEC-FACTORY-GATE`). The **CodingAgent
substrate** the shim drives (B4-A1, D-364..D-367) is owned by `SPEC-CODING-AGENT`
(D-031..D-039 — the behaviour, the dispatcher's single-`%Done{}` guarantee, the
`%Event{}` taxonomy, workspace backends); this SPEC only wires it as the worker's
`agent_bin`. The **consumption of the shim's real `head_sha`** (threading it
through gate/merge in place of the pre-declared `data.hash`) is **#486 (C1)** →
`SPEC-FACTORY-CORE` §4 amendment — a separate ARCH GAP cited, not owned here.

**Catalog registration required before first implementation PR:** add
`SPEC-FACTORY-FLEET` to `.claude/rules/spec-before-code.md` (catalog) and the
`D-NNN` block table in `docs/MISSION.md` (D-309, D-310, D-311, D-313, D-314,
D-316, D-334, **D-364–D-367** → this SPEC).
