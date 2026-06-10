# Software architecture — the durable spine (component L)

This file details **component L** (Durable Ledger / system-of-record) and the
durability partition of `supervision-tree.md`, in concrete Elixir/OTP. It is the
error-kernel of the factory: precious state, simple logic, nearest the root. L
exists to make one property true — **`□ ( decided(x) ↝ persisted(x) ∧
survives_restart(x) )`** (INV-16), with **RPO = 0** (NFR-RPO). Everything else in
the tree can crash and be rebuilt; L is the floor the rebuild stands on.

It is authored against the topology in `supervision-tree.md` (module names
`Tau.Factory.*`, the `rest_for_one` spine, the `Ledger.Supervisor` sub-tree) and
the durability ruling in `../01-research/otp-capabilities.md` §13
(Oban-as-system-of-record + `gen_statem` live FSM hybrid; ETS-under-owner;
deterministic-orchestrator / nondeterministic-activity split). It cross-
references HR-2 (append-only immutable verdicts), HR-9 (co-located single-writer
decision store), INV-16/19/21, CON-1..7, NFR-RPO/RTO.

Convention: pure logic is functions; invariant-bearing modules are
**properties-before-examples** (`StreamData`); only a genuine runtime property
(serialized writes, ETS ownership) gets a process.

---

## 1. The deterministic-orchestrator / nondeterministic-activity split

The factory borrows Temporal's durable-execution discipline (research §13): the
control loop persists **decisions and outcomes**, never the **reasoning** that
produced them. An LLM's chain-of-thought, a critic's deliberation, a git command's
stdout are *not* in the ledger; only the resulting *fact* is. This makes the
decision log **replayable** — re-reading it reconstructs the orchestrator's state
exactly, because nothing in it depends on re-running a nondeterministic step.

The split is the partition table from `supervision-tree.md` §2, restated as a
behavioural law:

| Class | Definition | Examples | Durability | On replay |
|---|---|---|---|---|
| **Decision** | A control-plane choice the orchestrator commits and is bound by | `select_next(unit)`, `admit(unit)`, `freeze_paths(unit, set)`, `append_verdict(hash, run, PASS)`, `revoke_verdict`, `debit_budget`, `record_challenge`, `merged(batch)`, `escalate(e)`, attempt-count increment | **durable, WAL-before-ack** (INV-16) — written to L before any external effect | re-read from L; **never re-derived** |
| **Activity** | A nondeterministic side-effecting step the decision *commissions* | LLM completion, `git push`/`rebase`, `mix test`/build, `gh` API call, worktree spawn, file capture | **not durable** — retryable, idempotent; their *outcome* becomes a decision | **re-executed if owed** (Oban job), never trusted from a stale heap |

**The law (the single most important boundary, research §10):** a decision is a
durable fact the orchestrator must honour after a restart; an activity is a
retryable effect whose *result* is folded back into a decision. Restart =
re-read decisions + re-drive owed activities. This is why `:temporary` workers
are death-certificate issuers, not resurrectors (`supervision-tree.md` §3): a
crashed activity is re-commissioned by the owning FSM from the *decision* state,
not auto-restarted blindly.

Two consequences load-bearing for the rest of this file:

- **Replayability ⇒ idempotency keys.** Because an activity may be re-driven
  after a crash that occurred *between* the activity and its outcome-decision,
  every decision write carries an idempotency key (§2) so re-applying it is a
  no-op. A merge that landed just before the crash must not merge twice.
- **WAL-before-effect ⇒ RPO=0 proof obligation.** A decision is externally
  visible only *after* its WAL commit (§6). The orchestrator never acts on an
  uncommitted decision; therefore no externally-observable effect can outrun the
  ledger, and a crash loses no committed decision (NFR-RPO).

What is explicitly **not** a decision: an LLM's intermediate reasoning, a gate
half's deliberation transcript, an agent's conversation. These are derived /
ephemeral (`supervision-tree.md` §2), rebuilt or discarded on crash — losing them
*is the point* of let-it-crash. Only the verdict, the cost line item, the
challenge ruling — the *facts* — persist.

---

