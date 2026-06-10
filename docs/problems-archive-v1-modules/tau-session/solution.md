---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: root
synthesised_from:
  - subproblems/cross-cutting-data/solution.md
  - subproblems/fsm-facade-helpers/solution.md
  - subproblems/cancellation-teardown/solution.md
  - subproblems/user-message-routing/solution.md
selection_method: synthesis
mode: non-leaf
revision: 0
---

# Solution: Complete the session decomposition by distributing the four residual concerns to their owning modules

## Recommendation

Land the four child recommendations as a coordinated four-PR sequence that
collectively reduces `lib/tau/session.ex` from a 1,438-LOC façade with inline
teardown, shared utilities, multi-branch routing and an anonymous-map data
shape to a thin `:gen_statem` whose every `handle_event/4` clause body is a
one-line delegation or a three-line FSM return. Concretely: (1) typed
accessors plus a 101-head `%Tau.Session.Data{}` struct-match sweep across the
nine sub-modules harden the data contract; (2) the eight `@doc false` helpers
disperse to their owning concern modules (`Data`, `Events`, new `Telemetry`,
new `Hooks`, existing `Queue`); (3) a new `Tau.Session.Cancellable` behaviour
distributes the two ~120-LOC `:cancel` clause bodies across `ProviderTurn`,
`ToolDispatch`, `Compaction`, and `CodingAgentTurn`, with `Data.reset_for_cancel/1`
owning the cross-cutting per-turn fields; (4) `SlashCommand.dispatch_idle/2`
plus `SlashCommand.dispatch/2` absorbs the idle-routing clause, and the two
non-idle clauses collapse to direct `Queue.handle_postpone/2` /
`Queue.handle_enqueue/4` delegations. The four PRs are ordered so each PR's
new surface is the next PR's substrate; no PR introduces a broken
intermediate state, and every PR is independently revertible.

## Selected from

- **Synthesised from:**
  - `subproblems/cross-cutting-data/solution.md` — typed accessors on `Data` + 101-head `%Data{} = data` struct-match sweep across nine sub-modules.
  - `subproblems/fsm-facade-helpers/solution.md` — distribute the eight `@doc false` helpers by concern; new `Tau.Session.Telemetry` and `Tau.Session.Hooks` modules; pure helpers consolidate into `Data`; `broadcast/2` consolidates into `Events`.
  - `subproblems/cancellation-teardown/solution.md` — `Tau.Session.Cancellable` behaviour with `cancel_cluster(scope, Data.t()) :: {mechanism, Data.t()}`; both `:cancel` clause bodies collapse to ≤5-line folds over a compile-time `@cancel_clusters` list.
  - `subproblems/user-message-routing/solution.md` — `SlashCommand.dispatch_idle/2` (verbatim idle-clause extraction) + `SlashCommand.dispatch/2` (six-arm dispatch table); two non-idle clauses delegate to existing `Queue` functions.

- **Composition rationale:** The four child recommendations compose by
  direct addition; each owns a disjoint cluster of `session.ex` lines and a
  disjoint set of new/extended sub-module surfaces. Three composition
  points need explicit reconciliation, all resolvable in favour of the
  child solutions as written:

  1. **`Data` is the merge point for two children.** `cross-cutting-data`
     adds `get_queue/2`, `put_queue/3`, `replace_field/3`, and
     `reset_for_cancel/1`; `fsm-facade-helpers` adds `append_message/2`,
     `generate_event_id/0`, `current_run?/2`. All seven additions are
     purely additive `def`s with `@spec`s on the same module; no
     field, type, or signature conflict. The struct-match sweep in
     `cross-cutting-data` extends naturally to the new accessors as
     they are added.

  2. **`Telemetry` module supersedes the `emit_user_message_telemetry/3`
     coupling that `user-message-routing` left in place.** The
     `user-message-routing` solution acknowledges in its Open Questions
     that `SlashCommand.dispatch_idle/2` will call the FSM-resident
     `Tau.Session.emit_user_message_telemetry/3` and that a follow-on
     should move it. `fsm-facade-helpers` IS that follow-on: it creates
     `Tau.Session.Telemetry` and moves `emit_user_message/3` there. The
     synthesis sequences `fsm-facade-helpers` BEFORE `user-message-routing`
     so the new `dispatch_idle/2`, `Queue.handle_enqueue/4`, and
     `Queue.handle_postpone/2` call the new
     `Tau.Session.Telemetry.emit_user_message/3` directly. The acknowledged
     coupling in `user-message-routing`'s solution is resolved at sequence
     time, not as a residual debt.

  3. **`Data.reset_for_cancel/1` is owned by `cross-cutting-data` and
     consumed by `cancellation-teardown`.** Both child solutions name the
     same function with the same scope (cross-cutting per-turn fields:
     `active_skill`, `tool_iterations`, `tool_loop_state`,
     `provider_retry_state`, `steering_queue`; NOT
     `tool_loop_call_lookups`, which `ToolDispatch.cancel_cluster/2`
     owns). Sequencing `cross-cutting-data` before
     `cancellation-teardown` means the function exists when the
     `:cancel` clause bodies are rewritten to call it. No content
     reconciliation is required.

  No tension surfaced between the four children that demands a
  re-decomposition; the parent's MECE claim (each child maps to a
  distinct cluster of `session.ex` lines with no overlap) holds in
  practice.

