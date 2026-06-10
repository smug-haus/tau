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

# Validation: Distribute helpers by concern, with pure/effectful split for the two telemetry helpers

## Overview

The solution makes eight discrete propositions: a destination assignment for
each of the eight `@doc false` helpers in `lib/tau/session.ex`, plus a
meta-claim that no logic changes occur and the migration is one-PR
non-breaking. Six claims are extracted and validated individually with full
Toulmin and a named falsification strategy each. Five claims withstood
falsification. One (claim 4 — `Tau.Session.Telemetry` as the home for the
two telemetry helpers) was **partially falsified**: a co-located
`lib/tau/telemetry/` directory already exists for the system-wide telemetry
subsystem. The namespaces (`Tau.Session.Telemetry` vs `Tau.Telemetry.*`) do
not collide at the compiler level, but the partial falsification narrows
the Qualifier: the new module name is acceptable iff the moduledoc
explicitly distinguishes session-scoped FSM/user-message telemetry from the
broader `Tau.Telemetry.*` namespace. No revision of solution.md is
triggered; the narrowed qualifier is recorded here.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This validation enforces all six components explicitly.

### Claim 1: The three pure data-shape helpers (`append_message/2`, `generate_event_id/0`, `current_run?/2`) belong in `Tau.Session.Data`

- **Claim (C):** "Everything else follows Proposal 2 exactly: `append_message/2`,
  `generate_event_id/0`, `current_run?/2` into `Tau.Session.Data`" (solution.md
  §Recommendation; §What changes line 1).
- **Grounds (G):** `lib/tau/session.ex:1345` defines `append_message/2` as
  `def append_message(data, msg), do: %{data | messages: data.messages ++ [msg]}`
  — pure struct manipulation. `lib/tau/session.ex:1347-1353` defines
  `generate_event_id/0` — pure ID generation. `lib/tau/session.ex:1291-1300`
  defines `current_run?/2` clauses — pure pattern matching on struct fields
  (no side effects). `lib/tau/session/data.ex` is already a `defstruct`
  module (`wc -l → 369`) that owns struct initialisation (`new/1` at line
  159). All three functions read/transform only `Tau.Session.Data` fields.
- **Warrant (W):** OTP non-negotiable #8 ("pure functions are the default;
  processes are the exception") combined with the Hickey principle that
  data and the operations on it co-locate without complecting. A
  `defstruct` module is the canonical home for pure operations on its own
  struct in idiomatic Elixir.
- **Qualifier (Q):** Universal across the three named functions. Holds
  unconditionally because all three are demonstrably pure and operate on
  `Data` fields (`messages`, `stream_ref`, `coding_agent_dispatcher`).
- **Rebuttal (R):** The claim would fail if any of the three functions
  secretly carried a side effect (e.g., a hidden `:telemetry.execute`) or
  operated on data that lives outside the `Data` struct. Inspection of
  the function bodies above shows neither.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §8; Elixir
  community practice (e.g. `Ecto.Schema`/`Ecto.Changeset` pairing — the
  schema module owns the changeset functions for its own data).

#### Falsification attempt for claim 1

- **Strategy:** Counter-example construction. Search for any side effect
  inside the three function bodies or any dependency on non-`Data` fields.
- **Attempt:** Read `lib/tau/session.ex:1291-1353` verbatim. `append_message`
  pattern-matches `data` and returns an updated struct — no side effect.
  `generate_event_id` calls `Code.ensure_loaded?` + `apply` or
  `:crypto.strong_rand_bytes` — both are pure with respect to observable
  state of the system (the random bytes are technically "non-deterministic"
  but introduce no shared-state coupling). `current_run?` pattern-matches
  on `:stream_ref` and `:coding_agent_dispatcher` — both fields owned by
  `Data` (per `data.ex` and the callsites at `coding_agent_turn.ex:730`,
  `session.ex:1293`).
- **Outcome:** withstood.
- **Action:** none.

### Claim 2: `broadcast/2` belongs as a `def` on `Tau.Session.Events`

