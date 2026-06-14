# Software architecture — the worker fleet (W)

This file details component **W** (`../03-system-architecture/system-architecture.md`
§1) in concrete Elixir/OTP, atop the spine fixed in `supervision-tree.md`. W is
the **horizontally-scalable execution tier**: one supervised process per worker
(implementer, test-author, critic, reviewer, researcher), each owning a *complete*
isolation boundary. Its job is to make the seven observed worktree failure modes
(`../01-research/tau-current-analysis.md` §3, F-1..F-7 — each tagged "this has
happened") **structurally unreachable**, by converting every prose `MUST` of
`worktree-discipline.md` into a process/OS boundary or a supervised lifecycle.

The governing invariants are INV-10..INV-12, INV-14, INV-15, INV-17 and CON-5
(`../02-requirements/invariants.md`, `conservation.md`); the functional surface is
FR-3.1, FR-3.2, FR-8.1, FR-8.2 (`R-list.md`). W is the **sole enforcer** of
INV-10 (resource isolation), INV-11 (no shared tree), INV-12 (verified position),
INV-14 (capture-before-destroy) and INV-15 (reclaim), per the enforcement matrix.

Cross-refs: `supervision-tree.md` (the tree + identity split), `gate-and-toolchain.md`
(the Toolchain adapter's **resource-namespace declaration** that makes isolation
total and polyglot; the masking gate that keys on the frozen gating-test path set),
`control-plane.md` (the Unit FSM `U` that decides worker outcomes), `governance.md`
(per-role model/budget policy pinned at spawn).

---

## 1. W — `WorkerSupervisor` (`DynamicSupervisor`) + `WorkerRegistry`

```
Tau.Factory.WorkerSupervisor   [DynamicSupervisor, one_for_one, :temporary]
└── (0..W_cap)  Tau.Factory.Worker   -- one per live worker, keyed in WorkerRegistry
```

- **One supervised process per worker.** A worker is a `Tau.Factory.Worker`
  GenServer started under the `DynamicSupervisor` and addressed by **logical key**
  via `{:via, Registry, {WorkerRegistry, worker_id}}` — never by pid (a stored pid
  is a dangling pointer after restart; `supervision-tree.md` §4). The owning Unit
  FSM holds `worker_id`, not a pid.
- **`restart: :temporary` — death-certificate, not resurrector.** A worker crash
  is an **outcome the owning Unit FSM (`U`) decides** via the durable solution
  tree (FR-8.2), *not* an auto-restart. The `DynamicSupervisor` issues the death
  certificate (the `worker_exit` it surfaces); it never silently re-spawns a
  crashed implementer onto a fresh worktree mid-flight. This is the decisive split
  the whole design rests on: **supervision recovers *infrastructure*; the FSM +
  solution tree recover *semantics*** (`supervision-tree.md` step 3). A gate FAIL
  or bad LLM output is a *semantic* outcome (handled by `U`'s retry ladder), never
  a crash to restart — the dominant BEAM-for-agents mistake (FR-8.2).
- **Roles are data, behaviour is one module.** `role ∈ {:implementer,
  :test_author, :critic, :reviewer, :researcher}` is a field, not a subclass
  (OTP non-negotiable 2 — pattern-match on atoms, no string-keyed dispatch). The
  role selects the brief, the per-role model/budget (policy, `governance.md`), and
  the *write-scope* (e.g. the implementer's worktree makes the frozen gating-test
  paths read-only/scanned — §5).

`child_spec` (per-worker, temporary):

```elixir
defmodule Tau.Factory.Worker do
  use GenServer, restart: :temporary   # crash = outcome, not auto-restart

  def start_link(%{worker_id: id} = spec) do
    GenServer.start_link(__MODULE__, spec,
      name: {:via, Registry, {Tau.Factory.WorkerRegistry, id}})
  end
end
```

---

## 2. The complete isolation boundary (INV-10) — the heart

Per worker, `init/1` **allocates AND owns** the full boundary. Ownership is by
**link**: every resource is created by the worker process and reclaimed when that
process dies (INV-15), so reclaim is automatic — *not* a checklist an agent must
remember (the failure mode of `worktree-discipline.md`). Two layers:

### (a) Private git checkout — closes F-1, F-2, F-6

A **private worktree** forked from a *system-established* ref (the Unit's pinned
base, itself derived from fresh `origin/main`; `control-plane.md`), never from the
spawning agent's branch and never the parent root.

- **INV-11 (no shared mutable tree).** The coordinator holds **no** mutable
  working tree a worker can reach; every checkout is a worker-private fork. No
  worker can move another's HEAD or the parent's HEAD. **F-1 (parent-HEAD drift)
  and F-2 (reviewer collisions) become unreachable** — there is no shared tree to
  collide on, and isolation is a property of `init/1`, not an opt-in `isolation:
  worktree` flag an agent might omit.
- **INV-12 (verified position).** Position is **mechanism, never a trusted brief
  assertion** (`worktree-discipline.md` "spawn-brief integrity"). The system sets
  the position; the worker's **first action verifies it and aborts** if it finds
  itself in the parent root or off the expected ref. **F-6 (spawn-brief integrity)
  becomes unreachable** — the worker never proceeds on an asserted position.

```elixir
def init(%{worker_id: id, base_ref: ref, toolchain: tc} = spec) do
  Process.flag(:trap_exit, false)               # crashes propagate; capture is a *monitor*, not terminate/2 (§3)
  ws = Path.join(workdir(), "w-#{id}")

  :ok = Toolchain.checkout(tc, base_ref, ws)    # engine executes the adapter's recipe (HR-3); private worktree at `ws`

  # INV-12 — verify, never trust the brief. Mechanism, not message.
  with {:ok, ^ws}  <- verify_pwd(ws),
       {:ok, ^ref} <- verify_head(ws, ref),
       false       <- in_parent_root?(ws) do
    ns = allocate_resource_namespace(ws, Toolchain.resource_namespace(tc))   # (b)
    {:ok, %State{id: id, ws: ws, ns: ns, toolchain: tc, role: spec.role}}
  else
    _ -> {:stop, {:position_unverified, ws, ref}}   # abort rather than work on the wrong tree
  end
end
```

### (b) Per-worker namespace for every mutable resource outside the checkout — closes F-5

**Worktree isolation isolates git refs ONLY; everything else leaks through it.**
The Burrito unpack cache at `~/.local/share/.burrito/<ver>/`, `~/.cache/zig/`,
`~/.mix/`, Hex-mirror and GitHub-release download caches all live in the spawning
user's `$HOME`, *survive* the worktree boundary, and race under concurrency — the
documented `XZ/LZMA Decode Failed` corruption (`worktree-discipline.md`,
"Shared $HOME-namespace caches").

The worker allocates a per-worker namespace for **every** such path. The set is
**not hardcoded** — it is the **Toolchain adapter's resource-namespace
declaration** (`gate-and-toolchain.md`; D-S2), which is what makes the isolation
**total and polyglot**: each language adapter declares the mutable paths *its*
build/test touches, and the engine namespaces each into the worktree:

```elixir
# Toolchain.resource_namespace(tc) → declarative list (data, not verdict — HR-3):
[{:env, "XDG_DATA_HOME", :rel,  ".xdg"},        # Burrito's documented race fix
 {:env, "XDG_CACHE_HOME", :rel, ".cache"},
 {:env, "MIX_HOME",       :rel, ".mix"},        # ~/.mix → per-worker
 {:env, "HEX_HOME",       :rel, ".hex"},        # Hex-mirror downloads → per-worker
 {:env, "ZIG_GLOBAL_CACHE_DIR", :rel, ".zig"}]  # content-addressable, but isolate anyway

defp allocate_resource_namespace(ws, decls) do
  for {:env, var, :rel, sub} <- decls, into: %{} do
    dir = Path.join(ws, sub); File.mkdir_p!(dir); {var, dir}   # lives *inside* the worktree → reclaimed with it
  end
end
```

Every `Port` the worker opens (build/test/agent — §4) is launched with
`env: state.ns`, so the subprocess inherits the per-worker namespace. Because the
namespace dirs live **inside** the worktree, reclaiming the worktree reclaims them
(INV-15) — no separate cleanup path to leak. **F-5 ($HOME-cache races) becomes
unreachable**: no two concurrent workers share any declared mutable path. This is
**MANDATORY under concurrency** (§7) — the Burrito XDG race is the canonical proof.

---

## 3. Capture-before-destroy (INV-14, CON-5) — an independent MONITOR, not `terminate/2`

`terminate/2` **does not run on `:kill` or on an owner/linked crash** (OTP: a
brutal-kill exit, a supervisor `:shutdown` to a non-trapping child, or a crash
while the scheduler can't deliver, all skip `terminate/2`). Relying on it to
capture uncommitted work would silently lose exactly the work a *killed* worker
holds — the most common end-state (`worktree-discipline.md` "capture-before-
destroy"; supervision-tree anti-pattern 11). So capture is the responsibility of
an **independent monitoring process**, not the dying worker.

A small **`Tau.Factory.WorkspaceJanitor`** (a GenServer high in the W subtree)
`Process.monitor/1`s every worker at spawn and catches its `:DOWN`. On `:DOWN` it
captures **all three dirty kinds before reclaim** — and the easily-missed one is
**untracked**, caught by *no* `git diff`:

```elixir
def handle_info({:DOWN, _ref, :process, _pid, _reason}, st) do
  %{ws: ws, id: id, ns: ns} = lookup_worker_meta(st, _pid)

  # 1. staged + unstaged  (git diff HEAD catches both)
  patch = sh!(ws, ["git", "diff", "HEAD"])
  # 2. UNTRACKED — caught by NO git diff; the one that silently vanishes
  untracked = sh!(ws, ["git", "ls-files", "--others", "--exclude-standard"])
  if untracked != "", do: sh!(ws, ["tar", "-czf", wip_tgz(id), "-T", "-"], stdin: untracked)
  status = sh!(ws, ["git", "status", "--short"])

  Ledger.capture(id, %{patch: patch, untracked_tgz: wip_tgz(id), status: status})  # → durable log (CON-5)
  reclaim(ws, ns)                                # 3. INV-15 — worktree + namespace gone
  {:noreply, drop_worker(st, _pid)}
end
```

- **All three kinds, or it is not capture.** Staged + unstaged via `git diff HEAD`;
  **untracked** via `ls-files --others --exclude-standard | tar` (a naïve
  `git diff` omits both staged *and* untracked — the documented trap). CON-5's
  balance `dirty(w) = committed ⊎ captured ⊎ discarded_by_decision` holds: nothing
  vanishes by omission.
- **Stream to a durable log so little is volatile.** Ideally the worker streams its
  agent's structured output and commits incrementally to the Ledger continuously
  (FR-6.3: persist *decisions and outcomes*), so the `:DOWN` capture is a thin
  backstop over a near-empty volatile tree rather than the sole rescue.
- **Then reclaim (INV-15) — closes F-3.** The monitor removes the worktree **and**
  the resource namespace in the same handler. **F-3 (leaked-locked worktrees — "the
  symptom that hides every other failure mode") becomes unreachable**: reclaim is a
  guaranteed monitor callback on *every* exit path including `:kill`, not a turn an
  agent must remember. **F-7 (stale-parent recovery procedure) likewise vanishes**
  — there is no leaked state to recover, so the multi-step recovery checklist that
  was itself evidence of weak isolation is unreachable.

Why a monitor and not a link-with-`trap_exit`: a monitoring process is *outside*
the worker's crash domain (INV-17), so a worker crash cannot take the janitor with
it, and `:DOWN` fires for `:kill` and `:shutdown` alike — the cases `terminate/2`
misses.

---

## 4. Agent processes — supervised `Port`, structured I/O (FR-3.2, GAP-4)

The LLM/coding sub-agent is driven via a **supervised `Port`** with **typed event
I/O**, never stdout screen-scraping (OTP non-negotiable: no shell-output scraping;
tools return structured `details`). The agent's lifecycle is **owned by the BEAM**:
the `Port` is opened by — and linked into — the worker process, so the agent's
crash domain is the worker's crash domain (INV-17).

```elixir
port = Port.open({:spawn_executable, agent_bin},
  [:binary, {:packet, 4}, :exit_status,    # length-framed packets → structured events, not line-scraping
   {:env, env_namespace(state.ns)},         # §2(b): enforced per-worker namespace on the sub-agent too
   {:cd, state.ws}])
# Inbound frames decode to typed events — extend Tau.Provider.Event, never an ad-hoc format:
def handle_info({port, {:data, frame}}, st), do: dispatch(decode_event(frame), st)
def handle_info({port, {:exit_status, n}}, st), do: handle_agent_exit(n, st)

# D-326: a normal completion is an ASSERTED in-band event, not exit status.
# The agent emits a typed work-product-ready frame BEFORE exiting; on decoding
# it the worker forwards work_ready(worker_id, branch, head_sha) to its Unit.
defp dispatch(%WorkReady{branch: b, head: h}, st) do
  send(st.report_to, {:work_ready, st.worker_id, b, h})   # the U `implementing → gating` trigger
  {:noreply, %{st | work_ready_seen?: true}}
end
# An exit 0 with NO prior work_ready is a no-op, surfaced as a death cert, NOT success:
defp handle_agent_exit(0, %{work_ready_seen?: false} = st),
  do: {:stop, {:shutdown, :no_work_product}, st}          # → worker_exit(id, :no_work_product)
```

**Completion is an asserted event, not an exit code (D-326, closes ARCH-GAP
#460).** A clean Port exit (`:exit_status 0`) carries a single bit and cannot
distinguish "did the work / pushed a real diff" from "ran and pushed nothing"
from "crashed but exited 0". So the agent's *success* is signalled by an in-band
`work_ready(branch, head_sha)` frame (a struct under the same event taxonomy,
mirroring the in-band `%Tau.CodingAgent.Event.Done{}` already used by
`Tau.Session`), decoded and forwarded as `work_ready(worker_id, branch,
head_sha)` — the **sole** trigger of U's `implementing → gating` edge. The
`branch`/`head_sha` payload is the evidence U needs to confirm a non-empty diff
before gating. `work_ready` is the success counterpart of the `worker_exit`
death certificate (§6); the two are disjoint, and an `exit_status 0` without a
prior `work_ready` is surfaced as `worker_exit(worker_id, :no_work_product)`,
routed to the Unit's retry ladder, never gated. This realises today's
`handle_info({port, {:data, _}}, st)` "future: forward to Unit FSM" stub (the
conforming wiring is P5c-3).

- **Structured events, not scraping.** Inbound frames decode to typed
  `%Tau.Provider.Event{}` / agent-event structs; a tool result is structured
  `details`. No `IO`-scraping, no ad-hoc event format (OTP non-negotiables).
- **External-process contrast.** If a sub-agent *must* be an external process, it
  is still wrapped in this supervised port + the **enforced per-worker resource
  namespace** (§2b). This is the direct fix for today's `coding_agent/` subprocess
  shell-out, whose un-namespaced `$HOME` sharing **causes** the F-5 races (GAP-4):
  there, subprocesses are free-running and share `$HOME`; here, every sub-agent
  inherits `state.ns` and dies inside the worker's crash domain.

### 4a. The real coding agent as the worker's `agent_bin` — the CodingAgent shim (A1, #487)

The §4 `agent_bin` is, in production dogfooding, **not** the canned
`Tau.Factory.Dogfood.Agent` script — it is the real `Tau.CodingAgent` substrate
(`docs/spec/SPEC-CODING-AGENT.md`; `Tau.CodingAgents.ClaudeCode`). The two speak
**different execution models** — the Worker speaks a raw `{:packet,4}` Port
emitting a `work_ready` frame (this §4 / D-326); the adapter speaks an Elixir
`Enumerable.t()` of `%Tau.CodingAgent.Event{}` ending in a single, dispatcher-
guaranteed `%Event.Done{}`. The bridge between them is pinned in
**SPEC-FACTORY-FLEET §4 B4-A1 + D-364..D-367**.

The shape chosen is an **`agent_bin`-shaped CodingAgent shim** (over in-process
driving) precisely because it keeps *this* §4 contract — the linked `Port`, the
`{:env, ns}` namespace, `{:cd, ws}`, the `{:packet,4}` `work_ready` frame, and the
crash domain — **unchanged**: the bridge lives entirely inside the shim, so the
Worker is untouched and the wrong-guess cost is one deletable executable rather
than a six-invariant Worker rewrite. The shim owns the **branch+commit step** the
CodingAgent substrate does not perform (the adapter edits files but emits no
commit/branch/`head_sha`), maps `%Done{0}`-over-non-empty-diff → `work_ready`
with the **agent's real `head_sha`**, maps `%Done{0}`-over-empty-diff and
`%Done{-1}`/`%Error{}` to the D-326 no-completion paths, and derives the worker
**heartbeat from consumed stream events** rather than a self-clock (so a wedged
agent is detectable — D-366). The shim and its `claude` sub-subprocess run wholly
**inside `state.ns` + `ws`** (D-365), which is exactly the "external-process
contrast" fix above made concrete. The real-`head_sha` this produces is consumed
by **#486 (C1)** in the Unit FSM/gate/merge (cited, not implemented in A1).

---

## 5. Oracle-separation spawn ordering + identity (INV-5, HR-7)

Oracle separation is **identity, not mere ordering**. The Unit FSM (`control-plane.md`)
drives W in this fixed sequence:

1. **Spawn the `:test_author` worker first.** It writes one failing gating test per
   `AC-N`/`D-NNN` against the **user-facing entry point** (INV-8; e.g.
   `Tau.CLI.main/1` with realistic argv, not a hand-built struct), and reports the
   exact `test/...` **path set** it owns.
2. **Freeze the path set** in the Unit's durable plan-of-record *before any
   `:implementer` worker is spawned* (FR-1.3). This frozen set is the
   test/production boundary all mechanical gates key on (path-based, survives
   rebase — `gate-and-toolchain.md`).
3. **Record the authoring identity** of every worker in the solution tree (HR-7),
   and assert the **identity predicate** at gate time:

   ```
   □ ( author(test_g) ≠ author(impl) )      -- INV-5; identity, not ordering
   ```

   Same-agent authorship of an oracle and its subject is rejected even if the
   ordering looks correct.
4. **The implementer's worktree makes the frozen gating-test paths read-only /
   scanned (INV-6).** The masking gate (`gate-and-toolchain.md`) scans the
   implementer's diff against the frozen path set; any implementer write to a
   gating-test path is a protocol violation surfaced to the `critic` — even with no
   assertion deleted. The boundary is the **frozen path set, not commit
   attribution**.

---

## 6. Crash containment (INV-17)

**Per-worker process = per-worker crash domain.** One worker's crash blast-radius
is exactly `{worker}`:

```
□ ( crashes(w) → blast_radius(w) = {w} )
```

- No `try/rescue` and no `:exit`-catching crosses the worker boundary (OTP
  non-negotiable 7). A crash propagates as a clean exit signal; the `:temporary`
  supervisor issues the death certificate; the `WorkspaceJanitor` monitor captures
  and reclaims (§3); the Unit FSM observes `worker_exit` and decides the outcome
  (§1).
- The janitor monitors (does not link) workers, so it survives any worker crash.
  The agent `Port` is linked *into* its worker, so an agent crash is contained to
  that one worker — never the fleet, never the coordinator.
- A semantic failure (gate FAIL, bad output) is **not** a crash: it is an FSM
  outcome (FR-8.2). The two recovery mechanisms — supervision (infra) and the
  retry ladder (semantics) — stay distinct.

---

## 7. Shared-resource isolation under concurrency (MANDATORY)

Worktree isolation isolates git refs **only**. Every row below leaks through it and
**must** be namespaced per worker before two workers run concurrently; the
declaration source is the Toolchain adapter (`gate-and-toolchain.md`, D-S2), not a
hardcoded list:

| Resource (leaks through worktree) | Leak class | Per-worker isolation | Closes |
|---|---|---|---|
| Burrito unpack cache `~/.local/share/.burrito/<ver>/` | `$HOME` | `XDG_DATA_HOME=<ws>/.xdg` | F-5 (canonical `XZ/LZMA Decode Failed` race) |
| zig cache `~/.cache/zig/` | `$HOME` | `XDG_CACHE_HOME` / `ZIG_GLOBAL_CACHE_DIR=<ws>/.zig` | F-5 |
| `~/.mix/` build/archive cache | `$HOME` | `MIX_HOME=<ws>/.mix` | F-5 |
| Hex mirror / pkg cache | `$HOME`/network | `HEX_HOME=<ws>/.hex` | F-5 |
| GitHub release downloads | network | per-worker download dir under `<ws>` | F-5 |
| (per-language, e.g. `~/.cargo`, `~/.npm`, pip cache) | `$HOME` | adapter-declared `<ws>/.<lang>` | F-5 |

Each maps to an `{:env, VAR, :rel, sub}` declaration (§2b) whose target lives
**inside** the worktree, so a single worktree reclaim removes the worktree *and*
every namespaced cache (INV-15) with no separate cleanup path to leak.

This isolation is **non-negotiable under concurrency** — the documented Burrito
XDG race is the proof that omitting it silently corrupts builds. A worker spec for
a concurrent build that lacks the namespace declarations is a spawn error, not a
warning.

---

## 8. Distribution note (D-S4)

Workers are the **horizontally-scalable tier** (`supervision-tree.md` step 6).
The control plane (L, S, K, **M**) stays single-node for strong consistency at the
merge point; only worker *execution* scales out, later, via an **explicit Oban
queue boundary** — remote workers *pull* work, are idempotent, and are
ref-correlated.

Crucially, **the isolation boundary defined here is node-local and self-contained**:
a worker's worktree, its resource namespace, its agent `Port`, and its
`WorkspaceJanitor` monitor all live on the worker's own node. Nothing in the
isolation model reaches across nodes — no `:global`, no cross-node ETS, no shared
filesystem assumption. **Moving a worker off-node therefore needs no change to the
isolation model**: the same `init/1` allocation, the same `:DOWN`-monitor capture,
and the same per-worker namespace apply unchanged on the remote node. Distribution
is configuration plus an Oban queue, not a rearchitecture of W.

---

## 9. How F-1..F-7 become structurally unreachable (summary)

| # | Observed failure | Structural closure here | Invariant |
|---|---|---|---|
| F-1 | parent-HEAD drift | no shared mutable tree; every checkout a worker-private fork (§2a) | INV-11 |
| F-2 | reviewer collisions (missing `isolation` flag) | isolation is a property of `init/1`, not an opt-in flag (§2a) | INV-10, INV-11 |
| F-3 | leaked locked worktrees | `:DOWN`-monitor reclaim on *every* exit path incl. `:kill` (§3) | INV-15 |
| F-4 | naïve capture loses staged/untracked | all-three-kinds capture; untracked via `ls-files \| tar` (§3) | INV-14, CON-5 |
| F-5 | `$HOME`-cache races | adapter-declared per-worker namespace inside the worktree (§2b, §7) | INV-10 |
| F-6 | trusted spawn-brief position | position set by system, **verified** by worker, abort on mismatch (§2a) | INV-12 |
| F-7 | stale-parent recovery procedure | no leaked state to recover ⇒ recovery procedure unreachable (§3) | INV-15 |

Capture is a **monitor, not `terminate/2`**, because `terminate/2` does not run on
`:kill` or on a linked/owner crash — the exact deaths a killed worker dies. An
independent `WorkspaceJanitor` `Process.monitor`s each worker, catches its `:DOWN`
for every exit reason, and captures all three dirty kinds (staged + unstaged via
`git diff HEAD`, **untracked** via `ls-files --others | tar` — caught by no
`git diff`) to the durable Ledger before reclaiming the worktree and its resource
namespace. The monitor lives outside the worker's crash domain (INV-17), so a
worker crash cannot defeat its own capture.
