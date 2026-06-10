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

# Validation: Command pattern for Input, pure-split for Keymap

## Overview

The solution asserts five checkable propositions: (1) returning `{model,
[Cmd.t()]}` makes `Input` public functions pure; (2) a thin `Cmd.execute/1`
dispatcher concentrates all side-effects; (3) `Keymap.quit_or_append/1`'s
`{model, [:stop_tui_supervisor]}` command tag propagates to `Cmd.execute/1`
through a single call path from `handle_event/2`; (4) all `Input`/`Keymap`
model-transformation branches become unit-testable without live processes;
(5) `Model.t()` struct fields, the `Tau.*` API surface, and sibling sub-problems
are unaffected. Seven falsification strategies are applied across the five
claims. Outcomes: four withstood, one partially falsified (claim 4 — the
`Store.append/3` call in `submit/1` remains side-effectful inside the otherwise
pure path; qualifier narrowed). No revision triggered.

---

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants found it
difficult to generate Toulmin structures, and their structures varied greatly
even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly to counter that variance.

---

### Claim 1: Every public Input function's return type changes from `map()` to `{map(), [Cmd.t()]}` and all `Tau.*` call sites are replaced by command list elements, making those functions pure.

- **Claim (C):** Every public `Input` function (`submit/1`, `cancel/1`,
  `steer/1`, `followup/1`, `handle_perms_command/2`) changes return type from
  `map()` to `{map(), [Cmd.t()]}`. `Tau.*` call sites are replaced by cmd list
  elements.
- **Grounds (G):** Current call sites — `lib/tau/tui/app/input.ex:32`
  (`Tau.send/2`), `:120` (`Tau.cancel/1`), `:139` (`Tau.steer/1`), `:168`
  (`Tau.send/2`), `:112` (`Tau.Session.set_permissions_mode/2`) — are
  unconditional side effects interleaved with model-transformation logic.
  Current `@spec` annotations (`@spec submit(map()) :: map()`, etc.) confirm
  the present return types. The `Cmd` module does not yet exist (`lib/tau/tui/app/cmd.ex`
  absent, confirmed by `find lib/tau/tui/app/`).
- **Warrant (W):** A function is pure iff its observable output is fully
  determined by its inputs and it causes no side effects. Replacing imperative
  `Tau.*` calls with tagged list elements defers execution to the caller;
  the function body then reads and transforms `model` only — satisfying
  referential transparency. This is the standard command-pattern warrant.
- **Qualifier (Q):** Holds for the five named public functions. Does not cover
  `submit_or_continue/1`, `clear_input/1`, or any non-public helpers (see
  claim 4 partial falsification regarding `Store.append/3` in `submit/1`).
- **Rebuttal (R):** If any branch in these functions retains a direct `Tau.*`
  call (e.g., via a `cond` arm omitted from the migration sketch), the function
  is not pure on that branch. The migration requires per-function attention; an
  incomplete migration leaves a mixed-purity interface.
- **Backing (B):** OTP non-negotiable #8 ("pure functions are the default;
  processes are the exception") from `.claude/rules/otp-non-negotiables.md`.
  Hickey "Simple Made Easy" (2011): complecting a value computation with a
  side effect makes both harder to test and compose.

#### Falsification attempt for claim 1

- **Strategy:** Edge-case enumeration — enumerate branches in each affected
  function and check whether any branch bypasses the command-pattern conversion.
- **Attempt:** Read `input.ex:21–177`. `submit/1` has three branches:
  empty-input (returns `model`, no effect — trivially pure), `/perms` intercept
  (delegates to `handle_perms_command/2`), and normal-submit (currently calls
  `Tau.send/2` then `Store.append/3`). `cancel/1` has one branch. `steer/1`
  has two branches (empty no-op and effectful). `followup/1` has three branches
  including an `idle` fallback that calls `submit/1`. `handle_perms_command/2`
  has three `cond` arms, one calling `Tau.Session.set_permissions_mode/2`.
  All identified `Tau.*` call sites match the five listed in the problem's
  context section. No additional unlisted call sites found. The `followup/1`
  idle branch calls `submit/1`, which itself has side effects under the current
  signature; after migration both would return `{model, cmds}` so composing
  them is structurally sound — the empty `Tau.send` in `followup/1:168` and the
  `submit/1` delegation chain both map cleanly to cmd list elements.
- **Outcome:** Withstood — no hidden branch produces an un-migrated `Tau.*`
  call outside the five documented sites. The migration sketch is complete for
  the claim's stated scope.
- **Action:** None.

---

