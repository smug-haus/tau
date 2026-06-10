---
template_version: 1
template_name: solution
parent_problem: ../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-2.md]
selection_method: hybrid
revision: 0
---

# Solution: Mechanical callsite replacement + `Model.context_window/1` accessor for the one non-trivial default

## Recommendation

Replace every `Map.get(model, :field, default)` and `Map.put(model, :field, val)` call across `Events`, `Input`, `Keymap`, `View`, and `Permission` with direct struct field access (`model.field`) and struct update syntax (`%{model | field: val}`). Update all `@spec` annotations that use `map()` as input or output to `Model.t()`. For the single field whose fallback is non-trivial — `context_window`, whose nil-fallback consults `Application.get_env/3` — add one typed accessor `Model.context_window/1` that owns that logic, replacing the duplicated nil-coalescion in `events.ex` and `view.ex`. All other `Map.get/3` calls whose defaults re-state values already present in `Model.new/1` become plain `model.field` accesses with no accessor indirection.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-1.md` (mechanical callsite replacement) and `proposals/proposal-2.md` (typed accessor for non-trivial defaults)
- **Why chosen:** Proposal 1 satisfies the acceptance criterion directly and completely at lowest cost and risk, and its uniform substitution is both reviewable and reversible. Its one identified weakness is the `context_window` nil-fallback: stripping the `Map.get` default from that site leaves the nil-coalescion logic duplicated across `events.ex` and `view.ex` in a way that cannot be typed away by struct access alone. Proposal 2's general `Model.update/2` function adds indirection without benefit for fields that are always populated by `@enforce_keys`; but its specific insight — that the `context_window` fallback should be owned by `Model` — is correct and narrow. The hybrid takes the full mechanical replacement of Proposal 1 and adds only the single accessor Proposal 2 motivates, avoiding Proposal 2's broader API surface. Proposal 3 is out-of-scope overreach: the problem statement explicitly excludes changing the field set, and introducing sub-structs is an API-breaking change with cascading unknowns (menu shape, StatusBar type updates, Cost.for_session return type). Proposal 4 defers satisfaction of the acceptance criterion; adding enforcement without fixing existing violations is the wrong sequencing when the violations are fully inventoried and mechanical to fix.

## What changes

- `lib/tau/tui/app/model.ex` — add `@spec context_window(t()) :: pos_integer()` + two-clause function that returns the field value when set, or the `Application.get_env(:tau, :compaction_threshold_tokens, 120_000)` fallback when nil.
- `lib/tau/tui/app/events.ex` — change `@spec update/2` and `@spec update_session_event/2` from `map()` to `Model.t()`; add `alias Tau.TUI.App.Model`; replace all `Map.get(model, ...)` and `Map.put(model, ...)` calls with struct field access and `%{model | ...}` update syntax; replace `Map.get(model, :context_window) || Application.get_env(...)` with `Model.context_window(model)`.
- `lib/tau/tui/app/view.ex` — change `@spec status_bar_model/1` from `map()` to `Model.t()`; replace all `Map.get(model, :field, default)` calls in `status_bar_model/1` with `model.field`; replace `Map.get(model, :context_window)` with `Model.context_window(model)`.
- `lib/tau/tui/app/keymap.ex` — change affected `@spec` lines to `Model.t()`; replace `Map.get(model, :pending_permissions, [])` with `model.pending_permissions`.
- `lib/tau/tui/app/permission.ex` — change affected `@spec` lines to `Model.t()`; replace `Map.get(model, :pending_permissions, [])` with `model.pending_permissions`; replace `Map.put(model, :pending_permissions, ...)` with `%{model | pending_permissions: ...}`.
- `lib/tau/tui/app/input.ex` (if any `Map.get/put` on model exists) — same treatment: struct access and `Model.t()` specs.
- `lib/tau/tui/app/completion.ex` and `lib/tau/tui/app/history.ex` — audit for `Map.get/put` on `Model.t()` values; apply the same mechanical replacement if found (acceptance criterion names these modules explicitly).

## What does not change

- The `Model.t()` struct's field set and `@enforce_keys` list — out of scope per problem.md.
- The `Model.new/1` constructor — no field additions or removals.
- Sub-field shapes (`usage`, `search`, `menu`) — they remain as typed in the current struct; no sub-struct extraction.
- `Tau.Cost.for_session/1` return type — no changes to modules outside `lib/tau/tui/app/`.
- `StatusBar` module — not touched; `status_bar_model/1` continues to return a plain `map()` as its output type.
- Sibling sub-problems (`duplicated-bounded-append`, `session-side-effects-in-pure-modules`, `transcript-coupling`) — no changes.
- The `Model.update/2` multi-field updater from Proposal 2 — not introduced; `%{model | ...}` syntax is sufficient and unambiguous at every callsite where the keyword list is a literal.

## Migration sketch

One PR, one file at a time in dependency order: (1) add `Model.context_window/1` to `model.ex` and verify `mix dialyzer` is clean; (2) update `events.ex` (the largest callsite set) and run `mix test` — this is the highest-risk step because `status_bar_model` defaults currently paper over missing fields in test fixtures; (3) update `view.ex`; (4) update `keymap.ex`, `permission.ex`, `input.ex`; (5) audit and update `completion.ex` and `history.ex`. Each file step can be a separate commit on the same branch so bisection is clean if a test surfaces a hidden fixture gap.

## Open questions

- Are there `Map.get/put` calls on `model` inside `completion.ex` or `history.ex` that are not inventoried in the problem statement? The acceptance criterion names them but the problem statement's context section does not enumerate their callsites. A grep pass is required before implementation.
- Do any test fixtures construct a partial `Model.t()` that relies on the defaulting behaviour of `Map.get` (e.g., setting `usage: nil` and relying on `Map.get(model, :usage, %{input_tokens: 0, ...})`)? Removing those defaults will surface a crash rather than a zero value. The implementation must verify `mix test` passes after each file's callsites are converted.
- Does Dialyzer propagate `Model.t()` correctly through `Model.context_window/1`'s two-clause pattern match, or does it widen the return type? Confirm with `mix dialyzer` after adding the function.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Mechanical callsite replacement; primary source for the bulk of the change.
- `proposals/proposal-2.md` — Typed accessor/updater façade; source for the `Model.context_window/1` accessor only.
- `proposals/proposal-3.md` — Sub-struct extraction; rejected (API-breaking, out-of-scope, cascading unknowns).
- `proposals/proposal-4.md` — Enforcement-first via custom Credo check; rejected (defers acceptance-criterion satisfaction; wrong sequencing when callsites are fully inventoried).

## Revision history

- (revision 0 — initial)
