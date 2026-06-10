---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: `Model.t()` struct discipline is undermined by pervasive `Map.get/3` and `Map.put/2` across consumer modules

## Statement

`Tau.TUI.App.Model` defines a typed struct with `@enforce_keys` to ensure
mandatory fields are always present, but consumer modules bypass struct field
access with `Map.get(model, :field, default)` and `Map.put(model, :field, val)`
throughout `Events`, `Input`, `Keymap`, and `View`. This means the compiler
cannot enforce field existence at call sites, `@enforce_keys` provides no
protection once the struct value leaves `Model.new/1`, and the default fallback
values embedded in `Map.get` calls can silently diverge from the canonical
defaults in `Model.new/1`.

## Context

- `lib/tau/tui/app/model.ex:14–28` — `@enforce_keys` lists 13 mandatory fields
- `lib/tau/tui/app/view.ex:118–138` — `status_bar_model/1` uses `Map.get(model, :field, default)` for every field it projects
- `lib/tau/tui/app/events.ex:234–258` — `on_message_end/2` uses `Map.get(model, :context_window)`, `Map.get(model, :warn_level, :ok)`
- `lib/tau/tui/app/events.ex:84` — `update_session_event/2` spec typed as `map()` not `Model.t()`
- `lib/tau/tui/app/keymap.ex:31` — `Map.get(model, :pending_permissions, [])` — field is in `@enforce_keys`
- `lib/tau/tui/app/permission.ex:40` — `Map.get(model, :pending_permissions, [])` — same enforced field
- `lib/tau/tui/app/events.ex:32` — `update/2` spec typed as `map()` not `Model.t()`
- The `@spec` signatures across all sub-modules use `map()` as both input and
  output type, not `Model.t()`, so Dialyzer cannot catch field-name typos.

## Complecting hypothesis

The MVU model struct is complected with generic-map access patterns because
the decomposition preserved the original anonymous-map access style of the
pre-decomposition `app.ex`, even though the struct was introduced as `Model.t()`
at the same time. The struct's value discipline (enforced keys, typed fields) is
present at construction but absent at all mutation sites.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

All consumer modules (`Events`, `Input`, `Keymap`, `View`, `Permission`,
`Completion`, `History`) access `Model.t()` fields via struct syntax
(`model.field`), not `Map.get/3`; `@spec` annotations use `Model.t()` not
`map()`; and no `Map.get` call with a default that re-states a canonical
default from `Model.new/1` remains.

## Out of scope

- Changing the struct's field set or the `@enforce_keys` list.
- Changes to `duplicated-bounded-append` (sibling sub-problem).
- Changes to `session-side-effects-in-pure-modules` (sibling).
- Changes to `transcript-coupling` (sibling).

## Amendment log

- (none yet)