### Claim 2: A new `Tau.TUI.App.Cmd` module with `Cmd.t()` tagged union and `execute/1` concentrates all side effects in one named dispatch point.

- **Claim (C):** New `lib/tau/tui/app/cmd.ex` defines `Tau.TUI.App.Cmd.t()`
  tagged union and `execute/1` dispatch. Tags: `{:send, sid, text}`,
  `{:cancel, sid}`, `{:steer, sid, text}`, `{:set_permissions_mode, sid, mode}`,
  `:stop_tui_supervisor`.
- **Grounds (G):** No `cmd.ex` exists today (`ls lib/tau/tui/app/` output
  confirms absence). The five `Tau.*` call sites in `input.ex` and the
  `spawn/1` block in `keymap.ex:288–292` cover every effect currently
  inlined in `Input`/`Keymap`. Five tags map one-to-one to those call sites:
  `{:send,…}` → `Tau.send/2`; `{:cancel,…}` → `Tau.cancel/1`;
  `{:steer,…}` → `Tau.steer/1`; `{:set_permissions_mode,…}` →
  `Tau.Session.set_permissions_mode/2`; `:stop_tui_supervisor` → the `spawn/1`
  block.
- **Warrant (W):** Concentrating all effectful dispatch in one function makes
  the effect surface enumerable and auditable; adding a new effect requires
  an explicit union extension rather than an ad-hoc call insertion anywhere in
  the codebase. This is the core benefit of the command pattern — effect intent
  as a value.
- **Qualifier (Q):** Holds as long as `execute/1` remains the only caller of
  `Tau.*` within the `Tau.TUI.App.*` namespace. If `Bootstrap.init/1` or
  `Tau.TUI.App` itself retains direct `Tau.*` calls (which is out of scope of
  this sub-problem), the concentration claim is partial.
- **Rebuttal (R):** `Bootstrap.init/1` is explicitly out of scope; it will
  continue to call `Tau.start_session/1` and `Tau.TUI.EventBridge.start_link/1`
  directly. The concentration claim covers only `Input`/`Keymap`, not the
  full `Tau.TUI.App.*` namespace.
- **Backing (B):** Rich Hickey, "The Value of Values" (Strange Loop 2012):
  representing effects as first-class values decouples intent from execution.
  Martin Fowler, "Command" pattern (PoEAA): encapsulating requests as objects
  provides a stable dispatch point.

#### Falsification attempt for claim 2

- **Strategy:** Dependency check — verify that the five tags in `Cmd.t()` cover
  every `Tau.*` and `spawn/1` call currently in `Input` and `Keymap`, with no
  omissions.
- **Attempt:** Cross-referenced the five tags against the context section of
  `problem.md` (six bullet points) and the actual `input.ex` grep output.
  `problem.md` lists: `Tau.send` (line 32, 168), `Tau.Session.set_permissions_mode`
  (line 113), `Tau.cancel` (line 120), `Tau.steer` (line 139), and
  `spawn(fn → DynamicSupervisor…)` (keymap.ex:288). Five distinct effect types
  → five tags. No gap detected. `Store.append/3` (line 34) is disk I/O but
  is NOT a `Tau.*` or `spawn/1` call; it is addressed in claim 4.
- **Outcome:** Withstood — the five `Cmd.t()` tags cover the full set of
  `Tau.*` / `spawn/1` effects in the scoped modules.
- **Action:** None.

---

### Claim 3: `Keymap.quit_or_append/1`'s `spawn/1` block is lifted to `defp do_stop_tui_supervisor/0`; the command tag `[:stop_tui_supervisor]` propagates through exactly one call path from `Keymap.handle_event/2` to `Cmd.execute/1`.

- **Claim (C):** `quit_or_append/1` emits `{model, [:stop_tui_supervisor]}`
  from the quit branch. The `{model, cmds}` pair propagates through
  `Keymap.handle/2` (the public boundary) to the façade's dispatch point,
  through a single call path.
- **Grounds (G):** `keymap.ex:286–300`: `quit_or_append/1` is `defp`; it is
  called from exactly one site — `keymap.ex:243` (`handle_char/2` for `?q`).
  `handle_char/2` is called from `handle_event_normal/2` (line 57,
  `defp handle_char(model, ch)`). `handle_event_normal/2` is called from
  `handle_event/2` (line 33). `handle_event/2` is called from
  `app/events.ex:35`. The call path is:
  `handle_event/2` → `handle_event_normal/2` → `handle_char/2` →
  `quit_or_append/1`. Confirmed by grep: `quit_or_append` appears exactly
  once as a call site (`keymap.ex:243`).
