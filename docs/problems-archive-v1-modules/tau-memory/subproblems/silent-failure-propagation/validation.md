---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/4
revision_triggered: none
---

# Validation: Ref-map in GenServer state + structured-result embedder contract

## Overview

The solution asserts that combining (a) a `pending_tasks: %{reference() =>
entry_id}` map in `Tau.Memory.Store.SQLite` state with (b) a new
`Tau.Memory.Embedder.embed_async/1` callback whose returned Task delivers
`{:ok, embedding} | {:error, kind, reason}` directly to the store's mailbox
will close the silent-failure gap described in the problem (D-046 stuck-
`"pending"` after a crashed embedding Task). Six discrete propositions are
extracted from the Recommendation and What-changes sections. Per-claim
falsification used a mix of strategies — dependency check against the running
codebase, edge-case enumeration over `Task.Supervisor.async_nolink/2`
semantics, type-level check on the new callback signature, prior-art
counter-case against the proposals' own Weaknesses section, and an
integration-test feasibility check. Five claims withstood; one (Claim 4 —
removal of `MemoryStore.store_embedding/3` public function) was partially
falsified because the named module path `lib/tau/memory/memory_store.ex` does
not exist in the codebase; the corresponding public function lives at
`lib/tau/memory/store/sqlite.ex:163-167`. The qualifier on Claim 4 narrows to
"remove the public `Tau.Memory.Store.SQLite.store_embedding/3` function (the
actual location)"; the underlying intent (no external callers after the
change) is preserved and the rest of the solution is unaffected. No solution
revision is triggered; the partial falsification is recorded as a path
correction that the implementer must follow.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants found
it difficult to generate Toulmin structures, and their structures varied
greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
The six components below are filled separately to counter that variance.

### Claim 1: A `%{reference() => entry_id}` map in `Store.SQLite` state, populated at dispatch and consumed by a real `{:DOWN, ref, ...}` clause that calls `do_mark_embedding_failed/3` with `:transient`, closes the crash-detection gap.

- **Claim (C):** Adding a `pending_tasks` ref-map to `Store.SQLite` state and
  giving the `{:DOWN, ref, :process, _pid, reason}` clause a non-trivial body
  that looks up the entry ID and invokes
  `do_mark_embedding_failed(db, entry_id, :transient)` when `reason != :normal`
  causes the entry to transition from `"pending"` to `"failed"` within the
  monitored task's lifetime, satisfying the problem's acceptance criterion.
- **Grounds (G):** The current code at `lib/tau/memory/store/sqlite.ex:300-302`
  is a body-less `{:noreply, state}` discard with no entry-ID context, which
  is exactly the failure mode named in `problem.md` (`Context` bullet 1) and
  caused by the missing mapping named in the `Complecting hypothesis`. The
  callee `do_mark_embedding_failed/3` already exists at
  `lib/tau/memory/store/sqlite.ex:582-616` and is unit-tested through the
  `{:store_embedding, _, {:error, kind, _}}` `handle_call` path
  (`test/tau/memory/store_sqlite_test.exs:611, 621`).
- **Warrant (W):** `Task.Supervisor.async_nolink/2` guarantees the calling
  process receives `{ref, result}` on normal completion and
  `{:DOWN, ref, :process, pid, reason}` on abnormal exit (Elixir stdlib
  contract). Therefore a clause that pattern-matches `{:DOWN, ...}` with a
  state-derived `(ref → entry_id)` lookup can deterministically act on
  every abnormal exit — which is the OTP non-negotiable #4 (cross-process
  events use monitored refs) applied to this specific gap.
- **Qualifier (Q):** Holds only for crashes of the outermost task spawned by
  `handle_continue/2`; does not cover a crash of `Store.SQLite` itself nor a
  crash that occurs before `async_nolink` returns the ref (vanishingly small
  window between spawn and `put_in`). For pre-existing stuck rows ingested
  before this change ships, this claim is silent — those are covered by the
  sibling `pending-rot-observability` and `retry-recovery-path` nodes.