- **Claim (C):** "`broadcast/2` into `Tau.Session.Events`" (solution.md
  §Recommendation; §What changes line 2 specifies "the PubSub topic string
  `"session:#{id}"` becomes a single point of definition here").
- **Grounds (G):** `lib/tau/session.ex:1366-1368` defines
  `broadcast(id, event)` as a thin `Phoenix.PubSub.broadcast` wrapper
  hard-coded to topic `"session:#{id}"`. `lib/tau/session/events.ex`
  already owns the dozens of event structs (`%Events.SessionStart{}`,
  `%Events.MessageEnd{}`, `%Events.SystemNotice{}`, etc.) broadcast on
  that topic — sub-modules already `alias Tau.Session.Events` and
  construct events with `%Events.X{}`. Verified by grep: every
  `broadcast` callsite in `lib/tau/session/` couples a `Tau.Session.broadcast`
  call with an `%Events.X{}` struct construction (e.g.
  `compaction.ex:164,173,220,222,264,266`; `coding_agent_turn.ex:88,162,...`).
- **Warrant (W):** OTP non-negotiable #4 ("Cross-process events MUST use
  `Phoenix.PubSub` or monitored refs"). The Elixir/Phoenix idiom places
  broadcast on the module that owns the broadcast vocabulary — e.g.
  `Phoenix.Channel.broadcast/3` lives on the module owning channel-message
  semantics. Co-locating the topic string with the structs it carries
  defines the wire contract in one place.
- **Qualifier (Q):** Holds for sub-modules that already construct `%Events.X{}`
  structs — i.e. every current caller. Does not hold for hypothetical
  callers wanting to broadcast a non-`Events` struct on the same topic; no
  such caller exists today.
- **Rebuttal (R):** The claim would fail if `Tau.Session.Events` were a
  protocol or otherwise unable to host module-level functions, or if a
  compile-time cycle would be created. `events.ex` is a plain `defmodule`
  with one `defstruct` per event type (no protocol) — adding a `def`
  function is mechanically straightforward. The circular-dependency
  concern (next paragraph) is the only real risk.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §4; `Phoenix.Channel`
  source as community precedent for "broadcast lives on the module that
  owns the broadcast vocabulary".

#### Falsification attempt for claim 2

- **Strategy:** Dependency check — verify no circular compile dependency is
  introduced.
- **Attempt:** `lib/tau/session/data.ex:209,345` currently call
  `Tau.Session.broadcast(...)` (in `Data.new/1` and a catalog-publish path).
  After migration `Data` would call `Tau.Session.Events.broadcast/2`.
  `data.ex:15` already declares `alias Tau.Session.Events` (verified) — so
  `Data` already compiles in the presence of `Events`. Adding `broadcast/2`
  as a `def` on `Events` does not require `Events` to reference `Data`, so
  no cycle is introduced. Verified by inspection: `events.ex` is purely
  struct definitions, no references to `Data`.
- **Outcome:** withstood.
- **Action:** none.

### Claim 3: A new `Tau.Session.Hooks` module is the right home for `hook_payload/3` + `transcript_path/1`

- **Claim (C):** "`hook_payload/3` + `transcript_path/1` into a new
  `Tau.Session.Hooks`" (solution.md §Recommendation; §What changes line 4
  specifies the rename `hook_payload/3` → `Hooks.payload/3`).
