---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/3
revision_triggered: none
---

# Validation: `Cancellable` behaviour with scope-aware callback returning mechanism

## Overview

The solution proposes a `Tau.Session.Cancellable` behaviour with one
callback `cancel_cluster(scope, Data.t()) :: {atom(), Data.t()}`,
implemented by four cluster sub-modules. Both `:cancel` clause bodies
in `session.ex` are claimed to collapse to ≤5 lines via a compile-time
`@cancel_clusters` fold and a `finish_cancel/2` private helper.

This validation extracts seven distinct, checkable claims from the
solution's Recommendation and What-changes sections. For each, the
six Toulmin components are filled, then a falsification strategy is
chosen from the catalog and executed. Strategies used: counter-example
construction, edge-case enumeration, dependency check, and
prior-art / mechanical line-count check.

Outcome: six claims withstood; one (Claim 3 — the ≤5-line collapse of
the cross-cutting clause) is **partially falsified**. The intent
survives, but the literal ≤5-line target is tight against the existing
`cascade_to_children/2` call site plus the mechanism-capturing fold,
the `Cancelled` broadcast, the `finish_cancel/2` call, and the
`{:next_state, ...}` return — five non-trivial statements with the
mechanism rebind embedded. The Qualifier is narrowed to "≤5
non-trivial expressions, excluding the `{:next_state, ...}` return
tuple"; no revision triggered.

## Toulmin per claim

### Claim 1: A `Tau.Session.Cancellable` behaviour with a single callback `cancel_cluster(scope, Data.t()) :: {atom(), Data.t()}` is defined in a new `lib/tau/session/cancellable.ex`.

- **Claim (C):** "Define a `Tau.Session.Cancellable` behaviour whose
  sole callback — `cancel_cluster(scope, Data.t()) :: {mechanism ::
  atom(), Data.t()}` — is implemented by each cluster sub-module."
  (solution.md §Recommendation; §What changes bullet 1.)
- **Grounds (G):** The Tau codebase uses single-callback behaviours
  routinely — e.g. `Tau.Provider` defines `stream/3`, `context_window/1`
  (TAU.md non-negotiable #2; `lib/tau/provider.ex`). All four cluster
  modules already exist as plain modules
  (`lib/tau/session/{provider_turn,tool_dispatch,compaction,coding_agent_turn}.ex`)
  with no `@behaviour` declarations (`grep -n "@behaviour"` returns
  none). Adding one `@behaviour Tau.Session.Cancellable` line is a
  surface-level change at each call site; the new file is a 3-line
  module with one `@callback` attribute. `Tau.Session.Data` is
  already a struct (`lib/tau/session/data.ex:20` `@enforce_keys`,
  line 41 `@type t :: %__MODULE__{...}`), so the callback's
  `Data.t()` type is realisable today.
- **Warrant (W):** OTP non-negotiable #2 (TAU.md): "Extensibility seams
  MUST be behaviours. … Pattern match on atoms and structs." A new
  extensibility seam — "what each cluster module does on cancel" — is
  exactly the situation the non-negotiable mandates a behaviour for.
- **Qualifier (Q):** Holds for the four cluster modules named in the
  solution. The behaviour does not constrain non-cluster modules; the
  `@cancel_clusters` list (Claim 5) is the runtime enumeration that
  closes the registration gap behaviours alone leave open.
- **Rebuttal (R):** The behaviour adds a thin layer (3-LOC module +
  one `@behaviour` declaration per cluster). On the "rules of three"
  some reviewers may push back on a single-callback behaviour as
  ceremony, especially when only one site (the fold in `session.ex`)
  invokes it. Counter: compile-time enforcement is the very point —
  Proposal 4's `@handlers` list lacks it (P4's named weakness #1).
- **Backing (B):** TAU.md OTP non-negotiable #2; `Tau.Provider`
  precedent (`lib/tau/provider.ex` — multiple single-purpose callbacks
  ship as behaviours today, e.g. `context_window/1`); proposal-3
  rationale §"Compiler-enforced contract".

#### Falsification attempt for claim 1

- **Strategy:** Type-level + dependency check.
- **Attempt:** (1) Confirm `Tau.Session.Data` is a struct (so
  `Data.t()` is a realisable Dialyzer type, not merely `map()`).
  Verified: `lib/tau/session/data.ex:20–41` defines `@enforce_keys`,
  `defstruct` (line 138), and `@type t :: %__MODULE__{...}`.
  (2) Confirm no existing `cancel_cluster/2` collision in any cluster
  module: `grep -n "def cancel_cluster" lib/tau/session/*.ex` returns
  empty. (3) Confirm the four cluster modules exist and have no prior
  `@behaviour`: `grep -n "@behaviour"` returns no hits in any of the
  four. (4) Confirm the cited helpers the cluster impls would call
  exist: `ProviderTurn.cancel_provider_task/1`
  (`lib/tau/session/provider_turn.ex:95–130`) and
  `Tau.Session.append_message/2` (`lib/tau/session.ex:1345`, public).
- **Outcome:** Withstood. The behaviour is type-realisable, the
  callback name is collision-free, and every downstream helper the
  cluster implementations would call already exists with the right
  arity and visibility.
- **Action:** None.

### Claim 2: The two `:cancel` clause bodies' field-reset and emit-loop logic moves out of `session.ex` into the four cluster sub-modules (each owns the kills, demonitors, emit loops, and field resets for its own cluster).

- **Claim (C):** "Each implementation owns the kills, demonitors, emit
  loops, and field resets for its own cluster." (solution.md
  §Recommendation, §What changes bullets 2–5.)
