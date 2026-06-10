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

# Validation: Extract `bounded_append` into `Tau.TUI.App.Model`

## Overview

The solution makes four checkable propositions: (1) a single canonical
implementation of `bounded_append/2` and `bounded_append_many/2` will exist in
`Model`; (2) a single `@transcript_cap 500` constant will exist in `Model`; (3)
the duplicate definitions will be absent from `Events` and `Input`; (4) no
external callers of `Events.bounded_append/2` will be silently broken.
Six claims total (the acceptance-criterion decomposition produces two additional
propositions from "What does not change": (5) function bodies are preserved
exactly; (6) `Model.t()` struct shape is unchanged). Falsification strategies
are edge-case enumeration and dependency/integration checks. All claims withstood
or survive with a narrowed qualifier; no revision is triggered.

---

## Toulmin per claim

### Claim 1: A single canonical implementation of `bounded_append/2` and `bounded_append_many/2` exists in `Tau.TUI.App.Model`.

- **Claim (C):** "Move `bounded_append/2`, `bounded_append_many/2`, and
  `@transcript_cap 500` into `Tau.TUI.App.Model` as public functions."
- **Grounds (G):** Currently `bounded_append/2` is private in both
  `lib/tau/tui/app/events.ex:429` and `lib/tau/tui/app/input.ex:193`.
  `bounded_append_many/2` exists only in `events.ex:445`. `Model` has no
  `bounded_append` function at all (verified: `grep -n bounded_append
  lib/tau/tui/app/model.ex` — zero hits). The solution's migration sketch
  step 1 adds the functions to `model.ex` before removing them elsewhere.
- **Warrant (W):** A module that declares a type and its invariants is the
  natural owner of pure helpers that enforce those invariants (OTP
  non-negotiable §8: pure functions are the default). `Model` already
  declares `transcript: [{String.t(), keyword()}]` at `model.ex:76` and
  is the single type-owner.
- **Qualifier (Q):** Q: holds after all three files are updated atomically in
  one PR; if the migration is interrupted mid-step (e.g. `events.ex` updated
  but `input.ex` not), duplication remains until completion.
- **Rebuttal (R):** If `model.ex` is wrapped in
  `if Code.ensure_loaded?(Ratatouille.Runtime)` (confirmed at `model.ex:1`)
  and `bounded_append` is called from a non-TUI code path compiled without
  Ratatouille, the function will be undefined at that call-site. The solution's
  Open Questions section acknowledges this.
- **Backing (B):** OTP non-negotiable §8 (`.claude/rules/otp-non-negotiables.md`);
  Hickey "Simple Made Easy" — place behaviour with the data it operates on.

#### Falsification attempt for claim 1

- **Strategy:** Dependency check — verify `model.ex` is conditionally compiled
  and confirm the compilation guard applies.
- **Attempt:** `grep -n "Code.ensure_loaded\|defmodule" lib/tau/tui/app/model.ex`
  confirms `if Code.ensure_loaded?(Ratatouille.Runtime) do` at line 1 wrapping
  the entire module. All three files (`events.ex`, `input.ex`, `model.ex`) share
  the same guard. Any call-site in `events.ex` or `input.ex` that calls
  `Model.bounded_append` would also be under the same guard, so the
  availability context is uniform. No falsifying case found.
- **Outcome:** withstood
- **Action:** none

---

### Claim 2: A single `@transcript_cap 500` constant is defined in `Tau.TUI.App.Model`; the copies in `Events` and `Input` are removed.

- **Claim (C):** "`@transcript_cap 500` … the cap constant … then exist in
  exactly one place."
- **Grounds (G):** Currently `@transcript_cap 500` exists at
  `lib/tau/tui/app/events.ex:24` and `lib/tau/tui/app/input.ex:191`
  (confirmed by grep). `model.ex` has no `@transcript_cap` attribute (verified:
  zero hits). The solution's "What changes" section removes it from both modules
  and adds it to `model.ex`.
- **Warrant (W):** A module attribute used only inside a function body is module-
  private; placing it alongside the function it governs ensures a single point of
  truth and eliminates drift risk. This is a standard Elixir constant-colocation
  pattern.