- **Rebuttal (R):** If the embedder implementation wraps its work in an
  inner Task that swallows its own crash (Proposal 1's own "Weaknesses" §2
  warning), the outer Task exits `:normal` and `{:DOWN, ..., :normal}` is the
  message delivered — no `:transient` failure is recorded and the entry
  stays `"pending"`. This is precisely the reason the solution pairs Claim 1
  with Claim 2 (Proposal 4's `embed_async/1`), which collapses the
  double-spawn so the outer Task IS the work and its crash IS the abnormal
  exit. Claim 1 is sound only because Claim 2 lands with it.
- **Backing (B):** OTP non-negotiables #1, #4, #7 (`TAU.md` "OTP
  non-negotiables (quick reference)"); Elixir stdlib `Task.Supervisor` docs
  (https://hexdocs.pm/elixir/Task.Supervisor.html#async_nolink/2); the
  established prior-art reference in proposal-1.md §"Prior art" cites
  `Tau.CircuitBreaker.Store` (`lib/tau/circuit_breaker/store.ex`) as the
  in-repo ref-tracking pattern.

#### Falsification attempt for claim 1

- **Strategy:** Edge-case enumeration over the `async_nolink/2` message
  surface and the pre-change code.
- **Attempt:** Enumerated the message classes the modified `handle_info`
  must handle: (i) `{ref, result}` from a Task that completed normally;
  (ii) `{:DOWN, ref, :process, _pid, :normal}` paired with (i);
  (iii) `{:DOWN, ref, :process, _pid, reason != :normal}` after the Task
  body raised, exited abnormally, or was killed; (iv) stray `:DOWN` for a
  ref the store never created (cannot occur with `async_nolink` but
  defensively must not crash). The current code at lines 295-302 discards
  (i), (ii), (iii), (iv) uniformly without context — confirmed against the
  Read of `sqlite.ex`. The proposed clause shape (proposal-1.md sketch
  lines 53-76, integrated into solution.md "What changes") routes (iii) to
  `do_mark_embedding_failed/3`, leaves (i)+(ii) idempotent, and tolerates
  (iv) via `Map.fetch/2 → :error`.
- **Outcome:** withstood — the strategy produced no message class that
  falsifies the claim under the qualifier stated above.
- **Action:** none.

### Claim 2: Replacing the `Embedder` behaviour callback with `embed_async/1`, returning `{:ok, Task.t()}` whose result message is `{:ok, embedding} | {:error, kind, reason}`, removes the inversion-of-control that made crash outcomes invisible and makes the success path carry the result as a value.

- **Claim (C):** Changing the `Tau.Memory.Embedder` behaviour from
  `embed(store, entry_id, content)` (callback-driven; the worker calls
  `Store.SQLite.store_embedding/3` itself) to `embed_async(content) :: {:ok,
  Task.t()}` (value-returning; the store reads the result off its own
  mailbox) eliminates the structural cause of the silent-failure pattern
  identified in `problem.md`'s `Complecting hypothesis` bullet 2.
- **Grounds (G):** The current `embed/3` at
  `lib/tau/memory/embedding_worker.ex:49-71` spawns an inner Task that calls
  `MemoryStore.store_embedding/3` (line 57) inside the inner Task body. The
  outermost `async_nolink`'d Task in `Store.SQLite.handle_continue/2`
  (`lib/tau/memory/store/sqlite.ex:309-311`) wraps that call. When the
  inner Task crashes before line 57, the outer Task's `embedder.embed(...)`
  returns `{:ok, inner_task}` and exits `:normal`, so the store sees
  `{ref, {:ok, inner_task}}` and never `{:DOWN, ..., abnormal}` — exactly
  the rebuttal in Claim 1. Replacing this with a single-Task contract that
  returns `{:ok, embedding} | {:error, kind, reason}` collapses the chain.
- **Warrant (W):** Hickey's "values, not side effects" — a function that
  returns a value composes more reliably than one that side-effects through
  a callback into shared state. Translated to OTP: a callback that delivers
  its outcome as a message to the process owning the relevant state
  (Store.SQLite) restores the temporal-coupling-free contract; the store is
  the sole writer, in line with OTP non-negotiable #1.
- **Qualifier (Q):** Assumes the embedder implementations can be migrated
  in a single PR (current production has one — `EmbeddingWorker`; tests have
  Mox-style stubs). A staged rollout with both `embed/3` and `embed_async/1`
  live simultaneously would re-introduce the double-spawn problem during the
  transition and falsify this claim's "removes the IoC" wording for that
  window.
- **Rebuttal (R):** If a future embedder needs to call out to an external
  pool that itself spawns a process and returns immediately (e.g. an HTTP
  client with its own connection process), the implementer might be tempted
  to spawn an inner Task again to "convert" that to a value. The behaviour
  signature alone does not prevent this; the contract MUST be documented as
  "the returned Task is the unit of failure" so implementers do not regress.
- **Backing (B):** Hickey, "Simple Made Easy" (complecting via callbacks
  vs. composition via values); the in-repo `Tau.Provider` behaviour — its
  `stream/3` callback returns a stream of `%Tau.Provider.Event{}` values
  rather than calling back into the session, which is the same shape this
  claim proposes for embedding.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — try to construct a code shape
  consistent with the proposed contract that still produces a silent stuck-
  `"pending"`.
- **Attempt:** Tried two shapes: (a) the new `EmbeddingWorker.embed_async/1`
  itself spawns an inner Task and returns the outer Task's ref — same
  failure mode as today; (b) the embedder returns an already-resolved Task
  (`Task.completed/1`-style) before the HTTP call runs, then does the HTTP
  call in a separate untracked process. Shape (a) is the rebuttal above and
  is contract-violating, not contract-conforming — the contract specifies
  the returned Task IS the work. Shape (b) is degenerate and identifiable
  in code review. Within the conforming contract, the result message
  carries the verdict by construction, and the store's `handle_info({ref,
  result}, ...)` clause can act on it. No conforming counter-example
  produced a stuck-`"pending"`.
- **Outcome:** withstood.
- **Action:** Document the contract clearly in the behaviour's `@doc` so
  the Rebuttal's degenerate shape is rejected in review. (Already implicit
  in the solution; surfaces explicitly here.)

### Claim 3: The `{ref, result}` success clause will handle the result value directly instead of discarding it.

- **Claim (C):** After the change, `handle_info({ref, embed_result},
  state)` demonitors, removes the ref from `pending_tasks`, and dispatches
  on `embed_result` — calling `do_store_embedding/3` for `{:ok, embedding}`
  or `do_mark_embedding_failed/3` for `{:error, kind, _}` — instead of the
  current pattern of `Process.demonitor(ref, [:flush])` + `{:noreply,
  state}` (`lib/tau/memory/store/sqlite.ex:295-298`) that drops the result.
- **Grounds (G):** Lines 295-298 currently match `{ref, _result}` with
  `_result` bound to the underscore wildcard — verified by Read. The
  `do_store_embedding/3` and `do_mark_embedding_failed/3` private helpers
  already exist at lines 543-579 and 582-616 respectively. The solution's
  "What changes" §1 bullet 3 names this clause body change explicitly.
- **Warrant (W):** OTP non-negotiable #1 — the store is the sole writer to
  its own state; routing the result through the store's mailbox (rather
  than through a callback the worker initiates) keeps that invariant. Plus
  Hickey: a value (`embed_result`) is easier to reason about than a side-
  effecting callback whose timing relative to `{:DOWN, ...}` is non-
  deterministic.
- **Qualifier (Q):** Assumes Claim 2 lands — i.e. the embedder actually
  produces `{:ok, embedding} | {:error, kind, reason}` as the Task result,
  not `{:ok, inner_task}` (the today shape). Without Claim 2, this clause
  has nothing actionable in `embed_result`.
- **Rebuttal (R):** If a future contributor adds a second `async_nolink`
  spawn from `Store.SQLite` for an unrelated purpose, its `{ref, result}`
  messages will land in the same clause. The clause must therefore
  distinguish "this ref is in `pending_tasks`" from "this ref is unknown"
  — a `Map.fetch/2` guard handles it, but the contributor MUST follow that
  discipline or this clause will mis-dispatch.
- **Backing (B):** OTP non-negotiables #1, #4 (`TAU.md`); the in-repo prior
  art at `lib/tau/circuit_breaker/store.ex` for ref-keyed dispatch in a
  GenServer's `handle_info`.

#### Falsification attempt for claim 3

- **Strategy:** Type-level check — does the new `handle_info({ref,
  embed_result}, ...)` clause type-check against the declared
  `embed_async/1 :: {:ok, Task.t()} | {:error, term()}` return and the
  `do_store_embedding/3`, `do_mark_embedding_failed/3` arities?
- **Attempt:** `do_store_embedding/3` accepts `(db, entry_id, embedding)`
  where `embedding` is a `list(float())` — matches the `{:ok, embedding}`
  branch. `do_mark_embedding_failed/3` accepts `(db, entry_id, kind)` with
  `kind in [:transient, :terminal]` — matches the `{:error, kind, _}`
  branch (existing `handle_call({:store_embedding, _, {:error, kind, _}})`
  at line 284 demonstrates the same dispatch shape compiles today). The
  ref → id lookup uses `Map.fetch/2`, which is well-typed. No type-level
  contradiction.
- **Outcome:** withstood.
- **Action:** none.

### Claim 4: The `Tau.Memory.MemoryStore` public `store_embedding/3` function will be removed (no external callers remain).

- **Claim (C):** Solution.md's "What changes" §4 names
  `lib/tau/memory/memory_store.ex` as the public-API module and states the
  public `store_embedding/3` will be removed.
- **Grounds (G):** Searched the repository:
  `find /home/brentw/src/tau/lib/tau -name memory_store.ex` returns
  nothing (verified by Bash). The function `store_embedding/3` exists at
  `lib/tau/memory/store/sqlite.ex:163-167` as a `@spec`'d public API on
  `Tau.Memory.Store.SQLite`, NOT in a separate `MemoryStore`/`memory_store.ex`
  module. The `EmbeddingWorker` aliases `Tau.Memory.Store.SQLite, as:
  MemoryStore` (`lib/tau/memory/embedding_worker.ex:32`) — that alias is
  the only thing in the repo named `MemoryStore`, and it points at
  `Store.SQLite`, not a separate public-API module.
- **Warrant (W):** A documented "what changes" must name an existing file
  path or the change cannot be applied as written. Solution.md is the
  implementer's brief (`factory-loop.md` "The draft-PR body" §"Scope &
  order"); a mis-named module path is an implementation hazard even when
  the intent (kill the public callback) is sound.
- **Qualifier (Q):** Claim narrowed: remove the public
  `Tau.Memory.Store.SQLite.store_embedding/3` function at
  `lib/tau/memory/store/sqlite.ex:163-167` AND the corresponding
  `handle_call({:store_embedding, ...})` clauses at lines 279-288. The
  underlying "no external callers" goal is preserved.
- **Rebuttal (R):** A future refactor MAY extract a `Tau.Memory.Store`
  public façade module to which `store_embedding/3` (or its replacement)
  belongs; the solution's wording could be read as anticipating that. But
  no such module exists at the time of validation, and the solution does
  not propose creating one — so the named path is a defect, not a
  forward-reference.
- **Backing (B):** `factory-loop.md` "The draft-PR body" (the body is the
  durable plan-of-record); `spec-before-code.md` (PR scope is named in
  files by their actual paths).

#### Falsification attempt for claim 4

- **Strategy:** Dependency check — does the file the solution names exist?
- **Attempt:** `find /home/brentw/src/tau/lib/tau -name memory_store.ex`
  returns no results; `ls /home/brentw/src/tau/lib/tau/memory/` lists
  `embedder.ex`, `embedding_worker.ex`, `loader.ex`, `migrations.ex`,
  `store/`, `store.ex`, `supervisor.ex` — no `memory_store.ex`. The
  function `store_embedding/3` is uniquely defined at
  `lib/tau/memory/store/sqlite.ex:163-167`. The alias `MemoryStore` is set
  inside `embedding_worker.ex` to point at `Tau.Memory.Store.SQLite`. The
  named path therefore does not exist; the function does exist at a
  different module.
- **Outcome:** partially falsified — the *intent* (remove the public
  callback) is sound and supported by the rest of the solution; the
  *target path* is wrong and must be corrected to
  `lib/tau/memory/store/sqlite.ex:163-167` before implementation. This is
  a qualifier narrowing, not a structural defect in the chosen approach.
- **Action:** Narrow Claim 4's qualifier (done above). No solution
  re-selection; the implementer brief inherits the corrected path. The
  selector / proposer do not need to re-run because the change is a
  surface-level mis-naming, not a structural error in the chosen approach.

### Claim 5: The crash path and success path become symmetric, both routed through `handle_info` using the same ref map.

- **Claim (C):** After the change, both message classes from
  `async_nolink` (`{ref, result}` for normal completion and `{:DOWN, ref,
  ...}` for abnormal exit) are handled by `handle_info` clauses that share
  the same `pending_tasks` map, eliminating the asymmetry where today's
  success and crash messages are both discarded by the same body-less
  clause.
- **Grounds (G):** The solution's "What changes" §1 bullets 3-4 give both
  clauses non-trivial bodies that use `pending_tasks` for cleanup (success)
  and lookup-then-fail (crash). The current code at
  `lib/tau/memory/store/sqlite.ex:295-302` has two clauses that both
  `{:noreply, state}` with no map and no entry-ID context — confirmed by
  Read.
- **Warrant (W):** OTP non-negotiable #4 — cross-process events use
  monitored refs. Symmetric handling of the two message shapes is the
  direct application of that rule; the asymmetry today is the rule's
  violation (the crash path is monitored but not acted on).
- **Qualifier (Q):** Holds for the message surface produced by
  `async_nolink/2`. Does not extend to messages from `Task.async/2` (which
  raises on abnormal exit rather than sending `:DOWN`) — not applicable
  here because the solution preserves `async_nolink`.
- **Rebuttal (R):** "Symmetric" is a structural description, not a
  behavioural identity claim — the two clauses do different things (write
  embedding vs. mark failed) precisely because the outcomes differ. The
  symmetry is in *both being handled with state context*, not in *doing
  the same thing*. A reader interpreting "symmetric" as "identical" would
  find the claim trivially false; the solution's text and the warrant make
  the intended sense clear.
- **Backing (B):** OTP non-negotiables #4 (`TAU.md`); Elixir
  `Task.Supervisor.async_nolink/2` docs.

#### Falsification attempt for claim 5

- **Strategy:** Edge-case enumeration over message classes (same as
  Claim 1's strategy, applied to the symmetry property rather than to the
  acceptance criterion).
- **Attempt:** For each message class produced by `async_nolink`, asked:
  is the corresponding clause stateful (uses `pending_tasks`) and
  actionable (produces a DB write or a no-op-with-cleanup)? Both clauses
  pass under the solution. No asymmetric residual identified.
- **Outcome:** withstood.
- **Action:** none.

### Claim 6: The change directly decomplects task identity from entry identity and eliminates the inversion-of-control that made crash outcomes invisible.

- **Claim (C):** The two complects named in `problem.md` (`Complecting
  hypothesis` bullets 1 and 2) are both resolved by this solution.
- **Grounds (G):** Bullet 1's complect ("task identity is complected with
  the entry") is resolved by the `pending_tasks: %{ref => entry_id}` field
  — verified by direct correspondence between the problem's wording and
  the solution's "What changes" §1 bullet 1. Bullet 2's complect ("'task
  completed normally' and 'task crashed' are complected in the same silent
  discard clause") is resolved by giving each message class its own
  actionable clause body — verified by direct correspondence to "What
  changes" §1 bullets 3-4.
- **Warrant (W):** Hickey's definition of complecting: braiding two
  independent concerns into one structure such that you cannot reason
  about them separately. Decomplecting is the structural inverse —
  separating them back out. The map gives task-ref and entry-id their own
  identity that can be related at lookup time without being braided in
  state.
- **Qualifier (Q):** "Decomplects" applies to the two specific complects
  named in `problem.md`. Other complects in the embedding pipeline (e.g.
  the embedder's HTTP-call retry policy mixed with its content-length
  policy in `embedding_worker.ex:81-95`) are out of scope and unaffected.
- **Rebuttal (R):** A purist might argue that storing `ref → entry_id` in
  the GenServer's heap is still a form of coupling — the store's lifetime
  is coupled to the in-flight task set. This is true but is the same
  coupling that any monitored-ref pattern carries; it is the
  *appropriate* coupling under OTP non-negotiable #4 (cross-process events
  use monitored refs), not a residual complect.
- **Backing (B):** Hickey, "Simple Made Easy" §"Complect"; the
  problem.md's own `Complecting hypothesis` section names the complects
  this claim asserts are resolved.

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — try to find a post-change
  code state where one of the named complects is still present.
- **Attempt:** Re-read the problem's two `Complecting hypothesis` bullets,
  then traced the solution's "What changes" against each. For bullet 1 the
  map IS the missing association; for bullet 2 the two clause bodies ARE
  the disambiguation. No residual found within the problem's named
  complects. (See Qualifier — out-of-scope complects are not a counter-
  example to this claim.)
- **Outcome:** withstood.
- **Action:** none.

## Cross-claim consistency

Claims 1 and 2 form a strict dependency pair: Claim 1's qualifier explicitly
notes that Claim 1 is sound only when Claim 2 also lands (otherwise the
double-spawn keeps the abnormal exit invisible to the store). Claim 3 in
turn depends on Claim 2 (without `embed_async/1` returning the embedding
verdict as the Task result, there is nothing actionable in the `{ref,
result}` clause). This dependency chain is internally consistent and matches
the solution.md "Why chosen" rationale that Proposal 1 and Proposal 4 are
only sound together.

Claim 4 (remove public callback) is independent of Claims 1-3 (state and
clause changes) — they touch disjoint surfaces. The partial falsification of
Claim 4 (wrong target path) does not affect Claims 1-3.

Claim 5 (symmetry) is a structural restatement of Claims 1 + 3 together; it
is consistent with both and does not add a new constraint.

Claim 6 (decomplecting) is a higher-level summary of Claims 1 + 2 against
the problem's `Complecting hypothesis`; it adds no constraint beyond those.

No tension between any pair of claims was identified.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Ref-map + real `:DOWN` clause closes crash gap | Edge-case enumeration over async_nolink messages | withstood | none |
| 2 | `embed_async/1` removes IoC | Counter-example construction over contract-conforming shapes | withstood | document contract |
| 3 | Success clause handles result value | Type-level check on new clause vs helpers | withstood | none |
| 4 | Remove public `store_embedding/3` from `memory_store.ex` | Dependency check (does the file exist?) | partially falsified | narrow path to `lib/tau/memory/store/sqlite.ex:163-167` |
| 5 | Crash and success paths become symmetric | Edge-case enumeration over message classes | withstood | none |
| 6 | Both named complects are resolved | Counter-example construction over problem's complects | withstood | none |

## Revision required

- **Target file:** none (no full revision triggered).
- **Revision kind:** qualifier narrowing in-place on Claim 4 only.
- **Rationale:** The partial falsification of Claim 4 is a path/module-name
  defect, not a structural defect in the chosen solution. The function the
  solution intends to remove genuinely exists and the removal is sound; only
  the named module path is wrong. The narrowed qualifier in Claim 4 (above)
  records the corrected path so the implementer's brief inherits it. Per
  validate.md §5 ("Partial falsifications: narrow each claim's Qualifier in
  place. No revision needed"), this does not warrant re-running the proposer
  or selector and does not warrant editing `problem.md`.

## Outstanding doubts

- **Migration order safety.** Solution.md's "Migration sketch" steps 1-2
  describe amending the behaviour and updating `EmbeddingWorker` before
  step 3 changes `Store.SQLite`. If a partial deployment runs with a
  newer `EmbeddingWorker` (calling `embed_async/1`) but an older
  `Store.SQLite` (only knows about `{:store_embedding, ...}`
  `handle_call`), the new Task result message `{ref, {:ok, embedding}}`
  will hit the existing discard clause at lines 295-298. The validator
  could not directly falsify this because migrations in this repo are
  applied as single PR units (`spec-before-code.md` §"What this rule
  forbids" — "MUST NOT merge a PR that adds new state to a SPEC'd boundary
  without a corresponding §3 entry and §4 contract update in the same
  PR"). Surfacing it for the implementer to confirm.
- **`{ref, result}` clause guard scope.** Solution.md "Open questions"
  §"`{ref, result}` clause guard" raises the same concern; the validator
  agrees this is a real review item but cannot falsify it ahead of
  implementation. A `when is_reference(ref)` guard combined with a
  `Map.fetch(pending_tasks, ref)` lookup is the discipline that resolves
  it; the reviewer must confirm in code.
- **Stuck-pending state lost on `Store.SQLite` crash.** The ref-map lives
  on the GenServer heap; if `Store.SQLite` itself crashes while embeddings
  are in flight, the map is lost and the affected entries revert to
  stuck-`"pending"`. Explicitly out of scope per the problem's
  `Out of scope` section (covered by `retry-recovery-path`), so this is
  not a falsification — recorded here for the parent validator.
