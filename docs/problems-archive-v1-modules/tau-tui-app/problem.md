---
template_version: 1
template_name: problem
node_kind: internal
depth: 0
parent: —
status: decomposed
---

# Problem: Inherited complecting in tau-tui-app sub-modules after decomposition

## Statement

The recent extraction of `Tau.TUI.App` into nine sub-modules (model, bootstrap,
history, completion, keymap, input, view, events, permission) reduced LOC in the
façade but did not resolve several inherited concerns that now span module
boundaries or are duplicated across them. Multiple sub-modules carry mixed
concerns — pure MVU state transformation entangled with side effects, view
rendering entangled with business logic, and shared helpers copied rather than
extracted — that make each sub-module harder to test, reason about, and evolve
independently.

## Context

- `lib/tau/tui/app.ex` — ~42 LOC façade; delegates to sub-modules
- `lib/tau/tui/app/model.ex` — 23-field struct + constructor (also owns `init_provider/1`, `init_model/1`, `transcript_pane_width/1`)
- `lib/tau/tui/app/bootstrap.ex` — Ratatouille init callback + runtime supervisor lifecycle
- `lib/tau/tui/app/events.ex` — session event dispatcher; owns `bounded_append/2`, `transcript_pane_width/1` (duplicated from Model)
- `lib/tau/tui/app/input.ex` — submit/steer/followup/cancel; owns its own copy of `bounded_append/2` (duplicated from Events)
- `lib/tau/tui/app/keymap.ex` — terminal key routing; directly calls `Tau.TUI.Supervisor` via side-effectful `spawn/1` in `quit_or_append/1`
- `lib/tau/tui/app/view.ex` — Ratatouille view; owns `status_bar_model/1` (projection from full model to StatusBar map)
- `lib/tau/tui/app/history.ex` — pure history navigation helpers
- `lib/tau/tui/app/completion.ex` — pure menu helpers
- `lib/tau/tui/app/permission.ex` — permission queue + dialog rendering (mixes event logic and view)
- Decomposition inventory: `docs/refactor/inventory-tui-app.md`
- SPEC-TUI-HEADLESS and SPEC-USER-TURN govern boundary contracts

## Complecting hypothesis

1. `bounded_append/2` (transcript ring-buffer) is complected with both the
   events module and the input module because neither owns it canonically; each
   carries a private copy, meaning the cap constant and the drop semantics are
   duplicated rather than single-sourced.

2. The MVU model struct (`Model.t()`) is complected with all consumer modules as
   a raw map-like value — callers use `Map.get/3`, `Map.put/2`, and pattern-match
   on anonymous map fields throughout `Events`, `Input`, `Keymap`, and `View`,
   bypassing the typed struct. Struct-field access (`model.field`) and
   anonymous-map access (`Map.get(model, :field, default)`) appear in the same
   function bodies, making struct enforcement effectively opt-in.

3. `Tau.TUI.App.Permission` is complected with both session-event handling and
   Ratatouille view rendering — it owns `on_permission_request/2` (pure MVU fold),
   `handle_permission_dialog_event/2` (key routing), and
   `render_permission_dialog/2` (view fragment) — three concerns that belong to
   Events, Keymap, and View respectively.

## Decomposition strategy

The four inherited concerns are distinct enough to be addressed independently
and do not overlap:
- **Duplicated shared helper** (`bounded_append`) — a missing extraction target.
- **Model access pattern inconsistency** — raw map vs struct discipline.
- **Cross-cutting session side effects in nominally-pure modules** — effects
  are present in Input, Keymap, and Bootstrap in ways that make unit testing
  harder.
- **Permission module concern mix** — a single module holds event, key-routing,
  and view responsibilities.

Axis: **concern (Hickey)** — name the woven concerns directly. Each sub-problem
names one woven pair and is solvable without knowing what the others conclude.

## Sub-problems (filled by decomposer)

1. **duplicated-bounded-append** — `bounded_append/2` is copied verbatim in
   `Events` and `Input`; it has no canonical home, so the cap and drop semantics
   can diverge silently.
2. **model-as-bag-of-maps** — `Model.t()` struct discipline is undermined by
   pervasive `Map.get/3` and `Map.put/2` calls in consumer modules, defeating
   struct enforcement and `@enforce_keys`.
3. **session-side-effects-in-pure-modules** — `Input`, `Keymap`, and `Bootstrap`
   mix `Tau.*` session calls and `spawn/1` with pure MVU transformations, making
   unit tests require a live session or process.
4. **transcript-coupling** — `on_message_end/2` in `Events` owns Markdown
   rendering, subagent tree lookups, `StatusBar` telemetry emission, and cost
   ETS access in one handler, coupling concerns that could be independently
   tested or replaced.

## Acceptance criterion

Each sub-problem is described at sufficient resolution that a proposer can
produce a concrete, independently-evaluable refactoring proposal without
needing to re-read sibling sub-problems.

## Out of scope

- Re-examining the correctness of the TUI's FSM or session protocol.
- Ratatouille framework behaviour or tick/subscription logic.
- The `History`, `Completion`, and `Keymap` modules' internal logic (they are
  already well-shaped within their stated scope).
- Dependency or OTP supervision tree changes.
- Performance or rendering fidelity issues.

## Amendment log

- (none yet)