- **Qualifier (Q):** Q: holds once migration is complete; intermediate states
  (during the PR) will transiently have the constant in all three locations
  before the deletions occur.
- **Rebuttal (R):** If another module in `lib/tau/tui/` also defines
  `@transcript_cap` with a different value for a different purpose (e.g. a
  render cap), that would not be addressed by this solution. Verified: no other
  `@transcript_cap` in the repo (`grep -rn transcript_cap lib/` returns only
  `events.ex:24` and `input.ex:191`). Rebuttal does not apply.
- **Backing (B):** DRY principle; Elixir module attributes as compile-time
  constants pattern (official Elixir docs §Module attributes).

#### Falsification attempt for claim 2

- **Strategy:** Edge-case enumeration — are there other consumers of
  `@transcript_cap` besides `bounded_append`?
- **Attempt:** In `events.ex`, `@transcript_cap` is referenced only inside
  `bounded_append/2` (lines 432–433) and `bounded_append_many/2` delegates
  through `bounded_append`. In `input.ex`, referenced only inside `bounded_append/2`
  (lines 196–197). No other reference found in either file or across the repo.
  Removing the attribute from `events.ex` and `input.ex` after moving the
  function is therefore safe.
- **Outcome:** withstood
- **Action:** none

---

### Claim 3: The duplication is absent from `Events` and `Input` after the change.

- **Claim (C):** "Delete both private copies from `Events` and `Input`."
- **Grounds (G):** Current state: `events.ex:429` has `def bounded_append/2`
  (public) and `events.ex:445` has `def bounded_append_many/2`; `input.ex:193`
  has `defp bounded_append/2`. These will be removed; all call-sites in both
  modules replaced with `Model.bounded_append/2`. Call-sites are:
  `events.ex:69,253,284,296,390` and `input.ex:41,103,145,174`.
- **Warrant (W):** Removing a local definition after aliasing the canonical
  module and updating call-sites produces no duplication — the compiler will
  error on any missed call-site referencing the removed private function,
  providing complete deletion verification.
- **Qualifier (Q):** Q: holds after `mix compile --warnings-as-errors` passes
  on both files post-deletion (any surviving call to the removed `defp` would
  cause a compile error in Elixir, not a silent failure).
- **Rebuttal (R):** The public `Events.bounded_append/2` (not just the private
  copies) must also be removed. The solution's "What changes" section specifies
  removing "the now-dead private/public definitions". If only the private copy
  is removed and the public one remains, duplication of definition persists
  (though in a different form). The migration sketch step 2 covers this
  explicitly.
- **Backing (B):** Elixir compiler error on undefined local calls; OTP
  non-negotiable §2 (no dead code paths).

#### Falsification attempt for claim 3

- **Strategy:** Edge-case enumeration — missed call-sites or compiler
  non-detection.
- **Attempt:** Elixir's compiler does not error on calls to `defp` functions of
  an *aliased* module — it errors on calls to undefined *local* functions. The
  call-sites in `events.ex` call `bounded_append(...)` unqualified, which
  resolves to the local `defp`. After removing the local `defp`, an unqualified
  call would fail to compile. If all unqualified calls are replaced with
  `Model.bounded_append(...)` and the local `defp` is removed, the compiler
  confirms completeness. Migration sketch step 2 includes `mix compile
  --warnings-as-errors` after each file change, which catches unused aliases
  and dead code as warnings-as-errors. This provides complete post-deletion
  verification.
- **Outcome:** withstood (qualifier already in solution; compiler as
  verification guard confirmed adequate)
- **Action:** none

---

### Claim 4: No external callers of `Events.bounded_append/2` are silently broken.

- **Claim (C):** "Callers must be audited; however, given the function is
  specific to internal transcript mutation, external callers are expected to be
  absent."
- **Grounds (G):** `grep -rn "Events.bounded_append" lib/ test/` returns zero
  hits (verified). The function is used only by unqualified calls inside
  `events.ex` itself. The migration sketch step 5 repeats this grep as a
  one-time check.
