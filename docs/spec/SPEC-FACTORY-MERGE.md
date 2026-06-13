# SPEC: Factory Merge Authority (the integration crux · M)

| | |
|---|---|
| **Status** | Draft |
| **Date** | 2026-06-10 |
| **Scope** | The `:tau_factory` **Merge Authority** (M): the single `gen_statem` that integrates green work units onto `origin/main`. The crux where **INV-1..4** are finally enforced — gate-before-merge, freshness, serialized merge, and main health. Owns the live-verdict CAS, the `--force-with-lease` freshness primitive, sole-writer-of-`main`, the merge-train, and the fair queue. |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + boundary contracts. Derived from the verified architecture in `docs/arch/` (system-architecture §1 M, §4 FC-3/FC-4, §5 rate arithmetic; merge-and-integration.md; synthesis HR-1/HR-2/HR-5; invariants INV-1..4, INV-20; liveness LIV-2, Q-L1). |
| **Issue** | TBD — file before the first implementation PR (`tau-github-workflow`); reference as `Closes #N`. |

**Changelog:** Initial draft — §0–§7 + Appendix B. Introduces D-300, D-301,
D-302, D-303, D-341. Cites (does not own) D-335 (verdict append-only
immutability — SPEC-FACTORY-CORE; M *reads* the latest verdict, immutability is
what makes the read sound), D-306 + D-303-health-via-Toolchain
(SPEC-FACTORY-GATE), D-319 (`E-DESTRUCTIVE` for non-M pushes —
SPEC-FACTORY-GOV). Verdict store is L (SQLite/Exqlite, SPEC-FACTORY-CORE);
`origin/main` mutation is via `git` subprocesses only.

**Amendment (2026-06-12, PR #465):** Introduces D-355 (durable merge-outcome,
RPO=0). Adds §4 B9 (M COMMIT → L merge-outcome write, WAL-before-ack, BEFORE
telemetry projection). Updates §5 `:committing` exit description and §6 D-NNN
block. Cited by SPEC-FACTORY-CORE §4 B3 (Unit `:awaiting_merge` reconcile-on-entry,
D-344 amendment).