## What changes

The change set is the union of the four child solutions' `What changes`
sections. Grouped by file and ordered by the PR sequence (see Migration
sketch); each line cites the originating child.

### A. `lib/tau/session/data.ex` (additive across two children)

- Add accessors: `get_queue/2`, `put_queue/3`, `replace_field/3` (from `cross-cutting-data`).
- Add cancel-scope reset: `reset_for_cancel/1` (from `cross-cutting-data`; consumed by `cancellation-teardown`).
- Add pure helpers: `append_message/2`, `generate_event_id/0`, `current_run?/2` (from `fsm-facade-helpers`).
- All seven additions are public `def`s with `@spec` typed against `Data.t()`. No field, default, `@enforce_keys`, or `@type t` change.

### B. New sub-modules under `lib/tau/session/`

- `lib/tau/session/cancellable.ex` — `Tau.Session.Cancellable` behaviour; one callback `cancel_cluster(scope :: :permission | :cross_cutting, Data.t()) :: {atom(), Data.t()}` (from `cancellation-teardown`).
- `lib/tau/session/telemetry.ex` — `Tau.Session.Telemetry`; `emit_transition/2` and `emit_user_message/3` (from `fsm-facade-helpers`).
- `lib/tau/session/hooks.ex` — `Tau.Session.Hooks`; public `payload/3` (renamed from `hook_payload/3`) and private `transcript_path/1` (from `fsm-facade-helpers`).

### C. Extensions to existing sub-modules

- `lib/tau/session/events.ex` — add `broadcast/2` as a public `def`; PubSub topic `"session:#{id}"` becomes a single point of definition (from `fsm-facade-helpers`).
- `lib/tau/session/queue.ex` — add `process_user_message/2` (verbatim move from `session.ex`) (from `fsm-facade-helpers`). No changes from `user-message-routing` (the existing `Queue.handle_postpone/2` and `Queue.handle_enqueue/4` are already-present delegation targets).
- `lib/tau/session/provider_turn.ex` — declare `@behaviour Tau.Session.Cancellable`; implement `cancel_cluster/2` calling existing `cancel_provider_task/1`, capturing the mechanism, clearing `{provider_task, cancel_flag, stream_ref, provider_span_ref, assembler}` (from `cancellation-teardown`). Defensive-read fix: replace `Map.put(data, key, value)` at line 179 with `Data.replace_field/3`; replace `Map.get(data, :persona_lifetime, :turn)` at line 337 with `data.persona_lifetime` (from `cross-cutting-data`).
- `lib/tau/session/tool_dispatch.ex` — declare `@behaviour Tau.Session.Cancellable`; implement scope-branching `cancel_cluster/2`: `:permission` runs the emit-and-synthesise loop formerly inlined in `session.ex` lines 842–961; `:cross_cutting` brutal-kills `tool_dispatcher` and `command_task`. Owns reset of `{pending_permission_requests, permission_dispatch_batch, permission_pending_results, tools_in_flight, tool_dispatcher, command_task, tool_loop_call_lookups}` (from `cancellation-teardown`).
- `lib/tau/session/compaction.ex` — declare `@behaviour Tau.Session.Cancellable`; implement `cancel_cluster/2` demonitoring `compaction_monitor`, brutal-killing `compaction_task`, clearing those two fields (NOT `compaction_failures`) (from `cancellation-teardown`).
- `lib/tau/session/coding_agent_turn.ex` — declare `@behaviour Tau.Session.Cancellable`; implement `cancel_cluster/2` guard-calling `Tau.CodingAgent.Dispatcher.cancel/1`, clearing `{coding_agent_dispatcher, coding_agent_pending, coding_agent_blocks}` (from `cancellation-teardown`).
- `lib/tau/session/model_swap.ex` — replace `Map.put(data, key, value)` at line 94 with `Data.replace_field/3` (parity fix from `cross-cutting-data`).
- `lib/tau/session/queue.ex` — replace `Map.get(data, queue_field)` / `Map.put(data, queue_field, new_queue)` at lines 43/63 with `Data.get_queue/2` / `Data.put_queue/3` (from `cross-cutting-data`).
- `lib/tau/session/slash_command.ex` — add `dispatch_idle/2` (verbatim extraction of the idle-clause body, refactored to call `dispatch/2`) and `dispatch/2` (six pattern-match clauses: `:builtin`, `:async`, `:skill_activation`, `:model_command` empty / non-empty, `:unknown_command`, `:sync`) (from `user-message-routing`). The new `dispatch_idle/2` calls `Tau.Session.Telemetry.emit_user_message/3` (resolving the coupling `user-message-routing` flagged in Open Questions).