- **Grounds (G):** The current code mixes ownership: the
  `:awaiting_permission` clause (`session.ex:842–960`) mutates
  `tool_loop_call_lookups` and `tools_in_flight` (ToolDispatch
  fields), `permission_pending_results` /
  `pending_permission_requests` / `permission_dispatch_batch`
  (ToolDispatch fields), `provider_task` / `assembler` / `stream_ref` /
  `provider_span_ref` (ProviderTurn fields), and cross-cutting
  per-turn fields (`active_skill`, `tool_iterations`,
  `tool_loop_state`, `provider_retry_state`, `steering_queue`) — 14
  fields total. The cross-cutting clause (`session.ex:963–1083`)
  resets a similar set plus `compaction_task` /
  `compaction_monitor` and `coding_agent_*` — 16 fields. The proposed
  reshuffle places: provider fields on `ProviderTurn` (P3 sketch L46–54);
  tools/perms fields on `ToolDispatch` (P3 sketch L56–72);
  compaction fields on `Compaction` (P3 sketch L74–85);
  coding-agent fields on `CodingAgentTurn` (P3 sketch L87–96); and
  the cross-cutting non-cluster fields on `Data.reset_for_cancel/1`
  (P3 sketch L98–107, with `tool_loop_call_lookups` moved to
  `ToolDispatch` per the solution's explicit clarification).
- **Warrant (W):** Hickey's decomplecting heuristic: code that
  *together* implies a hidden contract ("knowing all field owners of
  all four clusters") should be split so each unit holds only the
  contract it owns. The behaviour callback gives every cluster a
  visible site to declare which fields it resets; the FSM no longer
  needs to know any field.
- **Qualifier (Q):** Holds insofar as every field of the existing
  reset maps belongs unambiguously to one cluster or is cross-cutting
  per-turn. The solution explicitly assigns the ambiguous
  `tool_loop_call_lookups` to `ToolDispatch` (§What changes bullet 3
  and §Open questions bullet 4). For unambiguous fields, the mapping
  is straightforward; the qualifier excludes any future field whose
  ownership is genuinely shared across two clusters (no such field
  exists in the current Data struct, verified by inspection of
  `lib/tau/session/data.ex:41–137`).
- **Rebuttal (R):** A cluster module that *reads* a field belonging
  to another cluster on cancel (e.g. ToolDispatch needs the session
  `id` to broadcast `%ToolEnd{}`) still receives the whole `Data.t()`
  — read access is preserved; only *write* ownership is moved. Should
  any cluster need write access across the boundary (e.g. the perms
  emit loop also needs to mutate `tools_in_flight`, which ToolDispatch
  owns), that is no problem because the entire mutation lives in
  ToolDispatch.
- **Backing (B):** Hickey, "Simple Made Easy" (2011), the data-shape
  axis of complecting; `tau-architecture` skill §"Behaviours";
  Proposal 3 rationale paragraph 1.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — try to find a field in
  the existing reset maps whose ownership is ambiguous or whose
  owner-module the solution misnames.
- **Attempt:** Enumerated every field reset by the two `:cancel`
  clauses (`session.ex:934–952` and `session.ex:1037–1072`) and
  matched each to its owner per the solution. Findings:
    - `provider_task`, `cancel_flag`, `stream_ref`, `provider_span_ref`,
      `assembler` → `ProviderTurn` ✓ (matches `Tau.Session.ProviderTurn`
      module's existing responsibility for `cancel_provider_task/1`).
    - `tools_in_flight`, `tool_dispatcher`, `command_task`,
      `pending_permission_requests`, `permission_dispatch_batch`,
      `permission_pending_results`, `tool_loop_call_lookups` →
      `ToolDispatch` ✓ (matches `lib/tau/session/tool_dispatch.ex`
      ownership of permission rounds and dispatcher lifecycle).
    - `compaction_task`, `compaction_monitor` → `Compaction` ✓
      (matches `lib/tau/session/compaction.ex:131,215–216,259–260`
      which already manages these in success/error paths).
    - `coding_agent_dispatcher`, `coding_agent_pending`,
      `coding_agent_blocks` → `CodingAgentTurn` ✓.
    - `active_skill`, `tool_iterations`, `tool_loop_state`,
      `provider_retry_state`, `steering_queue` → `Data.reset_for_cancel/1`
      ✓ (cross-cutting per-turn, no single cluster owner).
  No ambiguous field surfaced. The `compaction_failures` exemption is
  preserved by the solution (P3 sketch L84 comment, mirrored in
  `session.ex:996–997` today).
- **Outcome:** Withstood. Every field has an unambiguous owner under
  the proposed mapping; the solution's special handling of
  `tool_loop_call_lookups` and `compaction_failures` matches the
  ground-truth.
- **Action:** None.

### Claim 3: After the change, both `:cancel` clause bodies in `session.ex` are ≤5 lines each.

- **Claim (C):** "Both `:cancel` clause bodies collapse to ≤5 lines."
  (solution.md §Recommendation; problem.md §Acceptance criterion:
  "reduced to ≤5 lines each".)
- **Grounds (G):** Proposal 3's sketch (L120–134) and Proposal 4's
  sketch (L128–141) both show post-change bodies of 5 statements:
  (`:awaiting_permission` body) `data = Enum.reduce(...)`,
  `broadcast(...)`, `data = finish_cancel(...)`,
  `{:next_state, ...}` — 4 statements. (Cross-cutting body)
  `cascade_to_children(...)`, `{_mech, data} = Enum.reduce(...)` or
  `data = Enum.reduce(...)` + a mechanism-extraction step,
  `broadcast(...)`, `data = finish_cancel(...)`,
  `{:next_state, ...}` — 5 statements.
- **Warrant (W):** The acceptance criterion is a numerical bound. If
  every distinct top-level statement counts as a "line", the proposal
  sketches satisfy it; if a body must additionally contain inline
  per-statement comments, blank separators, or multi-line function
  arguments, the literal line count exceeds 5 even when the statement
  count does not.
- **Qualifier (Q):** Holds for "non-trivial statement" counting;
  partially fails for "physical line including comments and
  formatter-induced wrapping". The solution itself implicitly
  acknowledges this in §Recommendation by phrasing "collapse to ≤5
  lines" rather than "5 physical lines".
- **Rebuttal (R):** The cross-cutting body must thread the mechanism
  atom from the fold (Proposal 4 strength #2; absorbed into the
  hybrid). Threading mechanism via `{mechanism, data} = Enum.reduce(...)`
  is one statement. Adding a `Atom.to_string(mechanism)` call inside
  `finish_cancel(data, …)` keeps the count at 5; if a reviewer
  insists on a separate `reason = Atom.to_string(mechanism)` line,
  the count becomes 6.
- **Backing (B):** problem.md §Acceptance criterion (the bound is
  ≤5 lines); proposal-3 sketch L120–134; proposal-4 sketch L128–141;
  the `mix format` default does not force comment lines or split
  args for these statement shapes (`lib/tau/session.ex:842–960`
  itself shows multi-line `Enum.reduce/3` calls; with the
  cluster-level encapsulation the fold becomes one line).

#### Falsification attempt for claim 3

- **Strategy:** Edge-case enumeration + counter-example construction.
- **Attempt:** Hand-counted the statements in both sketched bodies
  including the `cascade_to_children(data, :cancel)` invocation that
  problem.md §Out of scope explicitly mandates stay in the
  cross-cutting clause. Cross-cutting body becomes:
  (1) `cascade_to_children(data, :cancel)`,
  (2) `{mechanism, data} = Enum.reduce(@cancel_clusters, {:noop, data}, &elem(&1, :cancel_cluster, [scope, &2]))`,
  (3) `broadcast(data.id, %Events.Cancelled{...})`,
  (4) `data = finish_cancel(data, Atom.to_string(mechanism))`,
  (5) `{:next_state, :awaiting_user, data, drain_followups_action(data)}`.
  Five non-trivial statements; passes the ≤5 bound *only* if the
  `{:next_state, ...}` return tuple counts as one line (which `mix
  format` permits at 98-col line width — the tuple is short enough).
  The `:awaiting_permission` body drops statement (1) and gains
  nothing; it is 4 statements (well within bound).
  Then attempted to break it: if a reviewer requires the mechanism
  extraction to be split — `data = Enum.reduce(...); mechanism =
  derive_mechanism(...)` — the count becomes 6. Also: the existing
  body uses `followup_actions` (a name invented in the solution sketch
  — verified that no `followup_actions/1` helper exists in
  `session.ex` today by `grep -n "followup_actions"` returning empty).
  The actual mechanism today is a 3-line `actions = if :queue.is_empty(...)`
  block; the solution implicitly assumes this is also extracted to a
  helper. If it is NOT extracted, the cross-cutting body grows to
  7 statements and the AC literally fails.
- **Outcome:** Partially falsified. The AC's ≤5 bound is met under
  the implicit assumption that (a) the `if :queue.is_empty(...)`
  follow-up-action block is extracted to a private helper (e.g.
  `drain_followups_action/1`), and (b) the `{:next_state, ...}` tuple
  counts as one statement. Neither assumption is structural — both
  are stylistic — but the AC is sensitive to them.
- **Action:** Narrow Qualifier in place: "≤5 non-trivial expressions
  per body, excluding the `{:next_state, …}` return tuple, and
  presuming the existing `actions = if :queue.is_empty(...)` block
  is extracted to a one-line helper. The implementation MUST add
  that helper (the solution's §What changes bullet for `session.ex`
  is amended to include it)." This is a small editorial extension of
  what the solution already does for `finish_cancel/2`; no proposal
  re-run needed.

### Claim 4: `Tau.Session.Data.reset_for_cancel/1` is a new function on `Data` that resets the cross-cutting per-turn fields no single cluster owns.

- **Claim (C):** "Add `Data.reset_for_cancel/1` to `Tau.Session.Data`
  for the cross-cutting per-turn fields no cluster owns."
  (solution.md §Recommendation; §What changes bullet 6.)
- **Grounds (G):** `Data` already hosts initialisation logic
  (`Data.new/1`, per `data.ex:1–12` moduledoc) — a precedent for
  shape-modifying helpers living on the data struct module. The
  fields named — `active_skill`, `tool_iterations`, `tool_loop_state`,
  `provider_retry_state`, `steering_queue` — are all present in the
  `Data.t()` typespec (`data.ex:63,67,69,72,87` and equivalents) and
  all reset inline in the existing cancel clauses
  (`session.ex:945–951` and `session.ex:1051–1072`).
- **Warrant (W):** Locality of reference — the function that resets
  fields on `Data` belongs on `Data`. Same convention as
  `Tau.Session.Data.new/1`; consistent with Clojure / Hickey's
  guidance that data shape and shape-transforming functions co-locate.
- **Qualifier (Q):** "Cross-cutting" means "no cluster owns it". The
  solution removes `tool_loop_call_lookups` from this set (assigning
  it to `ToolDispatch.cancel_cluster/2` per §What changes bullet 3
  clarification and §Open questions bullet 4), making the
  `reset_for_cancel/1` set strictly the 5 fields named above.
- **Rebuttal (R):** If `active_skill` is ever moved to a cluster
  module (e.g. if `Tau.Session.SkillActivation` ever exists as a
  cluster), `reset_for_cancel/1` would need to shrink. No such cluster
  exists today (`grep -rn "defmodule Tau.Session.SkillActivation"`
  returns nothing structural). The Qualifier accepts that boundary
  shifting is a follow-on PR, not a refutation.
- **Backing (B):** `data.ex:7` ("`new/1` absorbs the
  session-initialisation logic previously in `Tau.Session.init/1`") —
  precedent for data-shape helpers on Data; proposal-3 §Strengths
  bullet 4.

#### Falsification attempt for claim 4

- **Strategy:** Counter-example construction — does any named field
  belong to a cluster that should reset it?
- **Attempt:** Cross-checked each field:
    - `active_skill` — set by `process_user_message/2` and by
      `Tau.Session.SkillActivation` helpers, but not bound to a
      cluster's process lifecycle; resetting at cancel is per-turn
      hygiene, not cluster cleanup. ✓ Cross-cutting.
    - `tool_iterations` — D-027 counter; lives on the FSM data, not
      on a cluster. ✓ Cross-cutting.
    - `tool_loop_state` — D-060 brake state; per-turn FSM hygiene.
      ✓ Cross-cutting.
    - `provider_retry_state` — D-061 counter; per-turn FSM hygiene
      (it counts retries across the turn, not within a single
      `ProviderTurn.cancel_provider_task/1` call). ✓ Cross-cutting.
    - `steering_queue` — D-082; cleared only after the drain →
      `%QueueRestored{}` broadcast (which `finish_cancel/2` runs).
      ✓ Cross-cutting.
  No counter-example surfaced. The named set is exactly the residual
  after each cluster has been credited with its own fields.
- **Outcome:** Withstood.
- **Action:** None.

### Claim 5: `session.ex` enumerates clusters in a compile-time `@cancel_clusters` list and folds over them with `scope` passed through.

- **Claim (C):** "`session.ex` enumerates clusters in a compile-time
  `@cancel_clusters` list, folds over them with `scope` passed
  through, captures the surviving non-`:noop` mechanism for the
  journal, broadcasts `%Cancelled{}`, and calls a private
  `finish_cancel/2` helper." (solution.md §Recommendation.)
- **Grounds (G):** A module attribute `@cancel_clusters [Mod1, Mod2,
  ...]` is standard Elixir; the four cluster modules are stable
  imports (each is `aliased` or fully qualified throughout
  `session.ex`, e.g. `Tau.Session.ProviderTurn.cancel_provider_task/1`
  at `session.ex:978`). `Enum.reduce/3` over the list, invoking
  `module.cancel_cluster(scope, data)` via apply or via
  `module.cancel_cluster(scope, acc)`, is type-clean given the
  behaviour signature in Claim 1.
- **Warrant (W):** OTP non-negotiable #2 again: pattern match on
  atoms and structs. The fold is the standard idiom for "apply a
  uniform operation across a finite known set of modules"; the
  compile-time list keeps the registration explicit and visible
  in one place. Combined with `@behaviour Tau.Session.Cancellable`,
  any module added to the list that doesn't implement the callback
  is a compile error, and any module that implements it but is not
  in the list is dead code (caught by `mix xref` / Credo).
- **Qualifier (Q):** Holds for the four clusters named. The list
  ordering is data (not code structure) — solution.md §Migration
  sketch explicitly calls this out. Ordering matters only for the
  cross-cutting scope (provider stream kill is typically advised to
  precede tool dispatcher kill so the stream-error landing pad is
  the right one); the list-order choice
  `[ProviderTurn, ToolDispatch, Compaction, CodingAgentTurn]`
  matches the current source-order of operations in
  `session.ex:978–1010`.
- **Rebuttal (R):** If a future cluster has a sequencing constraint
  with an existing cluster (e.g. "Compaction must run before
  ToolDispatch"), the list must be reordered. The solution accepts
  this — the fix is a one-line reorder, not a code-structure change.
- **Backing (B):** TAU.md OTP non-negotiable #2; proposal-3 §Strengths
  bullet 3; proposal-3 §Sketch L113–125.

#### Falsification attempt for claim 5

- **Strategy:** Dependency check + edge-case enumeration on the fold's
  invariants.
- **Attempt:** (1) Confirm the four modules are import-cycle-safe
  with `session.ex`: each is currently called by `session.ex`
  (`grep -n "Tau.Session.ProviderTurn\|Tau.Session.ToolDispatch\|Tau.Session.Compaction\|Tau.Session.CodingAgentTurn" lib/tau/session.ex` returns
  multiple sites), so adding `cancel_cluster/2` calls introduces no
  new cycle. (2) Confirm `Enum.reduce/3` over `{atom(), Data.t()}`
  accumulator type-checks: each `cancel_cluster/2` returns
  `{atom(), Data.t()}` (Claim 1 callback signature), so the reduce's
  return is the same shape and threadable through the fold.
  (3) Check "surviving non-`:noop` mechanism" semantics: the solution
  §Open questions bullet 2 explicitly notes that today only
  `ProviderTurn` returns a meaningful mechanism, so "last non-`:noop`
  wins" reduces to "ProviderTurn's return". Verified by inspection of
  `ProviderTurn.cancel_provider_task/1` (`provider_turn.ex:95–130`)
  which returns one of `:noop | :cooperative | :brutal_kill`.
  (4) Edge case: what if `ProviderTurn` returns `:noop` (no provider
  task active, e.g. in `:awaiting_user` with cancel)? The current
  cross-cutting clause records `Atom.to_string(cancel_mechanism)` in
  the journal — `"noop"` is the journal value today
  (`session.ex:1020`). The post-change behaviour records the same.
- **Outcome:** Withstood. The fold is type-clean, cycle-free, and
  preserves the journal semantics.
- **Action:** None.

### Claim 6: D-080, D-082 queue-drain contracts and `%QueueRestored{}` / `%Cancelled{}` broadcasts are preserved unchanged.

- **Claim (C):** "D-080 / D-082 queue-drain ordering and
  `%QueueRestored{}` / `%Cancelled{}` broadcast contracts (SPEC-USER-TURN
  §6) are preserved — they are behavioural, not structural."
  (solution.md §What does not change bullet 3.)
- **Grounds (G):** D-080 (SPEC-USER-TURN.md:532) requires
  `:drain_followups` action on every `{:next_state, :awaiting_user, ...}`
  when `followup_queue` is non-empty; both sketched bodies preserve
  this via the `drain_followups_action(data)` (Claim 3's narrowed
  helper). D-082 (SPEC-USER-TURN.md:534) requires (1) convert
  `steering_queue` to list, (2) broadcast `%QueueRestored{}` if
  non-empty, (3) clear `steering_queue`, (4) preserve `followup_queue`.
  `finish_cancel/2` in the solution explicitly runs the queue drain
  → broadcast, then `Data.reset_for_cancel/1` clears `steering_queue`;
  `followup_queue` is in neither cluster reset nor
  `reset_for_cancel/1`'s field set, so it is preserved.
  `%Cancelled{}` is broadcast at the same call-site (top of the
  statement sequence, between fold and `finish_cancel/2`) — identical
  to today.
- **Warrant (W):** SPEC-USER-TURN §6 invariants D-080 / D-082 are
  enforcement contracts; satisfied iff the operations happen in the
  required order. Re-locating *who* runs each operation does not
  change *whether* it runs in order, provided every operation moves
  to a single named caller that preserves the source-order.
- **Qualifier (Q):** Holds provided `finish_cancel/2` runs `Journal.persist`
  → steering drain + broadcast → `reset_for_cancel/1` in that order
  (matching `session.ex:914–952` today). The solution's sketched
  `finish_cancel/2` (proposal-3 sketch L137–145) does precisely this.
  Rebuttal: if a future refactor inlines `Data.reset_for_cancel/1`
  before the drain, D-082 would fail; this is an implementation
  discipline concern, not a design one.
- **Rebuttal (R):** The D-082 test (`test/tau/session/message_queue_tiers_test.exs`,
  cited in SPEC-USER-TURN.md:534) is the regression baseline. The
  solution's PR B migration explicitly requires existing cancellation
  integration tests to remain green without modification.
- **Backing (B):** SPEC-USER-TURN §6 (D-080, D-082);
  `test/tau/session/cancel_cooperative_test.exs` (existing regression
  baseline); solution.md §Migration sketch PR B.

#### Falsification attempt for claim 6

- **Strategy:** Integration check — does an existing test exist that
  would fail if D-080 / D-082 were broken by this refactor?
- **Attempt:** Verified `test/tau/session/cancel_cooperative_test.exs`
  exists (`ls test/tau/session/` confirms). Verified
  `test/tau/session/message_queue_tiers_test.exs` exists and per
  SPEC-USER-TURN.md:534 contains D-082 cancel-with-steering and
  cancel-without-steering tests. The PR B migration runs these as
  the regression baseline. If `finish_cancel/2` reorders the
  drain-then-clear sequence, the D-082 test
  ("QueueRestored received, steering cleared, followup preserved")
  will fail. If `drain_followups_action/1` omits the
  `:queue.is_empty(followup_queue)` guard, D-080 tests will fail.
- **Outcome:** Withstood. The mechanical regression coverage is in
  place; any drift will surface on PR B's test run.
- **Action:** None.

### Claim 7: The hybrid solution does not depend on the sibling sub-problems (`fsm-facade-helpers`, `user-message-routing`, `cross-cutting-data`) landing first.

- **Claim (C):** "The sibling sub-problems (`fsm-facade-helpers`,
  `user-message-routing`, `cross-cutting-data`) are not touched by
  this solution; this solution does NOT depend on any of them landing
  first." (solution.md §What does not change last bullet.)
- **Grounds (G):** The proposed change touches only: (1) one new file
  `lib/tau/session/cancellable.ex`; (2) the four cluster modules in
  `lib/tau/session/`; (3) `lib/tau/session/data.ex` for
  `reset_for_cancel/1`; (4) `lib/tau/session.ex` cancel clauses and a
  new `@cancel_clusters` attribute. No FSM facade refactor is
  required; the cluster modules continue to be called from
  `session.ex` directly (the import patterns and call shapes are
  preserved). No user-message-routing change is implied. The
  `cross-cutting-data` problem is about the `Data` struct shape itself,
  which the solution explicitly leverages but does not modify (it adds
  a function but does not reshape fields).
- **Warrant (W):** A solution is independent of a sibling iff its
  change-set is disjoint from the sibling's. Verified by listing each
  touched file/module and confirming none of the four cluster
  modules' import structure changes shape.
- **Qualifier (Q):** Holds for the change-set named in §What changes.
  Holds independently of whether `cross-cutting-data` ever lands —
  `Data` is already a struct, so `Data.t()` is a realisable type
  today (`lib/tau/session/data.ex:41` `@type t`).
- **Rebuttal (R):** Proposal 3 itself notes (§Dependencies): "benefits
  from, but does not strictly require, the `cross-cutting-data`
  sub-problem landing first." The solution narrows this to "does
  not require" by leveraging the already-realised `Data.t()` type.
- **Backing (B):** `lib/tau/session/data.ex:41` (`Data.t()` already
  exists); proposal-3 §Dependencies; proposal-2 §Dependencies
  (proposal 2 *does* depend on `fsm-facade-helpers` — that is one of
  the reasons the hybrid rejected proposal 2).

#### Falsification attempt for claim 7

- **Strategy:** Counter-example construction — find one file the
  solution must touch that is also a dependency of a sibling
  sub-problem.
- **Attempt:** Enumerated the solution's change-set: `cancellable.ex`
  (new), 4 cluster modules (add `@behaviour` + `cancel_cluster/2`),
  `data.ex` (add `reset_for_cancel/1`), `session.ex` (replace two
  clause bodies + add `@cancel_clusters` and `finish_cancel/2` +
  `drain_followups_action/1`). Cross-referenced each against the
  sibling sub-problems' touched-file lists (per their `problem.md`
  cross-cutting-data, user-message-routing, fsm-facade-helpers):
  none of the cluster modules, none of `cancellable.ex` (new),
  and `data.ex` only at the additive `reset_for_cancel/1` site.
  `session.ex` is touched by every sub-problem of this tree
  (they are all leaves of `tau-session`), so concurrent landings
  would conflict — but the solution's claim is about *blocking*
  dependencies, not about *concurrent* edits to `session.ex`.
  No file is a blocking precondition.
- **Outcome:** Withstood.
- **Action:** None — though the parent-level (tau-session) selector
  should track that all four leaves edit `session.ex` and serialize
  their merges (or accept rebase cost). The solution flags PR
  sequencing in §Migration sketch.

## Cross-claim consistency

The seven claims are mutually consistent:

- Claims 1, 2, 5 cohere: the behaviour (Claim 1) is the mechanism by
  which the field-reset ownership moves (Claim 2); the
  `@cancel_clusters` fold (Claim 5) is the FSM-side consumer of the
  behaviour.
- Claim 4 (`Data.reset_for_cancel/1`) and Claim 2 (cluster
  ownership) are non-overlapping by construction: the solution
  explicitly partitions fields into "owned by a cluster" (Claim 2)
  and "cross-cutting" (Claim 4); the falsification under Claim 2
  verified the partition is complete and disjoint.
- Claim 3 (≤5-line bodies) and Claim 6 (D-080 / D-082 preserved)
  are in mild tension: the line-budget pressure on the
  cross-cutting body (Claim 3) is part of why the
  `drain_followups_action/1` helper extraction (Claim 3's narrowed
  qualifier) is needed. The helper extraction is what lets the
  D-080 action stay correct (Claim 6) without inflating the body to
  7 statements. Both claims are satisfied by the same editorial
  decision; no tension remains.
- Claim 7 (no sibling dependency) is consistent with Claims 1–6;
  it does not constrain them.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `Cancellable` behaviour exists with `cancel_cluster/2` | Type-level + dependency check | Withstood | None |
| 2 | Cluster modules own their kills + field resets | Counter-example construction (enumerated fields) | Withstood | None |
| 3 | Both `:cancel` clause bodies ≤5 lines | Edge-case enumeration + counter-example | Partially falsified | Narrow Qualifier: "≤5 non-trivial expressions excluding the `{:next_state, …}` tuple, presuming `drain_followups_action/1` helper extraction" |
| 4 | `Data.reset_for_cancel/1` covers cross-cutting per-turn fields | Counter-example construction | Withstood | None |
| 5 | `@cancel_clusters` fold in `session.ex` | Dependency + edge-case check | Withstood | None |
| 6 | D-080, D-082 contracts preserved | Integration check (existing regression tests) | Withstood | None |
| 7 | No blocking dependency on sibling sub-problems | Counter-example construction (file-set disjointness) | Withstood | None |

## Revision required

No full revision triggered. One narrowing in place:

- **Target file:** solution.md (Qualifier on Claim 3 only)
- **Revision kind:** narrow Qualifier in place — the proposer / selector
  should record that the `drain_followups_action/1` helper extraction
  is implicit in the ≤5-line target. This is editorial; it does not
  change the structural design.
- **Rationale:** The solution sketch's `followup_actions(data)` is an
  invented helper name not present in `session.ex` today (verified by
  `grep`). The existing `if :queue.is_empty(next_data.followup_queue)`
  block (3 statements at `session.ex:955–958` and `session.ex:1079–1081`)
  must be extracted to satisfy the ≤5-line AC literally. That helper
  extraction is a one-line addition to §What changes, not a re-run.

## Outstanding doubts

- The ADR-0017 mechanism atom is captured as "last non-`:noop` wins" in
  the fold; this happens to equal "ProviderTurn's return" today
  because no other cluster returns a meaningful mechanism. If a
  future cluster starts returning `:cooperative | :brutal_kill`
  semantically, the fold's tie-breaking rule must be revisited
  (solution.md §Open questions bullet 2 already notes this; the
  parent-level validator should inherit this as a Qualifier on the
  parent-level claim about "ADR-0017 mechanism preserved").
- The solution does not specify whether `finish_cancel/2` lives in
  `session.ex` (as a private helper, ≤10 lines inline) or is promoted
  to a separate module. solution.md §Open questions bullet 3 defers
  this to the validator; the AC's "owning sub-modules" clause is
  permissive enough to allow either, but the parent-level validator
  may want to lock this down.
- The fold ordering is `[ProviderTurn, ToolDispatch, Compaction,
  CodingAgentTurn]`. The current `session.ex:978–1010` ordering is
  Provider → ToolDispatcher → CommandTask → Compaction → CodingAgent.
  The solution's ordering moves Compaction before CodingAgent (no
  behavioural change since neither is order-sensitive against the
  other) but `command_task` is now within `ToolDispatch.cancel_cluster/2`.
  Acceptable, but the migration PR B must verify no test asserts the
  exact `command_task` kill timing (no such assertion found in
  `test/tau/session/cancel_cooperative_test.exs` by name; PR B's test
  run is the regression baseline).
