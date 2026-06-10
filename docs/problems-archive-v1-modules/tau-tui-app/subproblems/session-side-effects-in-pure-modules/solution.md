---
template_version: 1
template_name: solution
parent_problem: ../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-2.md]
selection_method: hybrid
revision: 0
---

# Solution: Command pattern for Input, pure-split for Keymap

## Recommendation

Replace every public `Input` function signature with `{model, [Cmd.t()]}` using
the command pattern (proposal 1), and introduce a thin `Tau.TUI.App.Cmd` module
whose `execute/1` dispatches each command tag to the corresponding `Tau.*` or
`spawn/1` call. For `Keymap.quit_or_append/1` — which is `defp` and whose "quit"
path produces a trivially empty model delta — apply the narrower extraction from
proposal 2: lift the supervisor-stop body into a named `defp do_stop_tui_supervisor/0`,
and let the quit path emit `[:stop_tui_supervisor]` as a command that propagates
up through the private call chain to `Keymap.handle/2`, which then calls
`Cmd.execute/1`. The façade (`Tau.TUI.App`) gains a thin `run_input/2` helper that
destructures `{model, cmds}` and dispatches the command list. Both `Input` and
`Keymap` become unit-testable by asserting on `{model, [cmd]}` with no live
processes.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-1.md` (command pattern) and
  `proposals/proposal-2.md` (named-extract for private Keymap path)
- **Why chosen:**

  | # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
  |---|-----|---------------------|----------------|------|---------------|
  | 1 | Yes | Deep                | Medium         | Low  | Easy          |
  | 2 | Yes | Surface             | Low            | Low  | Easy          |
  | 3 | Yes | Substantial         | Medium         | Medium | Easy        |
  | 4 | Yes | Deep                | Medium-High    | Medium | Hard        |

  Proposal 1 wins on decomplecting depth: the pure/effect boundary is enforced
  by the return type, not by naming convention. Effect intent becomes a value
  (`[Cmd.t()]`), inspectable in tests and in process traces. The façade already
  exists as the dispatch boundary — the hook is structurally available.

  Proposal 2 is the right tool for `Keymap.quit_or_append/1` specifically: the
  quit path's model delta is `model` unchanged (no field mutation), so there is
  nothing meaningful to extract into a `pure_*` function. What the extraction
  buys here is isolation of the `spawn/1` block into a named function; the
  command-propagation path through `Keymap`'s private call chain then carries the
  `:stop_tui_supervisor` tag to `handle/2`, where `Cmd.execute/1` fires it. This
  avoids the full private-chain signature change being disproportionate to the
  trivial effect — the command tag propagates naturally up a call that already
  returns `model`.

  Proposal 3 is rejected: putting an effect-adapter module into `Model.t()` mixes
  a lifecycle concern into the MVU data struct — complecting in a different
  direction. Dialyzer coverage through a struct-carried module reference is weaker
  than through a typed command union.

  Proposal 4 is rejected: transient signal fields (`pending_send`, `:quitting`)
  on `Model.t()` introduce a new class of complecting (model + ephemeral intent
  state), the `fire_transition_effects/2` exhaustiveness problem has no compiler
  support, and the approach is the hardest to reverse if the effect enumeration
  turns out to be incomplete.

  The hybrid is valid (not "average of 1 and 2"): proposal 1 is the primary
  mechanism for all public `Input` functions; proposal 2's naming-extract is
  applied only to the one `defp` in `Keymap` where the command-pattern return
  change would otherwise require threading `{model, cmds}` through every private
  helper in `Keymap` for a single `:stop_tui_supervisor` tag.

## What changes

- **New:** `lib/tau/tui/app/cmd.ex` — defines `Tau.TUI.App.Cmd.t()` tagged union
  and `execute/1` dispatch. Tags: `{:send, sid, text}`, `{:cancel, sid}`,
  `{:steer, sid, text}`, `{:set_permissions_mode, sid, mode}`,
  `:stop_tui_supervisor`.
- **Modified:** `lib/tau/tui/app/input.ex` — every public function (`submit/1`,
  `cancel/1`, `steer/1`, `followup/1`, `handle_perms_command/2`) changes return
  type from `map()` to `{map(), [Cmd.t()]}`. `Tau.*` call sites are replaced by
  cmd list elements.
- **Modified:** `lib/tau/tui/app/keymap.ex` — `quit_or_append/1` emits
  `{model, [:stop_tui_supervisor]}` (empty-editor branch) or `{model, []}` (non-empty
  branch). The `spawn/1` block is lifted into `defp do_stop_tui_supervisor/0`
  and called only from `Cmd.execute/1`. The `{model, cmds}` pair propagates up
  through `Keymap.handle/2` (the public boundary), which returns `{model, cmds}`
  to the façade.
- **Modified:** `lib/tau/tui/app.ex` — gains `run_input/2` (or equivalent)
  helper that calls `Input.<fn>(model)`, destructures `{new_model, cmds}`, calls
  `Enum.each(cmds, &Cmd.execute/1)`, returns `new_model`. Existing `Keymap.handle/2`
  call sites updated to destructure similarly.
- **Modified:** `lib/tau/tui/app/input.ex` `@moduledoc` — remove "pure except for
  side-effectful Tau session calls" caveat; all public functions are now pure.

## What does not change

- The `Tau.*` and `Tau.Session.*` API surface (explicitly out of scope).
- `Bootstrap.init/1` and its lifecycle side effects (out of scope).
- `Model.t()` struct fields — no new fields are added.
- The `Tau.TUI.App` public interface and event-loop structure — the façade gains
  one private helper, not new public callbacks.
- Sibling sub-problems (`duplicated-bounded-append`, `model-as-bag-of-maps`,
  `transcript-coupling`) — disjoint file sets.
- Existing tests that do not call the affected `Input`/`Keymap` functions directly.

## Migration sketch

1. Introduce `lib/tau/tui/app/cmd.ex` with the `Cmd.t()` type and `execute/1`
   — no callers yet, compile-checks clean.
2. Update `Input` public functions one at a time: change return type to
   `{map(), [Cmd.t()]}`, move `Tau.*` call to a cmd list element. After each
   function, update its call site in `app.ex` (or `Keymap`) to destructure and
   route through `Cmd.execute/1`. Compile and run `mix test` between each function.
3. Update `Keymap.quit_or_append/1`: extract `do_stop_tui_supervisor/0`,
   return `{model, [:stop_tui_supervisor]}` from the quit branch, propagate
   through `handle/2` to the façade's dispatch point.
4. Update existing `Input`-focused tests to destructure `{model, _cmds}`; add
   new tests asserting on the cmd list values without any live process.
5. Run `mix compile --warnings-as-errors` and `mix test`; confirm `@moduledoc`
   caveat can be removed.

## Open questions

- `Keymap` uses `defp` throughout below `handle/2`. The full private call graph
  was not traced in any proposal. Before implementation, grep `keymap.ex` for all
  call sites of `quit_or_append/1` to confirm there is exactly one path from
  `handle/2` through which `{model, cmds}` must propagate.
- `Store.append/3` in `submit/1` is disk I/O remaining in the `Input` pure path.
  The problem statement scopes only `Tau.*` and `spawn/1`, so this is left as-is,
  but the open question is whether a follow-up sub-problem should address it or
  whether it is acceptable at the `Input` layer.
- The `Cmd.execute/1` dispatch for `:stop_tui_supervisor` still contains a
  `spawn/1`. This is correct (the effect must be asynchronous to avoid blocking
  the TUI event loop), but the spawn is now in one named location rather than
  inlined in a private function — verify this satisfies the OTP non-negotiable
  against spawning outside a supervision tree, or document the justification.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Command pattern: pure functions return `{model, [Cmd.t()]}`. Primary mechanism for all `Input` public functions and `Keymap.handle/2`.
- `proposals/proposal-2.md` — Thin effect-wrapper: extract effectful shells, keep pure cores unchanged. Naming-extract pattern applied to `Keymap.quit_or_append/1`.
- `proposals/proposal-3.md` — Behaviour-injected effect adapter via `Model.t()` field. Rejected: model-struct complecting, weaker Dialyzer coverage.
- `proposals/proposal-4.md` — Effect-boundary lift via state-transition inference. Rejected: transient signal fields, unenforceable exhaustiveness.

## Revision history

- (revision 0 — initial)