### D. Struct-match sweep across nine sub-modules

Add `%Data{} = data` (with `alias Tau.Session.Data` at the top of each
file) to every `def`/`defp` head that names `data` as a parameter; widen
the five `%{...} = data` heads to `%Data{...} = data`. Per-file head
inventory (from `cross-cutting-data` §C; 101 heads total): `tool_dispatch`
16, `coding_agent_turn` 22, `provider_turn` 20, `model_swap` 11,
`compaction` 7, `queue` 7, `slash_command` 6, `skill_activation` 6,
`journal` 6.

### E. `lib/tau/session.ex` (the FSM module — strict reduction)

- Remove all eight `@doc false` defs (`process_user_message`, `append_message`, `broadcast`, `emit_user_message_telemetry`, `hook_payload`, `transcript_path`, `current_run?`, `generate_event_id`) and update internal callsites to the new module-qualified names (from `fsm-facade-helpers`).
- Add compile-time `@cancel_clusters [Tau.Session.ProviderTurn, Tau.Session.ToolDispatch, Tau.Session.Compaction, Tau.Session.CodingAgentTurn]` (from `cancellation-teardown`).
- Replace the `:awaiting_permission` `:cancel` clause body (lines 842–961) with a ≤5-line body: fold `@cancel_clusters` with `scope: :permission`, capture surviving non-`:noop` mechanism, broadcast `%Cancelled{}`, call `finish_cancel(data, "awaiting_permission")`, return (from `cancellation-teardown`).
- Replace the cross-cutting `:cancel` clause body (lines 963–1083) with a ≤5-line body: `cascade_to_children(data, :cancel)`, fold `@cancel_clusters` with `scope: :cross_cutting`, capture mechanism, broadcast, `finish_cancel(data, Atom.to_string(mechanism))`, return (from `cancellation-teardown`).
- Add private `finish_cancel/2` (≤10 lines): `Journal.persist/3`, steering-queue drain → `%QueueRestored{}` broadcast, `Data.reset_for_cancel/1` (from `cancellation-teardown`).
- Replace the three `{:user_message, _, _}` `handle_event/4` clauses with one-line delegations: postpone → `Queue.handle_postpone/2`; enqueue → `Queue.handle_enqueue/4`; idle → `SlashCommand.dispatch_idle/2` (from `user-message-routing`).

### F. New tests

- Four cluster-cancel unit modules: `test/tau/session/{provider_turn,tool_dispatch,compaction,coding_agent_turn}_cancel_cluster_test.exs` (from `cancellation-teardown`).
- One test for `Data.reset_for_cancel/1` (from `cancellation-teardown`).
- No test changes are required by the other three children; the existing cancellation integration tests, TUI cancel smoke, and slash-routing tests are the regression baseline.

## What does not change