- **Warrant (W):** A single call path through private helpers means that
  propagating `{model, cmds}` up requires changing signatures of all
  intermediate `defp` functions on that path — `handle_char/2`,
  `handle_event_normal/2`, `handle_event/2` — or leaving the lower functions
  returning `map()` and handling the conversion at one boundary. The solution's
  migration sketch (step 3) specifies the propagation through `Keymap.handle/2`
  (which the solution treats as `handle_event/2`). This is structurally sound
  for a single path.
- **Qualifier (Q):** "Exactly one call path" holds today (grep-verified). If
  `quit_or_append/1` gains additional call sites in the future, the propagation
  contract must be revisited. Also, the solution uses "Keymap.handle/2"
  interchangeably with what the code calls `handle_event/2`; the public boundary
  in the actual source is `handle_event/2`, not a function named `handle/2`.
- **Rebuttal (R):** The solution's open question explicitly names this concern:
  "grep `keymap.ex` for all call sites of `quit_or_append/1` to confirm there
  is exactly one path." This validation confirms exactly one path; if that
  assumption is wrong (e.g., after a future refactor), the propagation
  claim must be re-evaluated.
- **Backing (B):** Solution open questions section; `keymap.ex:243` (grep
  result confirming single call site); `events.ex:35` (single external caller
  of `handle_event/2`).

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction — try to find a second call site
  for `quit_or_append/1` or a branching path through which the `cmds` list
  could be silently dropped.
- **Attempt:** Grep of `keymap.ex` for `quit_or_append` yields exactly two
  lines: the `defp` definition (line 286) and the single call site (line 243).
  The intermediate call chain (`handle_char/2` → `handle_event_normal/2` →
  `handle_event/2`) currently returns `map()`. After migration, each of these
  three private functions must change return type to `{map(), [Cmd.t()]}`. The
  `handle_event_normal/2` function has multiple clauses (lines 51–59); all
  clauses would need to return `{model, cmds}`. The non-char clauses (`handle_alt`,
  `handle_key`, `handle_readline_key`) also return `map()` today; after
  migration they would return `{model, []}` unless they also gain cmd-bearing
  paths. This is non-trivial cascading signature change across the full
  `handle_event_normal/2` dispatch, but does not falsify the "single path"
  claim — it merely quantifies the migration cost, which the solution
  acknowledges as "private call graph not traced in any proposal."
- **Outcome:** Withstood — no second call path found. The single-path claim
  is accurate, though the migration requires changing three private function
  signatures.
- **Action:** None; but the open question in the solution about tracing the
  full private call graph is confirmed as important.

---

### Claim 4: All `Input`/`Keymap` model-transformation branches become unit-testable without a live `Tau.Session` or `Tau.TUI.Supervisor` process.

- **Claim (C):** Both `Input` and `Keymap` become unit-testable by asserting on
  `{model, [cmd]}` with no live processes.
- **Grounds (G):** After migration, the only remaining calls to external modules
  in the affected functions would be to `Editor.*`, `History.*`, `Store.append/3`,
  and `Completion.*` — all of which operate on plain data or local I/O.
  `Tau.*` calls are removed from `Input`/`Keymap` bodies by definition of the
  migration. However, `input.ex:34` (`Store.append/3`) is disk I/O that the
  solution explicitly leaves in place: "The problem statement scopes only
  `Tau.*` and `spawn/1`, so this is left as-is" (open questions section).
- **Warrant (W):** Removing process-creating and process-communicating calls
  from function bodies is sufficient to unit-test those functions in isolation.
  But I/O side effects (file writes via `Store.append/3`) are also side effects;
  a test of `submit/1` that asserts only on the returned `{model, cmds}` still
  triggers a real disk write unless the test stubs `Store`.
- **Qualifier (Q):** Unit-testable *without a live `Tau.Session` or
  `Tau.TUI.Supervisor` process* — **yes**, unconditionally after migration.
  Unit-testable *without any side effect* (including I/O) — **no**, unless
  `Store.append/3` is stubbed or the test is run in a temp directory.
  The acceptance criterion in `problem.md` requires only that testing not
  require a live session process; disk I/O does not falsify the criterion.
- **Rebuttal (R):** The claim as stated in the solution's Recommendation is
  "unit-testable by asserting on `{model, [cmd]}` with no live processes."
  The qualifier "no live processes" is satisfied; "pure" in the strict sense
  is not, because `Store.append/3` remains. A test of `submit/1` that asserts
  `{model, [{:send, sid, text}]}` will also write to `data_dir`; the test
  harness must arrange a temp dir or mock `Store` to avoid flakiness.
