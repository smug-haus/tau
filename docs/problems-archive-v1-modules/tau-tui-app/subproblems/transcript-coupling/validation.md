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

# Validation: Split `on_message_end/2` into two named private handlers via dispatcher

## Overview

The solution proposes replacing the 77-LOC `on_message_end/2` in
`lib/tau/tui/app/events.ex` with a thin dispatcher that calls two named private
sub-handlers — `on_message_end_transcript/2` and `on_message_end_counters/2` —
each owning a disjoint field set on the model. Six claims are enumerated below,
drawn from the Recommendation and What-changes sections. Each receives full
Toulmin treatment and an explicit falsification attempt. Five claims withstood;
claim 3 is partially falsified on the enforcement-completeness axis, requiring a
qualifier narrowing (no solution revision needed).

---

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants found it
difficult to generate Toulmin structures, and their structures varied greatly even
though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to counter that
variance.

---

### Claim 1: The transcript-line construction pipeline is independently testable without a cost ETS table

- **Claim (C):** After the split, `on_message_end_transcript/2` is independently
  testable without a live cost ETS table (acceptance criterion (a)).
- **Grounds (G):** The current `on_message_end/2` reads the ETS table at
  `lib/tau/tui/app/events.ex:224` via `cost_for_session(model.session_id)` and
  then builds transcript lines in the same function body
  (`lib/tau/tui/app/events.ex:183–219`). The solution routes the ETS read
  exclusively into `on_message_end_counters/2` and the Markdown/subagent path
  exclusively into `on_message_end_transcript/2`, with the sub-handlers taking
  disjoint model field slices. `on_message_end_transcript/2` receives no
  `session_id` and has no path to ETS.
- **Warrant (W):** A function that accepts no `session_id` argument and imports
  no ETS-dependent alias cannot invoke `cost_for_session/1` even by accident.
  Structural argument isolation (function signature) is a stronger guarantee than
  a naming convention because it is enforced by the compiler's unused-variable and
  undefined-variable checks.
- **Qualifier (Q):** Holds for the as-specified split where `session_id` is
  excluded from `on_message_end_transcript/2`'s parameter set. If a future change
  passes the full model (including `session_id`) to the transcript handler, the
  guarantee degrades to convention.
- **Rebuttal (R):** The model struct itself carries `session_id`; if
  `on_message_end_transcript/2` receives the full model rather than a projected
  map, a future author can reach ETS through `model.session_id` without violating
  the function signature. The solution notes this in Open Questions.
- **Backing (B):** OTP non-negotiable #8 (pure functions are the default; pure
  functions composed without ETS side-effects are trivially unit-testable).
  Acceptance criterion (a) in `problem.md`.

#### Falsification attempt for claim 1

- **Strategy:** Edge-case enumeration — enumerate paths by which the transcript
  handler could acquire ETS access despite the proposed split.
- **Attempt:** (1) If `on_message_end_transcript/2` takes the full model map,
  `model.session_id` is available; a future ETS call is only a one-liner away.
  (2) A shared private alias (`alias Tau.Cost`) at the module level is accessible
  from any private function. (3) The solution specifies `@spec` annotations to
  document field ownership but `@spec` does not prevent cross-reads at runtime or
  at compile time.
- **Outcome:** Partially falsified — the claim holds for the described split *as
  long as `on_message_end_transcript/2` does not receive the full model*, but the
  solution's Migration Sketch does not specify what argument shape the sub-handlers
  take. If both receive the full `model`, path (1) is live and the claim's qualifier
  requires narrowing. The `@spec` annotations document intent but do not enforce it.
  However, the claim's stated level of enforcement ("structural, not conventional")
  does hold if the sub-handler takes only the projected fields it writes (`subagents`,
  `transcript`, `last_assistant`). See claim 3 for the enforcement-strength claim.