- `Tau.Session.Data` struct fields, defaults, `@enforce_keys`, `@type t`, and `Data.new/1` return shape (`{:ok, %Tau.Session.Data{}}`).
- `Tau.Session.Meta`, `Tau.Session.Journal.persist/3`, `Tau.Session.SlashCommand.classify_slash_command/4`, `Tau.Session.Queue.handle_postpone/2`, `Tau.Session.Queue.handle_enqueue/4`, `Tau.Session.Queue.drain_steering_queue_one/1`.
- `cascade_to_children/2` remains a private helper in `session.ex` invoked at the top of the cross-cutting `:cancel` clause.
- `ProviderTurn.cancel_provider_task/1` keeps its signature; `cancel_cluster/2` calls it internally.
- `ToolDispatch.finish_permission_round/1` (happy-path) is unchanged.
- D-077, D-078, D-080, D-082, D-083 queue cap / drain ordering / `%QueueRestored{}` / `%Cancelled{}` broadcast contracts (SPEC-USER-TURN §6).
- External `Tau.Session` public API; all eight moved helpers were `@doc false`.
- The `:gen_statem` callbacks, FSM state machine, and supervision tree.
- Nested-map reads into `data.tool_loop_state`, `data.tools_in_flight`, `data.coding_agent_state`, `data.metadata` — explicitly out of scope per `cross-cutting-data`.
- `generate_id/0` (public API at `session.ex:487`).
- All existing tests; no test changes outside the five new test modules in §F.
- Provider adapter normalisation, `try/rescue` removal, `dispatch_tools/2` re-extraction, queue cap / drain / steering semantics, and any `test/` change outside §F — all out of scope per `problem.md`.

## Migration sketch

Four PRs in strict order. Each PR ends with a green `mix test`; no PR
leaves an intermediate broken state; each PR is independently revertible.

**PR 1 — `cross-cutting-data` (foundational data contract).** Single PR,
four conceptual commits: (1) add `get_queue/2`, `put_queue/3`,
`replace_field/3` to `Data`; (2) defensive-fix sweep (`queue.ex:43,63`;
`provider_turn.ex:179,337`; `model_swap.ex:94`); (3) add
`alias Tau.Session.Data` to the eight sub-modules currently without it;
(4) full 101-head `%Data{} = data` sweep. `reset_for_cancel/1` lands
here too so `cancellation-teardown` (PR 3) can call it immediately. No
sub-module body logic changes; `mix dialyzer` gains tighter type
information at every entry point.

**PR 2 — `fsm-facade-helpers` (helpers disperse to owning concerns).**
Single PR, additive then substitutive: (1) add `append_message/2`,
`generate_event_id/0`, `current_run?/2` to `Data`; (2) add `broadcast/2`
to `Events`; (3) create `lib/tau/session/telemetry.ex` with
`emit_transition/2` and `emit_user_message/3`; (4) create
`lib/tau/session/hooks.ex` with `payload/3`; (5) add
`process_user_message/2` to `Queue`; (6) update all callsites in
`session.ex` and the six sub-modules to the new module-qualified names;
(7) delete the eight `@doc false` defs from `session.ex`. Steps 1–5 are
additive; steps 6–7 land together. This PR resolves the
`emit_user_message_telemetry` coupling that PR 4 would otherwise
inherit.

**PR 3 — `cancellation-teardown` (clusters own their teardown).** Three
sub-PRs as per the child's Migration sketch:
- **PR 3A** — add `Tau.Session.Cancellable` behaviour; implement
  `cancel_cluster/2` on `ProviderTurn`, `ToolDispatch`, `Compaction`,
  `CodingAgentTurn` with new unit tests in §F. No change to
  `session.ex`; the new code is dead but tested.
- **PR 3B** — wire `session.ex`: add `@cancel_clusters` and
  `finish_cancel/2`; replace both `:cancel` clause bodies with the
  ≤5-line folds. Existing cancellation integration tests and TUI cancel
  smoke are the regression baseline (no changes).
- **PR 3C** — remove any private helpers in `session.ex` that the new
  clause bodies no longer call.

**PR 4 — `user-message-routing` (routing collapses to delegations).**
Single PR, one commit: add `SlashCommand.dispatch/2` (six clauses) and
`SlashCommand.dispatch_idle/2` (calls `classify_slash_command/4` then
`dispatch/2`; emits `Telemetry.emit_user_message(:delivered, …)`); update
the three `handle_event` clauses in `session.ex` to delegate to
`Queue.handle_postpone/2`, `Queue.handle_enqueue/4`, and
`SlashCommand.dispatch_idle/2`. Because PR 2 has already created
`Tau.Session.Telemetry`, the open question in
`user-message-routing` about where telemetry lives is answered at land
time: `SlashCommand.dispatch_idle/2` calls
`Tau.Session.Telemetry.emit_user_message/3`, not the deleted
`Tau.Session.emit_user_message_telemetry/3`.