- **Backing (B):** `problem.md` acceptance criterion: "the model transformation
  can be unit-tested without a live `Tau.Session` or `Tau.TUI.Supervisor`
  process." `input.ex:34` confirms `Store.append/3` is outside the `Tau.*`
  scope restriction. Solution open questions: "Store.append/3 in submit/1 is
  disk I/O remaining in the Input pure path."

#### Falsification attempt for claim 4

- **Strategy:** Edge-case enumeration — enumerate all remaining side-effectful
  calls in `submit/1` after the proposed migration to identify any that require
  infrastructure beyond a plain map model.
- **Attempt:** Post-migration `submit/1` body: (a) `Editor.text/1` — pure;
  (b) `Editor.empty?/1` — pure; (c) cmd list element `{:send, sid, text}` —
  pure value; (d) `History.push/2` — pure (returns new history value);
  (e) `Store.append/3` — writes to disk at `model.history_data_dir`; not pure.
  A test of `submit/1` that asserts the returned `{model, cmds}` will still
  trigger a real `Store.append/3` call. The assertion on cmds works without a
  live session, but the test is not side-effect-free. The `problem.md`
  acceptance criterion does not require side-effect-freedom, only session-process
  independence — so the criterion is met, but the claim "unit-testable with
  no live processes" slightly overstates purity.
- **Outcome:** Partially falsified — the claim that functions are unit-testable
  without live processes is **true and satisfies the acceptance criterion**. But
  the implicit sub-claim that all side effects are deferred to `Cmd.execute/1`
  is false: `Store.append/3` remains inline in `submit/1`. The qualifier must
  be narrowed to: "unit-testable without a live `Tau.Session` or
  `Tau.TUI.Supervisor` process; disk I/O via `Store.append/3` in `submit/1`
  remains and requires a writable `history_data_dir` in tests."
- **Action:** Narrow qualifier (no solution revision needed; the narrowed
  claim still satisfies the `problem.md` acceptance criterion). The open
  question in the solution already acknowledges this; it is confirmed as a
  real residual, not a hypothetical.

---

### Claim 5: `Model.t()` struct fields, the `Tau.*` API surface, sibling sub-problems (`duplicated-bounded-append`, `model-as-bag-of-maps`, `transcript-coupling`), and the `Tau.TUI.App` public interface are unaffected.

- **Claim (C):** `Model.t()` struct fields — no new fields added. The `Tau.*`
  and `Tau.Session.*` API surface — explicitly out of scope. `Bootstrap.init/1`
  lifecycle side effects — out of scope. The `Tau.TUI.App` public interface and
  event-loop structure — façade gains one private helper, not new public
  callbacks. Sibling sub-problems — disjoint file sets.
- **Grounds (G):** The solution's "What does not change" section enumerates
  these explicitly. The changed file set (`lib/tau/tui/app/cmd.ex` new;
  `lib/tau/tui/app/input.ex`, `lib/tau/tui/app/keymap.ex`,
  `lib/tau/tui/app.ex` modified) does not overlap with `model.ex` (no field
  changes), `bootstrap.ex`, or the sibling subproblem directories. `Tau.*`
  module bodies are not in the changed set. `app.ex` gains `run_input/2` as
  a private helper, confirmed by the solution's "What changes" section
  specifying it as private.
- **Warrant (W):** If the changed-file set and the preserved-file set are
  disjoint, and no public-function signatures are removed or added on the
  preserved modules, the "unaffected" claim holds. The command pattern
  redirects effects through `Cmd.execute/1` without touching the effected
  API modules.
- **Qualifier (Q):** Holds assuming the façade's external callers (i.e.,
  `events.ex:35` calling `Keymap.handle_event/2`) receive the return-type
  change transparently through the `run_input/2` / destructure layer in
  `app.ex`. If any external caller directly pattern-matches on the `map()`
  return from `Keymap.handle_event/2`, it will need updating — but this is
  a compile-time error caught by Dialyzer/compiler, not a silent regression.
- **Rebuttal (R):** `events.ex:35` currently calls `Keymap.handle_event(model, event)`
  and uses the return as `model` (a plain map). After migration, if `handle_event/2`
  returns `{map(), [Cmd.t()]}`, the `events.ex` caller must destructure. This
  is a required change in `events.ex` that the solution's "What changes" section
  does not list. It is not a public-interface regression (it's an internal
  call), but it is an omitted file in the migration scope.
