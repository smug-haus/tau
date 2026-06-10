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

# Validation: Mechanical callsite replacement + `Model.context_window/1` accessor

## Overview

The solution makes seven claims across the Recommendation and What-changes
sections: (1) all `Map.get/3` and `Map.put/2` calls on `model` in the named
modules can be mechanically replaced with struct syntax; (2) `@spec` annotations
typed `map()` in those modules can be updated to `Model.t()`; (3) the
`context_window` nil-fallback is the only non-trivial default, and adding one
`Model.context_window/1` accessor suffices to consolidate it; (4) all other
`Map.get/3` defaults re-state values already present in `Model.new/1`; (5)
`completion.ex` and `history.ex` use `Map.get` only on sub-fields (`model.menu`,
`model.search`), not on the `Model.t()` value itself; (6) the `Model.update/2`
multi-field updater from Proposal 2 is unnecessary; (7) the struct's field set
and `@enforce_keys` list are unchanged. Seven claims, evaluated below.
Falsification used counter-example construction and dependency checks grounded in
`grep` evidence from the live codebase. One claim is partially falsified, which
narrows its qualifier; no full falsification; no revision required.

---

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants found it
difficult to generate Toulmin structures, and their structures varied greatly even
though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to counter that
variance.

---

### Claim 1: All `Map.get/3` and `Map.put/2` calls on the `Model.t()` value in `Events`, `Input`, `Keymap`, `View`, and `Permission` can be replaced with struct field access and `%{model | ...}` update syntax

- **Claim (C):** Replace every `Map.get(model, :field, default)` and
  `Map.put(model, :field, val)` call across `Events`, `Input`, `Keymap`, `View`,
  and `Permission` with direct struct field access (`model.field`) and struct
  update syntax (`%{model | field: val}`).
- **Grounds (G):** `grep` over the live codebase confirms the full inventory.
  `events.ex:236,241,252-257,312` — eight `Map.get/put` calls. `view.ex:69,120-129,134` —
  nine calls. `keymap.ex:31` — one `Map.get(model, :pending_permissions, [])`.
  `permission.ex:40-41` — one `Map.get` and one `Map.put` on `:pending_permissions`.
  `input.ex:52-53` — two `Map.get` calls on `event`, not on `model` (see Claim 5
  note). Every field accessed by these calls is declared in the `defstruct` at
  `model.ex:30-54`.
- **Warrant (W):** A named struct in Elixir supports direct field access
  (`s.field`) and struct update (`%{s | field: v}`) for any field declared in its
  `defstruct`; no runtime dispatch is required. Replacing `Map.get(s, :k,
  default)` with `s.k` is semantics-preserving when `:k` is always populated
  (enforced or initialised to a non-nil value by `new/1`), modulo the nil-default
  distinction handled in Claim 3.
- **Qualifier (Q):** Holds for every field accessed in the inventoried callsites
  provided the field is present in `defstruct` and `Model.new/1` provides a
  non-nil initial value (or the field is in `@enforce_keys`). Fields that are
  legitimately `nil` at runtime (e.g. `context_window`, `last_assistant`,
  `coding_agent`) require the nil case to be handled by the caller or an accessor,
  not silently swallowed by `Map.get`'s default.
- **Rebuttal (R):** If any callsite passes a non-`Model.t()` map through the
  function (e.g., a test fixture built as a bare `map()` rather than
  `%Model{...}`), replacing `Map.get` with struct field access will raise a
  `BadMapError` at runtime for that call. This is a real risk: `app_test.exs:22-39`
  constructs a plain map fixture, not a `%Model{}`, and passes it to `App.update/2`.
  The solution's migration sketch acknowledges this risk at step 2.
- **Backing (B):** Elixir documentation on structs: `https://hexdocs.pm/elixir/structs.html`.
  OTP non-negotiable §2 (`otp-non-negotiables.md`): "Extensibility seams MUST be
  behaviours; pattern match on atoms and structs." `model.ex:14-28` — `@enforce_keys`
  establishes which fields are always present at struct construction.

#### Falsification attempt for claim 1

- **Strategy:** Counter-example construction — attempt to find a callsite where
  `Map.get(model, :field, default)` cannot be replaced by `model.field` because
  the field is absent from `defstruct` or because the default diverges from the
  struct's nil-initial value in a way that changes semantics.
