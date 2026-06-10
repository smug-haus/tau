---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/5
revision_triggered: none
---

# Validation: Bind the Finch name, make the embedding pipeline self-healing, observable, and recoverable

## Overview

The root solution is a non-leaf synthesis composing four validated child
solutions into a single coherent change set landed across **three sequenced
PRs**. As a non-leaf validation, this document focuses on the cross-cutting
integration claims that only exist at the synthesis level — claims the child
validations could not have evaluated because they each saw only one layer.
Seven such propositions are extracted from the Recommendation, Composition
rationale, What changes, and Migration sketch sections. Each receives a full
six-component Toulmin treatment with a named falsification strategy. Six
withstand; one (Claim 5 — the *acceptance-criterion conjunction* claim that
the composed PRs together satisfy the parent AC) is **partially falsified**
because the conjunction has a sequencing dependency on PR-1 reaching
production *before* downstream observability/retry telemetry becomes
meaningful, and on the implementer correctly resolving the
behaviour-vs-sweeper contract overlap noted in the composition rationale.
The qualifier on Claim 5 is narrowed in place; no proposer/selector re-run
is required because the narrowing matches the solution's own Migration
sketch and Open questions sections. All child-level qualifier narrowings
(notably retry-recovery-path Claim 4 — dangling `memory_vec` row on
delete-during-retry — and silent-failure-propagation Claim 4 — the
mis-named `memory_store.ex` path) are surfaced as Outstanding doubts so the
parent solution inherits the right caveats.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This validation enforces all six components explicitly with prompts to
counter that variance.

### Claim 1: The four child solutions compose directly, with no conflict to resolve, because the decomposition was layered and the layers stack without overlap.

- **Claim (C):** "The four child solutions compose **directly**; there is no
  conflict to resolve. … No child solution is in tension with another. The
  decomposition was layered (one concern per layer); the layers stack
  without overlap." (`solution.md` §Composition rationale.)
- **Grounds (G):**
  - `problem.md` §Decomposition strategy partitions the failure surface
    into four "mutually exclusive (a concern belongs to exactly one layer)
    and collectively exhaustive" layers: configuration wiring, crash-to-
    callback propagation, observability of pending rot, retry/recovery.
  - The four child solutions touch disjoint primary surfaces:
    finch-name-mismatch owns `lib/tau/providers/config.ex` (new) +
    `lib/tau/application.ex:78` + `lib/tau/memory/embedding_worker.ex:106`
    default; silent-failure-propagation owns `lib/tau/memory/embedder.ex`
    callback shape + `Store.SQLite` state/handle_info/handle_continue
    bodies + `EmbeddingWorker.embed_async/1`; pending-rot-observability
    owns a new `handle_info(:check_pending_age, ...)` clause and three
    private module attributes inside the same `Store.SQLite`; retry-
    recovery-path owns a new `RetrySweeper` module, a new
    `Store.SQLite.list_retriable/1` public function and a new
    supervisor child.
  - Three child validations each ran the relevant child-level
    consistency check (`finch-name-mismatch/validation.md` Claim 4
    "No other files require updating" — withstood;
    `silent-failure-propagation/validation.md` cross-claim consistency
    section — no tension; `pending-rot-observability/validation.md`
    Claim 2 "no `handle_info` conflict" — withstood;
    `retry-recovery-path/validation.md` Claim 3
    "list_retriable/1 is additive only" — withstood).
- **Warrant (W):** A decomposition whose parts are MECE (mutually
  exclusive, collectively exhaustive) at the failure-layer level
  produces sub-solutions whose primary write surfaces are disjoint by
  construction; disjoint primary surfaces cannot conflict structurally.
  Hickey: "compose simple parts" — when the parts were themselves
  decomposed not to overlap, composition is concatenation. (See
  `problem.md` §Decomposition strategy text claiming MECE.)