- **Backing (B):** `events.ex:35` (grep confirmed); solution "What changes"
  section; `spec-before-code.md` source maps for `SPEC-TUI-HEADLESS.md` and
  `SPEC-USER-TURN.md` (the affected modules are covered by both SPECs).

#### Falsification attempt for claim 5

- **Strategy:** Dependency check — check every caller of `Keymap.handle_event/2`
  and `Input.*` functions to confirm they are covered by the solution's change
  set or are genuinely unaffected.
- **Attempt:** `events.ex:35` calls `Keymap.handle_event(model, event)` and
  uses the result as a new model. After migration, this line will receive
  `{map(), [Cmd.t()]}` instead of `map()` — it will fail to compile or
  produce a type error unless updated. `events.ex` is NOT listed in the
  solution's "What changes" section. `app.ex` is listed, but `events.ex` is
  a sibling file that delegates to `Keymap`. Grep output confirmed
  `app/events.ex:35` as the sole external caller of `Keymap.handle_event/2`.
  This is a real omission from the migration scope, but:
  (a) it is a compile-time failure, not a silent regression;
  (b) the acceptance criterion does not require a complete file enumeration,
  only that the model-transformation/side-effect decoupling is achievable;
  (c) fixing `events.ex` is a trivial destructure change.
  The "What does not change" claims (Model.t() fields, Tau.* API, Bootstrap,
  sibling sub-problems) are all withstood.
- **Outcome:** Withstood for the "What does not change" claims.
  The omission of `events.ex` from "What changes" is a migration-completeness
  gap (the implementer will discover it at compile time), not a falsification
  of the claims about what is preserved. Qualifier stands.
- **Action:** Note as an outstanding doubt for the implementer brief.

---

## Cross-claim consistency

Claims 1 and 2 are mutually reinforcing: claim 1 removes `Tau.*` from function
bodies; claim 2 collects those effects in `Cmd.execute/1`. They are consistent.

Claims 1 and 4 are in tension only at the `Store.append/3` edge: claim 1
says `submit/1` becomes pure (qualified to `Tau.*` / `spawn/1` only, per the
problem scope), while claim 4's partial falsification reveals that disk I/O
remains. The tension is resolved by the narrowed qualifier in claim 4 —
"no live session process required" rather than "fully pure." The
`problem.md` acceptance criterion matches the narrowed qualifier exactly.

Claim 3's "propagates through `Keymap.handle/2`" uses the solution's naming
("handle/2"), while the codebase uses `handle_event/2`. The mapping is
unambiguous and does not create a consistency problem.

Claim 5's omission of `events.ex` is an implementation-scope gap, not a
cross-claim inconsistency. No two claims contradict each other.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Input public fns return `{model, [Cmd.t()]}`, all `Tau.*` removed | Edge-case enumeration | Withstood | None |
| 2 | `Cmd.execute/1` concentrates all effects; 5 tags cover all call sites | Dependency check | Withstood | None |
| 3 | Single call path from `handle_event/2` through `quit_or_append/1` | Counter-example construction | Withstood | None |
| 4 | `Input`/`Keymap` unit-testable without live processes | Edge-case enumeration | Partially falsified — `Store.append/3` remains | Narrow qualifier; no revision |
| 5 | Model.t(), Tau.* API, siblings unaffected | Dependency check | Withstood (with noted gap) | Note `events.ex` for implementer |

---

## Revision required

No revision triggered. Claim 4 is partially falsified; the qualifier is
narrowed in place. The narrowed claim continues to satisfy the `problem.md`
acceptance criterion.

---

## Outstanding doubts

1. `events.ex:35` calls `Keymap.handle_event/2` and will require a destructure
   change after migration. This file is omitted from the solution's "What
   changes" section. The implementer will discover this at compile time; it
   does not require a solution revision, but the implementer brief should
   name it explicitly.

2. The `spawn/1` in `Cmd.execute/1` (for `:stop_tui_supervisor`) raises the
   question noted in the solution's open questions: does an unsupervised `spawn/1`
   inside `execute/1` violate OTP non-negotiable #1 (stateful subsystems under
   a supervisor)? The spawn is transient (fire-and-forget shutdown), not
   stateful; but this should be documented in the implementation PR or a
   `# D-xxx` comment citing the justification, not left implicit.

3. The full private-function call chain in `Keymap` below `handle_event/2`
   (specifically `handle_event_normal/2`, `handle_key/3`, `handle_char/2`)
   currently returns `map()`. After migration, all three must return
   `{map(), [Cmd.t()]}`. This cascading change is non-trivial and not
   enumerated in the migration sketch; the implementer should trace it before
   beginning step 3 of the migration.