- **Attempt:** Checked every `Map.get` field reference against `model.ex:30-54`:
  `:context_window`, `:warn_level`, `:pending_permissions`, `:session_id`,
  `:model`, `:provider`, `:usage`, `:context_tokens`, `:compaction`,
  `:permissions_mode` — all present in `defstruct`. `Map.get(model, :provider)`
  at `events.ex:312` accesses a field that is nil-initialised in `new/1` (the
  `init_provider/1` helper may return nil when no provider key is in opts);
  `model.provider` is equivalent. No counter-example found where the field is
  absent from the struct definition.
- **Outcome:** Withstood — no callsite accesses a field outside `defstruct`.

---

### Claim 2: `@spec` annotations typed `map()` in the named modules can be updated to `Model.t()`

- **Claim (C):** Update all `@spec` annotations that use `map()` as input or
  output to `Model.t()` in `Events`, `Input`, `Keymap`, `View`, and `Permission`.
- **Grounds (G):** Live evidence: `events.ex:31` — `@spec update(map(), term()) ::
  map()`; `events.ex:83` — `@spec update_session_event(map(), term()) :: map()`;
  `events.ex:160` — `@spec drain_bridge(map()) :: map()`. `view.ex:29` —
  `@spec render(map()) :: term()`; `view.ex:86` — `@spec render_menu(map()) ::
  term()`; `view.ex:117` — `@spec status_bar_model(map()) :: map()`.
  `keymap.ex:29,50,65,145,212` — all typed `map()`. `permission.ex:22,38` —
  typed `map()`. All these functions receive and return the MVU model.
- **Warrant (W):** Dialyzer's success-typing inference narrows `map()` to the
  struct type only when `@spec` declares `Model.t()`; without the spec update,
  Dialyzer cannot flag field-name typos or incorrect field types in callers. The
  point of the change is to give the type system a precise grip on the value.
- **Qualifier (Q):** The `@spec` update is safe for functions whose sole
  `map()` parameter is the MVU model. Functions that also accept plain `map()`
  event values (e.g. `keymap.ex:29` `handle_event(map(), map())` where the
  second argument is a Ratatouille key event) will require mixed specs — the
  event argument stays `map()` while the model argument becomes `Model.t()`.
