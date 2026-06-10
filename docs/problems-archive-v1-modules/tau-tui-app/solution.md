---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: root
synthesised_from: [subproblems/duplicated-bounded-append/solution.md, subproblems/model-as-bag-of-maps/solution.md, subproblems/session-side-effects-in-pure-modules/solution.md, subproblems/transcript-coupling/solution.md]
selection_method: synthesis
mode: non-leaf
revision: 0
---

# Solution: Module-wide decomplecting of `Tau.TUI.App` sub-modules via canonical helper home, struct discipline, command pattern, and intra-module handler split

## Recommendation

Land the four child recommendations as one coherent module-wide refactor sequenced
in dependency order so each later step works on a cleaner substrate than the last.
First, give `bounded_append/2` and `@transcript_cap` a canonical home in `Model`
and delete both private copies (child 1). Second, replace every `Map.get/Map.put`
on a `Model.t()` value with struct access across `Events`, `Input`, `Keymap`,
`View`, `Permission`, `Completion`, and `History`, retyping `@spec`s from `map()`
to `Model.t()` and introducing the single `Model.context_window/1` accessor for
the one non-trivial nil-fallback (child 2). Third, convert every public `Input`
function and `Keymap.handle/2` to return `{model, [Cmd.t()]}` against a new
`Tau.TUI.App.Cmd` tagged-union module, with the façade owning command dispatch
via a thin `run_input/2` helper, and lift `Keymap.quit_or_append/1`'s `spawn/1`
into a named `do_stop_tui_supervisor/0` invoked only from `Cmd.execute/1` (child
3). Fourth, replace `Events.on_message_end/2` with a thin dispatcher over two
disjoint-field private handlers, `on_message_end_transcript/2` and
`on_message_end_counters/2` (child 4). The four steps compose without conflict
because their primary file boundaries are orthogonal (Model API; callsite syntax;
Input/Keymap return shape; one Events function body), but they must land in this
order so each step's callsite churn does not collide with the next step's.

## Selected from

- **Synthesised from:**
  - `subproblems/duplicated-bounded-append/solution.md`
  - `subproblems/model-as-bag-of-maps/solution.md`
  - `subproblems/session-side-effects-in-pure-modules/solution.md`
  - `subproblems/transcript-coupling/solution.md`