## 2. `Tau.Factory.Ledger.Writer` — the single durable-decision GenServer

One writer per datum, co-located (HR-9). `Ledger.Writer` is the sole writer of
decisions; its mailbox **is** the serialization of the decision log (no lock
discipline, no distributed transaction — the FATAL of the rejected
authority-split, `system-architecture.md` §7). It is a thin process over Ecto:
almost no logic in the heap, all truth in the database.

### Process shape & placement

Under `Ledger.Supervisor` (`rest_for_one`), started after `Repo`, before
`Budget.Owner` (which rebuilds its ETS snapshot from L in `init/1`):

```
Ledger.Supervisor              [rest_for_one]
├── Tau.Factory.Ledger.Writer  (GenServer: single decision writer over Repo)
└── Tau.Factory.Budget.Owner   (GenServer: budget ETS snapshot; reads truth from Writer/Repo)
```

`call` everywhere on the write path — the reply is back-pressure
(`supervision-tree.md` §4); a `cast` into the ledger would be a mailbox time-bomb
that silently drops decisions on overload. The reply is the WAL-commit
acknowledgement: the caller does not proceed to the external effect until the
decision is committed.

### Write API

Each call is `(payload, idempotency_key)` → `{:ok, committed_ref} |
{:ok, :already_applied, existing_ref}`. The idempotency key is checked inside the
same DB transaction as the insert (a unique constraint), so a coordinator restart
that re-issues a decision **never double-applies**.

```elixir
defmodule Tau.Factory.Ledger.Writer do
  use GenServer

  # --- decisions (each WAL-committed before its `{:ok, _}` reply) ---

  @doc "Record an orchestrator decision (select/admit/freeze/...). Idempotent on key."
  @spec record_decision(decision :: map, key :: String.t()) ::
          {:ok, ref} | {:ok, :already_applied, ref}
  def record_decision(decision, key), do: GenServer.call(__MODULE__, {:record, decision, key})

  @doc "Append a gate verdict for (unit_hash, gate_run). APPEND-ONLY — never updates (HR-2)."
  @spec append_verdict(unit_hash :: String.t(), gate_run :: pos_integer,
                        half :: :critic | :reviewer | atom, status :: :pass | :fail,
                        key :: String.t()) :: {:ok, ref} | {:ok, :already_applied, ref}
  def append_verdict(hash, run, half, status, key),
    do: GenServer.call(__MODULE__, {:append_verdict, hash, run, half, status, key})

  @doc "Revoke a prior verdict. Inserts a NEW superseding row; never mutates the prior (HR-2)."
  @spec revoke_verdict(unit_hash :: String.t(), gate_run :: pos_integer,
                       reason :: String.t(), key :: String.t()) :: {:ok, ref}
  def revoke_verdict(hash, run, reason, key),
    do: GenServer.call(__MODULE__, {:revoke_verdict, hash, run, reason, key})

  @doc "Debit the budget ledger (double-entry; every debit names an owner). CON-3/CON-4, INV-21."
  @spec debit_budget(owner :: String.t(), amount_cents :: integer, meta :: map,
                     key :: String.t()) :: {:ok, ref} | {:error, :exceeds_ceiling}
  def debit_budget(owner, amount_cents, meta, key),
    do: GenServer.call(__MODULE__, {:debit, owner, amount_cents, meta, key})

  @doc "Record an implementer challenge and its critic ruling."
  @spec record_challenge(unit_hash :: String.t(), test :: String.t(),
                        spec_clause :: String.t(), ruling :: :upheld | :rejected,
                        key :: String.t()) :: {:ok, ref}
  def record_challenge(hash, test, clause, ruling, key),
    do: GenServer.call(__MODULE__, {:challenge, hash, test, clause, ruling, key})

  @doc "Record an escalation (reason ∈ E + state snapshot). CON-7."
  @spec record_escalation(reason :: atom, snapshot :: map, key :: String.t()) :: {:ok, ref}
  def record_escalation(reason, snapshot, key),
    do: GenServer.call(__MODULE__, {:escalation, reason, snapshot, key})

  # --- reads (decision facts; hot reads go via ETS snapshots, not here) ---
  @doc "Latest non-superseded verdict status for a content hash (the merge-CAS read)."
  @spec verdict_status(unit_hash :: String.t()) :: {:pass | :fail | :revoked, gate_run :: pos_integer} | :none
  def verdict_status(hash), do: GenServer.call(__MODULE__, {:verdict_status, hash})
end
```