- **Qualifier (Q):** Holds for the *primary* surfaces. Two child
  solutions (silent-failure-propagation, pending-rot-observability,
  retry-recovery-path) all touch the single file
  `lib/tau/memory/store/sqlite.ex` for different reasons; "no conflict"
  applies to clauses/functions, not to file-level commit overlap. A
  PR-2 that lands the handle_info-restructure of silent-failure-
  propagation and the new `handle_info(:check_pending_age, ...)` of
  pending-rot-observability simultaneously is by construction a single
  PR — which is exactly what the Migration sketch prescribes. Two
  *concurrent* PRs touching `Store.SQLite` would conflict at the
  factory-loop conflict check (`.claude/rules/factory-loop.md` §"The
  conflict check" clause 3 — disjoint codepoints).
- **Rebuttal (R):** Two child solutions reference the same callback
  contract from different perspectives — silent-failure-propagation
  *defines* `embed_async/1`, while retry-recovery-path was authored
  against the still-live `embed/3` and the synthesis text re-points it
  at `embed_async/1`. This is contract reuse, not contract conflict
  (Claim 4 below addresses it directly), but it is a load-bearing
  reconciliation that the implementer must execute. It is not a
  "stacking without overlap" property at the contract level.
- **Backing (B):** OTP non-negotiable #1
  (`.claude/rules/otp-non-negotiables.md`): stateful subsystems run as
  supervised processes, naturally producing disjoint primary write
  surfaces. `factory-loop.md` §"The conflict check" clauses 2 and 3
  (disjoint files, disjoint codepoints) — the rubric against which
  PR-level conflict is judged.

#### Falsification attempt for claim 1

- **Strategy:** Integration check — enumerate the union of file paths
  touched by all four child solutions, find overlaps, and ask whether
  any overlap produces a structural conflict the synthesis text fails
  to resolve.
- **Attempt:** The union, taken from each child's "What changes" plus
  the parent synthesis "What changes":
  - `lib/tau/providers/config.ex` (new) — finch-name-mismatch only.
  - `lib/tau/application.ex` line 78 — finch-name-mismatch only.
  - `lib/tau/memory/embedding_worker.ex` — finch-name-mismatch (line 106
    default) AND silent-failure-propagation (replace `embed/3` body with
    `embed_async/1` impl). Two distinct edits to the same file but at
    distinct regions (one default argument; one whole function body).
    Synthesised: PR-1 ships the default change; PR-2 ships the body
    change. No collision.
  - `lib/tau/memory/embedder.ex` — silent-failure-propagation only
    (callback declaration change).
  - `lib/tau/memory/store/sqlite.ex` — silent-failure-propagation AND
    pending-rot-observability AND retry-recovery-path
    (`list_retriable/1` addition). Three contributors. Synthesis maps
    them: PR-2 lands silent-failure + pending-rot together; PR-3 adds
    `list_retriable/1`. The Migration sketch explicitly bundles the
    overlapping concerns into one PR to avoid intermediate state. No
    collision.
  - `lib/tau/memory/supervisor.ex` — retry-recovery-path only (one new
    child entry).
  - `test/...` — each child adds disjoint test files.
- **Outcome:** withstood at the structural level. The overlap on
  `Store.SQLite` is real but the synthesis text recognises it and
  responds by bundling overlapping concerns into one PR (PR-2). The
  "no conflict" claim survives because the synthesis text and the
  Migration sketch together resolve the overlap into a sequencing
  prescription.
- **Action:** none.

### Claim 2: The three PRs MUST land in the order PR-1 → PR-2 → PR-3; that ordering is mechanically necessary, not stylistic.

- **Claim (C):** "Land the wiring fix first. … PR-2 is the largest of the
  three; review is manageable because the changes are localised. …
  The sweeper invokes the PR-2 `embed_async/1` contract, so PR-3
  depends on PR-2 having landed." (`solution.md` §Migration sketch.)
- **Grounds (G):**
  - PR-1 ships `Tau.Providers.Config.finch_name/0` and re-points
    `application.ex:78` and `embedding_worker.ex:106` default. The
    default at line 106 is `Tau.Finch` today, which does not name a
    registered pool (`finch-name-mismatch/validation.md` Claim 1 —
    withstood). Without PR-1, every embedding HTTP call crashes with
    `:noproc` and never reaches the path PR-2 and PR-3 instrument.
  - PR-2 introduces the `embed_async/1` callback and restructures
    `Store.SQLite` around `pending_tasks: %{reference() => String.t()}`
    plus symmetric `handle_info` clauses for `{ref, result}` and
    `{:DOWN, ref, ...}`. PR-2 also lands the observability timer.
  - PR-3's `RetrySweeper` re-invokes the embedder. The composition
    rationale §2 specifies the sweeper re-invokes `embed_async/1`
    (not the now-removed `embed/3`), routing the resulting Task ref
    through the same `pending_tasks` map and the same `handle_info`
    clauses as the primary write path. PR-3 is dead code without
    PR-2's contract change in place.
- **Warrant (W):** A change set in which Step B refers to symbols
  introduced by Step A creates a *compile-time and runtime
  precondition* — Step B will not compile, or will reach a dispatch
  with a missing callback, if Step A has not landed. The MECE-by-
  layer decomposition pre-supposes this ordering because the layers
  are themselves nested causally: wiring is upstream of crash
  propagation, which is upstream of observability and retry.
- **Qualifier (Q):** Holds for the "factory-loop serialised merge"
  model in `.claude/rules/factory-loop.md` §"Gate and merge under
  concurrency" ("**Merges are serialized** — one PR at a time"). If
  PR-1, PR-2, PR-3 were merged out of order under a hypothetical
  parallel-merge regime, the system would briefly compile but
  exhibit the silent-failure behaviour (PR-3 before PR-2) or remain
  fully broken (skip PR-1).
- **Rebuttal (R):** A reviewer might object that PR-1 is theoretically
  not strictly required before PR-2 — PR-2 plus a manual
  `Application.put_env(:tau, :finch_name, Tau.Providers.Finch)` in
  config would also make the pipeline live. But: no such config
  override exists in the repository today (verified by
  `finch-name-mismatch/validation.md` Claim 1 — "`grep -rn
  "finch_name" config/` returns empty output"); shipping PR-2 first
  would mean every smoke run of the embedding path remained broken
  until either PR-1 or such a config landed. The mechanical PR
  ordering is the only one that delivers a working system at each
  intermediate merged state.
- **Backing (B):** `.claude/rules/factory-loop.md` §"Pre-merge
  freshness re-check" (a PR must be re-gated against current
  `origin/main` before merge, so an out-of-order merge would fail
  the freshness check or the post-merge `main` health check at
  cycle step 8d). `.claude/rules/spec-before-code.md` §"What this
  rule requires" — a PR adding new state to a SPEC'd boundary must
  pair with the §3 amendment in the same PR; this rule reinforces
  the bundling of overlapping concerns into PR-2.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — try to construct a
  merge order other than PR-1 → PR-2 → PR-3 that produces a working
  acceptance-criterion-satisfying system at every intermediate
  `main` state.
- **Attempt:** Three permutations besides the canonical one:
  - PR-2 → PR-1 → PR-3: after PR-2 lands, the contract change is
    live, but `embedding_worker.ex` is still defaulting Finch name
    to the unregistered `Tau.Finch`. Every embedding still crashes
    at the HTTP boundary. The observability timer will fire
    detecting stale `"pending"` rows, but the AC's "reaches `ready`
    or `failed` with actionable signal" is satisfied only by the
    `"failed"` transition — and PR-2's crash propagation will
    correctly mark them `"failed"`. *Curious*: this permutation
    *does* satisfy the AC for new writes, because PR-2's crash
    propagation works even when the underlying call is doomed.
    But pre-existing `"pending"` rows are not retried until PR-3
    lands. So PR-2 → PR-1 satisfies the AC in a degraded sense.
    Not strictly forbidden; the synthesis prescribes the safer
    order to minimise the window in which the acceptance criterion
    is in its degraded-but-satisfied form.
  - PR-3 → PR-2 → PR-1: PR-3 references `embed_async/1`, which
    does not exist before PR-2. PR-3 will not compile. Falsifies
    this permutation.
  - PR-1 → PR-3 → PR-2: PR-3 references `embed_async/1` and
    `list_retriable/1`. The contract does not exist; the sweeper
    cannot call `embed_async/1`. Falsifies this permutation.
  - PR-2 → PR-3 → PR-1: PR-2 lands, contract live, observability
    firing. PR-3 lands, sweeper re-dispatches via `embed_async/1`
    but every call crashes (Finch name still wrong). The
    `RetrySweeper` is now generating telemetry storms of stuck-
    pending retries. PR-1 finally lands and the pipeline becomes
    healthy. This permutation works but is operationally noisy.
  - **Conclusion**: PR-3 cannot land before PR-2 (compile failure).
    PR-2 → PR-1 and PR-2 → PR-3 → PR-1 *technically* work but are
    degraded. PR-1 → PR-2 → PR-3 is the only permutation that
    delivers a strictly-improving system at each intermediate
    merge.
- **Outcome:** withstood — the canonical ordering is the only one
  delivering a strictly-improving system at every intermediate
  state. Other orderings either fail to compile or pass through a
  degraded state.
- **Action:** none. The synthesis text already states the ordering
  as a hard prerequisite, not a preference.

### Claim 3: PR-2 must bundle the silent-failure-propagation and pending-rot-observability changes together to avoid an intermediate state where the observability timer fires against a Store whose crash path is still broken.

- **Claim (C):** "These two child solutions both modify
  `lib/tau/memory/store/sqlite.ex` and must land together to avoid
  an intermediate state where the observability timer fires against
  a Store whose crash path is still broken." (`solution.md`
  §Migration sketch, PR-2 description.)
- **Grounds (G):**
  - pending-rot-observability's `handle_info(:check_pending_age,
    ...)` queries for `embedding_status = 'pending'` rows older
    than `@stale_threshold_ms = 35_000` ms
    (`pending-rot-observability/solution.md` §What changes).
  - silent-failure-propagation's intent is to transition crashed
    Tasks' entries from `"pending"` to `"failed"` so they never
    remain `"pending"` permanently
    (`silent-failure-propagation/solution.md` §Recommendation).
  - If observability ships standalone before silent-failure: every
    crash leaves an entry `"pending"`; the timer reports them all
    as "stale rot" within 35 s. Operators see telemetry storms with
    no actionable remediation (the entries will *never* transition
    to `"failed"` on their own).
  - If silent-failure ships standalone before observability: crashes
    are correctly marked `"failed"`; there is simply no telemetry
    for the rare residual stuck-`"pending"` (e.g. a Store crash
    losing the ref-map mid-flight). This is a smaller defect.
- **Warrant (W):** A telemetry signal is only actionable if there is
  a path to remediation; firing telemetry about a condition the
  system cannot resolve creates alert fatigue and operator
  confusion. Pairing them in one PR ensures the signal-vs-
  remediation relationship is intact at every merged `main` state.
- **Qualifier (Q):** "Must land together" applies to PR-grain
  bundling. Within PR-2, the commits may land in any internal
  order — the gate runs against the cumulative diff, not commit-by-
  commit. The serial-merge invariant
  (`.claude/rules/factory-loop.md`) means PR-2's diff is atomic at
  the `main` level.
- **Rebuttal (R):** A reviewer might argue that the alert fatigue
  is a soft cost and the bundling is therefore a stylistic
  preference, not a hard requirement. But the post-merge `main`
  health check (cycle step 8d) checks compile + test; a PR-2
  bundling that leaves a regression in either fails the health
  check and halts the loop. Splitting them invites a halt on a
  cosmetic regression in noisy telemetry — fixable but
  operationally costly.
- **Backing (B):** `.claude/rules/factory-loop.md` §"What this rule
  forbids" — "MUST NOT skip the post-merge `main` health check, nor
  continue the loop on a red `main`." OTP non-negotiable #5
  ("Telemetry events MUST cover everything user-visible or
  perf-sensitive") implies the signal must be *meaningful*, not
  merely present.

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction — construct an
  intermediate state where the bundling is unnecessary.
- **Attempt:** Suppose `@stale_threshold_ms` were set to a value
  high enough that no real entry would cross it before
  silent-failure-propagation also landed. Then the intermediate
  state is innocuous because the timer never reports anything.
  Defeats the *necessity* of bundling, but only at the cost of
  making the observability inert until the second PR — a strict
  inferiority to bundling. Construction fails as a counter-example
  because it does not show that splitting is *equally good*.
- **Outcome:** withstood — the bundling is materially better than
  any splitting strategy. No counter-example produced equivalent
  quality.
- **Action:** none.

### Claim 4: The sweeper and the primary write path share the `embed_async/1` contract by design, so sweeper-dispatched embeddings get the same crash-to-`"failed"` guarantee as write-dispatched embeddings, automatically.

- **Claim (C):** "in the composed plan the sweeper invokes
  `embed_async/1` instead [of `embed/3`], routing the resulting Task
  ref through the same `pending_tasks` map and the same
  `handle_info` clauses as the primary write path. There is exactly
  one dispatch path; the sweeper and the write path differ only in
  *who* enqueues the work, not in *how* the result propagates."
  (`solution.md` §Composition rationale clause 2.)
- **Grounds (G):**
  - retry-recovery-path's own solution was authored against
    `embed/3` (still-live at the time); the synthesis re-points it
    at `embed_async/1` — explicitly named in
    `solution.md` §What changes ("`Tau.Memory.RetrySweeper`
    GenServer (~80 LOC) … re-dispatches each row via
    `Tau.Memory.Embedder.embed_async/1` through the store's
    `handle_continue({:dispatch_embedding, id, content}, state)`
    path").
  - silent-failure-propagation introduces `pending_tasks` and
    matching `handle_info` clauses (`silent-failure-
    propagation/solution.md` §What changes).
  - If the sweeper routes through `handle_continue(
    {:dispatch_embedding, id, content}, state)`, the existing
    dispatch code (the same `Task.Supervisor.async_nolink/2` +
    `put_in(state.pending_tasks[ref], id)` sequence) is reused
    verbatim, and the resulting Task ref lands in the same map
    that PR-2 introduced — so the crash propagation flows through
    the same `handle_info({:DOWN, ref, :process, _pid, reason},
    state)` clause.
- **Warrant (W):** Reusing a single dispatch path for two enqueue
  sources (primary write at `handle_continue/2`; retry sweep) is
  the OTP-correct way to inherit invariants across feature
  layers. The Store is the sole writer (OTP non-negotiable #1);
  the map is the sole tracker (OTP non-negotiable #4); the
  symmetric `handle_info` clauses are the sole observer (OTP
  non-negotiable #4 applied symmetrically per
  `silent-failure-propagation/validation.md` Claim 5 — withstood).
- **Qualifier (Q):** Holds if the implementer routes the sweeper
  through `handle_continue({:dispatch_embedding, id, content},
  state)` — i.e. the sweeper sends a cast/call to the Store that
  triggers an internal `{:noreply, state, {:continue, ...}}` —
  rather than calling `embed_async/1` directly from the sweeper
  process. The latter would land the Task ref in the *sweeper's*
  mailbox, not the *store's*, breaking the inherited guarantee.
  The synthesis text names this routing explicitly ("through the
  store's `handle_continue({:dispatch_embedding, id, content},
  state)` path"); the qualifier is the implementer following that
  routing.
- **Rebuttal (R):** A naïve implementer might invoke
  `Tau.Memory.EmbeddingWorker.embed_async(content)` directly from
  `RetrySweeper.handle_info(:sweep, ...)`. The returned Task ref
  would be owned by the sweeper's process; `{ref, result}` and
  `{:DOWN, ref, ...}` would land in the sweeper's mailbox; the
  sweeper has no `handle_info({ref, result}, state)` clause; the
  result silently disappears. The composition rationale text
  guards against this verbally but the gate (`critic` + reviewer)
  must enforce it in code review of PR-3. This is a real
  implementation hazard, not a structural defect in the
  composition.
- **Backing (B):** `silent-failure-propagation/solution.md` §What
  changes (defines the canonical dispatch via `handle_continue`).
  OTP non-negotiable #4 (cross-process events use monitored refs)
  applied to a single owning process.
  `silent-failure-propagation/validation.md` Outstanding doubt
  §"Migration order safety" — surfaces the same risk for the
  primary write path; applies symmetrically to the sweeper.

#### Falsification attempt for claim 4

- **Strategy:** Counter-example construction — try to construct a
  sweeper implementation that conforms to PR-3's stated design but
  bypasses the inherited crash-to-`"failed"` guarantee.
- **Attempt:** Three candidate sweeper implementations:
  - (a) **Specified canonical**: `RetrySweeper.handle_info(:sweep,
    ...)` invokes `GenServer.cast(Store.SQLite, {:dispatch_retry,
    id, content})`, and Store's `handle_cast` returns
    `{:noreply, state, {:continue, {:dispatch_embedding, id,
    content}}}`. The sweep's enqueued Task ref lands in Store's
    `pending_tasks` map; crash propagates to `do_mark_embedding_
    failed/3` via the existing `:DOWN` clause. AC inherited.
  - (b) **Direct-invocation antipattern**: sweeper calls
    `EmbeddingWorker.embed_async(content)` and awaits the Task
    itself. Task ref lands in sweeper mailbox. Crash invisible to
    Store. AC NOT inherited. This is a contract-violating
    implementation that the synthesis text explicitly forbids
    ("routes through the store's `handle_continue` path").
  - (c) **Hybrid**: sweeper calls `embed_async/1`, then sends
    `{:track_ref, ref, id}` to the Store, which stores it in
    `pending_tasks`. Now the Store owns the ref but not the
    monitor — `Task.Supervisor.async_nolink/2`'s monitor is set
    on the *spawning* process (the sweeper). The Store will not
    receive `{:DOWN, ref, ...}`. AC NOT inherited. Subtle and
    plausible-looking; another hazard for code review.
  - The implementation hazards (b) and (c) demonstrate that the
    composition's guarantee is *contingent on the implementer
    using path (a)*. The composition rationale text names path
    (a) directly; code review of PR-3 is the gate against (b)
    and (c).
- **Outcome:** withstood as a *design* claim — the composition's
  contract-reuse pattern is sound and named explicitly in the
  synthesis text. Partially exposed as an *implementation
  hazard* — the implementer can deviate from the named routing
  and silently lose the guarantee. The hazard belongs in the
  PR-3 critic/reviewer gate, not in the synthesis text.
- **Action:** Add to Outstanding doubts — the PR-3 critic/
  reviewer brief MUST explicitly check that the sweeper routes
  through `handle_continue({:dispatch_embedding, id, content},
  state)` rather than spawning Tasks in the sweeper's own
  process. (Per
  `silent-failure-propagation/validation.md` Outstanding doubt
  §"Migration order safety" — same shape, applied to the
  sweeper.)

### Claim 5: Together the three PRs make the parent acceptance criterion mechanically true — every entry under default configuration reaches `"ready"` or `"failed"` (with actionable telemetry) within a bounded window, with no permanent-`"pending"` failure mode remaining.

- **Claim (C):** "Together these changes make the acceptance criterion
  mechanically true: every entry under default configuration reaches
  `"ready"` or `"failed"` (with actionable telemetry) within a
  bounded window, with no permanent-`"pending"` failure mode
  remaining." (`solution.md` §Recommendation, final sentence.)
- **Grounds (G):**
  - parent `problem.md` AC: "Every memory entry written under the
    default application configuration either reaches
    `embedding_status: 'ready'` when the embedding API responds
    successfully, or transitions to `embedding_status: 'failed'`
    with an actionable log/telemetry event, within the request
    timeout window — and no entry remains permanently in
    `embedding_status: 'pending'` due to a wiring defect or silent
    crash."
  - PR-1 closes the wiring defect (finch-name-mismatch validation
    Claim 1 — withstood).
  - PR-2's crash propagation transitions crashed entries from
    `"pending"` to `"failed"` with `:transient`
    (`silent-failure-propagation/validation.md` Claim 1 — withstood).
  - PR-2's observability timer emits actionable telemetry when
    stale `"pending"` entries exist (`pending-rot-
    observability/validation.md` Claim 3 — withstood).
  - PR-3's `RetrySweeper` re-dispatches stuck `"pending"` and
    transient-`"failed"` rows, closing the loop after configuration
    fix or transient fault clearance (`retry-recovery-path/
    validation.md` Claim 1 — withstood).
- **Warrant (W):** Conjunction-of-properties: if PR-1 closes the
  *cause*, PR-2 closes the *invisibility-of-effect*, and PR-3
  closes the *non-recovery*, then the union closes the failure
  surface the AC names. The AC's three sub-claims (the entry
  reaches `"ready"` OR `"failed"`; the failure is observable; no
  permanent-`"pending"`) are independently addressed by three
  composable PRs.
- **Qualifier (Q):** *Narrowed (partial falsification below):*
  Holds **after all three PRs have landed and `Store.SQLite` /
  `RetrySweeper` survive a full sweep interval**. At each
  intermediate merged `main` state:
  - After PR-1 only: AC partially satisfied — new entries reach
    `"ready"` or crash → currently still get stuck `"pending"`
    (silent crash; AC fails).
  - After PR-1 + PR-2: AC satisfied for *new* entries (each
    crashes → `"failed"` within 30 s; observability timer fires
    within 60 s of any residual `"pending"`); AC NOT satisfied
    for pre-existing stuck rows (no retry path).
  - After PR-1 + PR-2 + PR-3: AC fully satisfied within a bounded
    window of one sweep interval (60 s default) plus the
    `@stale_threshold_ms` (35 s) plus the request timeout (30 s).
  - The "within the request timeout window" wording in the AC is
    strictly satisfied only by PR-2's crash path; PR-3 closes a
    longer window for the recovery case. The synthesis claim is
    accurate but the AC's tightest reading allows only ~30 s,
    which only PR-2 meets for fresh writes. The "bounded window"
    framing in the synthesis is a paraphrase of the AC, not a
    quotation.
  - **Implementation hazard inherited from Claim 4**: if the
    sweeper bypasses the canonical dispatch path, retry-driven
    crashes are again invisible. The AC then fails for retry-
    dispatched embeddings.
- **Rebuttal (R):** Two paths-to-permanent-`"pending"` are not
  covered:
  - (i) A Store crash between dispatch and Task completion loses
    the ref-map; the Task may still complete and its result is
    received in nobody's mailbox; the entry stays `"pending"`.
    This is named in
    `silent-failure-propagation/validation.md` Outstanding doubt
    §"Stuck-pending state lost on `Store.SQLite` crash" and is
    explicitly out of scope per parent `problem.md` Out of scope
    section ("…covered by retry-recovery-path"). PR-3's retry
    sweeper covers it as long as the timer runs.
  - (ii) `RetrySweeper` itself crashes repeatedly enough to hit
    the supervisor's `:one_for_one` intensity threshold,
    cascading the supervisor down. While this is recovered by
    the Application supervisor, during the cascade the recovery
    loop is inactive and a fresh stuck row can accumulate. This
    is the
    `retry-recovery-path/validation.md` Claim 6 rebuttal —
    "effective restart rate doubles" — not a permanent failure,
    so the AC's "no permanent" wording is preserved.
- **Backing (B):** parent `problem.md` AC (verbatim); the four
  child validations' Claim 1 outcomes (all withstood for
  finch-name-mismatch, silent-failure-propagation, pending-rot-
  observability, retry-recovery-path);
  `.claude/rules/factory-loop.md` §"Incomplete-fix detection — do
  not deflect to a follow-up" (a finding that falsifies an AC is
  the merge being incomplete) — this exact criterion is what
  this claim must satisfy.

#### Falsification attempt for claim 5

- **Strategy:** Edge-case enumeration over the AC's literal
  wording ("ready or failed with actionable telemetry, within
  request timeout, no permanent pending due to wiring defect or
  silent crash") against the post-merge state at each of PR-1,
  PR-1+2, PR-1+2+3.
- **Attempt:** Enumerated five literal AC sub-conditions against
  three merge-state snapshots (15 cells):
  - PR-1 only:
    1. reaches `"ready"` ✓ (HTTP succeeds, no callback bug yet
       fixed but the success path was already working before).
    2. transitions to `"failed"` ✗ (crash still silent).
    3. actionable telemetry ✗.
    4. within request timeout ✗ for failures.
    5. no permanent `"pending"` due to silent crash ✗.
    Result: AC NOT satisfied after PR-1 alone.
  - PR-1 + PR-2:
    1. reaches `"ready"` ✓.
    2. transitions to `"failed"` ✓.
    3. actionable telemetry ✓ (telemetry event + Logger.warning).
    4. within request timeout ✓ for fresh writes.
    5. no permanent `"pending"` ✓ for new writes; ✗ for
       pre-existing rows that were already stuck before PR-2
       shipped.
    Result: AC satisfied for new entries, partially failed for
    legacy stuck rows.
  - PR-1 + PR-2 + PR-3:
    1-5: all ✓; legacy stuck rows are swept within one interval.
    Result: AC mechanically true.
  - **Critical finding**: the synthesis claim "Together these
    changes make the AC mechanically true" is true only of the
    *terminal* state, not of intermediate states. The synthesis
    Migration sketch acknowledges the sequencing but the
    Recommendation's final sentence is silent on it. A reader
    of the Recommendation alone could conclude the AC is met by
    any individual PR.
- **Outcome:** partially falsified — the claim's *terminal-state*
  truth withstands; its *intermediate-state* truth is false at
  PR-1 and partially false at PR-1+2. The qualifier in the
  Recommendation is implicit but not explicit; the Migration
  sketch makes it explicit. Reading both, the claim is correct;
  reading the Recommendation alone, it overstates.
- **Action:** Narrow Claim 5's qualifier in place (done above).
  No solution revision required — the qualifier matches the
  Migration sketch text and the Open questions list. The
  factory-loop's incomplete-fix detection is per-PR; each
  individual PR's draft body must cite which AC sub-condition
  it advances and the gate enforces it. The narrowed qualifier
  is consistent with the per-PR gate pattern in
  `.claude/rules/factory-loop.md`.

### Claim 6: The composed plan inherits five open questions from the child solutions; none block the recommendation but each should be resolved in the implementation PR that owns it.

- **Claim (C):** "The composed plan inherits five open questions
  from the child solutions; none block the recommendation but each
  should be resolved in the implementation PR that owns it."
  (`solution.md` §Open questions opening line.)
- **Grounds (G):**
  - The Open questions section lists seven distinct items
    (despite the "five" claim) — namespace for
    `Tau.Providers.Config`, `embed_async/1` inner-Task layering,
    `{ref, result}` clause guard discipline, threshold runtime
    vs compile-time, `(embedding_status, created_at)` index,
    duplicate-embedding race, and sweeper first-fire latency.
  - The five-vs-seven discrepancy is a counting error in the
    synthesis text. Each item is a genuine inherited question,
    sourced from a specific child solution's §Open questions
    block (verified by cross-reference: 1 of 1 from finch-name-
    mismatch, 1-2 of 3 from silent-failure-propagation, 1-2 of
    3 from pending-rot-observability, 1-3 of 3 from retry-
    recovery-path).
  - Each item is named with its originating sub-problem in
    parentheses and assigned to a specific PR for resolution.
- **Warrant (W):** A non-leaf solution's Open questions section is
  the union of child solutions' open questions, filtered for those
  that the composition's specific choices affect. If composition
  resolves a child's open question, the question is dropped;
  otherwise it propagates upward.
- **Qualifier (Q):** "None block the recommendation" holds because
  each item is either a tuning parameter (intervals, thresholds,
  index) or a code-review item the gate will catch (clause guard,
  inner-Task layering, sweeper routing). The synthesis claims
  "five" but lists seven — a documentation defect, not a
  structural one.
- **Rebuttal (R):** A reviewer might object that the duplicate-
  embedding race question, paired with the parent-validator's
  finding (Claim 4 above) about sweeper-routing hazards,
  collectively rises to a *blocking* concern. Both must be
  resolved correctly in PR-3's code, not deferred. The synthesis
  text says they "should be resolved in the implementation PR
  that owns it" — which is exactly what the factory-loop gate
  enforces, so the rebuttal is procedurally addressed.
- **Backing (B):** Each child validation's Outstanding doubts
  section (the canonical upward-propagation mechanism per
  `.code_audit/skills/code-audit-polya/validate.md` §"Outputs
  that feed parent").

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — find a child open
  question that the synthesis silently dropped and that does
  affect the parent AC.
- **Attempt:** Iterate each child solution's §Open questions:
  - finch-name-mismatch: 1 of 1 surfaced.
  - silent-failure-propagation: 1 (inner-Task layering)
    surfaced; 2 (clause guard) surfaced; 3 (`{:DOWN, :normal}`
    double-cleanup) NOT surfaced — but the synthesis text
    embeds the resolution in §What changes ("Tolerates
    `Map.fetch/2` returning `:error`") inline. Dropped because
    resolved, not silently.
  - pending-rot-observability: 1 (runtime vs compile-time)
    surfaced; 2 (index) surfaced; 3 (clause name conflict) NOT
    surfaced — but `pending-rot-observability/validation.md`
    Claim 2 confirmed no conflict. Dropped because resolved
    (by validation).
  - retry-recovery-path: 1 (duplicate-embedding race) surfaced;
    2 (sweep under high write load) NOT surfaced — affects
    performance, not the AC; dropped legitimately. 3 (startup
    delay) surfaced.
  - Total surfaced: 7 (matching the actual list). The synthesis
    text's "five" is a typo or carry-over from an earlier
    revision.
- **Outcome:** withstood as to substance; the "five" vs "seven"
  count is a textual defect that does not affect correctness or
  AC satisfaction.
- **Action:** Surface the count discrepancy as an Outstanding
  doubt; not solution-revision-worthy.

### Claim 7: The decomposition's MECE-by-layer property is what makes the parent solution coherent without bespoke conflict resolution.

- **Claim (C):** "The decomposition was layered (one concern per
  layer); the layers stack without overlap." (`solution.md`
  §Composition rationale, closing sentence.)
- **Grounds (G):**
  - `problem.md` §Decomposition strategy explicitly invokes MECE:
    "The four layers are mutually exclusive (a concern belongs to
    exactly one layer) and collectively exhaustive (every aspect
    of the broken pipeline … is covered)."
  - The four layers map onto distinct phases of a single failure
    pipeline: cause (PR-1) → propagation (PR-2 part 1) →
    observation (PR-2 part 2) → remediation (PR-3). Causal
    layering, not domain layering.
  - The §Composition rationale clauses 1, 2, 3 enumerate the
    three composition interfaces and one ordering constraint —
    explicit named interfaces are the marker of layered (not
    overlapping) composition.
- **Warrant (W):** MECE decomposition is the standard
  prerequisite for additive composition; when each child solves
  one disjoint concern, the parent is the union of children
  without bespoke reconciliation. (Folk wisdom of decomposition;
  also the design-reasoning skill's PSDH method assumes layered
  decomposition for non-leaf synthesis.)
- **Qualifier (Q):** Holds for the failure-layer decomposition
  this problem uses. A different decomposition (e.g. by
  *module*: store changes, embedder changes, sweeper changes)
  would have produced overlapping primary surfaces and required
  bespoke reconciliation. The MECE-by-layer choice is what makes
  the additive composition possible — it is not a property of
  composition in general.
- **Rebuttal (R):** The decomposition is MECE *over the failure
  surface named in the problem*; it is not MECE over all aspects
  of the embedding pipeline. The Open questions and Outstanding
  doubts capture the residuals: dangling `memory_vec` rows,
  sweeper error handling, store-crash mid-flight. These are not
  in the four layers; they belong to a broader pipeline-
  resilience concern that this problem deliberately excludes
  (parent `problem.md` §Out of scope).
- **Backing (B):** parent `problem.md` §Decomposition strategy
  (verbatim MECE claim); the PSDH method described in
  `.claude/skills/design-reasoning`; the in-repo prior art —
  `docs/spec/SPEC-MEMORY-STORE.md` divides the store along
  similar invariant lines (D-045, D-046, D-047).

#### Falsification attempt for claim 7

- **Strategy:** Counter-example construction — find a concern
  that belongs to more than one layer, or one that belongs to no
  layer.
- **Attempt:**
  - Concern A: "the `embed_async/1` callback contract" — touches
    both silent-failure-propagation (defines it) and retry-
    recovery-path (consumes it). Initially appears to belong to
    two layers. On closer reading: silent-failure owns the
    *contract*; retry-recovery is a *consumer* of that contract.
    Contract ownership and contract consumption are not the same
    concern. MECE preserved.
  - Concern B: "what to do when `Store.SQLite` itself crashes
    losing the ref-map" — belongs partly to crash-propagation
    (PR-2 can't fix it) and partly to retry-recovery (PR-3
    sweep eventually catches it). Two layers contribute. Initially
    appears to violate MECE — but the problem's §Out of scope
    explicitly excludes "performance of the embedding pipeline
    under load" and the residual is more properly named "store-
    crash mid-flight resilience", which is also out of scope.
    Both children acknowledge the residual as out-of-scope; the
    boundary is correctly drawn.
  - Concern C: "duplicate embed calls from racing sweeper + write
    path" — partly silent-failure (the contract permits double
    dispatch), partly retry-recovery (the sweeper is the
    duplicate source), partly pending-rot (the timer sees the
    race window). Three layers touch it. This is the strongest
    candidate counter-example. Reading the §Composition
    rationale: clause 3 says observability and retry are
    complementary, not redundant; the duplicate-race question is
    surfaced as an Open question rather than resolved. The
    decomposition does not claim to address this; the layers
    remain MECE-as-decomposed even though the *race condition*
    spans them. MECE applies to the *layers as decompositional
    cuts*, not to *all emergent properties of the system*.
  - No concern was found that belongs to no layer or that the
    layers cannot collectively address.
- **Outcome:** withstood — MECE-by-failure-layer is correctly
  applied and the composition is additive. The residual race
  condition is named as an Open question, not silently dropped.
- **Action:** none.

## Cross-claim consistency

The seven claims form a single argumentative arc:

- Claim 1 (composition is direct) establishes the structural premise.
- Claim 7 (MECE-by-layer) explains *why* Claim 1 holds — they are
  mutually reinforcing.
- Claim 2 (PR ordering is mechanically necessary) and Claim 3
  (PR-2 must bundle two children) constrain the temporal shape of
  Claim 1's composition.
- Claim 4 (sweeper inherits crash guarantee via shared contract)
  is the load-bearing reuse that makes Claim 5's conjunction
  achievable; Claim 4 has an explicit implementation hazard
  (direct-invocation antipattern; hybrid pattern) that the
  PR-3 gate must catch.
- Claim 5 (conjunction satisfies parent AC) is the synthesis
  claim that depends on Claims 1, 2, 3, and 4; its partial
  falsification narrows to "after all three PRs land *and* the
  PR-3 sweeper routes through the store's `handle_continue`",
  consistent with all upstream claims.
- Claim 6 (open questions are inherited correctly) is procedural;
  no tension with substantive claims.

No internal tension is identified. The seven claims share a
common qualifier — the implementer follows the synthesis text's
explicit routing and ordering prescriptions, and the per-PR
factory-loop gate catches deviations.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Four child solutions compose directly, no conflict | Integration check (file union) | Withstood | None |
| 2 | PR-1 → PR-2 → PR-3 ordering is mechanically necessary | Counter-example construction (permutations) | Withstood | None |
| 3 | PR-2 must bundle silent-failure + observability | Counter-example construction | Withstood | None |
| 4 | Sweeper inherits crash guarantee via shared `embed_async/1` contract | Counter-example construction (sweeper variants) | Withstood (design); implementation hazard flagged | Add PR-3 gate check for canonical dispatch routing |
| 5 | Three PRs together satisfy parent AC mechanically | Edge-case enumeration (AC × merge-state matrix) | Partially falsified — terminal-state truth holds; intermediate-state implicit qualifier required | Narrow qualifier; no revision |
| 6 | Five inherited open questions, none blocking | Counter-example construction (per-child OQ trace) | Withstood; "five" should be "seven" | Surface count discrepancy as Outstanding doubt |
| 7 | MECE-by-layer enables additive composition | Counter-example construction (concerns across layers) | Withstood | None |

## Revision required

None. Only Claim 5 is partially falsified, and the narrowing
("terminal state after all three PRs land *and* sweeper uses
canonical routing") matches the synthesis's own Migration sketch
and Open questions. Per
`.claude/plugins/polya-audit/skills/code-audit-polya/validate.md`
§5: "Partial falsifications: narrow each claim's Qualifier in
place. No revision needed; `validation.md` records the narrowed
qualifiers and the `falsification_outcome:
partially_falsified` flag."

- **Target file:** n/a
- **Revision kind:** n/a (in-place qualifier narrowing on Claim 5)
- **Rationale:** the partial falsification of Claim 5 records an
  implementation-time discipline (routing + ordering) that the
  factory-loop gate already enforces per PR. Re-running the
  proposer/selector would not change the structural composition;
  the only correct response is the narrowed qualifier the
  synthesis text already implicitly contains.

## Outstanding doubts

These doubts are inherited from the child validations and from
this validator's per-claim falsification attempts. The root
solution's coordinator and the per-PR critic/reviewer briefs
should carry them forward.

1. **Sweeper-routing hazard (Claim 4).** The PR-3 critic/reviewer
   gate MUST explicitly check that `RetrySweeper.handle_info(
   :sweep, ...)` enqueues work via a cast/call to `Store.SQLite`
   that triggers the existing `handle_continue({:
   dispatch_embedding, id, content}, state)` path, rather than
   spawning Tasks directly in the sweeper's own process. The
   latter silently loses the crash-to-`"failed"` guarantee.
   Direct-invocation and "track-ref-after-the-fact" antipatterns
   are both plausible-looking and both wrong; the gate brief
   must name them by name.

2. **AC's intermediate-state qualifier (Claim 5).** The synthesis
   Recommendation's final sentence ("Together these changes make
   the acceptance criterion mechanically true") is true at the
   PR-1+2+3 terminal state but overstates the truth at the
   PR-1+2 intermediate state (pre-existing stuck rows remain).
   Per-PR draft bodies must cite *which AC sub-conditions* the
   specific PR advances — the factory-loop's incomplete-fix
   detection rule (`.claude/rules/factory-loop.md`) enforces
   this. PR-1 advances no AC clause to true on its own; PR-2
   advances the AC to substantial truth for new entries; PR-3
   makes it complete. The per-PR critic should not be confused
   by the Recommendation's terminal-state framing into believing
   any intermediate PR alone closes the AC.

3. **Dangling `memory_vec` row on concurrent delete-during-retry**
   (inherited from `retry-recovery-path/validation.md`
   Outstanding doubt 1). The schema does not declare a FK from
   `memory_vec(entry_id)` to `memory_entries(id)`; a sweep that
   races a delete can leave a dangling vector row. The PR-3
   implementer should either add an ON DELETE CASCADE FK or
   ensure the sweeper's enqueue path is short enough that an
   in-progress delete removes the entry from the result set
   before re-dispatch. The pre-existing nature of the
   structural debt does not absolve PR-3 — the sweeper makes
   the race reachable for the first time.

4. **`memory_store.ex` path correction inherited from
   `silent-failure-propagation/validation.md` Claim 4**: the
   `Tau.Memory.MemoryStore` referent does not exist as a
   separate file; the public `store_embedding/3` to be removed
   lives at `lib/tau/memory/store/sqlite.ex:163-167` with the
   alias `Tau.Memory.Store.SQLite, as: MemoryStore` at
   `lib/tau/memory/embedding_worker.ex:32` being the only thing
   in the repo named `MemoryStore`. The parent `solution.md`
   §What changes also lists `lib/tau/memory/memory_store.ex` —
   the implementer brief MUST use the corrected path
   `lib/tau/memory/store/sqlite.ex:163-167`.

5. **Threshold coupling between embedding timeout and stale
   threshold** (inherited from `pending-rot-observability/
   validation.md` Outstanding doubt 1). The chosen
   `@stale_threshold_ms = 35_000` is hand-tuned to exceed
   `EmbeddingWorker`'s `@request_timeout_ms = 30_000` plus a
   5 s grace. If either constant changes, both must change in
   lockstep. The synthesis Open questions §4 (runtime vs
   compile-time) acknowledges this coupling.

6. **Open-questions count discrepancy (Claim 6).** The
   synthesis text says "inherits five open questions" but lists
   seven. Not solution-correctness-affecting; a documentation
   tidy-up.

7. **`{ref, result}` clause guard discipline** (inherited from
   `silent-failure-propagation/validation.md` Outstanding doubt
   2). The new `handle_info({ref, result}, state) when
   is_reference(ref)` clause must not accidentally match
   unrelated messages with a reference in tuple position 0; the
   `Map.fetch(pending_tasks, ref)` discipline is the
   resolution. PR-2 critic must confirm.
