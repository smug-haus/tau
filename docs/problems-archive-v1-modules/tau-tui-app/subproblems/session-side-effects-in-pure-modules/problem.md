---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Session side effects inlined in nominally-pure MVU sub-modules

## Statement

`Tau.TUI.App.Input`, `Tau.TUI.App.Keymap`, and `Tau.TUI.App.Bootstrap` each
describe themselves as pure MVU helpers (taking and returning model), but all
three contain unconditional `Tau.*` session calls, `Tau.Session.*` casts, and
`spawn/1` process creation mixed inline with the pure model-transformation
logic. This means every unit test of these modules must either run a live
`Tau.Session` FSM, stub the `Tau` module, or forgo the effectful branches
entirely — none of which the current test suite achieves cleanly.

## Context

- `lib/tau/tui/app/input.ex:32` — `Tau.send(model.session_id, text)` in `submit/1` (side effect, no boundary)
- `lib/tau/tui/app/input.ex:113` — `Tau.Session.set_permissions_mode/2` in `handle_perms_command/1`
- `lib/tau/tui/app/input.ex:120` — `Tau.cancel/1` in `cancel/1`
- `lib/tau/tui/app/input.ex:139` — `Tau.steer/1` in `steer/1`
- `lib/tau/tui/app/input.ex:168` — `Tau.send/2` in `followup/1` (second call site)
- `lib/tau/tui/app/keymap.ex:288–296` — `spawn(fn -> DynamicSupervisor.which_children(...) end)` in `quit_or_append/1`; spawns a process to stop the Ratatouille supervisor
- `lib/tau/tui/app/bootstrap.ex:26–41` — `Tau.TUI.EventBridge.start_link/1`, `Tau.start_session/1`, `Tau.TUI.RuntimeOpts.get/0` in `init/1`; these are expected in Bootstrap, but Bootstrap also calls `Model.new/3` which triggers `Store.load/2` (disk I/O)
- `lib/tau/tui/app/model.ex:104–106` — `Tau.Settings.data_dir/0`, `File.cwd!/0`, `Store.load/2` called from `Model.new/3`; constructor performs I/O

`Input`'s `@moduledoc` states "All functions are pure except for the
side-effectful Tau session calls" — acknowledging the entanglement without
resolving it.

## Complecting hypothesis

Pure MVU model transformations are complected with `Tau` session I/O in `Input`
and `Keymap` because the decomposition placed each feature (submit, steer,
followup, cancel, quit) in a single function that does both: compute the new
model AND fire the side effect. A caller cannot get the new model state without
triggering the side effect, and cannot test the state transition without a live
session process.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

Each function in `Input` and `Keymap` whose primary purpose is a pure model
transformation is separable from its side effect — either by returning the
model state and a description of the effect (command pattern), or by having the
side effect extracted to a wrapper layer — such that the model transformation
can be unit-tested without a live `Tau.Session` or `Tau.TUI.Supervisor` process.

## Out of scope

- Changing the session protocol or the `Tau.*` API surface.
- `Bootstrap.init/1` — the lifecycle side effects there are structurally
  expected and not a concern of this sub-problem.
- Changes to `duplicated-bounded-append` (sibling sub-problem).
- Changes to `model-as-bag-of-maps` (sibling).
- Changes to `transcript-coupling` (sibling).

## Amendment log

- (none yet)