- **Grounds (G):** `lib/tau/session.ex:1403-1416` defines `hook_payload/3`
  as a pure map merge of canonical hook-contract fields with the caller's
  extras; `lib/tau/session.ex:1418-1423` defines `transcript_path/1` as a
  delegate to the persistence backend's `path_for/2` callback. The
  function is the in-process side of the Phase-10 hook contract (mirroring
  Claude Code's). No existing sub-module owns the hook contract;
  `Tau.Hooks.Dispatcher` (called from `session.ex:1312`) owns hook
  *invocation* but not payload *construction*. External callers exist:
  `lib/tau/hook.ex:21` and `lib/tau/hooks/shell.ex:73` both reference
  `Tau.Session.hook_payload/3` in docstrings/comments.
- **Warrant (W):** Hickey decomplecting principle: a function that has its
  own protocol (Phase-10 hook contract) and no other natural home gets its
  own module rather than being attached to an unrelated existing module.
  Naming a module after the contract it implements makes the import
  self-documenting at callsites (`alias Tau.Session.Hooks` signals "this
  module participates in the hook contract").
- **Qualifier (Q):** Holds because no existing module owns the hook
  contract. Would not hold if `Tau.Session.Data` were chosen instead
  (Proposal 3's placement) — that would co-locate hook-contract logic with
  unrelated struct manipulation.
- **Rebuttal (R):** The rename `hook_payload/3 → payload/3` changes the
  bare function name, not just its module prefix. The docstring references
  in `lib/tau/hook.ex:21` and `lib/tau/hooks/shell.ex:73` are prose
  references inside comments — not code calls — so they break no
  compilation but become stale. Solution.md §Open questions already flags
  this. The rebuttal therefore lands as documentation hygiene, not as a
  falsification.
- **Backing (B):** Solution.md §Recommendation, citing Proposal 2's
  acknowledgement that the "Hooks" module is more cohesive than
  Proposal 3's `Util` co-location; Proposal 2 §Tradeoffs explicitly cites
  this distinction.

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction — find a sub-module already
  owning the hook contract that would be a better home.
- **Attempt:** Search `lib/tau/session/` and `lib/tau/hooks/` for modules
  whose responsibility is the in-session hook-payload contract.
  `Tau.Hooks.Dispatcher` exists (owns invocation; per `session.ex:1312`)
  but does not own payload assembly — it accepts a payload as input.
  `lib/tau/hook.ex` defines the `@behaviour` for hook implementations and
  is not session-scoped. No alternative home found.
- **Outcome:** withstood. (One stale comment in
  `lib/tau/hooks/shell.ex:73` and one stale docstring reference in
  `lib/tau/hook.ex:21` should be updated in the same PR — recorded in
  Outstanding doubts.)
- **Action:** none.

### Claim 4: A new `Tau.Session.Telemetry` module is the right home for `transition/3` and `emit_user_message_telemetry/3`

- **Claim (C):** "the two telemetry helpers (`transition/3`,
  `emit_user_message_telemetry/3`) go into a new `Tau.Session.Telemetry`
  module rather than into `Journal`. This keeps `Journal` scoped to
  persistence observability and gives the FSM-transition and user-message
  telemetry a clear home." (solution.md §Recommendation; §What changes
  line 3).
- **Grounds (G):** `lib/tau/session.ex:1355-1363` defines `transition/3`
  as a `:telemetry.execute([:tau, :session, :transition], …)` emitter;
  `lib/tau/session.ex:1387-1394` defines `emit_user_message_telemetry/3`
  as a `:telemetry.execute([:tau, :session, :user_message, event], …)`
  emitter. Both are FSM-observation telemetry, distinct from
  `Tau.Session.Journal`'s persistence-write telemetry. Callsites:
  `provider_turn.ex:463`, `coding_agent_turn.ex:704`,
  `tool_dispatch.ex:187,269` (all four `transition/3` callers pass a
  `data` argument that the definition ignores via `_data`) and
  `queue.ex:97,116,128` (the three `emit_user_message_telemetry/3`
  callers).
- **Warrant (W):** OTP non-negotiable #5 ("Telemetry events MUST cover
  everything user-visible or perf-sensitive") and the Hickey decomplecting
  principle: telemetry emission is a coherent concern (`:telemetry.execute`
  with `[:tau, :session, ...]` event names) distinct from persistence
  (`Journal`'s `persist/2`).
- **Qualifier (Q):** Holds **iff the new module's moduledoc explicitly
  distinguishes itself from the existing `lib/tau/telemetry/` subsystem
  (`Tau.Telemetry.*` namespace)**. (Narrowed from "universal" by partial
  falsification — see below.)
- **Rebuttal (R):** The claim would fail if (a) Elixir disallowed the
  module name `Tau.Session.Telemetry` because some other module already
  uses it (it does not — see falsification), or (b) the dropped `_data`
  argument from `transition/3` were used at some callsite (it is not —
  every caller's call site passes `data` only to satisfy the existing
  arity and the parameter is `_data` in the definition). Both rebuttals
  fail to falsify.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §5; solution.md
  §Recommendation explicitly cites Proposal 3's pure/effectful split as
  the justification for separating telemetry from `Journal`.

#### Falsification attempt for claim 4

- **Strategy:** Dependency check + edge-case enumeration. Verify (a) no
  module-name collision with the existing `lib/tau/telemetry/` directory,
  (b) the signature change (`transition/3 → emit_transition/2`) is safe
  at all callsites.
- **Attempt:** (a) `find lib/tau -name "telemetry*"` returns
  `lib/tau/telemetry` — a directory holding the *system-wide* telemetry
  subsystem under the `Tau.Telemetry.*` namespace. No file currently
  defines `Tau.Session.Telemetry`, so the compiler permits the new
  namespace. (b) `grep` of all `Tau.Session.transition` callsites
  (`provider_turn.ex:463`, `coding_agent_turn.ex:704`,
  `tool_dispatch.ex:187,269`) confirms each passes `data` as the second
  argument and the existing definition discards it via `_data`. Dropping
  the argument and renaming to `emit_transition(id, to)` is mechanically
  safe.
- **Outcome:** **partially falsified**. The compiler accepts the new
  module name, but a human reader navigating the codebase will encounter
  two `Tau.*Telemetry` namespaces (`Tau.Telemetry.*` and
  `Tau.Session.Telemetry`) and may conflate them. The original Claim is
  too broad — it implicitly asserts the name is unambiguous. The
  Qualifier above (requiring an explicit moduledoc distinction) is the
  narrowing required to restore the claim's truth.
- **Action:** Narrow the Qualifier in place (already done above). Record
  the moduledoc requirement in Outstanding doubts so the implementer
  picks it up. No solution.md revision required — the recommendation
  itself stands.

### Claim 5: `process_user_message/2` belongs in `Tau.Session.Queue` (retaining its `handle_event/4` back-call as out-of-scope coupling)

- **Claim (C):** "`process_user_message/2` into `Tau.Session.Queue`.
  `process_user_message/2` retains its `handle_event/4` back-call — that
  coupling is the user-message-routing sub-problem's scope, not this
  one's." (solution.md §Recommendation; §What changes line 5).
- **Grounds (G):** `lib/tau/session.ex:1310-1342` defines
  `process_user_message/2` as the hook-dispatch + routing path that calls
  `handle_event(:internal, :start_coding_agent | :start_provider, …, data)`
  (lines 1336-1340). Callsites: `slash_command.ex:269,292,309` (three
  external callers, all in `Tau.Session.SlashCommand`) plus three internal
  callers in `session.ex:630,651,693,704`. `Tau.Session.Queue` exists as a
  module (`lib/tau/session/queue.ex`, 180 LOC, `defmodule Tau.Session.Queue`)
  and is the established home for user-message-routing utilities — it
  already houses `emit_user_message_telemetry/3` callsites (queue.ex:97,
  116, 128).
- **Warrant (W):** Hickey decomplecting principle: a function whose
  responsibility is *routing decisions at the queue boundary* belongs in
  the module that owns the queue boundary, even if its implementation
  exhibits a transient coupling (the back-call into `handle_event/4`)
  that a future sub-problem will resolve. The acceptance criterion of
  this sub-problem is structural (location), not behavioural; declaring
  the back-call out-of-scope is consistent with problem.md §Out of scope.
- **Qualifier (Q):** Holds because Queue already exists and already
  participates in user-message routing. The back-call coupling is
  inherited, not introduced.
- **Rebuttal (R):** The claim would fail if `Tau.Session.Queue` did not
  exist (then this PR would need to either create a stub or move the
  function elsewhere). Solution.md §Open questions correctly flags this
  as a precondition; verification: `Queue` exists.
- **Backing (B):** problem.md §Out of scope (sibling sub-problem
  user-message-routing owns the back-call coupling); solution.md
  §Recommendation explicitly defers the coupling to that sub-problem.

#### Falsification attempt for claim 5

- **Strategy:** Dependency check — verify `Tau.Session.Queue` exists and
  is reachable from `Tau.Session.SlashCommand` (the primary external
  caller) without introducing a compile cycle.
- **Attempt:** `ls lib/tau/session/queue.ex` confirms the file exists
  (180 LOC). `grep "defmodule Tau.Session.Queue"` returns
  `lib/tau/session/queue.ex:1`. SlashCommand currently calls
  `Tau.Session.process_user_message(...)` at three sites; rewriting these
  to `Tau.Session.Queue.process_user_message(...)` requires no module
  cycle (Queue does not import SlashCommand, per inspection of
  queue.ex).
- **Outcome:** withstood.
- **Action:** none.

### Claim 6: The migration is purely additive then-rename, one-PR, no logic changes

- **Claim (C):** Solution.md §Migration sketch states steps 1-5 are
  "additive and can land in any order; step 6 and 7 land together. The
  entire migration is one PR with no intermediate broken states — the
  old names still exist until step 7." Solution.md §What does not change
  asserts: "The bodies of all eight functions — verbatim moves, no logic
  changes" and "External callers of the public `Tau.Session` API — all
  moved functions were `@doc false`".
- **Grounds (G):** The eight function bodies inspected at
  `lib/tau/session.ex:1291-1416` are short (mostly 1-10 LOC each) and
  contain no module-private references — every dependency is either a
  field on the passed-in struct, a stdlib call, or a public Phoenix /
  `:telemetry` call. Therefore each body can be copy-pasted into its
  destination module unchanged. The `@doc false` markers verified in
  `grep -n "@doc false" lib/tau/session.ex` confirm all eight are
  internal-API. External-caller scan
  (`grep -rn "Tau\.Session\.\(broadcast\|append_message\|generate_event_id\|transition\|emit_user_message_telemetry\|hook_payload\|process_user_message\|current_run\?\)" lib/`
  scoped to outside `lib/tau/session/`) returns three matches: all are
  docstring/comment references (`lib/tau/hook.ex:21`,
  `lib/tau/hooks/shell.ex:73`, `lib/tau/tui/app/bootstrap.ex:37`) — none
  are runtime calls.
- **Warrant (W):** OTP non-negotiable #8 (pure functions compose without
  surprise); refactoring-by-relocation preserves observable behaviour iff
  the moved function has no module-private dependency and no external
  caller is broken. Both conditions are mechanically verifiable and have
  been verified.
- **Qualifier (Q):** Holds for the eight named functions and their
  callsites within `lib/`. Does not address `test/` callsites — but
  `grep -rn ... test/` returns zero direct calls (a test calling
  `Tau.Session.hook_payload/3` would break and would need updating). The
  signature changes (`transition/3 → emit_transition/2`,
  `hook_payload/3 → Hooks.payload/3`) require a coordinated rename at
  every call site, not merely a module prefix change.
- **Rebuttal (R):** The claim would fail if (a) a hidden runtime caller
  outside `lib/` and `test/` exists (e.g., a config-driven dispatch); no
  such caller surfaced in `grep`. (b) The `defp transcript_path/1`
  helper in `session.ex:1418` is called only by `hook_payload/3` — once
  `hook_payload` moves to `Hooks`, `transcript_path/1` must move too
  (solution.md §What changes correctly specifies this).
- **Backing (B):** Solution.md §Open questions flags the rename test
  audit; problem.md §Out of scope excludes correctness changes; verified
  zero direct test callers via `grep`.

#### Falsification attempt for claim 6

- **Strategy:** Edge-case enumeration over the documented failure modes:
  (1) hidden runtime caller, (2) `transcript_path/1` dependency,
  (3) test-suite caller, (4) signature-change miss, (5) compile-cycle
  introduction.
- **Attempt:** (1) Grepped `lib/` and `test/` outside the session
  subtree for each helper name — only three matches, all comments. (2)
  `transcript_path/1` is `defp` on `session.ex` and is called only from
  `hook_payload/3` — confirmed by `grep` of "transcript_path" in
  `session.ex`. Co-moving it with `hook_payload` into `Hooks` is the
  natural action and solution.md §What changes specifies it
  ("`hook_payload/3` (renamed from `hook_payload/3`) and private
  `transcript_path/1`"). (3) `grep -rn "Tau\.Session\.hook_payload\|...\
  " test/` returns zero hits. (4) Signature changes are catalogued in
  Proposal 2's rename table and re-stated in solution.md §Open questions.
  (5) `Data`-to-`Events.broadcast` was the only candidate cycle —
  already cleared in Claim 2's falsification.
- **Outcome:** withstood. (The implementer must remember to co-move
  `transcript_path/1`, audit test callers, and apply the rename table —
  none of these are unstated.)
- **Action:** none.

## Cross-claim consistency

Claims 1-5 collectively partition the eight `@doc false` helpers across
five destination modules (`Data`, `Events`, new `Telemetry`, new `Hooks`,
existing `Queue`). The partition is a function (each helper appears in
exactly one destination); no two claims assign the same helper to
different homes. Claim 6 (additive-then-rename, one-PR) is consistent with
Claims 1-5 because every destination accepts the moved function purely
additively — no destination requires a prior structural change.

One potential tension: Claim 2 places `broadcast/2` on
`Tau.Session.Events`, and `Tau.Session.Data` calls
`Tau.Session.broadcast(...)` at `data.ex:209,345`. After migration, `Data`
will call `Tau.Session.Events.broadcast(...)`, which requires the existing
`alias Tau.Session.Events` in `data.ex:15` to remain. This is consistent
(the alias already exists) but is worth noting for the implementer.

No solution-internal contradictions detected.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Pure helpers → `Data` | Counter-example construction | withstood | none |
| 2 | `broadcast/2` → `Events` | Dependency check | withstood | none |
| 3 | `hook_payload` + `transcript_path` → new `Hooks` | Counter-example construction | withstood | none |
| 4 | Two telemetry helpers → new `Telemetry` | Dependency check + edge-case enumeration | **partially falsified** | Qualifier narrowed in place (moduledoc must distinguish from `Tau.Telemetry.*`) |
| 5 | `process_user_message/2` → `Queue` | Dependency check | withstood | none |
| 6 | Additive migration, no logic changes | Edge-case enumeration | withstood | none |

## Revision required

No solution.md revision triggered. Claim 4 was partially falsified; the
Qualifier was narrowed in place (the new `Tau.Session.Telemetry` module
must declare in its moduledoc that it is scoped to session-level FSM and
user-message telemetry, distinct from the system-wide `Tau.Telemetry.*`
namespace). This is documentation discipline at implementation time, not
a change of approach. The Recommendation in solution.md stands.

- **Target file:** n/a
- **Revision kind:** n/a
- **Rationale:** Partial falsification narrows the Qualifier in
  validation.md rather than the solution; the partial falsification does
  not invalidate the chosen destination, only requires the moduledoc to
  pre-empt reader confusion.

## Outstanding doubts

- The `hook_payload/3 → Hooks.payload/3` rename leaves stale prose
  references in `lib/tau/hook.ex:21` (the docstring) and
  `lib/tau/hooks/shell.ex:73` (a defensive comment) and one in
  `lib/tau/tui/app/bootstrap.ex:37` (a comment citing
  `Tau.Session.process_user_message/2`). These are not runtime breakages,
  but the implementer should update them in the same PR for consistency.
- Solution.md §Open questions flags a `Tau.Session.Queue` precondition;
  verification confirms Queue exists. This doubt is closed.
- Solution.md §Open questions asks whether any test directly calls
  `Tau.Session.hook_payload/3`; `grep` confirms zero direct callers in
  `test/`. This doubt is closed.
- Claim 4's narrowed Qualifier — the moduledoc requirement — must be
  carried into the implementer brief; if the implementer creates
  `Tau.Session.Telemetry` without a disambiguating moduledoc, the
  reviewer should flag it.
- `register_builtins/0` at `session.ex:1425` is also `@doc false` but
  is not listed among the eight helpers under this sub-problem's scope
  (problem.md §Context names only the eight). Confirm with the parent
  whether this helper is in scope of a sibling sub-problem; if not, it
  may slip through this decomposition.
