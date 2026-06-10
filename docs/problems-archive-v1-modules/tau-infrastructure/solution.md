---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: root
synthesised_from:
  - subproblems/supervision-tree-startup/solution.md
  - subproblems/telemetry-handler-coupling/solution.md
  - subproblems/circuit-breaker-invariant-split/solution.md
  - subproblems/global-name-collision/solution.md
selection_method: synthesis
mode: non-leaf
revision: 0
---

# Solution: tau-infrastructure cross-cutting correctness — four independent fixes, sequenced for minimal interference

## Recommendation

Land the four child recommendations as four separate PRs in the order
**(1) telemetry-handler-coupling → (2) circuit-breaker-invariant-split → (3) supervision-tree-startup → (4) global-name-collision**.
The first three are file-scoped and mutually non-interacting; ordering is
chosen to put the smallest, lowest-blast-radius patches first and the
broadest call-site sweep last. Each PR carries its own SPEC amendment
(only #2 and #4 need one), its own acceptance criterion satisfied in
isolation, and its own regression test. The combined effect restores
four invariants in `Tau.Application` and its cross-cutting subsystems —
asymmetric crash-safety in cost telemetry handlers, post-/pre-increment
coupling between `CircuitBreaker.Store` and the façade, unmonitored CLI
task and dual OTel enable-disable policy in `start/2`, and hard-coded
global atom names blocking multi-instance deployment — without
introducing new defects at sibling boundaries.

## Selected from

- **Synthesised from:** child solutions at
  `subproblems/supervision-tree-startup/solution.md`,
  `subproblems/telemetry-handler-coupling/solution.md`,
  `subproblems/circuit-breaker-invariant-split/solution.md`,
  `subproblems/global-name-collision/solution.md`.
- **Composition rationale:** The four child recommendations are
  **directly composable**. The decomposition strategy in `problem.md`
  partitions defects along the Hickey *concern* axis (steady-state
  event handling vs lifecycle vs data-shape-across-a-layer vs
  deployment topology); no concern lives in two children, so no
  recommendation contradicts another. Verifying composition file by
  file:

  - **telemetry-handler-coupling** touches `lib/tau/cost/tracker.ex`
    (rescue block in `handle_event/4`) and `lib/tau/telemetry/supervisor.ex`
    (`:rest_for_one` strategy + child-ordering invariant). Neither file
    is touched by any other child.
  - **circuit-breaker-invariant-split** touches
    `lib/tau/circuit_breaker/store.ex` (return convention),
    `lib/tau/circuit_breaker.ex` (delete `new_count - 1`),
    `lib/tau/circuit_breaker/state.ex` (`check/3` cooldown opt), and
    `docs/spec/SPEC-CIRCUIT-BREAKER.md` §4 B4. The `Store` is also
    referenced by **global-name-collision** but only in
    `start_link/1` / `init/1` (accepting `name:`/`table:` opts) — a
    different region of the file. The two PRs may overlap in the file
    but not in the same function; merging in order avoids any
    file-level conflict (#2 lands the return-convention change first,
    #4 then layers the opts threading on top, leaving the multi-op
    `update_counter` untouched).
  - **supervision-tree-startup** touches only `lib/tau/application.ex`
    (`start/2` body, `opts`, deletion of `maybe_dispatch_cli/0` and
    `otel_reporter_spec/0`). `Application.start/2` is also modified by
    **global-name-collision** (to call `Tau.Names.compute/1` and
    thread `names.*` opts into children). These overlap in the same
    function; ordering #3 before #4 means the `spawn_monitor` + `receive`
    block and the `OtelReporter` unconditional entry are present in
    `start/2` when #4 then adds the `Tau.Names.compute/1` /
    `:persistent_term.put/2` lines and rewrites the child specs to
    thread `names.*` fields. The two patches touch the same function
    but at clearly separable points (CLI dispatch block and OtelReporter
    spec list vs name resolution and child opts) — a textbook
    rebase-rather-than-conflict situation.
  - **global-name-collision** introduces `lib/tau/names.ex`, modifies
    `lib/tau/application.ex`, `lib/tau/circuit_breaker/store.ex`,
    `lib/tau/cost/tracker.ex`, and `lib/tau/registries.ex`, and sweeps
    ~30 bare-atom call sites. Modifying `Cost.Tracker` and
    `CircuitBreaker.Store` here is purely additive (accept `name:`,
    `table:` opts with defaults equal to current atoms), so the rescue
    block from #1 and the multi-op `update_counter` from #2 are
    preserved verbatim.

  No conflict resolution between children is required; the only ordering
  constraint is the same-function overlap of #3 and #4 in
  `Application.start/2`, satisfied by serial merge order. The four
  children together cover every finding listed in `problem.md`'s
  Context section: cost-tracker rescue gap, telemetry supervisor
  strategy, circuit-breaker counter-protocol leakage and asymmetric
  cooldown configurability, unmonitored CLI task, dual OTel enable
  policy, and hard-coded global atom names. There is no gap; the
  decomposition was complete.

## What changes

Listed by child PR, in the recommended landing order. Each item below is
exactly the change the child solution prescribes; file-level enumeration
is non-overlapping except where noted (#3 ∩ #4 in `application.ex`).

### PR 1 — telemetry-handler-coupling

- `lib/tau/cost/tracker.ex` — add `rescue` block to `handle_event/4`
  symmetric with the existing guard in `handle_coding_agent_cost/4`;
  emit `[:tau, :cost, :tracker, :handler_failed]` on error; return `:ok`.
- `lib/tau/telemetry/supervisor.ex` — change `strategy:` from
  `:one_for_one` to `:rest_for_one`; verify and (if necessary) reorder
  the child list so `Tau.Telemetry.Handlers` precedes `Tau.Cost.Tracker`.
- New test: inject a float into `:usage` to reach the `:ets.update_counter`
  raise path; assert `handle_event/4` returns `:ok` and the
  `[:tau, :cost, :tracker, :handler_failed]` event is emitted.

### PR 2 — circuit-breaker-invariant-split

- `lib/tau/circuit_breaker/store.ex` — `bump_failure_count/1` and
  `bump_success_count/1` use the two-element `update_counter` op list
  `[{pos, 0}, {pos, 1}]`, returning the **pre-increment** value;
  `@spec` unchanged; `@doc` updated.
- `lib/tau/circuit_breaker.ex` — `record_outcome/5` removes the
  `new_count - 1` adjustment and the comment block at lines 116–123;
  passes the Store return directly into the `State` struct.
- `lib/tau/circuit_breaker/state.ex` — `check/2` becomes `check/3`
  with an optional `cooldown_ms` keyword opt; `@default_cooldown_ms`
  remains as the fallback. `record_failure/2` and `record_success/2`
  are unchanged.
- `docs/spec/SPEC-CIRCUIT-BREAKER.md` §4 B4 — document the
  pre-increment return convention and the new `cooldown_ms` opt.
- Update tests asserting on `Store.bump_*/1` return values from
  post-increment to pre-increment (small set per the child's
  pre-implementation `grep`).

### PR 3 — supervision-tree-startup

- `lib/tau/application.ex`:
  - Delete `maybe_dispatch_cli/0` and its call site.
  - Delete `otel_reporter_spec/0`; replace its child-list entry with
    `Tau.OtelReporter` unconditionally (the existing `init/1`
    `:ignore` return is the sole gate).
  - Insert `spawn_monitor/1` + `receive` block on the `{:ok, pid}`
    branch of `start/2`, gated on `cli_argv()`, with the spawned
    process calling `exit(exit_code)` so the integer is carried as
    the `:DOWN` reason; the `receive` dispatches to `System.halt/1`.
  - Set `opts = [strategy: :rest_for_one, name: Tau.Supervisor,
    max_restarts: 10, max_seconds: 60]`.
- Tests asserting `Tau.OtelReporter` is absent when OTel is disabled
  must assert it is present-but-ignored (or be deleted if they were
  testing the now-removed `otel_reporter_spec/0` function).

### PR 4 — global-name-collision

- New file `lib/tau/names.ex` — `Tau.Names` struct + `compute/1` +
  `get/0` + `get/1`. `compute(:default)` returns existing atoms
  unchanged.
- `lib/tau/application.ex` — `start/2` reads `instance_id` from args
  (default `:default`), calls `Tau.Names.compute/1`, stores result in
  `:persistent_term` under `:tau_names`, threads `names.*` fields into
  every named child's `start_link/1` opts. **Overlaps PR 3's edits in
  `start/2`** — see "Composition rationale" above; the two patches
  touch disjoint regions of the function.
- `lib/tau/circuit_breaker/store.ex` — `start_link/1` and `init/1`
  accept `name:` and `table:` opts (defaults `__MODULE__` and
  `:tau_circuit_breakers`). Additive — preserves PR 2's pre-increment
  semantics.
- `lib/tau/cost/tracker.ex` — same pattern (`name:` opt). Additive —
  preserves PR 1's rescue block verbatim.
- `lib/tau/registries.ex` — `start_link/1` / `init/1` accept a `names:`
  struct and pass `names.<role>_registry` to each of seven `Registry`
  children.
- ~30 call sites under `lib/` — replace bare `Tau.PubSub`,
  `Tau.Providers.Finch`, and registry atoms with
  `Tau.Names.get().<field>`.
- Regression test: property asserting
  `Tau.Names.compute(:default)` round-trips to the historically-expected
  atoms.

## What does not change

- `Tau.Cost.Tracker.handle_coding_agent_cost/4` (already D-035-compliant).
- `Tau.Telemetry.Handlers` module body.
- `Tau.CircuitBreaker.State.record_failure/2` and `record_success/2`
  semantics and signatures.
- D-044 ETS row layout for the circuit breaker; `@schema_version` does
  not bump.
- The public `Tau.CircuitBreaker.call/3` API contract.
- The `Tau.Provider` behaviour, all provider adapters, and the session
  FSM logic.
- `Tau.OtelReporter` module and its `init/1` `:ignore` logic.
- `Tau.Application`'s 17-child tree composition beyond the
  `otel_reporter_spec` removal and the child-list rewrites driven by
  PR 4's `names.*` threading.
- All `start_link/1` external signatures for the `:default` instance —
  defaults match current atoms, so deployed configurations require no
  migration.
- All other audit modules (tau-cli, tau-memory, tau-coding-agent,
  tau-providers) — explicit per `problem.md`'s Out of scope.

## Migration sketch

Land the four PRs serially in the order above. Each PR is small enough
to gate independently under the factory loop's per-PR `critic` +
`reviewer` gate; none has a prerequisite from a sibling beyond the
ordering chosen here for conflict-minimisation:

1. **PR 1** (telemetry-handler-coupling) — 2 files, 1 test. No sibling
   dependency. Verify `Cost.Tracker.terminate/2` detaches both handler
   IDs before merging the `:rest_for_one` half (child's open question).
2. **PR 2** (circuit-breaker-invariant-split) — 4 files + SPEC amendment
   in the same PR. No sibling dependency. Run the pre-implementation
   `grep` for `bump_failure_count|bump_success_count` to enumerate
   test-side assertion updates; confirm `:ets.update_counter/3` two-op
   atomicity on OTP 27.2 before gating.
3. **PR 3** (supervision-tree-startup) — single-file change in
   `lib/tau/application.ex`. No sibling dependency. Confirm
   `exit(integer)` propagates as `{:DOWN, ref, :process, pid, integer}`
   (not `:normal`) via a smoke test before relying on the
   `is_integer(exit_code)` guard (child's open question).
4. **PR 4** (global-name-collision) — new file + 4 edited files + ~30
   call-site sweep. Rebases on top of PR 3's `start/2` body; the two
   patches touch disjoint regions, so the rebase is mechanical. After
   landing, all `start_link/1` defaults still match the historic atoms,
   so the regression baseline holds.

Each PR's child solution carries its own acceptance criterion and
gating-test paths; this root solution adds no further criterion beyond
the four already specified, and no additional CI gate beyond the
existing per-PR `critic` + `reviewer` + three-mechanical-gates pipeline.

## Open questions

The four child solutions enumerate seven open questions in total; the
root inherits all of them unchanged. Composition does not introduce new
open questions beyond:

- **Same-function overlap in `Application.start/2` (PR 3 ∩ PR 4).** The
  recommendation asserts the two patches touch disjoint regions of the
  function. If the implementer of PR 4 finds, on rebase, that PR 3's
  inline `spawn_monitor` block has migrated to a position that
  conflicts with name resolution sequencing (e.g. names must be in
  `:persistent_term` before the CLI dispatch can read them), this must
  be resolved at PR 4 implementation time — likely by moving the
  `Tau.Names.compute/1` + `:persistent_term.put/2` call to the very
  start of `start/2`, before any child spec list is constructed. No
  rule change required.
- **Implicit ordering on the SPEC-CIRCUIT-BREAKER amendment.** PR 2
  amends §4 B4. If a parallel PR (outside this module's scope) amends
  the same section concurrently, the second to merge must rebase on
  the first; this is the standard SPEC-amendment rebase pattern
  (`spec-before-code.md`) and not new.

## Linked sub-problems / proposals

- `subproblems/supervision-tree-startup/` → "Inline `spawn_monitor` +
  `receive` in `Application.start/2`; OtelReporter always-in-tree;
  relaxed restart bounds (`max_restarts: 10, max_seconds: 60`)."
- `subproblems/telemetry-handler-coupling/` → "Add symmetric `rescue`
  in `Cost.Tracker.handle_event/4`; switch
  `Tau.Telemetry.Supervisor` to `:rest_for_one` with `Handlers`
  before `Cost.Tracker`."
- `subproblems/circuit-breaker-invariant-split/` → "Change `Store.bump_*/1`
  to return pre-increment via multi-op `update_counter`; delete
  `new_count - 1` in the façade; promote `cooldown_ms` to an opt on
  `State.check/3`; SPEC §4 B4 amendment."
- `subproblems/global-name-collision/` → "Introduce `Tau.Names` struct;
  thread `instance_id` through `Application.start/2`; store derived
  names in `:persistent_term`; sweep ~30 bare-atom call sites to
  `Tau.Names.get().<field>`; `:default` instance preserves all
  existing atoms."

## Revision history

- (revision 0 — initial)