- **Composition rationale:** The four child solutions partition the inherited
  complecting along disjoint axes:

  | Child | Primary axis | Primary surface |
  |-------|--------------|-----------------|
  | 1 — bounded-append | canonical helper home | `Model` adds 2 functions + 1 constant; `Events`/`Input` lose duplicates |
  | 2 — struct discipline | callsite syntax + `@spec` typing | `Map.get/put` → `model.field`/`%{model | ...}` across 6+ files; `Model.context_window/1` accessor |
  | 3 — command pattern | function return shape | `Input` and `Keymap.handle/2` return `{model, [Cmd.t()]}`; new `Cmd` module; façade dispatches |
  | 4 — handler split | intra-function decomposition | one function body in `Events.on_message_end/2` replaced by dispatcher + two named handlers |

  The axes are independent: helper extraction (1) does not move callsites; struct
  discipline (2) changes call syntax but not return shapes; command pattern (3)
  changes return shapes and adds a new module; handler split (4) is wholly inside
  one function. No two children write to the same line of any file *for the same
  reason*. They DO touch overlapping files (`Events`, `Input`, `Keymap`), but at
  layered concerns: (1) adds aliases and removes definitions; (2) rewrites
  callsite syntax inside function bodies; (3) rewrites function signatures and
  introduces command dispatch; (4) restructures one function body.

  **Sequencing constraint.** (1) → (2) → (3) → (4) is the only ordering that
  avoids inter-step rework:

  - (1) before (2): the `bounded_append` callsites in `Events`/`Input` are
    rewritten by (1) to qualify with `Model.`; (2) then rewrites the surrounding
    `Map.get/put` calls in the same files. Reversing introduces a merge surface
    where (2) edits a `bounded_append` call that (1) is about to relocate.
  - (2) before (3): the new `Input` return shapes from (3) are easier to author
    against struct-typed models than against `Map.get/put` syntax. Reversing
    forces (3) to rewrite return shapes around legacy `Map.get` calls, then have
    (2) re-edit those same lines.
  - (2) before (4): the new `on_message_end_*` handlers in (4) are easier to
    author with `model.field` access throughout. Same reasoning as above.
  - (3) and (4) are independent of each other and could land in either order;
    (3) before (4) is preferred because (3)'s scope is broader and its merge
    risk against `main` is higher.

  **No tension between child recommendations.** Each child solution's "What does
  not change" section explicitly excludes the surfaces the other children
  modify, and each child's "What changes" list is internally consistent with
  every other child's exclusion list.

  **One acknowledged gap.** The root `problem.md` names four inherited concerns;
  the decomposer produced four sub-problems but substituted `transcript-coupling`
  for the listed `permission-module-concern-mix`. Children 2 and 3 partially
  address the Permission module (struct discipline in 2; the
  `set_permissions_mode` command tag in 3's `Cmd.t()`), but neither extracts
  `Permission.render_permission_dialog/2` to `View` nor moves
  `Permission.handle_permission_dialog_event/2` to `Keymap`. The Permission
  concern-mix is therefore *partially* addressed by this synthesis and remains an
  open question (see below) for a follow-up decomposition pass, not a blocker
  for the four-step plan.

## What changes

The full union of child "What changes" lists, deduplicated and grouped by file:

### New files
- `lib/tau/tui/app/cmd.ex` — `Tau.TUI.App.Cmd.t()` tagged union + `execute/1`
  dispatch. Tags: `{:send, sid, text}`, `{:cancel, sid}`, `{:steer, sid, text}`,
  `{:set_permissions_mode, sid, mode}`, `:stop_tui_supervisor`.

### `lib/tau/tui/app/model.ex`
- Add `@transcript_cap 500`.
- Add `def bounded_append/2` and `def bounded_append_many/2` with `@doc`/`@spec`.
- Add `def context_window/1` with `@spec context_window(t()) :: pos_integer()` —
  two-clause function returning the field value when set, or
  `Application.get_env(:tau, :compaction_threshold_tokens, 120_000)` when nil.

### `lib/tau/tui/app/events.ex`
- Remove `@transcript_cap 500`, the private `defp bounded_append/2`, the public
  `def bounded_append/2`, and `def bounded_append_many/2`.
- Add `alias Tau.TUI.App.Model` if not present; route all transcript appends
  through `Model.bounded_append/2`/`bounded_append_many/2`.
- Retype `@spec update/2` and `@spec update_session_event/2` from `map()` to
  `Model.t()`.
- Replace every `Map.get(model, ...)` and `Map.put(model, ...)` with struct field
  access and `%{model | ...}` update syntax.
- Replace `Map.get(model, :context_window) || Application.get_env(...)` with
  `Model.context_window(model)`.
- Replace `on_message_end/2` (~77 LOC) with a thin dispatcher (~4 LOC) that
  pipes through two new private functions:
  - `on_message_end_transcript/2` (~20 LOC) — reads `model.subagents` and
    `msg.content`; writes `model.transcript` and `model.last_assistant`; no ETS,
    no telemetry.
  - `on_message_end_counters/2` (~20 LOC) — reads `model.session_id`,
    `model.context_window`, `model.warn_level`, and `message.usage`; writes
    `model.usage`, `model.context_tokens`, `model.warn_level`, `model.status`;
    calls the existing `cost_for_session/1` private helper; emits the
    `[:tau, :tui, :status, :update]` telemetry event.
  - `cost_for_session/1` (the sole `try/rescue` site) is unchanged.

### `lib/tau/tui/app/input.ex`
- Remove `@transcript_cap 500` and `defp bounded_append/2`.
- Add `alias Tau.TUI.App.Model`; route the affected callsite through
  `Model.bounded_append/2`.
- Replace any `Map.get/put` on `model` with struct access; retype `@spec`s from
  `map()` to `Model.t()`.
- Change every public function (`submit/1`, `cancel/1`, `steer/1`, `followup/1`,
  `handle_perms_command/2`) return type from `map()` to `{Model.t(), [Cmd.t()]}`.
  Replace each `Tau.*`/`Tau.Session.*` call with an element in the returned
  command list.
- Remove the "pure except for side-effectful Tau session calls" caveat from
  `@moduledoc`; all public functions are now pure.

### `lib/tau/tui/app/keymap.ex`
- Retype affected `@spec`s to `Model.t()`; replace
  `Map.get(model, :pending_permissions, [])` with `model.pending_permissions`.
- In `quit_or_append/1`, lift the `spawn/1` body into a `defp
  do_stop_tui_supervisor/0` and return `{model, [:stop_tui_supervisor]}` (quit
  branch) or `{model, []}` (non-quit branch). Propagate `{model, cmds}` up
  through `handle/2`, which becomes the public boundary returning `{model, cmds}`
  to the façade. `do_stop_tui_supervisor/0` is called only from `Cmd.execute/1`.

### `lib/tau/tui/app/view.ex`
- Retype `@spec status_bar_model/1` from `map()` to `Model.t()`.
- Replace every `Map.get(model, :field, default)` in `status_bar_model/1` with
  `model.field`; replace `Map.get(model, :context_window)` with
  `Model.context_window(model)`.

### `lib/tau/tui/app/permission.ex`
- Retype affected `@spec`s to `Model.t()`.
- Replace `Map.get(model, :pending_permissions, [])` with
  `model.pending_permissions`; replace
  `Map.put(model, :pending_permissions, ...)` with
  `%{model | pending_permissions: ...}`.

### `lib/tau/tui/app/completion.ex` and `lib/tau/tui/app/history.ex`
- Audit for `Map.get/put` on `Model.t()` values; apply the same mechanical
  replacement if found.

### `lib/tau/tui/app.ex` (façade)
- Add a thin `run_input/2` helper that calls `Input.<fn>(model)`, destructures
  `{new_model, cmds}`, runs `Enum.each(cmds, &Cmd.execute/1)`, and returns
  `new_model`. Update existing `Keymap.handle/2` callsites to destructure
  identically.

### Tests
- Add the two new unit tests for `on_message_end_transcript/2` (stub
  `SubagentTree`, no ETS) and `on_message_end_counters/2` (mock session counter,
  attached telemetry handler, no Markdown content).
- Update existing `Input`-focused tests to destructure `{model, _cmds}`; add new
  tests asserting on the command list values without any live process.
- No test changes are required for child 1 (function bodies preserved exactly)
  or child 2 (struct access is observationally equivalent provided no fixture
  relied on `Map.get` defaulting; verify per child 2's open questions).

## What does not change

- The `Model.t()` struct's field set and `@enforce_keys` list — no field added,
  removed, or renamed.
- `Model.new/1` — no signature change.
- Sub-field shapes (`usage`, `search`, `menu`) — no sub-struct extraction.
- `Tau.Cost.for_session/1` return type and `Tau.Cost` API — unchanged.
- `Tau.TUI.StatusBar` module — no new functions; `context_pct/2` and
  `warn_level/1` called as before.
- `Tau.TUI.Render.Markdown` and `Tau.TUI.SubagentTree` — no changes.
- The `Tau.*` and `Tau.Session.*` public API surface — unchanged (out of scope).
- `Bootstrap.init/1` and its lifecycle side effects — out of scope.
- The `Tau.TUI.App` public interface and event-loop structure — façade gains one
  private helper, no new public callbacks.
- The telemetry event schema `[:tau, :tui, :status, :update]` and its metadata
  (including `session_id`) — D-168/D-169 unchanged.
- `Cost.for_session/1` and the `cost_for_session/1` private helper in `Events` —
  unchanged; `try/rescue` stays where it is.
- SPEC-TUI-HEADLESS Appendix B source map — no new files to register; `Cmd` is
  an internal sub-module of `Tau.TUI.App`, not a boundary.
- The cap value 500 and the ring-buffer drop semantics — preserved exactly.
- The `Tau.TUI.App.Transcript` module — does not exist and is not introduced.

## Migration sketch

One branch, four PRs (or four commits on one PR) in strict order — each
gateable independently because each preserves observable behaviour:

1. **PR1 (child 1).** Add `bounded_append`, `bounded_append_many`,
   `@transcript_cap` to `Model`. Update `Events` and `Input` to alias + call
   through `Model`; remove duplicates. `mix compile --warnings-as-errors`,
   `mix test`. Grep `Events.bounded_append` for external callers (expected
   zero).

2. **PR2 (child 2).** Add `Model.context_window/1`. Walk the file list in
   dependency order — `events.ex` (largest), then `view.ex`, then `keymap.ex`,
   `permission.ex`, `input.ex`, `completion.ex`, `history.ex`. Each file is one
   commit so bisection is clean if a fixture surfaces a hidden gap. `mix
   compile --warnings-as-errors`, `mix test`, `mix dialyzer` after the final
   commit.

3. **PR3 (child 3).** Introduce `lib/tau/tui/app/cmd.ex` (no callers yet).
   Convert `Input` public functions one at a time: change the return type,
   move `Tau.*` calls to cmd-list elements, update the corresponding
   `app.ex`/`Keymap` callsite to destructure and call `Cmd.execute/1`. Compile
   and test between each function. Then convert `Keymap.quit_or_append/1`:
   lift `do_stop_tui_supervisor/0`, return `{model, [:stop_tui_supervisor]}`,
   propagate through `handle/2`. Update `Input`-focused tests to destructure
   `{model, _cmds}`; add new tests asserting on the cmd list. Remove
   `Input.@moduledoc` purity caveat.

4. **PR4 (child 4).** Introduce `on_message_end_transcript/2` and
   `on_message_end_counters/2` reproducing the existing logic. Replace
   `on_message_end/2`'s body with the dispatcher pipe. `mix compile
   --warnings-as-errors` to confirm no cross-reads. Add the two new unit tests.

Each PR is independently revertible. Existing integration tests are expected to
pass throughout because all four child changes preserve observable behaviour at
the `Tau.TUI.App` public interface.

## Open questions

- **Permission concern-mix is only partially addressed.** The root `problem.md`
  lists `Permission` carrying event logic + key routing + view rendering as one
  of the four inherited concerns; the decomposer substituted `transcript-coupling`
  for it. After this synthesis lands, `Permission` will benefit from struct
  discipline (child 2) and the `set_permissions_mode` cmd tag (child 3), but its
  view fragment is still co-located with its event logic and key routing. A
  follow-up sub-problem should decompose `Permission` along the same Events /
  Keymap / View lines the root problem identifies.
- **`Store.append/3` in `Input.submit/1`** is disk I/O remaining in the `Input`
  pure path after child 3. Child 3's open question 2 notes this is in-scope
  ambiguous; the synthesis defers it to a follow-up.
- **`Cmd.execute/1` for `:stop_tui_supervisor`** retains a `spawn/1` (correct,
  to avoid blocking the event loop, but now in one named location). Verify
  against `.claude/rules/otp-non-negotiables.md` — supervised processes are
  required for stateful work; this is a one-shot fire-and-forget; document the
  justification at the call site.
- **Test fixtures may rely on `Map.get` defaulting.** Child 2's open question 2
  identifies this risk; implementers must verify `mix test` passes after each
  file's conversion. If a fixture surfaces, fix the fixture, do not re-introduce
  the default.
- **`completion.ex`/`history.ex` `Map.get/put` audit** must run before
  implementation begins (child 2 open question 1); they may have no such calls,
  in which case those files are no-ops for child 2.
- **Dialyzer widening on `Model.context_window/1`** must be verified (child 2
  open question 3); a two-clause pattern match returning the same type from
  both branches should propagate cleanly.
- **Independence of the two new `Events` handlers is convention-enforced, not
  type-enforced** (child 4 open questions 1–2). A reviewer checklist is the
  only guard against a future author re-coupling them.
- **`Keymap` private call graph** below `handle/2` was not fully traced in
  child 3; a grep before implementation is required to confirm exactly one path
  carries the `{model, cmds}` propagation (child 3 open question 1).

## Linked sub-problems / proposals

- `subproblems/duplicated-bounded-append/` → "Extract `bounded_append/2`,
  `bounded_append_many/2`, and `@transcript_cap 500` into `Tau.TUI.App.Model` as
  public functions; remove both private copies from `Events` and `Input`."
- `subproblems/model-as-bag-of-maps/` → "Replace every `Map.get/Map.put` on
  `Model.t()` with struct access across `Events`, `Input`, `Keymap`, `View`,
  `Permission` (and audit `Completion`/`History`); retype `@spec`s from `map()`
  to `Model.t()`; add `Model.context_window/1` for the one non-trivial
  nil-fallback."
- `subproblems/session-side-effects-in-pure-modules/` → "Convert public `Input`
  functions and `Keymap.handle/2` to return `{model, [Cmd.t()]}` against a new
  `Tau.TUI.App.Cmd` module; lift `Keymap.quit_or_append/1`'s `spawn/1` into a
  named function called only from `Cmd.execute/1`; add a `run_input/2` dispatch
  helper to the façade."
- `subproblems/transcript-coupling/` → "Replace `Events.on_message_end/2` with a
  thin dispatcher over two disjoint-field private handlers
  (`on_message_end_transcript/2`, `on_message_end_counters/2`); the
  `cost_for_session/1` `try/rescue` site is unchanged."

## Revision history

- (revision 0 — initial)