- **Action:** Narrow qualifier (see claim 3). No solution revision required here
  since the structural guarantee is architecturally achievable within the proposal;
  the Migration Sketch should state the projected-field shape explicitly.

---

### Claim 2: The warn-level computation and telemetry emission are independently testable without a Markdown content block

- **Claim (C):** After the split, `on_message_end_counters/2` is independently
  testable without a Markdown content block (acceptance criterion (b)).
- **Grounds (G):** In the current code, `on_message_end/2` runs the Markdown
  rendering pipeline (`lib/tau/tui/app/events.ex:183–219`) and the warn-level
  telemetry path (`lib/tau/tui/app/events.ex:232–249`) in the same function body.
  The solution assigns Markdown rendering and subagent filtering exclusively to
  `on_message_end_transcript/2` ("reads `model.subagents` and `msg.content`; no
  ETS, no telemetry dependency") and telemetry to `on_message_end_counters/2`
  ("reads `model.session_id`, `model.context_window`, `model.warn_level`, and
  `message.usage`; emits telemetry conditionally").
- **Warrant (W):** When the telemetry handler does not receive `msg.content` and
  does not import `Tau.TUI.Render.Markdown`, it cannot invoke Markdown rendering.
  A test can therefore construct a minimal `model` with `session_id`,
  `context_window`, `warn_level`, and `usage` and call the counters handler with
  no Markdown content — satisfying criterion (b).
- **Qualifier (Q):** Holds when `on_message_end_counters/2` does not accept
  `msg.content` as an argument. If the dispatcher passes the full `msg` to both
  sub-handlers (as the thin dispatcher described in the solution implies), the
  Markdown renderer is accessible from the counters handler as a compile-time
  alias.
- **Rebuttal (R):** The dispatcher pipes `model` through both handlers with
  presumably the same `msg` argument. If both sub-handlers receive `msg`, a future
  author can add `Markdown.render(msg.content...)` inside `on_message_end_counters/2`
  without violating the function signature constraint. The `@spec` annotation
  cannot prevent this.
- **Backing (B):** Acceptance criterion (b) in `problem.md`. OTP non-negotiable #8.

#### Falsification attempt for claim 2

- **Strategy:** Dependency check — verify that `on_message_end_counters/2` as
  specified has no dependency on `Tau.TUI.Render.Markdown`.
- **Attempt:** The solution specifies that `on_message_end_counters/2` "reads
  `model.session_id`, `model.context_window`, `model.warn_level`, and
  `message.usage`" with no mention of `msg.content` or Markdown. The field list
  is disjoint from the transcript handler's field list. The module-level alias
  `alias Tau.TUI.Render.Markdown` at `lib/tau/tui/app/events.ex:20` is in scope
  for all private functions in the module, but calling it requires explicitly
  naming it.
- **Outcome:** Withstood — the counters handler as specified does not call
  `Markdown.render/1` and accepts no `msg.content` argument. The Markdown alias
  is in scope at the module level but is not invoked. A unit test for
  `on_message_end_counters/2` need not supply a Markdown-ready content block.
  The alias reachability is a future-author risk, not a falsification of the
  current claim.
- **Action:** None.

---

### Claim 3: The separation is structurally enforced at the function-signature level, not merely conventional

- **Claim (C):** "Proposal 4 enforces the transcript/counters separation at the
  function signature level: `on_message_end_transcript/2` receives no `session_id`
  and has no path to ETS; `on_message_end_counters/2` receives no content blocks
  and has no path to Markdown. The enforcement is structural, not conventional."
- **Grounds (G):** The solution states `on_message_end_transcript/2` "receives no
  `session_id`" and `on_message_end_counters/2` "receives no content blocks". The
  `@spec` annotations on both sub-handlers "document field ownership". The module-
  level alias `alias Tau.TUI.Render.Markdown` is at `lib/tau/tui/app/events.ex:20`;
  the module-level alias for `Tau.Cost` is not present in the current file, and
  `cost_for_session/1` is called by name.
- **Warrant (W):** If the sub-handlers receive projected arguments (not the full
  model and not the full `msg`), then missing fields are compile-time errors. The
  Elixir compiler raises `KeyError` or a dialyzer warning when accessing absent
  map keys on a typed struct; `@spec` alone does not cause a compile error on
  access of unspecced fields in a plain map.
- **Qualifier (Q):** The structural enforcement holds **only if** the sub-handlers
  receive projected argument shapes (e.g., only the fields they own), not the
  full model map and not the full `msg`. If the dispatcher passes `(model, msg)`
  to each sub-handler with the same full types, the separation is documentary, not
  enforced. `@spec` annotations on functions that accept the full model type do not
  prevent cross-field reads.
- **Rebuttal (R):** The thin dispatcher as described — "pipes through the two
  sub-handlers in sequence" — most naturally passes `(model, msg)` unchanged to
  each sub-handler (matching the `on_message_end/2` arity). In that case, both
  sub-handlers have full access to `model.session_id`, `msg.content`, and the
  module-level Markdown alias. `@spec` annotations constrain what the spec *says*
  a function does; they do not constrain what it *can* access. Dialyzer does not
  warn on accessing map keys present in a wider-typed argument.
- **Backing (B):** Elixir docs on `@spec` and Dialyzer: specs are used for type
  checking via Dialyzer but do not restrict runtime access to struct/map fields
  beyond what the type spec narrows the argument to. OTP non-negotiable #2:
  enforcement seams must be structural, not conventional.

#### Falsification attempt for claim 3

- **Strategy:** Type-level check — reason over the proposed types to determine
  whether the compiler enforces the claimed separation.
- **Attempt:** If `on_message_end_transcript/2` has signature
  `@spec on_message_end_transcript/2 :: (model_t, msg_t) -> model_t`, where
  `model_t` is the full model map type and `msg_t` is the full message type, then
  Dialyzer has no basis to warn when `on_message_end_transcript/2` calls
  `cost_for_session(model.session_id)` — because `session_id` is a valid key in
  `model_t`. The claim of structural enforcement via function signature requires
  either: (a) the argument is a projected map/struct with `session_id` absent, so
  the compiler raises on access, or (b) a custom opaque type that does not expose
  `session_id`. Neither is mentioned in the solution; only `@spec` annotations
  "documenting field ownership" are specified.
- **Outcome:** Partially falsified — the claim of "structural, not conventional"
  enforcement is overstated as written. The `@spec` annotations document field
  ownership; they do not prevent cross-reads when the full model is passed. The
  claim survives in a narrowed form: the separation is *documentary-structural*
  (enforced by code review against named `@spec` contracts) rather than
  *compiler-structural* (enforced by the type system). The solution's own Open
  Questions section acknowledges this fragility: "a future author adding a field
  read could re-couple silently. A review checklist note is the only guard."
- **Action:** Narrow qualifier — the claim holds as "structurally clearer than
  naming-convention-only (Proposal 1), with field ownership documented via
  `@spec`", not as "compiler-enforced structural separation". No solution revision
  required; the narrowed qualifier is an accurate description of what Proposal 4
  achieves. The solution's own Open Questions section already contains an honest
  caveat.

---

### Claim 4: The `try/rescue` site for ETS unavailability is isolated in a single helper (`cost_for_session/1`) and is not embedded in a multi-concern function body (acceptance criterion (c))

- **Claim (C):** After the split, the `try/rescue` site is "isolated in a single
  helper rather than embedded in a multi-concern function body" (acceptance
  criterion (c)).
- **Grounds (G):** The current `on_message_end/2` is a 77-LOC multi-concern
  function; `cost_for_session/1` is already a private helper
  (`lib/tau/tui/app/events.ex:262–269`). The solution states: "the existing
  `cost_for_session/1` private helper (the sole `try/rescue` site) remains
  unchanged and is called only from `on_message_end_counters/2`". After the
  split, `on_message_end_counters/2` is a ~20-LOC single-concern function.
- **Warrant (W):** A ~20-LOC function with a single concern (counters, ETS, warn
  computation, telemetry) is meaningfully less "multi-concern" than a 77-LOC
  function with four distinct concerns. The `try/rescue` is already isolated in
  `cost_for_session/1`; after the split, `on_message_end_counters/2` calls it
  without also performing Markdown rendering or subagent tree queries.
- **Qualifier (Q):** Criterion (c) as written requires the `try/rescue` to be
  "isolated in a single helper rather than embedded in a multi-concern function
  body". The current implementation already isolates the `try/rescue` in
  `cost_for_session/1` (`lib/tau/tui/app/events.ex:262–269`); what changes is the
  function that calls it, from 77-LOC multi-concern to ~20-LOC single-concern.
- **Rebuttal (R):** `on_message_end_counters/2` at ~20 LOC still combines ETS
  read, warn computation, and telemetry emit — as acknowledged in the Open
  Questions. If "single concern" is read strictly, criterion (c) is met but
  further separation within `on_message_end_counters/2` is left for a future
  problem statement.
- **Backing (B):** Acceptance criterion (c) in `problem.md`. `problem.md` §Context
  citing `lib/tau/tui/app/events.ex:262–269` as the `try/rescue` location.

#### Falsification attempt for claim 4

- **Strategy:** Dependency check — verify that `cost_for_session/1` is the sole
  `try/rescue` site and that after the split it is called only from
  `on_message_end_counters/2`.
- **Attempt:** `grep -n "try/rescue\|try do\|rescue" lib/tau/tui/app/events.ex`
  yields lines 262–268 (the `cost_for_session/1` body) as the only `try/rescue`
  in the file (confirmed by reading `lib/tau/tui/app/events.ex:262–269`). The
  solution specifies that `cost_for_session/1` "remains unchanged and is called
  only from `on_message_end_counters/2`". The current call site is
  `lib/tau/tui/app/events.ex:224` within `on_message_end/2`; after the split it
  moves to the body of `on_message_end_counters/2`.
- **Outcome:** Withstood — the `try/rescue` is already isolated in a helper;
  after the split the helper is called from a narrower (~20-LOC) function. The
  current codebase already satisfies criterion (c) partially (the `try/rescue` is
  in a helper); the refactor completes it (the helper is called from a
  single-concern function).
- **Action:** None.

---

### Claim 5: All public APIs of `Tau.TUI.App.Events` are preserved; no SPEC amendments are required

- **Claim (C):** "All public APIs of `Tau.TUI.App.Events` — no public function
  signatures move." "SPEC-TUI-HEADLESS Appendix B source map — no new files to
  register."
- **Grounds (G):** The solution's What-does-not-change section lists: all public
  APIs unchanged; the telemetry event schema `[:tau, :tui, :status, :update]` and
  its metadata (including `session_id`) unchanged; SPEC-TUI-HEADLESS Appendix B
  unchanged. The refactor is "purely mechanical and stays within
  `lib/tau/tui/app/events.ex`". The new private functions are `defp`, not public.
- **Warrant (W):** A refactor that introduces only private functions and does not
  change the signatures of existing public functions does not alter the module's
  public API contract. Private functions are not part of a module's exported
  surface and do not require SPEC amendments under `spec-before-code.md`'s trigger
  rules (which are source-file based, not function-visibility based).
- **Qualifier (Q):** Holds for the as-specified refactor that introduces only
  `defp` functions inside the existing file. If the implementation introduces a
  new module or moves a public function, the claim would be false.
- **Rebuttal (R):** If a future implementer misreads the brief and extracts a
  submodule (e.g., `Tau.TUI.App.Events.Transcript`), a new file would be created,
  requiring a SPEC-TUI-HEADLESS Appendix B amendment. The solution explicitly
  prohibits new modules; this is a guard against implementer scope creep, not a
  design ambiguity.
- **Backing (B):** `spec-before-code.md` §"What counts as coordination-heavy" and
  the SPEC-TUI-HEADLESS mandatory-scope list (requires amendments only for new
  files in `lib/tau/tui/`). `solution.md` §What-does-not-change.

#### Falsification attempt for claim 5

- **Strategy:** Counter-example construction — attempt to construct a scenario
  where the described refactor requires a public API change or SPEC amendment.
- **Attempt:** The solution introduces two new private functions and a thin
  dispatcher body. No new module is created. No `@callback` or `use` macro is
  changed. The telemetry event name, keys, and metadata are unchanged. The
  `on_message_end/2` public-facing handler signature `(model, %{message: msg} = e)`
  is unchanged (the dispatcher retains the same pattern). No new file is introduced.
- **Outcome:** Withstood — no counter-example found. The refactor is intra-file
  and intra-module; no SPEC amendment is triggered.
- **Action:** None.

---

### Claim 6: The telemetry event schema `[:tau, :tui, :status, :update]` and its `session_id` metadata field are preserved (D-168/D-169 invariants unchanged)

- **Claim (C):** "The telemetry event schema `[:tau, :tui, :status, :update]` and
  its metadata (including `session_id`) — D-168/D-169 invariants unchanged."
- **Grounds (G):** The current telemetry call at `lib/tau/tui/app/events.ex:244–248`
  emits `%{context_pct: pct, warn_level: new_warn, session_id: model.session_id}`.
  The solution assigns `on_message_end_counters/2` to "read `model.session_id`"
  and "emit telemetry conditionally" with no schema change. The What-does-not-
  change section explicitly states the schema and `session_id` metadata are
  unchanged.
- **Warrant (W):** The `session_id` field is sourced from `model.session_id`, and
  the solution assigns `model.session_id` as an input to `on_message_end_counters/2`.
  As long as the counters handler receives a model with `session_id` and the
  telemetry call body is reproduced verbatim, D-168/D-169 are preserved.
- **Qualifier (Q):** Holds when `on_message_end_counters/2` receives a model with
  a valid `session_id`. If the argument is a projected map that omits `session_id`,
  the D-169 metadata `session_id` key would be absent or nil — this would be a
  D-169 invariant violation.
- **Rebuttal (R):** Claim 3 notes that structural enforcement via `@spec` does not
  prevent the counters handler from receiving the full model. The specific
  requirement that `on_message_end_counters/2` must receive `model.session_id`
  means the argument cannot be projected to exclude it — the counters handler
  necessarily has access to `model.session_id`, which is consistent with claim 3's
  narrowed qualifier (the ETS-access path exists through the model, but the
  telemetry requirement is precisely what justifies it).
- **Backing (B):** SPEC-TUI-HEADLESS §5d (D-168, D-169). `problem.md` §Context
  citing `lib/tau/tui/app/events.ex:232–249`.

#### Falsification attempt for claim 6

- **Strategy:** Integration check — verify that the D-168/D-169 telemetry
  invariant is preserved by examining the telemetry call site and its required
  inputs.
- **Attempt:** The current call at `lib/tau/tui/app/events.ex:244–248` emits
  three metadata fields: `context_pct`, `warn_level`, and `session_id`. All three
  are computed from `model.session_id`, `model.context_window`, `model.warn_level`,
  and `message.usage`. The solution assigns all these inputs to
  `on_message_end_counters/2`. The migration sketch confirms "one driving
  `on_message_end_counters/2` with a mock session counter and a `:telemetry.attach`
  handler (no Markdown content)". The event name and metadata schema are unchanged.
- **Outcome:** Withstood — the integration requirement is satisfiable; all inputs
  to the telemetry call are assigned to the counters handler's input set.
- **Action:** None.

---

## Cross-claim consistency

Claims 1 and 3 are in mild tension: Claim 1 asserts "independent testability
without a cost ETS table" and Claim 3 asserts "structural, not conventional,
enforcement". Claim 3's partial falsification (narrowed to documentary-structural)
does not falsify Claim 1 — testability without ETS holds if the sub-handler does
not *call* `cost_for_session/1`, regardless of whether the compiler *prevents* it.
A unit test that passes a model without a valid ETS table will surface any
accidental ETS call as a `test/1` failure (since the `try/rescue` would catch
`ArgumentError` and return zeros — the test would not crash, but the ETS read
would not be exercised). This is adequate for criterion (a) under the narrowed
qualifier.

Claims 3 and 6 are in constructive tension: Claim 6 requires
`on_message_end_counters/2` to receive `model.session_id` for D-169 compliance,
which means `on_message_end_transcript/2` could also access it (same model). This
confirms claim 3's partial falsification — the separation is not compiler-enforced.
The tension resolves in the narrowed qualifier: documentary-structural separation
with `@spec` contracts is sufficient for the acceptance criterion; full compiler
enforcement would require a separate argument type design not proposed here.

No claim pairs are logically contradictory. The set is internally consistent
under the narrowed qualifiers from claims 1 and 3.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Transcript handler testable without ETS | Edge-case enumeration | Partially falsified — qualifier narrowed | Narrow Q: holds if sub-handler does not receive full model with `session_id` |
| 2 | Counters handler testable without Markdown | Dependency check | Withstood | None |
| 3 | Enforcement is structural, not conventional | Type-level check | Partially falsified — `@spec` is documentary, not compiler-enforced | Narrow Q: "documentary-structural via `@spec`"; no revision required |
| 4 | `try/rescue` isolated in helper, not multi-concern function | Dependency check | Withstood | None |
| 5 | Public APIs and SPEC-TUI-HEADLESS Appendix B unchanged | Counter-example construction | Withstood | None |
| 6 | D-168/D-169 telemetry schema and `session_id` metadata preserved | Integration check | Withstood | None |

---

## Revision required

Claims 1 and 3 are partially falsified, both narrowed via Qualifier rather than
by revision. The narrowed forms are:

- **Claim 1 (narrowed Q):** Transcript handler is independently testable without
  ETS *provided* its argument does not include `session_id` (projected map or
  explicitly absent). The Migration Sketch should state the argument shape.
- **Claim 3 (narrowed Q):** The separation is "documentary-structural via `@spec`
  annotations" rather than "compiler-structural via type exclusion". The solution's
  own Open Questions section already acknowledges this.

No file revision is needed. The coordinator should ensure the implementer brief
specifies the projected argument shapes for the two sub-handlers explicitly, so
that claim 1's stronger structural guarantee can be achieved at implementation time.

---

## Outstanding doubts

- The dispatcher ordering (`on_message_end_transcript/2` before
  `on_message_end_counters/2`) is not load-bearing today, but is not enforced as
  such. If a future change makes counters depend on a transcript-produced field,
  the ordering becomes a hidden coupling with no type-system guard. The solution
  acknowledges this; no further action required here, but the parent-level
  validator should note it.
- `on_message_end_counters/2` still combines ETS read + warn computation +
  telemetry emit. If a future problem targets warn-level isolation from ETS reads,
  the solution explicitly defers this to Proposal 2's `StatusBar.maybe_emit/3`
  approach. The unresolved `session_id` metadata question in Proposal 2 must be
  answered before that refactor. This is an open design question, not a claim
  falsification.
- The `@spec` annotations' field-ownership semantics are not validated by the Elixir
  compiler at call sites; their effectiveness as an enforcement mechanism depends on
  code review discipline. If the project's review gate does not check `@spec`
  compliance on private functions, the documentary separation degrades to a comment.