### WAL-before-ack (INV-16, RPO=0)

The Writer relies on **SQLite's WAL** (`synchronous=FULL`): each `handle_call`
wraps the insert in `Repo.transaction/1`; the database commits to its
write-ahead log and `fsync`s
before the transaction returns, and only *then* does the GenServer reply `{:ok,
ref}`. The caller (the orchestrator / unit FSM) treats that reply as the licence
to perform the external effect. Therefore:

```
decision formed → Writer.call → Repo txn (WAL fsync) → {:ok, ref} → external effect
                                ▲ durable here, before any effect is visible
```

A crash anywhere left of the `{:ok, ref}` loses an *un-acked* decision whose
effect never happened — correct. A crash right of it finds the decision durable
and the effect either done (idempotency key makes re-apply a no-op) or owed (the
Oban job re-drives it). **RPO = 0** holds by this ordering (proof sketch in §6).

### Idempotency keys

The key is a deterministic function of the decision's logical identity, not a
random UUID — so the *same* decision re-issued after a restart produces the *same*
key and collides on the unique constraint:

- `select`/`admit`: `"select:" <> unit_id <> ":" <> attempt`
- `append_verdict`: `"verdict:" <> unit_hash <> ":" <> Integer.to_string(run) <> ":" <> half`
- `debit_budget`: `"debit:" <> owner <> ":" <> action_id` (the billable action's id)
- `merged`: `"merge:" <> unit_hash <> ":" <> merge_sha`

On a unique-constraint violation the Writer returns `{:ok, :already_applied,
existing_ref}` rather than raising — a restart re-applying a decision is a benign
no-op, never a double-debit or double-merge (research §13 pitfall:
"non-transactional snapshot → double-merge").

---

## 3. Ecto schema sketch

Tables + key columns, not full migrations. The decision log is the canonical
store; ETS snapshots (§4) and any solution-tree view are *derived* from it. Note
the design centre: **`verdicts` is append-only and immutable per
`(unit_hash, gate_run, gate_half)` — HR-2.**

### `units` (PRs)

```elixir
schema "units" do
  field :unit_id,        :string          # logical key (Registry key; never a pid)
  field :issue_refs,     {:array, :integer}
  field :state,          :string          # planned|oracle|implementing|gating|refine_k|awaiting_merge|merged|escalated
  field :frozen_scope,   :map             # declared file set + declared gating-test paths (HR-4)
  field :policy_version, :integer         # FK → policy_versions (pinned at admission, HR-8)
  field :attempt_count,  :integer         # INV-19 durable retry counter
  timestamps()
end
```

### `attempts`

```elixir
schema "attempts" do
  belongs_to :unit, Unit, foreign_key: :unit_id, references: :unit_id, type: :string
  field :k,        :integer               # refine index ≤ N (INV-19)
  field :strategy, :string                # :refine | :pivot
  field :unit_hash, :string               # content hash of the diff this attempt produced
  field :outcome,  :string                # :green | :red | :pivoted | :escalated
  timestamps()
end
```

### `verdicts` — **APPEND-ONLY, IMMUTABLE (HR-2)**

The schema realizes HR-2 structurally, not by convention:

- **No `update`/`delete` is ever issued against this table.** The `Ledger.Writer`
  exposes only `append_verdict` and `revoke_verdict`, *both inserts*. A revoke is
  a **new superseding row** (`superseded_by`/`kind = :revoke`), never an in-place
  mutation of the original.
- A partial unique index `(unit_hash, gate_run, gate_half) WHERE kind = 'verdict'`
  guarantees one *original* verdict per coordinate; revokes are unconstrained
  appends that *point at* the original.
- `inserted_at` (monotonic, DB-clocked) plus a monotonic `seq` `bigserial` give a
  total order for "latest".

```elixir
schema "verdicts" do
  field :unit_hash,    :string            # content hash of exactly the gated diff (INV-1)
  field :gate_run,     :integer           # which gate execution (rebase produces a new run)
  field :gate_half,    :string            # "critic" | "reviewer" | "ac_linkage" | "masking" | "mutation"
  field :kind,         :string            # "verdict" | "revoke"
  field :status,       :string            # "pass" | "fail"   (null for kind="revoke")
  field :supersedes_id, :id               # for kind="revoke": the row it supersedes
  field :reason,       :string            # revoke reason / finding ref
  field :seq,          :integer           # bigserial — total append order
  field :inserted_at,  :utc_datetime_usec # DB-clocked; never updated
end
# NO updated_at. NO update changeset. Writes are inserts only.
```

**"Latest verdict status for a hash" is a query over the append-only table** —
greatest-run, not-superseded:

```elixir
def latest_verdict(hash) do
  # 1. the highest gate_run that has a complete original verdict set
  # 2. exclude any (run, half) that a later revoke row supersedes
  from(v in Verdict,
    where: v.unit_hash == ^hash and v.kind == "verdict",
    where: fragment(
      "NOT EXISTS (SELECT 1 FROM verdicts r WHERE r.kind = 'revoke' AND r.supersedes_id = ?)",
      v.id),
    order_by: [desc: v.gate_run, desc: v.seq])
  |> Repo.all()
  |> fold_required_halves()   # PASS iff every required half present & not revoked & status=pass
end
```

**Why immutability closes the value-staleness hole the merge CAS reads.** The
rejected design ("hash-keyed verdict freshness alone", `system-architecture.md`
§7) closes *content* staleness — the verdict is keyed to the diff hash — but not
*value* staleness: a late finding or upheld challenge can flip a verdict
PASS→FAIL *after* the merge authority read it. If verdicts were mutable, the
merge CAS would read a value that could change under it (a TOCTOU on the verdict
itself). Because the table is append-only and immutable, the CAS instead reads
the *latest-not-superseded* row inside its critical section (`supervision-tree.md`
§4): a revoke is a new row the CAS will observe, never a silent mutation of the
row it already saw. **FC-4** (`system-architecture.md` §4) — "verdict flips
PASS→FAIL after green" — is discharged here: G appends a revoke; M's CAS reads
the latest and rejects; INV-1 holds despite value-staleness; the authority-split
FATAL is closed (HR-2).

### `challenges`

```elixir
schema "challenges" do
  field :unit_hash,   :string
  field :test,        :string
  field :spec_clause, :string             # the §4 contract clause cited
  field :ruling,      :string             # "upheld" | "rejected" (by independent critic)
  field :seq,         :integer
  timestamps(updated_at: false)
end
```
(> 2 `upheld` on one unit → E-CHALLENGE escalation, INV-18; computed by a count
query, not stored mutable state.)

### `escalations`

```elixir
schema "escalations" do
  field :reason,    :string               # one of the closed/total set E (INV-18); E-UNCLASSIFIED catch-all
  field :snapshot,  :map                  # state snapshot at escalation (CON-7: recorded reason ∧ state)
  field :delivered, :boolean, default: false  # flipped by the operator-notification activity's outcome
  timestamps(updated_at: false)
end
```

### `budget_ledger` — **double-entry (CON-3 / CON-4)**

Every debit names an owner; the invariant `spent + remaining = total` and
`Σ attributed(owner) = total_spent` are *audited* against this table each cycle
(§7). Two complementary rows model double-entry: a `debit` against the global
pool and a `credit_to_owner` attribution; in a single-pool model these collapse
to one row with a mandatory non-null `owner`.

```elixir
schema "budget_ledger" do
  field :owner,        :string            # factory_step | agent_id | gate_run — NON-NULL (CON-4: ∃! owner)
  field :amount_cents, :integer           # signed: negative = debit
  field :action_id,    :string            # the billable action (idempotency anchor)
  field :meta,         :map               # provider, tokens_in/out, model
  field :seq,          :integer
  timestamps(updated_at: false)
end
# remaining = total_budget + Σ amount_cents   (invariant audited per cycle, §7)
```

### `policy_versions`

```elixir
schema "policy_versions" do
  field :version,        :integer
  field :model_per_role, :map
  field :retry_bound_n,  :integer         # engine-clamped: min(policy, ceiling); ∞ rejected (HR-8)
  field :budget_total,   :integer
  field :gate_manifest,  :map             # gate-floor non-shrinkable
  field :conflict_pred,  :map             # floor only tightened
  timestamps(updated_at: false)
end
```
(Versioned, immutable rows; a unit pins `policy_version` at admission so a
policy edit mid-flight cannot change a unit's rules under it — HR-8.)

### `cost_line_items`

Reuse target for the current `cost/tracker.ex` adapter-tagged line items (D-038).
Feeds CON-4 (cost attribution). One row per billable provider call, owner-tagged,
joined to `budget_ledger` by `action_id`.

```elixir
schema "cost_line_items" do
  field :owner,      :string              # ∃! owner (CON-4)
  field :action_id,  :string
  field :provider,   :string
  field :model,      :string
  field :tokens_in,  :integer
  field :tokens_out, :integer
  field :cost_cents, :integer
  timestamps(updated_at: false)
end
```

---

## 4. `Tau.Factory.Budget.Owner` — hot-read ETS snapshot over durable truth

`Budget.Owner` is a GenServer owning a `read_concurrency: true` ETS table holding
the *current remaining budget snapshot*. Admission (S) checks budget on **every**
billable action (INV-21); routing every such read through `GenServer.call` would
serialize the entire fan-out behind one mailbox for no consistency gain (research
§8). So **admission reads bypass the mailbox** — a direct `:ets.lookup` on the
snapshot table — the hot-read pattern (`supervision-tree.md` §4).

### Truth vs snapshot

- **Truth is in SQLite** (`budget_ledger`), written through `Ledger.Writer`
  (`debit_budget`). The snapshot is *derived*.
- **`init/1` rebuilds the snapshot from durable truth** — on owner restart it
  reads `remaining = total + Σ amount_cents` from `budget_ledger` and seeds the
  ETS table. The snapshot is never the system of record; it cannot drift past a
  restart because it is reconstructed from L.
- **Write-through:** a successful `debit_budget` (the durable write) updates the
  ETS snapshot in the *same* `handle_call` *after* the WAL commit returns — never
  before. Truth leads; the snapshot follows. If the snapshot update is lost to a
  crash, `init/1` rebuilds it correctly from L (CON-3 holds).

```elixir
defmodule Tau.Factory.Budget.Owner do
  use GenServer
  @table :tau_factory_budget

  # HOT READ — bypasses the mailbox (admission calls this directly, INV-21)
  @spec remaining() :: integer
  def remaining, do: :ets.lookup_element(@table, :remaining, 2)

  @spec admits?(amount_cents :: integer) :: boolean
  def admits?(amount), do: remaining() >= amount      # NFR-BUDGET-PRECISION: pre-action check

  def init(_) do
    table = :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    :ets.insert(table, {:remaining, Tau.Factory.Ledger.rebuild_remaining()})  # from durable truth
    {:ok, %{table: table}}
  end

  # write-through: AFTER the durable debit commits, update the snapshot
  def handle_call({:applied_debit, amount}, _from, st) do
    :ets.update_counter(@table, :remaining, {2, -amount})
    {:reply, :ok, st}
  end
end
```

### Why this is **not** a "Manager" anti-pattern

OTP non-negotiable #3 forbids a "Manager"/"Service" GenServer wrapping shared
state for its own sake. `Budget.Owner` is not that:

1. **It owns a genuine runtime resource** — the ETS table's *lifecycle* (ETS dies
   with its owner). The process exists to own the table, not to namespace
   functions (research §8: "the owner is a GenServer with almost no logic; the
   reads bypass its mailbox entirely" — exactly `CircuitBreaker.Store`).
2. **It is not the writer of truth.** Writes go through `Ledger.Writer` to
   SQLite; `Budget.Owner` holds only a *derived hot projection*. A Manager
   anti-pattern centralises *authority*; this centralises only a *cache* whose
   authority lives elsewhere.
3. **Reads do not funnel through it** — they hit ETS directly. A Manager
   anti-pattern's defining sin is serialising reads through one mailbox; this
   explicitly avoids that.
4. **Almost no logic in the heap.** The clamp/admission logic is pure
   (`Tau.Factory.Policy`, property-tested); the owner is a boring lifecycle
   anchor. (Litmus: if it crashed, nothing irreplaceable is lost — the snapshot
   rebuilds from L. That is the test for "not a Manager".)

---

## 5. Oban as the durable backlog / system-of-record for owed work

The prose `/loop` driver and the prose "solution-tree.json reconciled against
GitHub" are both replaced by durable mechanisms. **Oban** (on its SQLite/Lite
engine — or a hand-rolled SQLite backlog, §8) is
the system-of-record for **what work exists and what is owed**: the factory-step
backlog, retries, and the recurring driver. This is the durability ruling
(research §13): durability is the harder property to retrofit, so the *owed-work*
spine lives in Oban where it is battle-tested, and only *live reactivity* lives in
the FSMs.

### The hybrid — what lives where

| Concern | Home | Why |
|---|---|---|
| **Factory-step backlog** ("execute one factory step" for unit U) | **Oban job** | durable, survives node death/deploy by construction; at-least-once |
| **Retry of an owed step** (transient infra failure of an *activity*) | **Oban retry** (backoff) | retried-with-backoff is free; distinct from the *semantic* N≤3 refine bound (which is durable FSM state, §3 `units.attempt_count`) |
| **The recurring driver** (re-invoke "execute one factory step" on an interval) | **Oban cron plugin** | replaces the prose `/loop`; a `@reboot`/cron job enqueues the next step; the kill switch is a row/sentinel checked at job start |
| **Live reactivity** — state timeouts, agent `:DOWN`, escalation reply, mid-flight freshness re-check | **`gen_statem` unit FSM** | the job model would force polling (`snooze`) and lose timeout/postpone ergonomics (research §13) |
| **Decision facts** (verdicts, debits, challenges, escalations) | **Ecto tables via `Ledger.Writer`** (§2/§3) | the append-only system of record; Oban jobs *write through* L for facts |

**The boundary:** Oban owns *durability and the backlog* (at-least-once, retry,
cron); the `gen_statem` unit FSM owns *live reactivity* (timeouts, `:DOWN`,
escalation). Both write through the same transactional store (L) — so the
solution tree, not any process heap, is the single source of truth across any
restart (consistent with the factory-loop rule's "solution tree is the single
source of truth across a meta-restart"). An Oban worker for a factory step is
thin: it resolves/starts the unit's FSM via the Registry, hands it the durable
state, and lets the FSM drive — the job is the *durable trigger*, the FSM is the
*live actor*.

> **Note (research §13 caveat):** Oban job args are JSON (atoms → strings); the
> ledger never relies on atom-keyed job args for decision facts — facts are typed
> Ecto rows. Oban Pro Workflows (DAG fan-out/fan-in for the gate) are a candidate
> for the gate batch but are a paid product with version-sensitive APIs; v1 uses
> plain Oban queues + `Task.async_stream` for the gate (`supervision-tree.md` §0:
> the gate is bounded fan-out, not a stream).

---

## 6. Recovery / resume (LIV-5, NFR-RTO) and the RPO=0 proof sketch

### Coordinator crash → resume

A `Coordinator` (K) crash restarts *only* it (`rest_for_one`; it is started last)
and it **resumes from L** — it does not resurrect in-flight units blindly
(`supervision-tree.md` §3, FC-1):

1. **Re-read in-flight units from L.** Query `units` where `state ∉ {merged,
   escalated}`. These are the owed semantic work.
2. **Re-spawn each unit's `gen_statem` from its last snapshotted state.** The FSM
   is started under `UnitSupervisor` (DynamicSupervisor) via `{:via, Registry,
   {UnitRegistry, unit_id}}`, rehydrated from the durable `units` row (state,
   `attempt_count`, `frozen_scope`, `policy_version`). The FSM's last *decision*
   is in L; its in-flight *activity* (a running gate, a spawned worker) is
   re-driven from the owed-work backlog (Oban) — not trusted from a vanished heap
   (the decision/activity split, §1).
3. **Reconcile against the external tracker (CON-2).** Run the reconciliation
   pass (§7): for each in-scope issue, `state_tree(i) ≡ state_tracker(i)`. A unit
   the tree thinks is `awaiting_merge` but whose PR the tracker shows *merged*
   (the merge landed just before the crash) is reconciled to `merged` via the
   `merged` decision's idempotency key — no double-merge.

RTO budget: NFR-RTO `p95 ≤ 60 s` — bounded by the in-flight-unit count and a few
indexed queries; FSM rehydration is cheap (re-read a row, not replay reasoning).

### RPO = 0 proof sketch (NFR-RPO, INV-16)

**Claim:** no committed decision is lost across any crash; a decision is
externally visible only after its WAL commit.

1. By §2, every decision write is `Repo.transaction/1` → SQLite WAL `fsync` →
   `{:ok, ref}` reply, *in that order*. The reply is the only signal the caller
   uses to proceed.
2. The orchestrator performs an external effect (push, spawn, escalate-notify)
   **only after** receiving `{:ok, ref}` — i.e. only after the WAL commit. So
   *visibility(effect) ⊐ commit(decision)*: every externally observable effect is
   preceded by a durable decision.
3. A crash partitions time into "before the `{:ok, ref}`" and "after":
   - **Before** the reply: the transaction either committed (durable; recovery
     re-reads it — no loss) or did not (no effect happened — nothing to lose). RPO
     boundary is *exactly* the WAL commit; an un-acked decision had no effect.
   - **After** the reply: the decision is durable in WAL; recovery re-reads it.
     If its effect had already happened, the idempotency key (§2) makes
     re-application a no-op; if owed, Oban re-drives it.
4. ∴ the data-loss window for *committed* decisions is 0 (NFR-RPO), and no
   committed decision is re-done destructively (idempotency). ∎

This is FC-8 (`system-architecture.md` §4): if L is briefly unavailable, the
caller blocks on that specific datum and never guesses past it (fail-closed) —
the system never acts on an uncommitted decision, which is the same ordering that
makes RPO=0 hold.

---

## 7. Reconciliation pass (CON-1, CON-2, CON-3/4 audits)

A reconciliation pass runs each cycle (and on resume, §6) — a cheap audit that
catches conservation drift early rather than at milestone end (`conservation.md`
epilogue). It is **pure logic over durable rows** (a function, not a process),
invoked by the cron driver; properties-before-examples since it bears the
conservation invariants.

| Law | Audit (pure check over L) | On violation |
|---|---|---|
| **CON-1 work conservation** | every `accepted` unit is in exactly one of `{merged, escalated, rejected, in_flight}`; none "disappeared" | raise E-RECONCILE; surface the orphaned unit |
| **CON-2 issue reconciliation** | `∀ i ∈ scope. state_tree(i) ≡ state_tracker(i)` and `|steps_recorded| = |steps_executed|` (fetch tracker via `gh` *activity*, compare to `units`/`attempts`) | reconcile state or escalate the mismatch (e.g. tracker-closed with no merging step) |
| **CON-3 budget conservation** | `Σ budget_ledger.amount_cents = remaining − total`; `Budget.Owner` snapshot equals the durable sum | rebuild snapshot from truth; if truth itself is unbalanced, E-BUDGET |
| **CON-4 cost attribution** | every `cost_line_items` / `budget_ledger` row has a non-null `owner`; `Σ attributed(owner) = total_spent` | flag unattributed spend (a debit with no owner) |
| **CON-6 verdict conservation** | every `merged` unit has, for each required gate half, a latest-not-superseded `pass` verdict against its merged hash | a merged unit missing a fresh verdict is a gate bypass — escalate |
| **CON-7 escalation conservation** | every `escalations` row is `delivered = true` with reason+snapshot recorded | re-deliver undelivered escalations |

The reconciliation function takes L's rows (and, for CON-2, a tracker snapshot
from a `gh` activity) and returns `:ok | {:drift, [finding]}`. Drift findings are
themselves recorded as decisions (an audit trail of audits). The pass is the
audit half of double-entry accounting (`conservation.md`): every quantity has one
writer-of-record (L) and a balance check (this pass).

---

## 8. Durable store — **DECIDED: SQLite/Exqlite** (OQ-1 resolved)

**Decision (operator, OQ-1):** the durable store is **SQLite via Exqlite**, to
preserve tau's **single self-contained binary** deployment (Burrito-packaged, no
external services). This is now a fixed design constraint, not an open question
(`../06-roadmap/open-questions.md` OQ-1 = resolved).

