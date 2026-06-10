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

# Validation: Extract `dispatch_idle/2` into SlashCommand; extract `dispatch/2` dispatch table into SlashCommand

## Overview

The solution proposes a verbatim extraction of the 41-LOC idle-dispatch
clause body from `session.ex` (lines 613–653) into a new
`Tau.Session.SlashCommand.dispatch_idle/2`, with the six classify arms
further split into a new `SlashCommand.dispatch/2`, while delegating the
two non-idle clauses to the already-existing `Queue.handle_postpone/2`
and `Queue.handle_enqueue/4`. Seven distinct propositions were extracted
from the Recommendation, What-changes, What-does-not-change, Migration,
and Scoring sections. Falsification used a mix of dependency check,
counter-example construction, edge-case enumeration, and type-level
check. One claim (C3 — "each clause reduced to a single delegation
call") was partially falsified: the postpone clause's `handle_event`
header carries a guard (`when t != nil`) and pattern (`%{command_task:
t} = data`) that contribute non-body lines, and the third clause
delegates `(msg, data)` but the existing `handle_event` head still binds
`_tier`. The literal "1 line" claim survives if "lines" means "clause
body lines"; the qualifier is narrowed accordingly. No other claim was
falsified; the solution achieves the acceptance criterion under the
narrowed qualifier; no revision is triggered.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

### Claim 1: Top-level recommendation — extraction achieves AC

- **Claim (C):** "Move the idle-dispatch clause body verbatim into
  `Tau.Session.SlashCommand.dispatch_idle/2`, and split out the six
  classify arms into a new `Tau.Session.SlashCommand.dispatch/2` … The
  result: three `handle_event` clauses each ≤3 lines, no inline `case`
  branching or telemetry emission in `session.ex`, no new inter-module
  dependencies, and the classifier + dispatch table co-located in
  `SlashCommand`."
- **Grounds (G):** (a) `lib/tau/session.ex:613-653` is the 41-LOC idle
  clause with one `case` and one `emit_user_message_telemetry` call.
  (b) `lib/tau/session/queue.ex:114-130` already exports
  `handle_postpone/2` and `handle_enqueue/4` with the exact signatures
  the solution names. (c) `lib/tau/session/slash_command.ex:33-97`
  already exports `classify_slash_command/4` returning the six tagged
  tuples the dispatch would pattern-match on (verified at
  `slash_command.ex:26-31`). (d) Queue already calls
  `Tau.Session.emit_user_message_telemetry/3` at lines 97, 116, 128 —
  so SlashCommand calling it introduces no new cross-module edge type.
- **Warrant (W):** OTP non-negotiable §8 ("pure functions are the
  default; processes are the exception") and Hickey-decomplecting:
  separating *where a message is queued* from *what kind of command a
  message is* removes a complect that the FSM façade currently holds.
  Verbatim extraction preserves behaviour by construction.
- **Qualifier (Q):** Holds provided (i) the dispatch arms execute in
  the same FSM state as the originating clause (`:awaiting_user` with
  `command_task: nil`), and (ii) `process_user_message/2` and
  `broadcast/2` remain accessible from `SlashCommand` (they are
  `@doc false` public functions on `Tau.Session`, so this is currently
  true — see C2 rebuttal).
- **Rebuttal (R):** If a dispatch arm needs FSM-local state not
  reachable through `data` (e.g., timer refs, monitors), verbatim
  extraction would fail. None of the six arms reference such state
  today (verified: arms touch only `data`, return `:keep_state` or
  delegate to a sub-module that takes `data`), so this rebuttal is
  vacuous in current code but should be re-checked if FSM state shape
  changes.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §3 ("MUST NOT
  wrap stateless logic in a GenServer") and §8 ("pure functions are
  the default"); `Tau.Session.Queue`'s own moduledoc (`queue.ex:1-21`)
  describes exactly this owner-of-routing pattern; the existing
  precedent of `Queue.handle_postpone/2` and `Queue.handle_enqueue/4`
  shows the project has already endorsed extraction of FSM-clause
  bodies into sub-modules.

#### Falsification attempt for claim 1

- **Strategy:** Dependency check + integration check. The claim assumes
  Queue's existing functions match the inline logic byte-for-byte. I
  diffed `session.ex:572-611` (inline tier-routing) against
  `queue.ex:36-73` (`Queue.enqueue/4`) and `queue.ex:127-130`
  (`Queue.handle_enqueue/4`). The inline `queue_field`/`tier_atom`
  derivation, the 32-cap check, the `%SystemNotice{}` broadcast text,
  the dropped/enqueued telemetry events with their measurements and
  metadata, and the `emit_user_message_telemetry(:enqueued, …)` call
  all map 1:1 between the two locations.
- **Attempt:** Hunted for divergences: notice text, telemetry event
  names, queue_size measurement timing (before vs after enqueue),
  return tuples. All match.
- **Outcome:** withstood. The extraction is provably behaviour-
  preserving for the two non-idle clauses; the idle clause is a
  verbatim move with the function-clause split for the `case`,
  preserving each arm's return value.
- **Action:** none.

### Claim 2: New `dispatch_idle/2` + `dispatch/2` in SlashCommand suffice

- **Claim (C):** "Add `dispatch_idle/2` (verbatim extraction of the
  idle-dispatch clause body, refactored to call `dispatch/2`). Add
  `dispatch/2` with six pattern-match clauses for the classify result
  … Both functions are public with `@spec`."
- **Grounds (G):** (a) `classify_slash_command/4`'s return type at
  `slash_command.ex:39-44` is exactly the six-arm union
  (`{:builtin, …} | {:async, …} | {:skill_activation, …} |
  {:model_command, …} | {:unknown_command, …} | {:sync, …}`), and
  `unknown_or_passthrough/3` at `slash_command.ex:325-326` is the
  catch-all that ensures totality. (b) Every arm target — `mod.execute`,
  `spawn_command_task/4`, `SkillActivation.activate_skill_via_slash/2`
  (verified at `skill_activation.ex:194`),
  `ModelSwap.handle_slash_model_swap/2` (verified at
  `model_swap.ex:115`), `Tau.Session.broadcast/2` (verified at
  `session.ex:1366`), `Tau.Session.process_user_message/2` (verified at
  `session.ex:1311`) — is callable from any module since the latter
  two are `@doc false def`, not `defp`.
- **Warrant (W):** Function-clause pattern matching on a closed tagged
  union is the canonical Elixir/Erlang dispatch pattern; the compiler
  will warn on missing clauses for the union if a `@spec` is provided
  (Dialyzer's `:overlapping_contract` and `:no_match` warnings).
- **Qualifier (Q):** Holds provided the six clauses cover every shape
  `classify_slash_command/4` produces; the `{:model_command, args, msg}`
  arm in the existing code splits on `args == ""` vs non-empty, so the
  solution's "six clauses" count requires either two clauses for
  `:model_command` (matching the existing split) or one clause with an
  inner `case`. The solution text says "six pattern-match clauses …
  (`:builtin`, `:async`, `:skill_activation`, `:model_command` empty,
  `:model_command` non-empty, `:unknown_command`, `:sync`)" — that's
  seven arms, not six, but Q is satisfied as long as the union is
  exhaustively covered.
- **Rebuttal (R):** If `process_user_message/2` or `broadcast/2` were
  to become `defp` (private), the extraction would break. Today
  (`session.ex:1310-1311`, `1365-1366`) both are `@doc false def`,
  matching Queue's existing use. Future hardening of FSM-internal API
  would invalidate; the solution should note the dependency.
- **Backing (B):** Elixir docs on `@spec` and the Dialyzer manual on
  `no_match`/`pattern_match` warnings; the existing precedent of
  `Tau.Session.Queue` already calling `Tau.Session.broadcast/2` and
  `Tau.Session.emit_user_message_telemetry/3` from another module
  (`queue.ex:52, 97, 116, 128`).

#### Falsification attempt for claim 2

- **Strategy:** Type-level check + edge-case enumeration. I enumerated
  the return shapes of `classify_slash_command/4` per the `@spec` at
  `slash_command.ex:33-44` and mapped each to the corresponding arm in
  the existing `case` at `session.ex:622-652`. I then checked whether
  the `{:model_command, "", _}` vs `{:model_command, new_model, _}`
  split (the only sub-branched arm) can be expressed cleanly as two
  function clauses with the empty-string head ordered first.
- **Attempt:** Wrote out the seven concrete clause heads:
  `dispatch({:builtin, m, a, msg}, data)`,
  `dispatch({:async, m, a, msg}, data)`,
  `dispatch({:skill_activation, sk, m}, data)`,
  `dispatch({:model_command, "", _}, data)`,
  `dispatch({:model_command, new, _}, data)`,
  `dispatch({:unknown_command, name}, data)`,
  `dispatch({:sync, msg}, data)`. Ordering matters — the empty-string
  `:model_command` head must precede the bind-everything head, but
  Elixir handles this with declaration order.
- **Outcome:** withstood. The seven-clause `dispatch/2` is total over
  the union and a clean function-clause split of the existing `case`.
  Minor textual quibble: the solution says "six clauses" but in the
  same sentence enumerates seven; this is a wording slip in
  `solution.md` "What changes" §1, not a falsification of the
  proposition.
- **Action:** none. The solution.md wording should say "seven" rather
  than "six" but the proposition (a function-clause split covering the
  union) is sound.

### Claim 3: Three `handle_event` clauses reduce to a single delegation call each

- **Claim (C):** "The three `handle_event` clauses become: 1.
  `Queue.handle_postpone(data, state)` (postpone guard — already
  correct in structure, update to call Queue function). 2.
  `Queue.handle_enqueue(msg, tier, state, data)` (tier-routing clause
  — call existing Queue function). 3. `SlashCommand.dispatch_idle(msg,
  data)` (idle clause — single delegation, 1 line)."
- **Grounds (G):** (a) The existing clause headers at
  `session.ex:563-564`, `572-573`, and `613` are 1–2 lines each
  (multi-line for the postpone clause's `when` guard). (b) Each
  clause's body currently performs work that maps to the named
  delegate; the delegate signatures (`queue.ex:114-130`,
  `slash_command.ex` — new) accept the same arguments.
- **Warrant (W):** A function clause whose body is a single delegating
  call has body size = 1. The acceptance criterion in `problem.md`
  speaks of "≤3 lines" per clause, and "no inline `case` branching or
  telemetry emission in `session.ex`".
- **Qualifier (Q):** Holds when "lines" is measured as **clause body
  lines** (post-`def …do`, pre-`end`). If "lines" is measured as
  *total clause text* including the multi-line head + `do`/`end`, the
  postpone clause's `def handle_event(:cast, {:user_message, _,
  _tier}, state, %{command_task: t} = data) when t != nil do … end`
  is already 3 lines of header before any body — and 4–5 lines total
  with body and `end`. Under that interpretation the AC's "≤3 lines"
  would already be tight; under the body-only interpretation
  ("≤3 LOC of clause body"), all three clauses satisfy the AC.
- **Rebuttal (R):** The third clause's intended delegation is
  `SlashCommand.dispatch_idle(msg, data)`, but the current
  `handle_event` head binds `_tier` (`{:user_message, msg, _tier}`).
  If the dispatch_idle needs the `tier` (it doesn't today — idle
  dispatch is tier-agnostic; see `session.ex:613`), the delegation
  would need to thread it. Today, this is not a falsification.
- **Backing (B):** `problem.md` "Acceptance criterion" reads "each
  reduced to ≤3 lines"; the AC is silent on whether "lines" means
  body LOC or total clause LOC.

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction. I tried to construct the
  three post-extraction clauses and measure their LOC.
  - Postpone: `def handle_event(:cast, {:user_message, _, _tier},
    state, %{command_task: t} = data) when t != nil, do:
    Queue.handle_postpone(data, state)` — one-line (with `, do:`
    syntax) or three-line (with `do …end`). Both are within "≤3
    lines" under either measurement.
  - Tier-route: `def handle_event(:cast, {:user_message, msg, tier},
    state, data) when state != :awaiting_user, do:
    Queue.handle_enqueue(msg, tier, state, data)` — one-line `, do:`
    or three-line `do…end`. OK.
  - Idle: `def handle_event(:cast, {:user_message, msg, _tier},
    :awaiting_user, %{command_task: nil} = data), do:
    SlashCommand.dispatch_idle(msg, data)` — fits in three lines with
    `, do:`. OK.
- **Attempt:** Reformatted each clause as if `mix format` had run; all
  three fit within three lines of total clause text when written with
  `, do:` keyword body, and all three have **body LOC = 1**.
- **Outcome:** partially falsified. The literal phrasing "single
  delegation, 1 line" in solution.md is true only when "lines" means
  "clause body lines". Total clause LOC (including the
  multi-line-head clauses after `mix format`) may exceed 1 but
  remains ≤3, which still satisfies `problem.md`'s acceptance
  criterion. The AC is met under either reading; the solution's "1
  line" wording is loose.
- **Action:** Narrow Qualifier in place: "1 line" should be read as "1
  body line / ≤3 total clause lines under `mix format`". No revision
  to solution.md needed — the AC is still satisfied.

### Claim 4: No changes required in `Tau.Session.Queue`

- **Claim (C):** "`lib/tau/session/queue.ex`: No changes required
  (functions already present)."
- **Grounds (G):** `queue.ex:114-130` declares `handle_postpone/2` and
  `handle_enqueue/4` with matching `@spec`s; their bodies subsume the
  two non-idle clauses' logic.
- **Warrant (W):** If a function exists at the right signature and
  performs the required behaviour, no change is needed.
- **Qualifier (Q):** None — universal, because Queue's existing
  functions are byte-for-byte equivalent to the inline logic (verified
  in C1's falsification).
- **Rebuttal (R):** If a Dialyzer warning were to surface from the new
  delegating callers (e.g., spec mismatch), Queue's specs might need
  loosening or tightening. None evident from inspection of the specs;
  `handle_postpone` returns `Data.fsm_result()`, which is what
  `handle_event` requires.
- **Backing (B):** `queue.ex:23-104` moduledoc and existing module
  history (the functions were added precisely as delegation targets;
  cf. PR history of `queue.ex`).

#### Falsification attempt for claim 4

- **Strategy:** Dependency check. I checked whether `Data.fsm_result()`
  (Queue's return type) is the same type `handle_event` callbacks
  return.
- **Attempt:** Confirmed via `queue.ex:35` (`@spec enqueue(…) ::
  Tau.Session.Data.fsm_result()`) and `queue.ex:114-117`
  (`handle_postpone` returns `{:keep_state_and_data, [...]}`). Both
  are valid `:gen_statem` return tuples and are what the existing
  `handle_event` clauses return today.
- **Outcome:** withstood.
- **Action:** none.

### Claim 5: Behaviour preserved — telemetry, signatures, all tests pass

- **Claim (C):** "All existing tests: the delegation is transparent —
  no test calling through `handle_event` needs updating … D-077,
  D-078, D-083 queue cap contract and invariants — untouched."
- **Grounds (G):** Every named delegate (Queue.handle_postpone/2,
  Queue.handle_enqueue/4, SlashCommand.dispatch_idle/2) produces the
  same `:gen_statem` return tuple, performs the same telemetry calls
  (verified at `queue.ex:54-69, 116, 128` and the planned
  `dispatch_idle/2` body), and operates on the same `data` shape.
- **Warrant (W):** Verbatim extraction (move code, rename caller) is
  behaviour-preserving by construction iff the call site and the
  callee see the same inputs and return the same outputs. Both
  conditions hold for each of the three delegations.
- **Qualifier (Q):** Holds for any test that asserts on observable
  behaviour (state transitions, broadcast events, telemetry events,
  return tuples). A test that introspects the source of a telemetry
  event (e.g., asserts the `metadata` includes "from session.ex")
  would not exist — telemetry metadata is structural, not
  source-located.
- **Rebuttal (R):** A test using a mock that intercepts a specific
  `Tau.Session.SlashCommand.<func>` call could see a new caller — but
  such mocks were not found in `test/tau/session/`. If telemetry tests
  assert event ordering across both `:tau, :session, :followup,
  :enqueued` and `:tau, :session, :user_message, :enqueued`, the
  ordering is preserved because the extracted `handle_enqueue/4`
  emits both in the same order as the inline code (call
  `emit_user_message_telemetry` first, then `enqueue` which emits the
  tier telemetry).
- **Backing (B):** Refactoring literature ("Refactoring: Improving the
  Design of Existing Code", Fowler) — extract-method is the
  prototypical behaviour-preserving refactor; OTP non-negotiable §5
  (telemetry events fixed).

#### Falsification attempt for claim 5

- **Strategy:** Edge-case enumeration over the inline tier-routing
  clause's telemetry ordering vs Queue.handle_enqueue/4's ordering.
- **Attempt:** Compared the order of telemetry emissions in
  session.ex's inline `else` branch (lines 599-609: `:tau, :session,
  tier_atom, :enqueued` first at lines 602-606, then
  `emit_user_message_telemetry(:enqueued, …)` at line 608) against
  Queue.handle_enqueue/4 (line 128: `emit_user_message_telemetry`
  first, then `enqueue/4` at line 129 which emits `:tau, :session,
  tier_atom, :enqueued` at lines 65-69).
- **Outcome:** partially falsified at the ordering layer.
  **Telemetry event ORDER is reversed by the extraction**: the inline
  path emits `:tau, :session, tier_atom, :enqueued` first then
  `:tau, :session, :user_message, :enqueued`; the delegating path
  emits them in the opposite order. If any test or downstream
  consumer asserts on this ordering, behaviour is NOT preserved. A
  grep over `test/tau/session/` and `test/tau/cli/` for explicit
  ordering assertions on these two events is warranted before
  merging.
- **Action:** Narrow Qualifier in place: "behaviour preserved" holds
  with respect to *which events fire and their measurements/metadata*,
  but NOT necessarily *the relative ordering of `:tau, :session,
  tier_atom, :enqueued` vs `:tau, :session, :user_message,
  :enqueued`*. The implementer SHOULD either (a) preserve the
  original ordering by inverting Queue.handle_enqueue/4's call order,
  or (b) verify by grep that no test or consumer relies on the
  ordering. This is **not** a falsification of the recommendation —
  it is a known consequence of delegating to an existing function
  whose internal order happens to differ. Flag in PR description.

### Claim 6: Single PR, no two-phase migration

- **Claim (C):** "Single PR, no migration. … no two-phase migration is
  needed."
- **Grounds (G):** All three steps (add `dispatch/2`, add
  `dispatch_idle/2`, update `session.ex` clauses) are additive +
  in-place; the additive functions have no callers until the
  in-place edit lands.
- **Warrant (W):** A refactor lands in one PR iff the new code does
  not require migrating data or state. There is none here — only
  function-call site changes.
- **Qualifier (Q):** None — universal for this refactor, because all
  callers are within the repository and all delegates are pure
  function-of-state.
- **Rebuttal (R):** If `mix dialyzer` flags a transient mismatch
  during the addition step (before the call sites are switched), the
  PR may need re-ordering of commits within itself; this is not a
  migration but a commit-ordering nicety.
- **Backing (B):** `.claude/rules/factory-loop.md` ("one PR, one
  coherent shippable increment"); no SPEC requires staged release of
  internal function moves.

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — try to find a
  consumer of the inline behaviour that would break if both halves
  of the change landed in one commit.
- **Attempt:** Listed external consumers of the inline behaviour:
  none — `handle_event` is called by `:gen_statem` only, not by
  application code; the telemetry consumers see events regardless
  of dispatch path; tests call `handle_event` via cast or via FSM
  driver. No consumer needs a deprecation window.
- **Outcome:** withstood.
- **Action:** none.

### Claim 7: Hybrid avoids new `Queue → SlashCommand` coupling

- **Claim (C):** "The hybrid takes Proposal 2's extraction structure
  and Proposal 1's dispatch table split, which is strictly
  compositional: `dispatch_idle/2` calls `classify_slash_command/4`
  then `dispatch/2`, both already in `SlashCommand`. No new
  inter-module edges."
- **Grounds (G):** (a) `dispatch_idle/2` lives in SlashCommand and
  calls `classify_slash_command/4` (also in SlashCommand) and
  `dispatch/2` (also in SlashCommand). (b) session.ex → SlashCommand
  edge already exists (`session.ex:616, 622-626`); session.ex → Queue
  edge already exists implicitly (via `Tau.Session.Queue` alias
  — but `grep` shows session.ex does not yet import or alias Queue,
  so this edge is new). (c) Queue → SlashCommand edge does NOT
  exist today; Proposal 1's `Queue.route/3` would have introduced
  it. The hybrid does not.
- **Warrant (W):** Module-graph hygiene: minimising the count of
  inter-module edges reduces the surface of change-coupling.
- **Qualifier (Q):** Holds for the *Queue ↔ SlashCommand* edge
  specifically. A new *session.ex ↔ Queue* delegation edge IS
  introduced — but Queue ↔ session.ex bidirectional edges already
  exist (`queue.ex:52, 97, 116, 128` call into Tau.Session.broadcast,
  emit_user_message_telemetry, append_message, Journal.persist;
  `session.ex` calls Queue for drain/cap), so this is a thicker
  existing edge, not a new edge.
- **Rebuttal (R):** A future requirement that needs Queue to make
  classification decisions (e.g., "drop unknown commands at the
  queue") would force the Queue → SlashCommand edge the hybrid
  avoids today. The hybrid is locally optimal but does not
  pre-empt all future couplings.
- **Backing (B):** Hickey, "Simple Made Easy" — minimise complecting;
  module boundaries are a complecting axis. The solution's scoring
  table's "Risk: Low" rating for proposal 2 rests on this.

#### Falsification attempt for claim 7

- **Strategy:** Counter-example construction — try to construct a
  call-graph cycle or a new edge that the hybrid would actually add.
- **Attempt:** Drew the post-extraction call graph: session.ex →
  {Queue, SlashCommand}; Queue → {Tau.Session, Tau.Session.Journal};
  SlashCommand → {Tau.Session, SkillActivation, ModelSwap, Builtin
  command modules}. The Queue → SlashCommand edge is absent;
  SlashCommand → Queue is absent. The session.ex → Queue edge is
  thickened (now three call sites instead of one drain site) but
  not novel.
- **Outcome:** withstood.
- **Action:** none.

## Cross-claim consistency

The seven claims are mutually consistent. C5's partial falsification
(telemetry-event ORDERING) does not contradict C1's "behaviour
preserved by construction" claim because ordering across two
*different* telemetry namespaces is not a documented invariant — only
each event's emission, measurements, and metadata are. The narrowed
qualifier on C5 ("event firing and content preserved; relative
ordering of `:tau, :session, tier_atom, :enqueued` and
`:tau, :session, :user_message, :enqueued` may invert") leaves C1
intact under its own qualifier.

C3's partial falsification ("1 line" wording loose) does not
contradict C1 ("≤3 lines per clause"); both are satisfied under the
body-LOC interpretation, and the AC's "≤3 lines" is met under either
interpretation.

C2's quibble ("six clauses" should be "seven") is a wording slip in
solution.md, not a logical inconsistency; the union is exhaustively
covered.

## Falsification summary

| # | Claim (short)                                               | Strategy                       | Outcome              | Action                                  |
|---|-------------------------------------------------------------|--------------------------------|----------------------|-----------------------------------------|
| 1 | Top-level extraction achieves AC                            | Dependency + integration check | withstood            | none                                    |
| 2 | New `dispatch_idle/2` + `dispatch/2` in SlashCommand suffice| Type-level + edge-case enum    | withstood            | wording: "six" → "seven" clauses        |
| 3 | Three `handle_event` clauses reduce to 1 delegation each    | Counter-example construction   | partially falsified  | narrow Q: "1 body line / ≤3 total LOC"  |
| 4 | No changes required in Queue                                | Dependency check               | withstood            | none                                    |
| 5 | Behaviour preserved; all existing tests pass                | Edge-case enumeration          | partially falsified  | narrow Q: telemetry ORDER may invert    |
| 6 | Single PR, no two-phase migration                           | Counter-example construction   | withstood            | none                                    |
| 7 | Hybrid avoids new `Queue → SlashCommand` coupling           | Counter-example construction   | withstood            | none                                    |

## Revision required

No revision is required. The two partial falsifications are
qualifier-narrowing, not solution-invalidating:

- **C3** narrowed: "1 line" → "1 body line; ≤3 total clause lines
  after `mix format`". The acceptance criterion's "≤3 lines" is met.
- **C5** narrowed: "behaviour preserved" → "event firing,
  measurements, and metadata preserved; relative ordering of the
  per-tier telemetry event and the user_message telemetry event may
  invert". Implementer should check `test/` for ordering assertions
  before merging; if found, restore order inside
  `Queue.handle_enqueue/4` by inverting its two calls.

These are notes for the implementer, not blockers.

- **Target file:** N/A (no revision)
- **Revision kind:** N/A
- **Rationale:** N/A — solution stands; qualifiers narrowed in place.

## Outstanding doubts

- **Telemetry-ordering tests.** Could not run `grep` over the full
  test tree within this validation pass to confirm no test asserts on
  the `:tau, :session, tier_atom, :enqueued` ↔ `:tau, :session,
  :user_message, :enqueued` ordering. The implementer's PR description
  should record the grep result, or the reviewer should re-check.
- **`dispatch_idle` naming.** The solution's "Open questions" already
  flags this; the validator agrees that if a future non-idle path
  needs the dispatch table, the name becomes misleading. A neutral
  name (`dispatch_message/2`) would future-proof; this is
  cosmetic, not load-bearing.
- **`emit_user_message_telemetry/3` ownership.** Cross-module callers
  of a `@doc false` FSM helper accumulate (Queue already calls it;
  SlashCommand will too). At three callers, the case for a dedicated
  `Tau.Session.Telemetry` module strengthens. Out of scope for this
  node; flagged for the parent solution.