- **Warrant (W):** A function with no external call-sites cannot have external
  callers silently broken by its removal. Zero grep hits in `lib/` and `test/`
  is definitive for a single-repo codebase.
- **Qualifier (Q):** Q: holds for the current codebase state. External packages
  or plugins that call `Events.bounded_append/2` as a published API would not
  be caught by the in-repo grep. The solution itself scopes the "no external
  callers" claim only to the repo.
- **Rebuttal (R):** If tau has downstream consumers (plugins, extensions) that
  `alias Tau.TUI.App.Events` and call `bounded_append/2`, those would be broken
  without being caught. The solution does not address this but acknowledges the
  audit requirement.
- **Backing (B):** In-repo grep coverage; `lib/tau/tui/app/events.ex` is not
  listed in any `SPEC-*.md` public API surface; `SPEC-TUI-HEADLESS.md` and
  `SPEC-USER-TURN.md` are the relevant specs and neither lists `bounded_append`
  as a boundary-contract function.

#### Falsification attempt for claim 4

- **Strategy:** Integration check — could an extension or plugin call this
  function?
- **Attempt:** The `SPEC-EXTENSIONS.md` describes extension loading via
  `Tau.Extension` behaviour and `Tau.Extensions.Loader`. Extensions interact
  through the `Tau.Extension` behaviour and PubSub, not by aliasing internal TUI
  App modules. No extension interface documents `Events.bounded_append/2` as a
  callable surface. However, the `docs/spec/SPEC-EXTENSIONS.md` cannot
  categorically rule out an extension author calling any Elixir module that
  happens to be loaded. The claim's qualifier "external callers are **expected**
  to be absent" is probabilistic, not absolute.
- **Outcome:** partially falsified — the qualifier should be narrowed: "no
  external callers **within the tau repo**; out-of-repo extension authors are
  not audited"
- **Action:** narrow qualifier in place; no solution revision needed. The
  narrowed qualifier is already implicit in the solution's phrasing ("expected
  to be absent") and the migration sketch's in-repo grep.

---

### Claim 5: The function bodies (`list ++ [item]` → `Enum.drop` semantics) are preserved exactly.

- **Claim (C):** "The function bodies … are preserved exactly."
- **Grounds (G):** Both copies are byte-identical per the problem statement and
  confirmed by reading `events.ex:429–437` and `input.ex:193–201`. The solution
  moves, not rewrites, these bodies. Migration sketch steps 4 confirms via `mix
  test` that no behavioural change occurs.
- **Warrant (W):** A copy-move operation that makes no substitutions to the
  function body preserves semantics exactly. The only change is the site of
  definition; the AST of the body is unchanged.
- **Qualifier (Q):** Q: holds when the migration is performed by textual move
  of the exact body, not a re-implementation. Verified by `mix test` (step 4).
- **Rebuttal (R):** If an implementer introduces a subtle difference (e.g.,
  `Enum.take(-@transcript_cap, new_list)` vs. `Enum.drop`) while moving, the
  body would not be "preserved exactly". The solution requires an exact move;
  `mix test` is the verification gate.
- **Backing (B):** Elixir AST equivalence is verifiable by inspection; `mix
  test` as regression gate.

#### Falsification attempt for claim 5

- **Strategy:** Counter-example construction — is there any way the moved body
  could behave differently than the original?
- **Attempt:** The body references only `@transcript_cap`, `list`, `item`,
  `length/1`, `Enum.drop/2`, and `++`. None of these are module-local except
  `@transcript_cap`, which becomes `@transcript_cap` in `model.ex` with the
  same value 500. No external state, no process calls, no references to sibling
  private functions. Counter-example would require the cap value to differ or
  the body to be mis-transcribed — both excluded by the migration's step 2
  compile-check and step 4 test run.
- **Outcome:** withstood
- **Action:** none

---

### Claim 6: `Model.t()` struct shape and field names are unchanged.

- **Claim (C):** "`Model.t()` struct shape and field names — no field is added,
  renamed, or typed differently."