**Why it fits cleanly:**

1. **Reuse, not new dependency.** The current repo's memory subsystem
   (`lib/tau/memory/store/` + `migrations.ex` + `supervisor.ex`) already runs on
   **Exqlite** (SQLite; FTS5 + sqlite-vec — SPEC-MEMORY-STORE, ADR-0020), and
   `lib/tau/cost/tracker.ex` already produces adapter-tagged cost line items
   (D-038, the source for `cost_line_items`, §3/CON-4). The durable ledger reuses
   that Exqlite scaffolding (an Ecto-over-Exqlite repo); no Postgres/Postgrex is
   introduced. Exqlite is a NIF and ships **inside** the Burrito binary.
2. **The schema's authority is single-writer, not concurrent.** L is
   append-only, single-writer, double-entry accounting with WAL-before-ack
   (§2–§3, HR-9). SQLite's single-writer model is *exactly* what the ledger wants,
   not a limitation to fight.
3. **RPO=0 holds on SQLite.** SQLite in **WAL mode with `synchronous=FULL`**
   `fsync`s the WAL before commit; `Repo.transaction/1` returns only after that
   commit, so a decision's effect is visible only after it is durable
   (visibility(effect) ⊐ commit(decision) — §6 proof). The independent
   final-validation confirmed RPO=0 is achievable on Exqlite-WAL.