**Amendment (2026-06-13, PR #477):** Introduces **D-356** (merge-result PubSub
delivery, M's emission half). M, on every terminal outcome of a train member,
**broadcasts `{:merge_result, :merged | :rejected}` to PubSub topic
`"factory:pr:#{id}"`** on the shared `Tau.PubSub` (one instance, D-184 analog) —
the result-emission act the arch named (`control-plane.md` §5; merge-and-
integration.md). This was already a §4 B1/B8 boundary and a §3 `[C206-B1]`
constraint; the **code emitted only telemetry** (a driver-side bridge re-derived
`{:merge_result, _}` from `[:tau, :factory, :merge, :merged|:reject]`), so this is
a **non-conformance closure plus a newly-owned D-NNN**, not a contract change.
Updates §5 `:committing` exit line, adds D-356 to §6, and cross-references
SPEC-FACTORY-CORE D-356 (the U subscribe-before-request consume half). Resolves
#478 (telemetry-vs-PubSub mismatch).

## 0. Why this spec exists

M is the **crux** of the autonomous factory: it is the one component where the
four integration-safety invariants are *finally* enforced, and the one the
verifiers found hardest to make correct. Two holes are FATAL if mishandled. The
**merge TOCTOU** (HR-1): between reading `head(origin/main)` and pushing, the
ref can move, so a naïve read-compare-push can land a stale diff. The **verdict
value-staleness** (HR-2, the authority-split FATAL): a verdict can flip PASS→FAIL
on the *same* hash when a late challenge or incomplete-fix finding lands, so
hash-keying alone closes *content* staleness but **not value** staleness.

The naïve "do it all inside one `handle_call`" shape is also wrong for a third
reason (final-validation H-1): the per-integration build cost `T_int = T_gate +
T_health` is **minutes**. Running it on M's mailbox blocks every waiting unit's
`call` (tripping the 5 s default `GenServer.call` timeout) and relocates the very
gate saturation HR-5 exists to defeat *into the merge process itself*.

This spec therefore makes M a **single `gen_statem`** (`:idle/:integrating/
:committing`) that runs the slow build **off its mailbox** in a monitored `Task`
and serializes only the short COMMIT. INV-3 holds because at most one
`:integrating` train exists at a time and the CAS push runs in the one M
process. The load-bearing mechanisms are the **live-verdict CAS** (HR-2), the
**`--force-with-lease` atomic ref-update** (HR-1), **sole-writer-of-`main`**
(required for INV-2), the **merge-train** (HR-5, the throughput-stability fix),
and the **fair FIFO+aging queue** (LIV-2).

The component is maximally coordination-heavy (triage 5/5; §1) and therefore
requires this spec before any implementation PR modifies the merge boundary, per
`.claude/rules/spec-before-code.md`.

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | `origin/main` is the shared ref every in-flight unit races to advance; the live train, the wait-queue, and each member's `restale_count` are read on assembly and written on every merge/reject. M is the sole writer of `main` precisely because the state is contended. |
| 2 | Temporal coupling | 1 | The CAS has a strict order — re-read the *latest* verdict, **then** `--force-with-lease` — and both must be adjacent and post-build; a verdict may revoke *during* `T_int`, so the read must happen at the merge instant, not at gate time. |
| 3 | Cross-process coordination | 1 | M (`gen_statem`), the monitored build `Task` (off-mailbox), L (verdict reads), the Toolchain adapter (health recipe), N× U (async submit + result), K (E-RED-MAIN), PubSub observers — coordination spans many processes with no shared mailbox. |
| 4 | Feedback loops | 1 | Every merge advances `origin/main`, re-staling the other in-flight branches, each forced to re-rebase and re-gate; gate utilization `ρ_g = (W−1)/W → 1` feeds back on effective merge rate. The train and aging close the loop. |
| 5 | State accumulation | 1 | A unit's `restale_count` accumulates across freshness races (drives aging priority); the live train accumulates green members until commit; the red-main flag persists until an operator decision clears it. |

**Triage score: 5/5. L0 + boundary contracts indicated.**

## 2. Component decomposition

Naming is precise so §4 contracts attach to specific operations. All modules are
under `Tau.Factory.*` and supervised high in the `rest_for_one` spine, beside
`Repo`/`Ledger`/`Budget.Owner` (arch `supervision-tree.md` line 76):
precious authority, simple logic, restartable state derived from L on `init/1`.

| # | Component | Role |
|---|-----------|------|
| C1 | `Tau.Factory.MergeAuthority` | **M.** Single `gen_statem` (`:idle`/`:integrating`/`:committing`). Sole writer of `origin/main`. Accepts non-blocking submissions, assembles the train, runs the build off-mailbox in a monitored `Task`, and serializes the short COMMIT (re-read verdict + CAS push). One `:integrating` train at a time **is** INV-3. |
| C2 | `Tau.Factory.Merge.Train` | Pure train assembler/bisector: `assemble/2` (pick a batch `B` of green units under the fair policy), `bisect/2` (`O(log B)` culprit search on a red tip). No process. Properties before examples. |
| C3 | `Tau.Factory.Merge.Cas` | The COMMIT critical section as data + effects: `assert_all_verdicts_live/1` (re-read latest verdict per member, HR-2) then `cas_push/2` (`git push --force-with-lease`, HR-1). The `git` subprocess boundary. |
| C4 | `Tau.Factory.Merge.Queue` | Pure fair wait-queue: FIFO sequence + aging by `restale_count`; `effective_priority/1` monotone. No process. Properties before examples. |
| C5 | `Tau.Factory.Merge.Health` | Post-integration health on the batch tip via the `Tau.Factory.Toolchain` behaviour (recipe is adapter data; the judgement is M's). `:green` / `{:red, report}`. *Recipe owner cited from SPEC-FACTORY-GATE.* |

Boundaries (B-N attach contracts in §4):

| # | Boundary | Operation |
|---|----------|-----------|
| B1 | **U** (SPEC-FACTORY-CORE) ↔ M (C1) | `request_merge(unit, hash)` → `:queued` (**non-blocking** submit); async `:merged`/`:rejected` via `"factory:pr:#{id}"`. **Cited counter-boundary (B6 there).** |
| B2 | M (C1) ↔ build `Task` (C2/C5) | `rebase_train → gate_batch_tip → health_check` run off the mailbox; reports `{:built, units, base, tip}` / `{:build_failed, …}` / `:DOWN`. |
| B3 | M COMMIT (C1) ↔ L (verdict read) | `verdict_status(hash) → {:pass, run} \| {:revoked, _} \| :none` — a **pure read of the latest** append-only verdict, inside `:committing`. **Cited (reads D-335-owned data).** |
| B4 | M COMMIT (C3) ↔ `origin/main` (git) | `git push --force-with-lease=refs/heads/main:<expected-old-oid> origin <tip>:refs/heads/main` — atomic conditional ref-update; M is the **sole** writer. |
| B5 | M (C5) ↔ Toolchain (G) | `health_recipe(lang)` (adapter data) + engine-side `judge_health/1`. **Cited, SPEC-FACTORY-GATE.** |
| B6 | M (C1) ↔ K (SPEC-FACTORY-CORE) | `escalate(:"E-RED-MAIN")` on a post-merge red main re-check (global). |
| B7 | non-M actor ↔ `origin/main` | any non-M push ⇒ `classify_main_write/1 → {:escalate, :"E-DESTRUCTIVE"}`. **Cited, SPEC-FACTORY-GOV/D-319.** |
| B8 | M (C1) ↔ observers | `[:tau, :factory, :merge, …]` telemetry; `"factory:pr:#{id}"` PubSub result fan-out (never the control path). |

## 3. L0 constraints

Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious.

### Q1: What can be written by more than one actor?

- **★ [C200-B4]** `origin/main` has **exactly one writer**: M's `cas_push` (C3).
  This is **required for INV-2**, not a convenience. If a second writer (an
  operator script, a self-host bootstrap path, a stray worker) could advance
  `origin/main`, M's `expected-old-oid` would be a **stale projection** of the
  true ref and the `--force-with-lease` check would race a writer M cannot see —
  reintroducing the TOCTOU below the primitive (the authority-split second hole).
  Every non-M push is structurally forbidden (`[C212-B7]`).
- **★ [C201-B3]** The verdict store L is append-only and **immutable per
  `(hash, run)`** (owned by D-335, SPEC-FACTORY-CORE). M never writes a verdict;
  it only *reads the latest*. A challenge or late finding makes the **Gate**
  append a superseding revocation — never an in-place mutation. M's correctness
  depends on that immutability, so the read is sound: "latest status for a hash"
  is a deterministic query over append-only rows.
- **[C202-B1]** The live train and the wait-queue are written only by M, on
  assemble/commit/reject. U *submits* and *reads* results; it never mutates the
  train.

### Q2: What ordering assumptions are implicit?

- **★ [C203-B2]** The serialized thing is the **COMMIT, not the build**
  (final-validation H-1). `T_int = T_gate + T_health` is *minutes*; running it in
  a `handle_call` blocks M's mailbox for `T_int`, trips the 5 s `call` timeout in
  every waiting U, and relocates HR-5's saturation into M. So the slow
  `rebase → gate → health` runs **off the mailbox** in a monitored `Task`
  (`:integrating`); only the short `re-read-verdict + cas_push` is serialized
  (`:committing`). Putting the build back inside `handle_call` is forbidden.
- **★ [C204-B3]** The CAS re-reads the verdict **at the merge instant, after the
  build** — not at gate time (HR-2; final-validation H-3). A revoke can land
  *during* `T_int`; `assert_all_verdicts_live/1` runs in `:committing`, adjacent
  to `cas_push`, so a PASS→FAIL flip on the same hash is caught before any push.
  Reading the verdict once pre-build and trusting it across `T_int` is forbidden.
- **★ [C205-B4]** The CAS *apply* is the **VCS primitive, not M-side timing**
  (HR-1). `git push --force-with-lease=<ref>:<expected-old-oid>` compares-and-sets
  **atomically on the remote**: the push is rejected unless `origin/main` is
  *still* at `expected-old-oid`. There is no window between a read and the push to
  lose. An M-side "read head, compare, then push" is non-atomic and forbidden.
- **★ [C206-B1]** `request_merge` is **non-blocking** (final-validation H-1b). U
  submits (the call returns `:queued` immediately) and learns the outcome
  asynchronously via `"factory:pr:#{id}"`. A synchronous `call` held open across
  `T_int` is forbidden — it is the H-1 mistake on the *caller* side.

### Q3: What happens if a component fails silently?

- **★ [C207-B2]** A **wedged build** (the `Task` neither completes nor crashes)
  would hang M in `:integrating` forever, silently starving the whole merge
  stage. `:integrating` MUST arm a mandatory `:state_timeout`; on expiry M
  abandons the build (requeues the train) rather than waiting indefinitely. A
  `Task` *crash* surfaces as `:DOWN` and is handled (requeue), but a wedge emits
  no message — the timeout is the only signal.
- **★ [C208-B5]** A buggy or adversarial Toolchain adapter MUST NOT be able to
  fake `:green`. The adapter supplies only the *recipe* (data); M **executes and
  judges** the structured artifact itself (HR-3, FC-5). The judgement is the
  engine's, never the adapter's `:green` claim.
- **[C209-B6]** A red post-merge `main` is **never** swallowed: it gates the
  merge precondition closed (`□ red(main) → ¬∃ d. merge(d)`), raises
  `E-RED-MAIN` to K, and leaves `main` red **and named** for an operator
  revert-vs-fix-forward decision.

### Q4: What information crosses a boundary, and what is lost?

- **★ [C210-B3]** What crosses from L into the CAS is the **latest** verdict
  status, not a cached one. Hash-keying closes content staleness; **immutability +
  latest-wins** closes value staleness (HR-2). If only a hash-keyed cache crossed,
  a revoked-but-cached PASS would merge — the authority-split FATAL. The crossing
  datum MUST be a live read.
- **★ [C211-B4]** `expected-old-oid` is `base(d)` — the `origin/main` head the
  gate ran against. Because M is the sole writer (`[C200]`), the **only** way the
  lease fails is a freshness violation, which the primitive rejects (FC-3). No
  other information is needed to enforce INV-2; the ref's own value carries it.
- **[C212-B7]** A non-M `origin/main` write crossing the action boundary carries
  only enough to classify it: `classify_main_write(actor)` for `actor ≠
  :merge_authority` ⇒ `{:escalate, :"E-DESTRUCTIVE"}` (INV-20; cited
  SPEC-FACTORY-GOV/D-319). It is never auto-executed.

### Q5: Where are the feedback loops, and are they bounded?

- **★ [C213-B4]** The re-gate feedback (each merge advances `origin/main`,
  re-staling the other `W−1` branches) makes single-PR serial merge **unstable**:
  `ρ_g = (W−1)/W → 1` as `W` grows, so effective merge rate *falls* as `W` rises
  (rate-split verifier). The **merge-train** (HR-5) bounds it: integrating a batch
  `B` in one rebase+gate+health cycle makes the re-stale cost `O(1)` per *batch*,
  not `O(W)` per *unit*. `B` and `W_cap` derive from the **measured** `T_unit /
  T_int` on the bootstrap toolchain; until measured, operate conservatively
  (small `W_cap`, `B ≥ 2`, never `B = 1` which is the unstable serial regime).
- **★ [C214-B1]** A green+fresh branch must not starve behind a stream of small
  fast merges (LIV-2, Q-L1). The queue is **FIFO + aging**: a unit's effective
  priority rises with `restale_count`, so after bounded re-stales it is admitted
  to the train **ahead** of newcomers. Aging is **required, not optional** — pure
  FIFO is falsifiable under exactly the many-small-PR workload the fleet produces.

### Q6: What are the pre/post-conditions at each boundary?

- **[C215-B3]** `assert_all_verdicts_live/1` pre: L running; the train assembled.
  Post: returns `:all_pass` only if **every** member's *latest* verdict is
  `{:pass, _}`; a single `{:revoked, _}` halts the commit (eject that member, no
  push). No member with a revoked verdict can be in the pushed tip (INV-1).
- **[C216-B4]** `cas_push/2` post: on `:ok` the ref advanced atomically and
  `fresh(d)` held by the primitive (INV-2); on `{:error, :stale_ref}` **no merge
  occurs** — the train is requeued to rebase onto the new head and re-gate the
  new tip. M MUST NOT retry the push or force past the lease.

### Q7: What is the message-ordering protocol?

- **★ [C217]** The **control path is the `gen_statem`** (submit + transitions);
  the **build is an off-mailbox monitored `Task`** (liveness via the `Task`'s
  `ref`/`:DOWN`); the **result plane is PubSub** (`"factory:pr:#{id}"`,
  `"factory:escalation"`) — decoupled fan-out, never the control path. No
  `:global`, no `Process.whereis |> send` (OTP non-negotiable #4).
- **[C218]** M's recoverable state (live train + wait-queue) is **derived from L
  on `init/1`** — no pid is stored durably; units are keyed by id, not pid. A
  restart rebuilds the train from L and resumes; an in-flight push that the WAL
  shows as un-acked is re-attempted (idempotent: the CAS rejects if it already
  landed).

### Q8: What is the change-impact (what else must move if this changes)?

- **[C219]** Changing `W_cap` / `B` sizing is **policy**, engine-clamped, and
  touches no invariant (D-300..303 hold for any `B ≥ 1`). Adding a second
  `origin/main` writer would break INV-2 and is forbidden (`[C200]`). Replacing
  `--force-with-lease` with an M-side compare reopens HR-1 and requires
  re-discharging D-301. Clustering M would import split-brain into the one place
  that cannot tolerate it (D-S4; M stays single-node).

## 4. Boundary contracts

### B1: Unit (U, *cited SPEC-FACTORY-CORE*) ↔ Merge Authority (C1)

- `request_merge/2 :: (unit_id, hash) -> :queued` — **non-blocking**; the result
  `:merged` / `{:rejected, reason}` arrives async on `"factory:pr:#{unit_id}"`.
- Pre: M running; the unit holds a fresh PASS verdict for `hash` in L.
- Post: the unit is enqueued in the fair wait-queue; M starts **no second
  `:integrating` train** while one is in flight (INV-3).
- Invariant (**D-302**): `□ |{d : merging(d)}| ≤ 1`. A blocking `call` held
  across `T_int` is forbidden (`[C206]`, arch H-1b).

### B2: Merge Authority (C1) ↔ build `Task` (C2/C5)

- On `:idle → :integrating`: `Task.Supervisor.async_nolink(MergeTasks, fn ->
  rebase_train(units, base) ⨟ gate_batch_tip(tip) ⨟ health_check(tip) end)`.
- Pre: a non-empty green batch assembled; `base = current_main_head()` captured
  as the CAS `expected-old-oid`.
- Post: the `Task` reports `{:built, units, base, tip}` (`:integrating →
  :committing`), or `{:build_failed, units, {:health_red, report}}` (bisect), or
  `:DOWN` (requeue). M's mailbox stays free for `T_int` (`[C203]`).
- Invariant: `:integrating` arms a `:state_timeout`; a wedged build cannot hang M
  (`[C207]`). The build runs **off the mailbox** — never inside `handle_call`.

### B3: Merge Authority COMMIT (C1) ↔ Ledger verdict read (*cited D-335*)

- `verdict_status/1 :: (hash) -> {:pass, run} | {:revoked, _} | :none` — a pure
  read of the **latest** append-only verdict, run **inside `:committing`**, after
  the build.
- `assert_all_verdicts_live/1 :: (units) -> :all_pass | {:revoked, unit}`.
- Pre: train built; L up.
- Post: `:all_pass` ⟺ every member's latest verdict is `{:pass, _}` **now**;
  a `{:revoked, u}` ejects `u` and retries the rest with **no push**.
- Invariant (**D-300**, INV-1; relies on **D-335** immutability): the CAS reads a
  **live** verdict before any push; a flip PASS→FAIL on the same hash is caught
  (HR-2, FC-4). Reading the verdict only pre-build is forbidden (`[C204]`).

### B4: Merge Authority COMMIT (C3) ↔ `origin/main` (git)

- `cas_push/2 :: (tip, expected_old_oid) -> :ok | {:error, :stale_ref}` via
  `git push --force-with-lease=refs/heads/main:<expected_old_oid> origin
  <tip>:refs/heads/main`.
- Pre: `assert_all_verdicts_live == :all_pass`; M is the **sole** writer of
  `origin/main` (`[C200]`).
- Post: `:ok` ⇒ ref advanced atomically, `fresh(d)` held by the primitive;
  `{:error, :stale_ref}` ⇒ **no merge**; requeue → rebase onto new head →
  re-gate the new tip (FC-3). M MUST NOT retry/force past a rejected lease.
- Invariant (**D-301**, INV-2): freshness is enforced by the **VCS primitive**,
  not M-side timing (HR-1, `[C205]`).

### B5: Merge Authority (C5) ↔ Toolchain (G, *cited SPEC-FACTORY-GATE*)

- `health_recipe/1 :: (lang) -> {:ok, recipe}` (adapter **data** only);
  `judge_health/1 :: (report) -> :green | {:red, report}` (**engine** judges).
- For the bootstrap toolchain the recipe is `mix compile --warnings-as-errors`
  + `mix test`, run in an isolated workspace on the batch **tip**, **pre-push**.
- Invariant (**D-303**, INV-4; health-recipe ownership cited from
  SPEC-FACTORY-GATE): a buggy/adversarial adapter cannot fake `:green` — M runs
  and judges the artifact (HR-3, FC-5, `[C208]`).

### B6: Merge Authority (C1) ↔ Coordinator (K, *cited SPEC-FACTORY-CORE*)

- `escalate(:"E-RED-MAIN")` (global) on a **post-merge** red `main` re-check —
  the standing backstop for an accumulation a stateless per-PR gate cannot catch
  (`factory-loop.md` cycle 8d). A red **batch tip** is ejected pre-push (B5,
  bisect); E-RED-MAIN is reserved for a post-merge main re-check.
- Post: `□ red(main) → ¬∃ d. merge(d)` until an operator clears it; `main` left
  red and named (`[C209]`).

### B7: Non-M actor ↔ `origin/main` (*cited SPEC-FACTORY-GOV/D-319*)

- `classify_main_write/1 :: (actor) -> :ok | {:escalate, :"E-DESTRUCTIVE"}`;
  `actor ≠ :merge_authority` ⇒ escalate, **never** auto-execute (INV-20).
- The self-host bootstrap pushes **through M** like any unit — it is not
  privileged; a bypass would be the one writer M cannot see, breaking INV-2 for
  every concurrent unit (`[C200]`).

### B8: Merge Authority (C1) ↔ observers

- Paired `[:tau, :factory, :merge, …]` spans (`*.start`/`*.stop`/`*.exception`):
  `:attempt`, `:cas`, `:commit`, `:reject`, `:health`, `:bisect`, `:queue`. The
  `:queue` span's `max_restale_count` / `max_wait_ms` are the **live
  falsification test for LIV-2** (an unbounded climb is starvation surfacing).
  Spans also feed the `T_int` model the §sizing rule depends on — measurement is
  a binding input, not optional instrumentation.

### B9: Merge Authority COMMIT (C1) ↔ Ledger merge-outcome write (*D-355, PR #465*)

- `record_merge_outcome/2 :: (ledger, attrs) -> {:ok, ref}` — append-only row in
  `merge_outcomes`; WAL-before-ack (D-315 / RPO=0). `attrs` carries `:unit_id`,
  `:outcome` (`:merged`), `:commit_sha` (the landed tip), `:reason` (`nil` for
  `:merged`), `:run`.
- **Ordering constraint (D-355):** M appends the durable outcome row **BEFORE** the
  ephemeral `telemetry(:merged, …)` projection fires. Telemetry/PubSub is a derived
  projection of the durable row — not the primary decision record.
- Pre: `cas_push` returned `:ok` (the ref advanced atomically).
- Post: the outcome row is WAL-committed and readable via
  `Ledger.Reader.merge_outcome_for/2` by the time any observer receives the
  telemetry projection (WAL-before-ack: `GenServer.call` reply arrives only after
  `step/2` returns).
- Invariant (**D-355**, durable-merge-outcome): every landed merge is recorded in L
  before its ephemeral projection fires; the outcome survives the producer's death
  (RPO=0). Enforced by `merge_outcome_durability_test.exs` — oracle-separated gating
  test; PR #465.

## 5. State enumeration

### Merge Authority (M) — `gen_statem`, `state_functions`

| State | Meaning | Entry | Exit |
|-------|---------|-------|------|
| `:idle` | Accept submissions; assemble the next train; handle revocation notices | start (rebuild train+queue from L); commit/requeue done | non-empty green batch → `:integrating` |
| `:integrating` | Monitored `Task` runs `rebase → gate → health` **off the mailbox**; M still accepts submissions for the *next* train but starts no second train (INV-3) | a green batch assembled, `base` captured | `Task {:built,…}` → `:committing`; `{:build_failed, :health_red}` → `:idle` (bisect/eject); `:DOWN` → `:idle` (requeue); `:state_timeout` → `:idle` (requeue wedged build) |
| `:committing` | **Short** critical section: `assert_all_verdicts_live` (re-read latest, HR-2) then `cas_push` (`--force-with-lease`, HR-1) | `Task` returned `:built` | push `:ok` → `:idle` (commit, broadcast `:merged`); `{:error, :stale_ref}` → `:idle` (requeue all); `{:revoked, u}` → `:idle` (eject `u`, retry rest) |

```
:idle ──assemble──▶ :integrating ──Task :ok──▶ :committing ──push ok──▶ :idle
   ▲                    │  │                         │
   │   request_merge ───┘  │ {:build_failed}/:DOWN   │ stale_ref / verdict_revoked
   │   (queued, async)     ▼  /:state_timeout         ▼
   └───────────── bisect / requeue / eject ◀──── requeue / eject ───────┘
```

Illegal transitions are **unrepresentable** (no clause): `:idle → :committing`
directly cannot happen — no diff reaches a push without passing through a built,
re-validated train (INV-1). The build **never** runs in a `handle_call`; it is
always the off-mailbox `Task` (`[C203]`). `:committing` is always short
(milliseconds): no gate, no health, no rebase happens there.

### The merge-train batch lifecycle

```
submitted(green) ─enqueue→ wait-queue (FIFO + aging by restale_count)
  assemble(B)  → train [u1..uB], base = head(origin/main)         (:integrating)
  rebase_train → tip ; gate_batch_tip(tip) ; health_check(tip)    (off-mailbox Task)
    health RED → bisect(train) → eject culprit (→ U refines) → re-integrate rest
    Task :ok   → :committing:
       assert_all_verdicts_live(train):
         {:revoked,u} → eject u, retry rest         (FC-4 — value-staleness)
         :all_pass    → cas_push(tip, base):
            :ok        → COMMIT: record_merge_outcome(L) WAL-before-ack (D-355);
                         PubSub.broadcast("factory:pr:#{id}", {:merge_result, :merged}) ∀ member (D-356); advance origin/main
            :stale_ref → requeue all, rebase onto new head, re-gate  (FC-3 — TOCTOU)
  post-merge main re-check RED → E-RED-MAIN (global halt; main left red, named)
```

On every **terminal rejection** of a train member (verdict-revoked, build-failed
health-RED eject, task-down/wedged requeue exhausted to an eject, stale-ref) M
likewise broadcasts `{:merge_result, :rejected}` to `"factory:pr:#{id}"` for the
affected member(s) (D-356). A `:rejected` re-gates at U (INV-2); a member only
*requeued* (e.g. `:stale_ref` for a later rebase attempt) is **not** a terminal
rejection and is not yet published — U keeps awaiting. The broadcast is the
authoritative async result the arch's `control-plane.md` §5 names; the
`[:tau, :factory, :merge, …]` telemetry remains a *derived observer projection*
(§4 B8), never the control-path delivery.

The tip is gated as **one diff**, so INV-1..3 hold over the *combination*: a
batch of individually-green units whose **combination** breaks a test is caught
by the tip health check, then bisected (`O(log B)`) and the culprit ejected — it
never lands. Aging guarantees a re-staled large branch is eventually trained
ahead of newcomers (LIV-2).

### Escalation reasons M raises

| `e` | Trigger | Scope | Owner |
|-----|---------|-------|-------|
| `E-RED-MAIN` | post-merge `main` health red | global | this SPEC (D-303) |
| `E-DESTRUCTIVE` | non-M `origin/main` write attempt | per-action | *cited GOV/D-319* |

`E-CONFLICT` (unresolvable rebase) is raised by U on a rejected/looping rebase,
not by M; M's `:stale_ref` path is an ordinary requeue, not an escalation.

## 6. D-NNN invariants

> Owned by this SPEC. Each names its detection method. Cited D-NNN (D-335 verdict
> immutability; D-306 / Toolchain health from gate; D-319 destructive) are
> enforced by their owner SPEC and only *consumed* here.

**D-300 — Gate-before-merge, final enforcer (INV-1):**
A diff `d` lands on `origin/main` only if, **at the merge instant inside
`:committing`**, M re-reads the **latest** verdict for `hash(d)` from L and it is
`{:pass, run}` for every train member. A verdict that flipped PASS→FAIL on the
same hash (challenge / late incomplete-fix finding) is read as `{:revoked, _}`
and halts the commit **before any push** (HR-2, FC-4). This relies on the
verdict store being append-only and immutable (**D-335**, cited). Enforced by
`merge_verdict_revoke_test.exs`: a green verdict is superseded by an appended
revoke *after* the build starts; assert no push occurs and `merge_rejected(unit,
:verdict_revoked)` fires. Traceability: "no `main` commit lacks a PASS
verdict@hash; mutation: drop the verdict read ⇒ test fails."

**D-301 — Freshness via the VCS primitive (INV-2):**
The CAS apply is `git push --force-with-lease=refs/heads/main:<expected-old-oid>
origin <tip>:refs/heads/main`, where `expected-old-oid = base(d)` is the
`origin/main` head the gate ran against. The remote performs the compare-and-set
**atomically**; a lease rejection (`origin/main` advanced since the gate) yields
**no merge** — requeue, rebase, re-gate the new tip. There is no M-side
read-then-push window (HR-1, FC-3). Enforced by an integration test
`merge_force_with_lease_test.exs`: advance `origin/main` (via M, the sole writer)
between gate and CAS; assert the push is rejected and no merge lands.

**D-302 — Serialized merge via a single `gen_statem` (INV-3):**
At most one `:integrating` train exists at a time, and the `cas_push` runs in the
single M process — so commits are serialized by construction (no lock, no lease).
The multi-minute build runs **off the mailbox** in a monitored `Task`;
`request_merge` is non-blocking. Enforced by a concurrency stress test
`merge_serialized_test.exs`: submit N concurrent `request_merge`; assert `□ |{d :
merging(d)}| ≤ 1` (instrument the `:integrating`-enter count) and that no
submitter's call blocks for `T_int`.

**D-303 — Main health gates the merge precondition (INV-4):**
The combined health check runs on the batch **tip pre-push, inside the
`:integrating` Task, off M's mailbox**, language-agnostically via the Toolchain
behaviour (recipe is adapter data; **M judges** — a bad adapter cannot fake
`:green`, HR-3/FC-5). A red tip is **bisected and the culprit ejected before any
push** — it never lands. A **post-merge** red `main` re-check raises
`E-RED-MAIN`, gates the precondition closed (`□ red(main) → ¬∃ d. merge(d)`), and
halts the loop with `main` red and named. Enforced by `merge_health_test.exs`: a
red batch tip ⇒ bisect + eject, no push; a post-merge red main ⇒ `E-RED-MAIN` +
no further push. (Health-recipe ownership cited from SPEC-FACTORY-GATE.)

**D-355 — Durable merge outcome, WAL-before-ack (RPO=0):**
Every successfully-landed merge is recorded in a durable, append-only
`merge_outcomes` row in L (via `Ledger.Writer.record_merge_outcome/2`,
WAL-before-ack, D-315) **before** the ephemeral `telemetry(:merged, …)`
projection fires. The row survives the producer (MergeAuthority) dying — RPO=0.
`Ledger.Reader.merge_outcome_for/2` returns `{:merged, commit_sha}` from this
row, enabling U to reconcile on resume without re-submitting an already-landed
merge (D-344 / PR #465). Owned by this SPEC (§4 B9); cited by
SPEC-FACTORY-CORE (Unit `:awaiting_merge` reconcile, D-344 amendment).
Enforced by `merge_outcome_durability_test.exs` (oracle-separated; the
MergeAuthority/Unit gating test for PR #465).

**D-356 — Merge-result PubSub delivery, M's emission half (the async result
plane):**
On every **terminal** outcome of a train member, M broadcasts
`{:merge_result, :merged}` (on `cas_push` `:ok`, ∀ member) or
`{:merge_result, :rejected}` (on any terminal rejection of a member: verdict-
revoked eject, health-RED eject, exhausted requeue, or other non-requeue reject)
to PubSub topic `"factory:pr:#{id}"` on the shared `Tau.PubSub` instance. This is
the **authoritative async result-delivery** the arch names
(`control-plane.md` §5 *U → M `request_merge` ; M → U `merge_result`* edge; merge-
and-integration.md *“learns the outcome via a `pr:#{id}` PubSub event”*) and the
§4 B1/B8, §3 `[C206-B1]` contract. The `[:tau, :factory, :merge, …]` telemetry is
a **derived observer projection** (§4 B8), never the control-path delivery; a
driver-side telemetry→Unit bridge that re-derives the result is **forbidden** (it
re-creates an at-most-once-without-replay hazard between M's emit and U's
subscription, closed only by the subscribe-before-request ordering owned by
SPEC-FACTORY-CORE **D-356**, U's consume half). A `:merged` lands at the U
`merged` terminal; a `:rejected` re-gates at U (INV-2). On `:merged` M MUST
record the durable outcome (D-355) **before** the broadcast (the broadcast is the
ephemeral projection of the durable row, WAL-before-ack). Enforced by
`merge_result_pubsub_test.exs` (oracle-separated; asserts a real `request_merge`
on M produces a `{:merge_result, _}` on `"factory:pr:#{id}"` and **no** driver
bridge mediates it). *Counterpart to SPEC-FACTORY-CORE D-356 (U subscribe-before-
request); the two halves share the identifier — one invariant, two enforcers.*

**D-341 — Fair merge progress, no starvation (LIV-2):**
M serves merge-ready units from a **FIFO + aging** wait-queue;
`effective_priority(seq, restale_count) = seq − aging_weight · restale_count` is
monotone, so a unit re-staled `k` times is admitted to the train ahead of
newcomers after bounded re-stales. With aging, `green(d) ∧ fresh(d) ↝ ◇ merge(d)`
holds under the many-small-PR workload pure FIFO falsifies (Q-L1). Enforced by a
property test `merge_queue_property_test.exs` (tagged `:property`): no unit's wait
under a fair adversarial submit stream exceeds the aging bound; the live
`:queue` telemetry `max_restale_count`/`max_wait_ms` are the runtime
falsification watch.

## 7. Acceptance criteria

Each is expressed against an observable signal. PR groupings are indicative.

- **AC-1 (PR-MERGE-1):** `mix compile --warnings-as-errors` passes with
  `Tau.Factory.MergeAuthority` + `Merge.{Train, Cas, Queue, Health}` present;
  `Tau.Factory.Supervisor` starts M (and `MergeTasks` `Task.Supervisor`) under
  `Tau.Application`. Signal: `mix test` boots the tree with M `:idle`.
- **AC-2 (PR-MERGE-2, D-302):** `mix test
  test/tau/factory/merge_serialized_test.exs` passes — N concurrent
  `request_merge` submissions; at most one `:integrating` train exists at any
  instant, and no submitter's `call` blocks for `T_int` (`request_merge` returns
  `:queued` immediately). Signal: the `:integrating`-enter overlap count is ≤ 1.
- **AC-3 (PR-MERGE-2, D-300):** `merge_verdict_revoke_test.exs` passes — a
  verdict revoked **after** the build starts is re-read in `:committing`; assert
  **no push** and `merge_rejected(unit, :verdict_revoked)`. The post-green
  revocation ⇒ no merge (the HR-2 value-staleness contract).
- **AC-4 (PR-MERGE-3, D-301):** `merge_force_with_lease_test.exs` passes —
  `origin/main` advancing mid-gate ⇒ the `--force-with-lease` push is **rejected**
  and **no merge** lands; the unit requeues to rebase + re-gate. Signal: the CAS
  span records `:stale_ref` and `origin/main` is unchanged by the rejected push.
- **AC-5 (PR-MERGE-3, D-303):** `merge_health_test.exs` passes — a **red batch
  tip** is bisected, the culprit ejected, and the rest re-integrated, never
  landing the red tip; a **post-merge red `main`** raises `E-RED-MAIN`, gates the
  precondition closed, and halts with `main` red and named.
- **AC-6 (PR-MERGE-4, D-341):** `mix test --only property` passes including
  `merge_queue_property_test.exs` — under an adversarial small-PR submit stream
  no unit's wait exceeds the aging bound (FIFO+aging; `green ∧ fresh ↝ ◇ merge`).
- **AC-7 (PR-MERGE-4, B7/INV-20):** `merge_sole_writer_test.exs` passes — a
  simulated non-M `origin/main` write is classified `{:escalate, :"E-DESTRUCTIVE"}`
  and **not** auto-executed; M remains the only path that advances `origin/main`.
- **AC-8 (meta):** the gating tests above run in CI as a blocking job; the
  `[:tau, :factory, :merge, :queue]` `max_restale_count`/`max_wait_ms` telemetry
  is asserted present (the LIV-2 live watch).
  *(meta — verified by CI wiring; exempt from the unit-test-linkage check.)*
- **AC-9 (PR-MERGE-5, end-to-end / substance):** M integrates one real green
  unit from `request_merge` to a landed `origin/main` commit on the self-hosting
  Elixir toolchain — re-read verdict live, `--force-with-lease` push, post-merge
  health green — **no human in the loop**. Signal: the exact `request_merge`
  call, the observable merged commit SHA on `main`, and the green
  `[:tau, :factory, :merge, :health]` span (the dogfood proof). *This AC depends
  on SPEC-FACTORY-{CORE,GATE} landing; it is the integration gate, not a
  MERGE-only unit.*

## Appendix B — Source map

Files that bring a PR into scope of this SPEC (`D-NNN`/`C-N` → file:symbol):

- `lib/tau/factory/merge_authority.ex` (C1; D-300, D-301, D-302, D-303, D-341,
  D-355, D-356 — the `gen_statem`, `:idle`/`:integrating`/`:committing`; D-356
  PubSub broadcast of `{:merge_result, _}` to `"factory:pr:#{id}"` on every
  terminal member outcome) — PR-MERGE-1..5/PR#465/PR#477
- `test/tau/factory/merge_result_pubsub_test.exs` (D-356 emission gating test) — PR#477
- `lib/tau/factory/ledger/migrations.ex` (D-355 migration `20260612_010_merge_outcomes`) — PR#465
- `lib/tau/factory/ledger/writer.ex` (D-355 `record_merge_outcome/2`,
  `merge_outcome_for/2`) — PR#465
- `lib/tau/factory/ledger/reader.ex` (D-355 `merge_outcome_for/2` projection) — PR#465
- `lib/tau/factory/unit.ex` (D-355/D-344 reconcile-on-entry in `:awaiting_merge`) — PR#465
- `test/tau/factory/merge_outcome_durability_test.exs` (D-355/D-344 gating test) — PR#465
- `lib/tau/factory/merge/train.ex` (C2; assemble/bisect, D-303 tip) — PR-MERGE-3
- `lib/tau/factory/merge/cas.ex` (C3; `assert_all_verdicts_live` + `cas_push`,
  D-300, D-301) — PR-MERGE-2/3
- `lib/tau/factory/merge/queue.ex` (C4; FIFO+aging, D-341) — PR-MERGE-4
- `lib/tau/factory/merge/health.ex` (C5; Toolchain-judged health, D-303) — PR-MERGE-3
- `lib/tau/factory/supervisor.ex` + `lib/tau/application.ex` (M + `MergeTasks`
  `Task.Supervisor` in the `rest_for_one` spine) — PR-MERGE-1
- `test/tau/factory/merge_serialized_test.exs` (D-302) — PR-MERGE-2
- `test/tau/factory/merge_verdict_revoke_test.exs` (D-300) — PR-MERGE-2
- `test/tau/factory/merge_force_with_lease_test.exs` (D-301) — PR-MERGE-3
- `test/tau/factory/merge_health_test.exs` (D-303) — PR-MERGE-3
- `test/tau/factory/merge_queue_property_test.exs` (D-341) — PR-MERGE-4
- `test/tau/factory/merge_sole_writer_test.exs` (B7/INV-20) — PR-MERGE-4

**Cross-SPEC boundaries (cited, not owned here):** B1 → `SPEC-FACTORY-CORE`
(U/`request_merge`, B6 there); B3 → `SPEC-FACTORY-CORE` D-335 (verdict
append-only immutability — the read M depends on); B5 → `SPEC-FACTORY-GATE`
(D-306; Toolchain health recipe / `D-303`-health-via-Toolchain); B7 →
`SPEC-FACTORY-GOV` (`E-DESTRUCTIVE`, D-319).

**Catalog registration required before first implementation PR:** add
`SPEC-FACTORY-MERGE` to `.claude/rules/spec-before-code.md` (catalog) and the
`D-NNN` block table in `docs/MISSION.md` (D-300, D-301, D-302, D-303, D-341 →
this SPEC).