- **Grounds (G):** The solution adds only module-level functions and a module
  attribute to `model.ex`; it does not modify `@enforce_keys`, `defstruct`, or
  the `@type t` definition. Confirmed: `model.ex:14–93` defines the struct and
  type; the proposed changes (adding functions and `@transcript_cap`) are
  appended after the struct block per Elixir convention.
- **Warrant (W):** Adding functions and module attributes to an Elixir module
  does not alter the module's struct definition. Struct fields are declared
  only in `defstruct`; `@type t` is a documentation type. Adding neither
  changes the struct.
- **Qualifier (Q):** Q: none — universal for this specific change type (adding
  functions to an Elixir module cannot modify its defstruct).
- **Rebuttal (R):** Rebuttal: none. Elixir's compilation model makes this
  categorically true — `defstruct` and function definitions are orthogonal
  constructs. No change to `defstruct` is possible without explicitly editing it.
- **Backing (B):** Elixir language specification §defstruct; `mix compile
  --warnings-as-errors` as structural regression gate.

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — can adding a function to a
  module alter struct shape?
- **Attempt:** In Elixir, `defstruct` is evaluated once at compile time based
  on the argument list passed to `defstruct`. Function definitions (`def`,
  `defp`) do not interact with `defstruct` — they compile to distinct entries
  in the module's BEAM chunk. Adding `def bounded_append/2` cannot add, rename,
  or retype a struct field. No counter-example is constructable.
- **Outcome:** withstood
- **Action:** none

---

## Cross-claim consistency

Claims 1–3 form a coherent whole: move the function (C1), move the constant
(C2), remove duplicates (C3). No tension among them. C4 (external caller audit)
is independent and does not conflict with C1–C3. C5 (body preservation) is
entailed by C1–C3 if migration is a move not a rewrite; no tension. C6 (struct
stability) is orthogonal to all others; no tension.

One potential tension: C1 makes `bounded_append` **public** in `Model` (the
solution says "public functions"), whereas both current copies are `defp`. A
critic could argue that making it public introduces a new external API surface.
However, `bounded_append` is a pure function whose inputs and outputs are
entirely determined by the `Model.t()` transcript type — it is appropriate for
`Model` to expose it publicly for any future sub-modules in the `Tau.TUI.App.*`
namespace. This is not a tension requiring revision; it is a deliberate scope
choice recorded in the solution.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Single canonical impl in Model | Dependency check (compilation guard) | withstood | none |
| 2 | Single @transcript_cap in Model | Edge-case enumeration (other users of constant) | withstood | none |
| 3 | Duplication absent from Events/Input | Edge-case enumeration (missed call-sites) | withstood | none |
| 4 | No external callers broken | Integration check (extension authors) | partially falsified | narrow qualifier to in-repo only |
| 5 | Function bodies preserved exactly | Counter-example construction | withstood | none |
| 6 | Model.t() struct shape unchanged | Counter-example construction | withstood | none |

---

## Revision required

No revision triggered. Claim 4 is partially falsified but the narrowed qualifier
("no in-repo external callers") is already implicit in the solution's own
language ("expected to be absent" + in-repo grep in migration step 5). The
solution text does not overclaim; no solution.md edit is required.

---

## Outstanding doubts

- The `Code.ensure_loaded?(Ratatouille.Runtime)` compilation guard wrapping
  `model.ex` is acknowledged as an open question in the solution. If CI runs
  `mix test` without Ratatouille in scope (e.g. stripped-deps mode), the module
  and its functions including `bounded_append` are undefined, meaning any test
  exercising the transcript path would fail to compile. The solution flags this
  as an open question but does not resolve it. Confidence: the compilation guard
  applies equally to `events.ex` and `input.ex`, so this risk pre-exists the
  change and is not introduced by it — but it is worth confirming.
- `transcript_pane_width/1` in `model.ex` is `defp`, not `def`. The solution
  cites it as "existing precedent" for non-pure-struct helpers in `Model`. It is
  a valid precedent, but the fact that `transcript_pane_width` is private while
  `bounded_append` would be public is a minor asymmetry. No action required;
  noted for the parent-level validator.