4. **D-S4 reinforced.** SQLite is a node-local file, which *strengthens* the
   single-node control-plane stance (`supervision-tree.md` §6): there is no shared
   database to tempt a naïve multi-master split of the merge point. The off-node
   execution tier (OQ-5) therefore reaches the control node through an **API/queue
   boundary**, never a shared SQLite file (`distribution-readiness.md`).

**The owed-work backlog / cron driver (§5) on SQLite.** Two acceptable
realizations; both preserve the single binary:

- **Preferred — Oban on its SQLite engine (`Oban.Engines.Lite`, via
  `ecto_sqlite3`).** Oban supports SQLite single-node; this keeps Oban's
  battle-tested retry/backoff/uniqueness/cron without Postgres. Caveats (accepted
  under D-S4): the Lite engine is newer, single-node only, and uses a polling
  notifier rather than Postgres `LISTEN/NOTIFY` — all fine for the factory's
  modest job rate (factory-steps, not high-throughput ingest). Validate the Lite
  engine on a spike before committing.
- **Fallback — a minimal hand-rolled durable `jobs` table** over the same Exqlite
  store + an internal cron-tick process, if the Lite engine's single-node limits
  bite. This re-implements only the slice of Oban the factory uses
  (enqueue/lease/retry-with-backoff/cron) — a bounded, known cost.

Either way, the **durable ledger** (solution tree, append-only verdicts, budget,
policy versions — the system of record) is **plain Ecto-over-Exqlite and
independent of the Oban-engine choice**. The remaining sub-decision is only
*which backlog mechanism* (Oban-Lite vs hand-rolled), resolvable by a spike; it
does not affect the schema, RPO=0, or any invariant.

> Throughout the other layer-04 files, "Postgres" / "Oban (Postgres-backed)" in
> the durability descriptions should be read as **SQLite/Exqlite** /
> **Oban-Lite-on-SQLite (or a hand-rolled SQLite backlog)** per this decision;
> the research (`../01-research/`) and verification (`../05-verification/`) files
> retain their original Postgres-vs-SQLite weighing as the decision trail.