After PR 4: `lib/tau/session.ex` satisfies the parent acceptance
criterion — no inline teardown, no `@doc false` cross-module utility
functions, no multi-branch routing bodies, no anonymous-map data init;
every `handle_event/4` body is a one-line delegation or a three-line
FSM return; `Tau.Session.Data` exports a typed struct that all
sub-modules pattern-match against.

The four PRs MAY be opened in parallel for review but MUST be merged in
order (1 → 2 → 3A → 3B → 3C → 4) so each landing PR sees its
substrate already in `main`. The factory-loop conflict check
(`.claude/rules/factory-loop.md` "Parallel execution") will serialize
them on the disjoint-files clause since they all touch `Data`,
`session.ex`, and overlapping sub-modules.

## Open questions

- **`finish_cancel/2` placement.** `cancellation-teardown` Open Questions
  asks whether the ≤10-line `finish_cancel/2` should remain a private
  helper in `session.ex` or be promoted to `Data` / a new
  `Tau.Session.Cancel.Finish` module. The synthesis defers to the
  validator. Keeping it inline keeps PR 3B small; promoting it
  honours a stricter reading of the parent's "no teardown logic in
  `session.ex`" criterion. The line-count is small enough that
  either reading is defensible.

- **Mechanism-atom semantics under the cluster fold.** `cancellation-teardown`
  flags that "last non-`:noop` wins" is currently equivalent to "provider's
  mechanism" because provider is the only cluster returning a non-`:noop`
  mechanism. If a future cluster begins returning a meaningful mechanism,
  the fold's tie-breaking rule must be revisited. No action here; flagged
  for the validator and any future cluster author.

- **`Data.replace_field/3` typed-key check.** `cross-cutting-data` notes
  Dialyzer cannot verify at the call site that `key` names a valid
  struct field. The single-grep "auditable escape hatch" property is
  the intended trade. Carried forward unchanged.

- **`dispatch_idle/2` naming under future invocation from non-idle
  state.** `user-message-routing` flags that the name encodes the
  current FSM state and would become misleading if dispatch is ever
  invoked from another state. Carried forward; rename is cheap if it
  becomes wrong.

- **`Tau.Session.Hooks.payload/3` rename.** `fsm-facade-helpers` Open
  Questions asks whether any external tooling references
  `Tau.Session.hook_payload/3` by name. Verify via grep over hook
  scripts and tests during PR 2.

- **Future sub-struct extraction in `Data`.** `cross-cutting-data` notes
  that the 101-head sweep creates re-edit cost if `Data` is later
  decomposed into sub-structs (Proposal 3 of that sub-problem). This is
  a known trade and is acceptable for this synthesis; the sub-struct
  refactor would be a successor audit node, not part of this plan.

## Linked sub-problems / proposals

- `subproblems/cross-cutting-data/` → "Typed accessors on `Data` + 101-head `%Data{} = data` struct-match sweep across nine sub-modules; adds `get_queue/2`, `put_queue/3`, `replace_field/3`, `reset_for_cancel/1`."
- `subproblems/fsm-facade-helpers/` → "Distribute the eight `@doc false` helpers by concern: pure helpers into `Data`; `broadcast/2` into `Events`; new `Tau.Session.Telemetry` and `Tau.Session.Hooks`; `process_user_message/2` into `Queue`."
- `subproblems/cancellation-teardown/` → "`Tau.Session.Cancellable` behaviour with scope-aware `cancel_cluster(scope, Data.t()) :: {atom(), Data.t()}`; both `:cancel` clauses collapse to ≤5-line folds over `@cancel_clusters`; `Data.reset_for_cancel/1` owns the cross-cutting field reset."
- `subproblems/user-message-routing/` → "`SlashCommand.dispatch_idle/2` (verbatim idle-clause extraction) plus `SlashCommand.dispatch/2` (six-arm dispatch table); two non-idle clauses delegate to existing `Queue.handle_postpone/2` and `Queue.handle_enqueue/4`."

## Revision history

- (revision 0 — initial synthesis from the four validated child solutions)