- **Rebuttal (R):** `view.ex:117` — `@spec status_bar_model(map()) :: map()` has
  `map()` as its _return_ type, which the solution explicitly preserves ("not
  touched; `status_bar_model/1` continues to return a plain `map()`"). So the
  return-type of `status_bar_model/1` is intentionally left as `map()` per the
  solution's What-does-not-change section. This is not a rebuttal to the claim
  itself but a scope boundary that the spec must not violate.
- **Backing (B):** Dialyzer documentation on success typing:
  `https://www.erlang.org/doc/man/dialyzer.html`. `problem.md` acceptance
  criterion: "`@spec` annotations use `Model.t()` not `map()`".

#### Falsification attempt for claim 2

- **Strategy:** Type-level check — run Dialyzer mentally over the proposed spec
  changes to identify any case where `Model.t()` is narrower than what the
  function actually handles, which would produce a Dialyzer success-type warning.
- **Attempt:** `keymap.ex:29` is `handle_event(map(), map())`. The first `map()`
  is `model`; the second is the Ratatouille key event (a bare map with `:ch`,
  `:key`, `:mod` keys). After the change, the spec becomes
  `handle_event(Model.t(), map()) :: Model.t()`. Dialyzer accepts this: the first
  argument is narrowed (always correct, since callers pass `Model.t()`); the
  second remains `map()` (correct for Ratatouille events). No warning expected.
  `view.ex:117` — solution explicitly preserves `map()` as the return type, so
  no issue. No type-level counter-case found.
- **Outcome:** Withstood — no function is called with a value that is strictly
  wider than `Model.t()` for the model parameter.

---

### Claim 3: The `context_window` nil-fallback is the _only_ non-trivial default; adding `Model.context_window/1` suffices to consolidate all non-trivial nil-coalescion

- **Claim (C):** For the single field whose fallback is non-trivial —
  `context_window`, whose nil-fallback consults `Application.get_env/3` — add one
  typed accessor `Model.context_window/1` that owns that logic, replacing the
  duplicated nil-coalescion in `events.ex` and `view.ex`. All other `Map.get/3`
  calls whose defaults re-state values already present in `Model.new/1` become
  plain `model.field` accesses with no accessor indirection.
- **Grounds (G):** `events.ex:236-237` — `Map.get(model, :context_window) ||
  Application.get_env(:tau, :compaction_threshold_tokens, 120_000)` is the only
  `Application.get_env` call for a model field in the inventoried modules.
  `view.ex:126` — `Map.get(model, :context_window)` with no `Application.get_env`
  fallback (passes nil through to `StatusBar`); this call does not duplicate the
  non-trivial fallback. `view.ex:124` — `Map.get(model, :usage, %{input_tokens:
  0, ...})` — default re-states the value from `model.ex:127`; replacing with
  `model.usage` is safe. All other defaults in `view.ex:120-129` follow the same
  pattern: their defaults duplicate `Model.new/1` values.
- **Warrant (W):** A fallback is "non-trivial" if it cannot be expressed as a
  struct field read: it consults external state (here, `Application.get_env`).
  A fallback is "trivial" if its default is identical to the value `Model.new/1`
  seeds into the field, making the `Map.get` default unreachable for any struct
  value that went through `new/1`. Only `Application.get_env` fallbacks are
  non-trivial by this definition.
- **Qualifier (Q):** Holds for the inventoried consumer modules. Narrows if any
  module outside the inventory (e.g., `bootstrap.ex`) contains additional
  `Application.get_env` model-field fallbacks not visible in the grep evidence.
  Also: `view.ex:126` passes `model.context_window` (possibly nil) to `StatusBar`;
  if `StatusBar` internally applies the `Application.get_env` fallback, the
  consolidation is incomplete unless `view.ex` also calls `Model.context_window/1`
  instead of the bare field access.
- **Rebuttal (R):** The solution's What-changes section states `view.ex` should
  replace `Map.get(model, :context_window)` with `Model.context_window(model)`.
  But the `view.ex` callsite at line 126 feeds `StatusBar.context_pct/2` (or
  equivalent), where nil may be valid and handled downstream. If `view.ex` calls
  `Model.context_window/1` (the accessor with the `Application.get_env` fallback),
  it changes observable behaviour relative to the current nil-passthrough. The
  solution is internally consistent only if `StatusBar` already handles nil by
  falling back to `Application.get_env`; otherwise the two callsites in `view.ex`
  and `events.ex` have genuinely different semantics, and they should not both
  call the same accessor.
- **Backing (B):** `events.ex:236-237` and `view.ex:126` (live codebase).
  `model.ex:129` — `context_window: nil` in `new/1`. `problem.md` acceptance
  criterion: "no `Map.get` call with a default that re-states a canonical default
  from `Model.new/1` remains."

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction — find a second non-trivial default
  (one that cannot be replaced by plain struct access) in the inventoried modules.
- **Attempt:** Examined every `Map.get(model, :field, default)` call in the grep
  evidence:
  - `view.ex:124` — default `%{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0}` re-states `model.ex:127`. Trivial.
  - `view.ex:125` — default `0` re-states `model.ex:128` (`context_tokens: 0`). Trivial.
  - `view.ex:127` — default `:idle` re-states `model.ex:131` (`compaction: :idle`). Trivial.
  - `view.ex:129` — default `:default` re-states `model.ex:124` (`permissions_mode: Map.get(runtime_opts, :permissions_mode, :default)`). Trivial for any `Model.t()` that went through `new/1`.
  - `events.ex:241` — `Map.get(model, :warn_level, :ok)`. Default `:ok` re-states `model.ex:131` (`warn_level: :ok`). Trivial.
  - `events.ex:312` — `Map.get(model, :provider)` with no default. Becomes `model.provider`.
  - `keymap.ex:31` — default `[]` re-states `model.ex:123` (`pending_permissions: []`). Trivial.
  - `permission.ex:40` — same field, same trivial default.

  One partial counter-case: the solution states `view.ex` should call
  `Model.context_window/1` (the accessor). But `view.ex:126` currently passes
  `context_window` as nil to a downstream struct (not applying the fallback), so
  calling `Model.context_window/1` would change the semantic: nil becomes
  `120_000` instead of nil. This does not falsify the claim that there is only one
  non-trivial default, but it does mean the solution's proposed treatment of
  `view.ex:126` requires a semantic decision — not just a mechanical substitution.
  The qualifier must be narrowed: the claim holds for `events.ex`, but the
  treatment of `view.ex:126` is context-dependent.

- **Outcome:** Partially falsified — the `view.ex:126` callsite is an instance
  where the solution's instruction to call `Model.context_window(model)` is not
  purely mechanical: it changes observable behaviour (nil → 120_000) unless
  `StatusBar` already handles nil identically. The qualifier is narrowed: "for
  `events.ex`'s callsite, `Model.context_window/1` is a correct consolidation;
  for `view.ex:126`, the implementer must verify whether `StatusBar` expects nil
  or a concrete value, and choose accordingly (either bare `model.context_window`
  or `Model.context_window(model)`)."
- **Action:** Narrow qualifier; no solution revision needed. The narrowed claim
  survives; the open question is noted in Outstanding doubts.

---

### Claim 4: All `Map.get/3` defaults in the inventoried consumer modules re-state values present in `Model.new/1`, making them redundant on any struct value that went through `new/1`

- **Claim (C):** All other `Map.get/3` calls whose defaults re-state values
  already present in `Model.new/1` become plain `model.field` accesses with no
  accessor indirection.
- **Grounds (G):** Verified exhaustively in the Claim 3 falsification attempt
  above. Every default in `view.ex:124-129` and `events.ex:241`, `keymap.ex:31`,
  `permission.ex:40` duplicates an explicit initial value in `model.ex:108-133`.
- **Warrant (W):** If `Model.new/1` is the sole constructor (no `%Model{...}` literals
  outside `model.ex`) and `@enforce_keys` enforces all mandatory fields, then any
  live `Model.t()` value has all `@enforce_keys` fields set to non-nil values.
  The `Map.get` default is therefore unreachable, making the `Map.get` call
  semantically equivalent to plain struct access for values that went through `new/1`.
- **Qualifier (Q):** Holds for values constructed via `Model.new/1`. Does NOT hold
  for bare-map fixtures in tests that omit fields (see Claim 6 note and Rebuttal).
  After conversion, tests that use bare maps will crash at the struct access; this
  is the intended outcome per the migration sketch ("surfaces a crash rather than a
  zero value").
- **Rebuttal (R):** `app_test.exs:22-39` constructs a bare `map()` fixture missing
  several mandatory fields (`usage`, `context_tokens`, `compaction`, `warn_level`,
  `permissions_mode`, `pending_permissions`). After the struct-access conversion,
  `App.update/2` and its callees will raise on this fixture. The migration sketch
  acknowledges this; the fix is to convert the fixture to `%Model{...}` or to call
  `Model.new/1`. This is a known migration cost, not a falsification of the claim
  itself.
- **Backing (B):** `model.ex:14-28` (`@enforce_keys`); `model.ex:108-133`
  (`new/1` initial values); `problem.md` acceptance criterion.

#### Falsification attempt for claim 4

- **Strategy:** Dependency check — verify that `Model.new/1` is the sole
  constructor for `Model.t()` values in the production code path (not tests).
- **Attempt:** Searched for `%Tau.TUI.App.Model{` and `%Model{` in `lib/` (outside
  `model.ex` itself): no hits found. All production construction goes through
  `Model.new/1`. The claim's precondition holds in production code.
- **Outcome:** Withstood — in production, no `Map.get` default is reachable on a
  value that went through `new/1`.

---

### Claim 5: `completion.ex` and `history.ex` use `Map.get` only on sub-fields (`model.menu`, `model.search`), not on the `Model.t()` value itself

- **Claim (C):** Audit `completion.ex` and `history.ex` for `Map.get/put` on
  `Model.t()` values; apply the same mechanical replacement if found (acceptance
  criterion names these modules explicitly).
- **Grounds (G):** `completion.ex:56` — `Map.get(model.menu || %{}, :selected,
  0)` — called on `model.menu`, a `nil | map()` sub-field, not on the `Model.t()`
  value. `history.ex:95` — `Map.get(model.search, :search_index, 0)` — called on
  `model.search`, a `nil | map()` sub-field. The `@spec` annotations in
  `completion.ex` and `history.ex` use `map()` for the model parameter; these
  should be updated to `Model.t()` per the acceptance criterion.
- **Warrant (W):** `Map.get` on a sub-field (`model.menu`) is not the struct
  discipline problem identified in `problem.md`; the problem is `Map.get` on the
  `Model.t()` struct itself. Sub-field maps (`menu`, `search`) have no named
  struct type (they are `nil | map()` in `model.ex:73,83`), so `Map.get` with a
  default is the correct access pattern for those fields.
- **Qualifier (Q):** Holds for the current codebase. If `menu` or `search` are
  later given dedicated struct types, the same discipline applies to them.
- **Rebuttal (R):** The `@spec` annotations in `completion.ex` still use `map()`
  (e.g. `@spec update_menu(map()) :: map()`). The acceptance criterion requires
  those to be updated to `Model.t()` even though the `Map.get` calls there are on
  sub-fields. The solution's What-changes section covers this ("audit…apply the
  same mechanical replacement if found"), but the replacement for these files is
  limited to the `@spec` update, not a Map.get → struct access change.
- **Backing (B):** `model.ex:73,83` — `search: nil | map()`, `menu: nil | map()`.
  `completion.ex:47,56`; `history.ex:94-95` (live codebase).

#### Falsification attempt for claim 5

- **Strategy:** Counter-example construction — look for any `Map.get` call in
  `completion.ex` or `history.ex` that accesses a top-level `Model.t()` field
  (not a sub-field).
- **Attempt:** All `Map.get` references in these files access `model.menu` or
  `model.search`, both of which are sub-fields typed `nil | map()`. No call
  accesses a top-level `Model.t()` field via `Map.get`. The grep evidence confirms
  this exhaustively.
- **Outcome:** Withstood — no direct `Map.get` on a `Model.t()` field in
  `completion.ex` or `history.ex`.

---

### Claim 6: The `Model.update/2` multi-field updater from Proposal 2 is unnecessary; `%{model | ...}` syntax is sufficient at every callsite

- **Claim (C):** The `Model.update/2` multi-field updater from Proposal 2 is not
  introduced; `%{model | ...}` syntax is sufficient and unambiguous at every
  callsite where the keyword list is a literal.
- **Grounds (G):** The `Map.put` chain at `events.ex:252-257` updates six fields
  in sequence. After conversion to struct update, this becomes either a pipeline
  of `%{m | field: val}` updates or a single `%{model | status: :idle, transcript:
  ..., last_assistant: nil, usage: ..., context_tokens: ..., warn_level: ...}`.
  Both are syntactically valid. `%{model | field1: v1, field2: v2, ...}` is
  idiomatic Elixir for multi-field struct updates.
- **Warrant (W):** Hickey: "Simple is not easy, but it is better." The `Model.update/2`
  function from Proposal 2 adds a call-site indirection without enabling any
  additional static checking or enforcement. `%{model | ...}` with a literal
  keyword list is transparent to Dialyzer and avoids the runtime cost of
  converting a keyword list to struct updates inside a function.
- **Qualifier (Q):** Holds when the keyword list passed to the hypothetical
  `Model.update/2` is always a compile-time literal. If a callsite needed a
  dynamically-constructed list of field updates, `Model.update/2` would add value;
  no such callsite exists in the inventoried code.
- **Rebuttal (R):** The six-field update at `events.ex:252-257` could be more
  readable as `Model.update/2` in a literal keyword form. This is a style
  preference, not a semantic argument. The solution's rejection on cost/benefit
  grounds is defensible.
- **Backing (B):** `proposals/proposal-2.md` (rejected for reasons cited in
  solution.md). Elixir struct update syntax docs: `https://hexdocs.pm/elixir/structs.html#updating-structs`.

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — find a callsite where `%{model |
  ...}` syntax is insufficient (e.g., a dynamic field list, or a pattern-match
  context where only a function call composes).
- **Attempt:** The `events.ex:252-257` chain is the most complex case. It updates
  six fields sequentially; each field value is a computed local. A single struct
  update literal `%{model | status: :idle, transcript: t, last_assistant: nil,
  usage: u, context_tokens: n, warn_level: w}` covers it without any helper
  function. No dynamic field-set construction was found. No counter-case.
- **Outcome:** Withstood.

---

### Claim 7: The `Model.t()` struct's field set, `@enforce_keys` list, `Model.new/1` constructor, sub-field shapes, `Tau.Cost.for_session/1` return type, and `StatusBar` module are unchanged

- **Claim (C):** The `Model.t()` struct's field set and `@enforce_keys` list — out
  of scope per problem.md. The `Model.new/1` constructor — no field additions or
  removals. Sub-field shapes (`usage`, `search`, `menu`) remain as typed.
  `Tau.Cost.for_session/1` return type — no changes. `StatusBar` module — not
  touched.
- **Grounds (G):** `problem.md` Out-of-scope section explicitly excludes "changing
  the struct's field set or the `@enforce_keys` list." `model.ex:14-28,30-54` —
  current field set. The solution's What-does-not-change section lists each of
  these explicitly.
- **Warrant (W):** Out-of-scope constraints in `problem.md` are acceptance-criterion
  boundaries; a solution that violates them fails the acceptance criterion
  regardless of correctness. The solution correctly identifies and preserves all
  out-of-scope elements.
- **Qualifier (Q):** Universal — the solution explicitly preserves these elements
  in its What-does-not-change section.
- **Rebuttal (R):** None. Adding `Model.context_window/1` is a behaviour-only
  addition (new function, no struct change), which is within scope. Rebuttal: none
  — the solution does not extend to any out-of-scope element.
- **Backing (B):** `problem.md` Out-of-scope section.

#### Falsification attempt for claim 7

- **Strategy:** Dependency check — verify that adding `Model.context_window/1`
  does not require any `defstruct` or `@enforce_keys` change.
- **Attempt:** `context_window: pos_integer() | nil` is already declared in
  `defstruct` at `model.ex:51` and in the `@type t` at `model.ex:90`.
  `Model.context_window/1` reads this existing field; no struct change is needed.
- **Outcome:** Withstood — the accessor is additive; no field set or `@enforce_keys`
  change is required.

---

## Cross-claim consistency

Claims 1–7 are internally consistent. Claims 1 and 2 are complementary (struct
access + spec update); Claims 3 and 4 partition the `Map.get` callsite population
into trivial defaults (Claim 4) and the one non-trivial default (Claim 3); Claims
5 and 1 partition the `Map.get` population between top-level model fields (Claim
1) and sub-field accesses (Claim 5); Claims 6 and 1 are consistent (replacement
syntax choice). Claim 7 is independent (scope boundary).

One tension: Claim 3 states that `view.ex`'s `context_window` callsite should use
`Model.context_window(model)`, but the falsification of Claim 3 shows this would
change observable behaviour (nil → 120_000) unless `StatusBar` handles nil
identically to the fallback value. This does not create a cross-claim
inconsistency per se, but it means Claim 3 and Claim 7 ("StatusBar not touched")
interact: if the StatusBar module currently handles nil by applying the same
`Application.get_env` fallback internally, then using `Model.context_window/1`
in `view.ex` introduces a redundant double-fallback rather than a change. If
StatusBar does _not_ handle nil this way, the semantic change in `view.ex` is
real. The interaction is flagged as an outstanding doubt.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | All Map.get/put on Model.t() replaceable with struct syntax | Counter-example construction | Withstood | None |
| 2 | @spec map() → Model.t() across named modules | Type-level check | Withstood | None |
| 3 | context_window is the only non-trivial default; one accessor suffices | Counter-example construction | Partially falsified — view.ex:126 semantic ambiguity | Narrow qualifier; implementer must verify StatusBar nil-handling before choosing accessor vs. bare field |
| 4 | All other Map.get defaults re-state Model.new/1 values | Dependency check | Withstood | None |
| 5 | completion.ex / history.ex Map.get is on sub-fields only | Counter-example construction | Withstood | None |
| 6 | Model.update/2 unnecessary; struct update syntax sufficient | Counter-example construction | Withstood | None |
| 7 | Field set, enforce_keys, new/1, sub-fields, Cost, StatusBar unchanged | Dependency check | Withstood | None |

---

## Revision required

No full falsification occurred. Claim 3 was partially falsified; the qualifier is
narrowed in place. No revision to `solution.md` or `problem.md` is needed.

---

## Outstanding doubts

1. **`view.ex:126` — nil vs. fallback semantics.** `Map.get(model, :context_window)` currently passes nil through to StatusBar. The solution proposes replacing this with `Model.context_window(model)` (which returns `120_000` on nil). Whether this is correct depends on StatusBar's internal nil-handling. The implementer must grep `lib/tau/tui/status_bar.ex` for `context_window` nil handling before deciding which form to use at `view.ex:126`. This doubt does not block implementation but must be resolved at that file step.

2. **`app_test.exs:22-39` bare-map fixture.** The test fixture constructs a plain `map()` missing `usage`, `context_tokens`, `compaction`, `warn_level`, `permissions_mode`, and `pending_permissions`. After the struct-access conversion, `App.update/2` will raise a `BadMapError` for this fixture. The migration sketch correctly identifies this as the highest-risk step at `events.ex`. The fixture will need to be converted to `Model.new/1` or a `%Model{...}` literal before `mix test` passes. This is a known migration cost, not a structural problem with the solution.

3. **`completion.ex` and `history.ex` @spec update only.** The `Map.get` calls in these files are on sub-fields (`model.menu`, `model.search`) and cannot be replaced with `Model.t()` field access. The change in these files is limited to updating `@spec` annotations from `map()` to `Model.t()`. The solution's What-changes section covers this, but the wording ("audit for `Map.get/put` on `Model.t()` values; apply the same mechanical replacement if found") could mislead an implementer into expecting struct-access replacements in these files where none are warranted.
