# Software architecture — Merge Authority (M) & integration

This file maps the verified **Merge Authority** component
(`../03-system-architecture/system-architecture.md` §1 M; HR-1, HR-2, HR-5;
§5 path arithmetic) onto concrete Elixir/OTP. It is the spine file
`supervision-tree.md` defers to for everything inside the
`Tau.Factory.MergeAuthority` box (tree line 76). M is the **crux**: it is where
INV-1, INV-2, INV-3, INV-4 are *finally enforced*, and where the verifiers
(`../05-verification/synthesis.md`) found the two hardest holes — the merge
TOCTOU (HR-1) and verdict **value**-staleness (HR-2, the authority-split FATAL).

Cross-refs: gate halves and the Toolchain behaviour live in the planned
`gate-and-toolchain.md`; the Coordinator FSM and escalation routing in
`control-plane.md`; the Ledger (L) verdict store in `durable-spine.md`.

---

## 1. Why a single `gen_statem` **is** INV-3 — and why the build runs *off* its mailbox

INV-3 (`□ |{d : merging(d)}| ≤ 1`) is enforced by **construction**, not by lock
discipline: M is a single process, so the act that *commits* a merge — the
ref-update push — is serialized by the runtime against every other commit. There
is no mutex to acquire, no lease to renew, no lock to leak on crash.

**The critical correction (final-validation H-1).** The serialized thing is the
**commit**, NOT the multi-minute build. The per-integration cost `T_int = T_gate
+ T_health` is *minutes* (§5 arithmetic). Running it inside a `handle_call` would
block M's mailbox for `T_int` — relocating the very saturation HR-5 exists to
defeat *into the merge process itself*, and tripping the default 5 s
`GenServer.call` timeout in every waiting `U`. So M is a **`gen_statem`** that
runs the build **off its mailbox** in a monitored `Task`, and serializes only the
short commit:

```elixir
defmodule Tau.Factory.MergeAuthority do
  @behaviour :gen_statem            # states: :idle | :integrating | :committing
  # Sole writer of origin/main (INV-11 contribution; INV-20 gate).
  # INV-3 holds because (a) at most ONE :integrating train exists at a time, and
  # (b) the CAS push happens in the single M process — commits are serialized.
end
```

- **`:idle`** — accepts `request_merge` submissions (non-blocking; see below),
  assembles the next train, and on a non-empty green set transitions to
  `:integrating`. It also handles verdict-revocation notifications while idle.
- **`:integrating`** — spawns a **monitored `Task`** that runs the slow,
  side-effecting work *off the mailbox*: `rebase_train` → `gate_batch_tip` →
  `health_check` (the `T_int` activities). M stays **responsive**: it keeps
  accepting submissions into the *next* train and records revocations; it simply
  starts no *second* integration (INV-3) and times the state with a
  `:state_timeout` watchdog so a wedged build cannot hang M forever.
- **`:committing`** — entered on the Task's `:ok`. A **short** critical section:
  re-read the latest verdict for every train member (catching any revoke that
  landed *during* the build — final-validation H-3) and `cas_push` with
  `expected_old_oid` (HR-1). Milliseconds, not minutes. Then back to `:idle`.

```
:idle ──assemble──▶ :integrating ──Task :ok──▶ :committing ──push ok──▶ :idle
   ▲                    │  │                         │
   │   request_merge ───┘  │ Task {:red,_}/:DOWN     │ stale_ref / revoked
   │   (queued, async)     ▼                         ▼
   └───────────────── bisect/eject ◀────────── requeue / eject ──────────┘
```

**`request_merge` is non-blocking (final-validation H-1b).** `U` does **not**
issue a synchronous `GenServer.call` that would block for `T_int`. It *submits*
(the call returns `:queued` immediately) and learns the outcome via a monitored
ref / a `pr:#{id}` PubSub event (`control-plane.md`). The reply that matters
(`:merged` / `:rejected`) arrives asynchronously; no control-path call is held
open across a build.

**Error-kernel placement.** M sits high in the `rest_for_one` spine
(`supervision-tree.md`), beside `Repo`, `Ledger`, `Budget.Owner`: precious
authority, simple logic, restartable. Its *state* is small and reconstructable
(the live train + wait-queue derive from L on `init/1`); its *risk* — the git
subprocesses and the build — is pushed into the monitored Task whose crash is a
`:DOWN` M handles (eject/requeue), never a fault that takes M down.

