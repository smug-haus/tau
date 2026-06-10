---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-3.md, proposals/proposal-4.md]
selection_method: hybrid
revision: 0
---

# Solution: `Cancellable` behaviour with scope-aware callback returning mechanism

## Recommendation

Define a `Tau.Session.Cancellable` behaviour whose sole callback —
`cancel_cluster(scope, Data.t()) :: {mechanism :: atom(), Data.t()}` —
is implemented by each cluster sub-module (`ProviderTurn`, `ToolDispatch`,
`Compaction`, `CodingAgentTurn`). Each implementation owns the kills,
demonitors, emit loops, and field resets for its own cluster, and returns
`{:noop | :cooperative | :brutal_kill, data}`. Add
`Data.reset_for_cancel/1` to `Tau.Session.Data` for the cross-cutting
per-turn fields no cluster owns. `session.ex` enumerates clusters in a
compile-time `@cancel_clusters` list, folds over them with `scope` passed
through, captures the surviving non-`:noop` mechanism for the journal,
broadcasts `%Cancelled{}`, and calls a private `finish_cancel/2` helper
that runs `Journal.persist/3`, drains `steering_queue` to `%QueueRestored{}`,
and applies `Data.reset_for_cancel/1`. Both `:cancel` clause bodies
collapse to ≤5 lines.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-3.md` (spine) and
  `proposals/proposal-4.md` (callback-signature enrichment).
- **Why chosen:** Proposal 3 is the deepest decomplection on the
  data-shape axis (each cluster module declares which fields it
  resets; the FSM holds no field knowledge) and is the only proposal
  that gives compiler-enforced cancel coverage via `@behaviour`. Its
  two named weaknesses — loss of ADR-0017's `mechanism` atom in the
  uniform fold, and `ToolDispatch.cancel_cluster/1` having to
  phase-disambiguate via field inspection — are exactly the two
  problems Proposal 4 solves: P4 threads the mechanism through the
  reduce via `{atom(), Data.t()}` and passes `scope` into each
  handler. Importing P4's signature into P3's behaviour absorbs P4's
  strengths without paying P4's costs (a novel `%Cancelling{}` event
  struct that is not actually PubSub-published, plus a silently
  authoritative `@handlers` list with no compile-time check). The
  hybrid keeps P3's compiler enforcement and removes both of P3's
  named weaknesses. Proposal 1 was rejected because it leaves
  `drain_steering_and_reset/2` resident in `session.ex` as a private
  helper, only partially satisfying the AC, and because adding the
  cancel function to each cluster module without a behaviour offers
  no protection against a future cluster sub-module forgetting to
  implement it. Proposal 2 was rejected because it concentrates
  cross-cluster knowledge in a new coordinator module rather than
  distributing ownership to the clusters themselves (the opposite of
  decomplecting on the data-shape axis) and depends on the
  `fsm-facade-helpers` sub-problem to avoid an import cycle.

Scoring table:

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|---|---|---|---|---|
| 1 | Partially | Substantial | Low | Low | Easy |
| 2 | Yes | Substantial | Medium | Medium | Hard |
| 3 | Yes | Deep | Medium | Low | Easy |
| 4 | Yes | Deep | Medium | Medium | Medium |
| **Hybrid (3+4)** | **Yes** | **Deep** | **Medium** | **Low** | **Easy** |

## What changes

- **New file `lib/tau/session/cancellable.ex`** — defines the
  `Tau.Session.Cancellable` behaviour with one callback:
  `@callback cancel_cluster(scope :: :permission | :cross_cutting, Tau.Session.Data.t()) :: {atom(), Tau.Session.Data.t()}`.
- **`lib/tau/session/provider_turn.ex`** — declare
  `@behaviour Tau.Session.Cancellable`; implement
  `cancel_cluster(_scope, data)` to call existing `cancel_provider_task/1`,
  capture its returned mechanism atom (`:cooperative | :brutal_kill | :noop`),
  and clear `{provider_task, cancel_flag, stream_ref, provider_span_ref, assembler}`.
- **`lib/tau/session/tool_dispatch.ex`** — declare
  `@behaviour Tau.Session.Cancellable`; implement `cancel_cluster(scope, data)`
  branching on `scope`: `:permission` runs the existing
  `finish_permission_round/1`-shaped emit-and-synthesise loop (formerly
  inlined in `session.ex` lines 842–961), `:cross_cutting` brutal-kills
  `tool_dispatcher` and `command_task`. Returns `{:noop, data}`. Owns the
  reset of `{pending_permission_requests, permission_dispatch_batch,
  permission_pending_results, tools_in_flight, tool_dispatcher, command_task,
  tool_loop_call_lookups}`.
- **`lib/tau/session/compaction.ex`** — declare
  `@behaviour Tau.Session.Cancellable`; implement
  `cancel_cluster(_scope, data)` to demonitor `compaction_monitor`,
  brutal-kill `compaction_task`, clear those two fields (NOT
  `compaction_failures`). Returns `{:noop, data}`.
- **`lib/tau/session/coding_agent_turn.ex`** — declare
  `@behaviour Tau.Session.Cancellable`; implement
  `cancel_cluster(_scope, data)` to guard-call
  `Tau.CodingAgent.Dispatcher.cancel/1` and clear
  `{coding_agent_dispatcher, coding_agent_pending, coding_agent_blocks}`.
  Returns `{:noop, data}`.
- **`lib/tau/session/data.ex`** — new function
  `reset_for_cancel/1` resetting the cross-cutting per-turn fields
  (`active_skill`, `tool_iterations`, `tool_loop_state`,
  `provider_retry_state`, `steering_queue` — but NOT
  `tool_loop_call_lookups`, which `ToolDispatch.cancel_cluster/1` owns).
- **`lib/tau/session.ex`** —
    - Add compile-time module list
      `@cancel_clusters [Tau.Session.ProviderTurn, Tau.Session.ToolDispatch, Tau.Session.Compaction, Tau.Session.CodingAgentTurn]`.
    - Replace the `:awaiting_permission` `:cancel` clause body (lines 842–961)
      with a ≤5-line body that folds `@cancel_clusters` with
      `scope: :permission`, picks the surviving non-`:noop` mechanism,
      broadcasts `%Cancelled{}`, calls `finish_cancel(data, "awaiting_permission")`,
      and returns `{:next_state, :awaiting_user, data, followup_actions(data)}`.
    - Replace the cross-cutting `:cancel` clause body (lines 963–1083)
      with a ≤5-line body that calls `cascade_to_children(data, :cancel)`,
      folds `@cancel_clusters` with `scope: :cross_cutting`, picks the
      surviving non-`:noop` mechanism, broadcasts `%Cancelled{}`, calls
      `finish_cancel(data, Atom.to_string(mechanism))`, and returns
      `{:next_state, :awaiting_user, data, followup_actions(data)}`.
    - Add private `finish_cancel/2` (≤10 lines) running
      `Journal.persist/3`, the steering-queue drain →
      `%QueueRestored{}` broadcast, and `Data.reset_for_cancel/1`.
- **New tests** — one test module per cluster
  (`test/tau/session/{provider_turn,tool_dispatch,compaction,coding_agent_turn}_cancel_cluster_test.exs`)
  exercising each `cancel_cluster/2` in isolation, plus a test for
  `Data.reset_for_cancel/1`.

## What does not change

- `cascade_to_children/2` stays a private helper in `session.ex`,
  invoked at the top of the cross-cutting clause body (the problem
  statement explicitly preserves this call site).
- `Tau.Session.Journal.persist/3` is unchanged; cancel paths continue
  to call it.
- D-080 / D-082 queue-drain ordering and `%QueueRestored{}` /
  `%Cancelled{}` broadcast contracts (SPEC-USER-TURN §6) are
  preserved — they are behavioural, not structural.
- The external `%Tau.Session.Events.Cancelled{}` struct, its consumers,
  and the journal `"cancellation"` entry's schema are unchanged.
- `try/rescue` removal is explicitly out of scope.
- `ProviderTurn.cancel_provider_task/1` keeps its current signature and
  contract; the new `cancel_cluster/2` calls it internally.
- `ToolDispatch.finish_permission_round/1` (the happy-path) is unchanged;
  the `:permission`-scope `cancel_cluster/2` branch shares structure
  with it but does not call it.
- The sibling sub-problems (`fsm-facade-helpers`, `user-message-routing`,
  `cross-cutting-data`) are not touched by this solution; this solution
  does NOT depend on any of them landing first.

## Migration sketch

Land in three independently-mergeable PRs to keep blast radius bounded:

1. **PR A — behaviour + cluster implementations + tests.** Add
   `Tau.Session.Cancellable`, implement `cancel_cluster/2` on the four
   cluster modules with new unit tests, and add `Data.reset_for_cancel/1`.
   Nothing in `session.ex` changes; the new code is dead but tested. CI
   green proves each cluster's teardown is correct in isolation.
2. **PR B — wire `session.ex`.** Add `@cancel_clusters` and
   `finish_cancel/2`; replace both `:cancel` clause bodies with the
   ≤5-line fold. The existing cancellation integration tests
   (`test/tau/session/cancellation_*` and the TUI cancel smoke) are the
   regression baseline; they must remain green without modification.
3. **PR C — delete dead code and inline helpers.** Remove any private
   helpers in `session.ex` that the new clause bodies no longer call.

If `PR B` reveals an ordering subtlety (e.g. provider kill must precede
tool dispatcher kill, or vice versa), the fix is a one-line reorder of
the `@cancel_clusters` list — the order is data, not code structure.

## Open questions

- Does the `:awaiting_permission` `:cancel` path tolerate running
  `ProviderTurn.cancel_cluster/2` against a nil `provider_task`? The
  existing `cancel_provider_task/1` already handles the nil case
  (returns `:noop`), so the uniform fold across both scopes should be
  safe — but PR A's unit test for `ProviderTurn.cancel_cluster/2` must
  exercise the nil case explicitly.
- Is the mechanism atom captured by the fold (last non-`:noop` wins)
  semantically equivalent to the current cross-cutting clause's
  recorded mechanism (which today comes only from
  `cancel_provider_task/1`)? Provider is the only cluster that returns
  a non-`:noop` mechanism, so "last non-`:noop`" reduces to "provider's
  return" — but if a future cluster ever returns a meaningful
  mechanism, the fold's tie-breaking rule must be revisited.
- Should `finish_cancel/2` be a private helper in `session.ex`, or
  promoted to `Tau.Session.Data` (or a new `Tau.Session.Cancel.Finish`
  module) so the FSM owns zero teardown logic? Keeping it inline keeps
  the PR small; the validator should rule on whether ≤10 inline lines
  of journal+drain+reset in the FSM module satisfies the AC's "owning
  sub-modules" clause.
- `tool_loop_call_lookups` ownership: `ToolDispatch.cancel_cluster/2`
  owns it for the `:permission` scope (existing inline code mutates it
  there); does the `:cross_cutting` scope also need to clear it, or
  does `Data.reset_for_cancel/1`? The current cross-cutting clause
  resets it; the recommendation places it in `ToolDispatch` (which
  owns the field) and runs the cluster fold for both scopes, so the
  reset happens in either case.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — add `cancel_*` siblings on each cluster
  module without a behaviour. Rejected: no compile-time enforcement,
  leaves drain helper in `session.ex`.
- `proposals/proposal-2.md` — extract both clause bodies into a new
  `Tau.Session.Cancel` coordinator module. Rejected: concentrates
  rather than distributes cluster knowledge; import-cycle risk with
  `session.ex` helpers requires `fsm-facade-helpers` first.
- `proposals/proposal-3.md` — `Cancellable` behaviour with single-arg
  `cancel_cluster/1` + `Data.reset_for_cancel/1`. Chosen as the
  spine.
- `proposals/proposal-4.md` — `%Cancelling{}` internal event +
  `handle_cancelling/2` dispatcher. Chosen for the signature
  enrichment: `scope` argument and `{atom(), Data.t()}` return.

## Revision history

- (revision 0 — initial)