**Deterministic FSM / nondeterministic activity split (the Temporal split).**
This is a *conceptual* decision/effect split **and** a *concurrency* split: the
`gen_statem` transitions are the deterministic decisions (assemble, commit-or-
reject); `git fetch`/`rebase`/`gate`/`health`/`push` are nondeterministic
**activities** run in the Task (or, for the push, the short `:committing`
section). The FSM decides *whether* to merge; the activities perform the effects
and report back. Serialization lives in the commit, not in a blocked mailbox.

---

## 2. The merge CAS — HR-1 (freshness TOCTOU) + HR-2 (verdict value-staleness)

A merge is **one compare-and-swap inside one `handle_call` critical section**.
Because M is concurrency-1, the critical section is free — no other merge can
interleave. The CAS has two halves that close the two holes the verifiers found,
plus the atomic apply:

### 2a. Read the LATEST verdict (HR-2 — value-staleness)

Verdicts in L are **append-only and immutable per `(hash, run)`**
(`invariants.md` INV-9; HR-2). A challenge or a late masking / incomplete-fix
finding does **not** mutate the green verdict — the Gate **appends a superseding
revocation**. The merge precondition reads the *latest* status for `hash(d)`,
**inside** the CAS, so a flip PASS→FAIL on the same hash is caught. This is the
authority-split FATAL (`../05-verification/synthesis.md`: "a verdict flips
PASS→FAIL on the same hash; hash-keying closes content but not value staleness").
Hash-keying alone is insufficient — the *latest-wins* append-only read is the fix.

```elixir
# Inside handle_call, deterministic — a pure read of durable L state.
case Tau.Factory.Ledger.verdict_status(hash) do
  {:pass, run} -> {:cont, run}        # live lease
  {:revoked, _} -> {:halt, :verdict_revoked}   # superseded ⇒ do NOT merge
  :none -> {:halt, :no_verdict}
end
```

Equivalent framing (HR-2): the gate issues a **revocable merge lease** on green;
any later finding revokes it; merge requires a *live* lease. The CAS reads the
lease at the merge instant, not at gate time.

### 2b. Apply via atomic conditional ref-update (HR-1 — the ref TOCTOU)

The origin/main TOCTOU is closed by the **VCS primitive, not by timing**. A naïve
"read `head(origin/main)`, compare, then push" has a window: the ref can move
between the read and the push. `git push --force-with-lease=<ref>:<expected-oid>`
performs the compare-and-set **atomically on the remote**: the push is rejected
unless `origin/main` is *still* at `expected-oid`. There is no window to lose.

```sh
# The CAS apply, run as a side-effecting ACTIVITY (the nondeterministic side):
git push --force-with-lease=refs/heads/main:"$EXPECTED_OLD_OID" \
         origin "$BATCH_TIP":refs/heads/main
#   success  → ref advanced atomically; INV-2 (fresh) held by the primitive.
#   rejected → ref moved since gate (someone/something advanced main); see 2c.
```

`EXPECTED_OLD_OID` is `base(d)` — the `origin/main` head the gate ran against.
The push is the *only* writer of `origin/main` (§3), so the only way the lease
fails is a freshness violation, which the primitive rejects. INV-2
(`merge(d) → fresh(d)`) is enforced by the ref-update semantics, not by an M-side
timing comparison.

### 2c. On lease/CAS rejection → do NOT merge; rebase into the next train

A rejected lease means `origin/main` advanced. M **does not retry the push**, does
not force past it — it rejects the merge, emits `merge_rejected(unit, :stale_ref)`,
and the unit re-enters the **next merge-train** (§4) to rebase onto the new head
and re-gate the train tip. No stale diff ever lands.

### The two failure interleavings, closed (FC-3, FC-4)

From `system-architecture.md` §4:

**FC-3 — origin/main advances during a gate.** Gate ran against base `B₀`; while
gating, `origin/main` moved to `B₁`. At CAS-apply time the lease
`--force-with-lease=…:B₀` is rejected (remote is at `B₁`). → reject, rebase into
next train, re-gate the tip. **INV-2 held by the primitive.** No stale merge.

```
t0  gate(d) runs against head=B0
t1  origin/main advances B0 → B1   (e.g. a prior train member merged)
t2  M CAS: push --force-with-lease=...:B0   → REJECTED (remote at B1)
t3  M: merge_rejected(:stale_ref); unit → next train, rebase onto B1, re-gate
```

**FC-4 — verdict flips PASS→FAIL after green** (challenge or late finding). The
green verdict for `hash(d)` is superseded by an appended revocation in L. At
CAS-read time (2a) M reads `:revoked` and halts — **before** any push. **INV-1
holds despite value-staleness.** The authority-split FATAL is closed.

```
t0  gate(d) appends verdict (hash, run, PASS)        → L
t1  late incomplete-fix finding ⇒ gate appends (hash, run, REVOKE)  → L (latest)
t2  M CAS read: verdict_status(hash) = {:revoked,…}  → halt, no push
t3  M: merge_rejected(:verdict_revoked); unit re-gates
```

Both holes are closed by *append-only durable reads* (HR-2) and a *VCS atomic
primitive* (HR-1) — neither by M-side timing, which is exactly why concurrency-1
plus these two mechanisms is sufficient.

---

## 3. Sole writer of origin/main

M is the **only** process that pushes `origin/main`. This is not a convenience —
it is **required for INV-2**. The freshness CAS (2b) compares against the
`origin/main` head the gate observed. If a *second* writer (an operator script, a
self-host bootstrap path, a stray worker) could also advance `origin/main`, then:

- M's `expected-old-oid` would be a **stale projection** of the true ref state,
  and the lease check would be racing a writer M cannot see — reintroducing the
  TOCTOU at a layer the primitive cannot close. This is the **authority-split
  second hole**: freshness checks a stale projection of the ref when authority
  over the ref is split.

Therefore every other push path is **structurally forbidden** and routes through M
or trips escalation:

```elixir
# Any non-M push attempt is a destructive/irreversible action on shared state.
# Classified at the action boundary (INV-20) ⇒ E-DESTRUCTIVE, never auto-executed.
def classify_main_write(actor) when actor != :merge_authority,
  do: {:escalate, :"E-DESTRUCTIVE"}   # control-plane.md routes to K
```

- Operator-initiated history rewrites, force-pushes, releases → E-DESTRUCTIVE
  (INV-20; `liveness.md` E-table), surfaced to the human, never autonomous.
- The self-host bootstrap (the factory building itself) pushes **through M** like
  any other unit — it is not privileged. A bootstrap that bypassed M would be the
  one writer M cannot see, breaking INV-2 for *every* concurrent unit.

Sole-writer + the CAS together give: INV-1 (gate-before-merge, M is the
unskippable precondition holder), INV-2 (freshness, primitive-enforced against a
ref only M moves), INV-3 (serialized, concurrency-1).

---

## 4. The merge-train / batch integration (HR-5) — the throughput fix

### The instability single-PR serial merge causes

`system-architecture.md` §5 and the rate-split verifier: the naïve cap
`W* = T_unit / T_merge` is an **upper bound, not a stable point**. `T_unit` is
**endogenous in `W`** via the re-gate feedback loop — every serial single-PR
merge advances `origin/main`, re-staling the other `W−1` in-flight branches, each
of which must re-gate. Gate-stage utilization

```
ρ_g = (W − 1) / W  →  1   as W grows
```

drives the gate to saturation; effective merge rate *falls* as `W` rises. The
serial-merge-per-PR design is **unstable** at the concurrency the fleet is built
to exploit.

### The train breaks the loop

Instead of merging one PR and re-staling `W−1` peers, M **assembles a batch `B`
of green units**, rebases them **as a train**, runs **ONE** combined gate + health
cycle on the **batch tip** — *off the mailbox, in a monitored Task* (§1, H-1) —
then integrates the batch atomically in a short commit section:

```elixir
# :idle → :integrating — spawn the slow work OFF the mailbox; M stays responsive.
def handle_event(:internal, :assemble, :idle, data) do
  case assemble_train(data) do
    {:ok, units} ->
      base = current_main_head()                       # the expected_old_oid for the CAS
      task = Task.Supervisor.async_nolink(MergeTasks, fn ->
        with {:ok, tip} <- rebase_train(units, base),  # activity: rebase as a train
             {:ok, _}   <- gate_batch_tip(tip),        # ONE combined gate on the tip
             :green     <- health_check(tip)           # ONE health cycle (§5)
          do {:built, units, base, tip} else err -> {:build_failed, units, err} end
      end)
      {:next_state, :integrating, %{data | task: task, units: units, base: base}}
    :empty -> {:keep_state, data}                      # nothing green; stay idle
  end
end

# :integrating → :committing — Task returned; enter the SHORT critical section.
def handle_event(:info, {ref, {:built, units, base, tip}}, :integrating, %{task: %{ref: ref}} = d) do
  # RE-VALIDATE ON RETURN (H-2/H-3): a revoke may have landed DURING the build.
  case assert_all_verdicts_live(units) do                 # HR-2: re-read latest, now
    :all_pass ->
      case cas_push(tip, base) do                          # HR-1: atomic ref-update
        {:ok, head}     -> {:next_state, :idle, commit(d, units, head)}
        {:error, :stale_ref} -> {:next_state, :idle, requeue_all(d, units)}
      end
    {:revoked, u} -> {:next_state, :idle, eject_and_retry(d, u, units)}
  end
end

# Task crash / red health → eject the culprit, no commit.
def handle_event(:info, {ref, {:build_failed, units, {:health_red, _}}}, :integrating, %{task: %{ref: ref}} = d),
  do: {:next_state, :idle, bisect_and_eject(d, units)}     # §below
def handle_event(:info, {:DOWN, ref, :process, _, reason}, :integrating, %{task: %{ref: ref}} = d),
  do: {:next_state, :idle, requeue_all(d, d.units)}        # build process died → retry
# plus a :state_timeout on :integrating: a wedged build cannot hang M forever.
```

The build runs in `MergeTasks` (a `Task.Supervisor`), so M's mailbox is free the
whole time `T_int` elapses — accepting `request_merge` submissions for the *next*
train and recording revocations — while still integrating **one** train at a time
(INV-3). The **commit section re-reads verdicts** (`assert_all_verdicts_live`)
*after* the build, closing the window where a revoke lands mid-build (H-3): the
verdict read and the `cas_push` are adjacent, both post-build.

This makes the re-stale cost **O(1) per batch** instead of O(W) per unit: the
freshness re-check and re-gate are **amortized across the whole batch**. The
`(W−1):1` amplification term is amortized away. The batch tip is gated as **one
diff**, so INV-1..3 are preserved over the batch (one verdict, one CAS, one
serialized integration).

### Batch-health failure → bisect, eject, re-integrate

If the combined health check on the batch tip is **red**, M does not know *which*
member broke it. It **bisects** the train (standard `git bisect`-style halving
over the train members) to find the culprit, **ejects** it (→ that unit's U
refines, `system-architecture.md` U-FSM), and **re-integrates the rest** as a
smaller train. A single bad unit costs `O(log B)` health runs, not a failed batch.

```
train [u1 u2 u3 u4]  health(tip) = RED
  bisect → culprit = u3
  eject u3 → U(u3) refines
  re-integrate [u1 u2 u4] → health OK → CAS push
```

### The arithmetic and sizing rule (Q-1 binding)

Per-integration cost `T_int ≈ T_gate + T_health`. Train throughput is
`B / T_int`, replacing `1 / T_merge` degraded by the `(W−1):1` amplification.
Stability becomes:

```
arrival_rate  ≤  B / T_int          (stable; B amortizes the re-gate term)
W_cap  derived from  ρ_g < 1 − margin,  with  T_unit(W)  modeled ENDOGENOUSLY
B      sized to the steady-state count of simultaneously-green units
```

Both `W_cap` and `B` depend on the **measured** `T_unit / T_int` ratio on the
**bootstrap (self-hosting Elixir) toolchain** (Q-1 / Q-2,
`../05-verification/synthesis.md`; `system-architecture.md` §5). **Measure before
sizing.** Until measured, operate **conservatively**: small `W_cap`, `B ≥ 2`
(never `B = 1`, which is the unstable single-PR regime). Guessing `T_int` high
causes re-gate storms and merge starvation; guessing low wastes capacity — so
instrument `T_int` from day one (§7 telemetry feeds the model directly).

The serialized integration stage (M) is the **intended bottleneck** — it is the
only place INV-1..4 can be enforced — and its service time is toolchain-bound
(`T_int`). Toolchain build/test speed is therefore the **highest-leverage
throughput lever in the whole factory** (rate-split finding). Back-pressure on a
full train is routed to the **running fleet** (pause/slow in-flight implementers
via the Scheduler), not only to admission (HR-5).

---

## 5. Post-integration health check (INV-4) via the Toolchain behaviour

After the train tip is assembled, M runs **ONE** combined health check on the
batch tip **pre-push** (so a red tip never lands), **inside the `:integrating`
Task — off M's mailbox** (§1, H-1), **language-agnostically** through the
`Tau.Factory.Toolchain` behaviour (HR-3; `gate-and-toolchain.md`). Its `:green`/
`:red` result is what the Task reports back; the commit section then re-validates
verdicts and pushes (§4). The judgement is the engine's, not the adapter's:

```elixir
# Toolchain returns a DECLARATIVE recipe + structured report format (HR-3);
# the engine (here M's health activity) executes and JUDGES the artifact itself.
{:ok, recipe}  = Tau.Factory.Toolchain.health_recipe(lang)   # adapter: data only
{:ok, report}  = run_in_isolated_workspace(recipe, tip)       # engine executes
case Tau.Factory.Toolchain.judge_health(report) do            # engine judges
  :green -> :ok
  :red   -> {:health_red, report}   # ⇒ E-RED-MAIN, halt the loop (§ below)
end
```

For the bootstrap toolchain this is `mix compile --warnings-as-errors` +
`mix test`. The adapter supplies the *recipe*; the *judgement* is the engine's —
a buggy/adversarial adapter cannot fake green (HR-3, FC-5).

**Red ⇒ E-RED-MAIN, halt, no further merge while red (INV-4).** A red health
verdict is M state. It:

1. gates the merge precondition **closed** (`□ red(main) → ¬∃ d. merge(d)`),
2. raises **E-RED-MAIN** to the Coordinator K (global escalation,
   `liveness.md` E-table; `control-plane.md` routes it),
3. leaves `main` **red and named** — the loop halts, the failing check is
   surfaced to the operator; no further merge occurs until a human decides
   revert-vs-fix-forward.

Because the health check is pre-push in this design, a red tip is *ejected before
landing* (bisect, §4); E-RED-MAIN is reserved for the case where `main` itself is
found red on a post-merge re-check (e.g. an accumulation a stateless per-PR gate
cannot catch — the standing backstop, `factory-loop.md` cycle step 8d).

**Dogfood note (P5c-7, M10 — recording, not redesigning).** The
`mix tau.factory.dogfood` capstone (`control-plane.md` §7; SPEC-FACTORY-CORE
§4 B11 / AC-12) drives this **real** health path: `Merge.Health.check` runs the
Elixir toolchain (`mix compile --warnings-as-errors` + `mix test`) on the
integrated tip in the **local bare-repo sandbox**, and its `:green` result is an
AC-12 observable. The CAS push (§2b, `--force-with-lease`) advances the sandbox's
**local** `origin/main` only — the dogfood harness hard-refuses a non-local
origin before booting (D-359), so M's sole-writer force-push (§3) is
blast-radius-confined to a throwaway local repo. No change to M's contract: the
dogfood is the production merge path pointed at a sandbox remote.

---

## 6. Fair queue (LIV-2, Q-L1) — FIFO + aging

INV-3 serializes merges; **LIV-2** demands no green+fresh branch starves behind a
stream of others (`green(d) ∧ fresh(d) ↝ ◇ merge(d)`). M holds a **wait-queue**
of merge-ready units and serves them under a **fair policy**.

**Recommendation: FIFO + aging — and aging is required, not optional.** The
reason is the re-gate feedback loop itself: every merge advances `origin/main`,
forcing every *other* waiting branch to re-rebase and re-gate (Q-L1). A **large**
branch (big diff, slow gate) loses every freshness race to a stream of **small**
fast branches — each small merge re-stales the large one before it can complete
its own gate. Pure FIFO does not prevent this (the large branch keeps getting
bumped to the back of *gating*, not the queue); **aging** does: a unit's
effective priority rises with the number of times it has been re-staled, so after
bounded re-stales it is admitted to the train **ahead** of newcomers and allowed
to complete.

```elixir
# priority = base_fifo_seq − age_bonus(restale_count)
# a unit re-staled k times jumps ahead, bounding its starvation window.
defp effective_priority(%{seq: seq, restale_count: k}),
  do: seq - aging_weight() * k
```

The merge-train (§4) compounds the benefit: batching a re-staled large branch
**with** the small ones into one train means they merge **together** rather than
the large one chasing a moving target — train assembly is itself an anti-starvation
mechanism. Aging is the backstop for the pathological case the train alone does
not cover (a branch too large to co-train with the current green set).

Justification for the added complexity: without aging, LIV-2 is **falsifiable**
under exactly the workload the fleet is built to produce (many small concurrent
PRs); the cost is one integer per queued unit and a monotone priority function.
The complexity is bounded; the starvation it prevents is not.

---

## 7. Telemetry (NFR-OBS)

Every user-visible / perf-sensitive M action emits paired `[:tau, :factory,
:merge, …]` spans (`*.start` paired with `*.stop` / `*.exception`,
`otp-non-negotiables.md` §5). These spans also **feed the `T_int` model** the §4
sizing rule depends on — measurement is not optional instrumentation, it is the
binding input to `W_cap` and `B`.

| Span | Measurements / metadata | Feeds |
|------|-------------------------|-------|
| `[:tau, :factory, :merge, :attempt]` | `unit_id`, `hash`, `batch_size`, `expected_old_oid` | request rate |
| `[:tau, :factory, :merge, :cas]` | `:ok`/`:stale_ref`/`:verdict_revoked`, `duration_ms` | CAS reject rate (freshness pressure) |
| `[:tau, :factory, :merge, :commit]` | `batch_size`, `new_head`, `duration_ms` | merge throughput `B / T_int` |
| `[:tau, :factory, :merge, :reject]` | `reason`, `unit_id` | re-stale / revoke diagnostics |
| `[:tau, :factory, :merge, :health]` | `:green`/`:red`, `duration_ms` (= `T_health`) | `T_int`, E-RED-MAIN rate |
| `[:tau, :factory, :merge, :bisect]` | `culprit_unit`, `steps` (= `O(log B)`) | batch-failure cost (Q-2) |
| `[:tau, :factory, :merge, :queue]` | `depth`, `max_restale_count`, `max_wait_ms` | LIV-2 starvation watch (§6) |

`max_restale_count` and `max_wait_ms` are the **live falsification test** for
LIV-2: an unbounded climb is starvation surfacing, and triggers an aging-weight
review.

---

## 8. Distribution note (D-S4) — M stays single-node

M is the **consistency-critical point** and stays **single-node**, by ruling
(`supervision-tree.md` §6; `system-architecture.md` §6 / §7). Clustering M would
import **split-brain** into the one place that cannot tolerate it: two M instances
on a partitioned cluster could each believe they hold the merge lease and each
`--force-with-lease` against a ref the other has moved, defeating INV-2/INV-3 at
the layer below the VCS primitive (the primitive serializes *pushes*, not
*deciders*). **D-S4:** the merge serialization point is exactly the boundary that
must *not* be replicated.

Only agent **execution** scales horizontally (later, via an explicit Oban queue —
idempotent, ref-correlated workers that *pull* work). M, L, S, K — the control
plane — stay single-node. Moving execution off-node is configuration plus a
queue, never a rearchitecture of M. Location-transparency discipline holds now
(Registry keys, PubSub events, no `:global`, no cross-node ETS) so the boundary
is honest, but M itself never crosses it.

---

## Invariant → mechanism map (this file)

| Invariant | Mechanism in M |
|-----------|----------------|
| INV-1 gate-before-merge | CAS reads a **live** verdict lease before any push (2a) |
| INV-2 freshness | `--force-with-lease=<ref>:<expected-oid>` atomic ref-update (2b); sole-writer (3) |
| INV-3 serialized merge | single `gen_statem`: one `:integrating` train at a time + the commit push serialized in M; build runs off-mailbox in a Task (1) |
| INV-4 main health | pre-push health on the batch tip; red ⇒ E-RED-MAIN, merge gated closed (5) |
| INV-20 no unilateral destruction | every non-M `origin/main` write ⇒ E-DESTRUCTIVE (3) |
| LIV-2 merge progress | fair wait-queue, FIFO + aging; train co-batches re-staled branches (6) |
| HR-1 ref TOCTOU | closed by the VCS primitive, not M-side timing (2b) |
| HR-2 value-staleness | append-only latest-verdict read inside the CAS (2a, FC-4) |
| HR-5 throughput stability | merge-train amortizes re-gate to O(1)/batch; `ρ_g < 1` (4) |
| D-S4 | M single-node; clustering = split-brain (8) |
