---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Effect-boundary lift — move all session calls out of Input/Keymap into App façade

## Approach

Remove every `Tau.*` call and `spawn/1` from `Input` and `Keymap` entirely. Each
function that formerly fired a side effect now returns a pure `model` (or
`{model, effect_tag}` only where the façade cannot infer the effect from model
state alone). The `Tau.TUI.App` façade (`app.ex`) becomes the sole location for
session calls: it inspects the before/after model state after calling each
`Input` or `Keymap` function, and fires the appropriate `Tau.*` call based on the
state transition. This is a boundary-lift rather than a command pattern: effects
are inferred from state change, not described by the callee.

## Rationale

If the façade already owns the `Tau.TUI.App` event loop, it is structurally the
correct owner of all `Tau.*` side effects. `Input` and `Keymap` are MVU helpers —
they should describe state transitions only. The façade can detect transitions
(e.g., `:idle → :sending`, `permissions_mode` change, editor cleared on cancel)
and fire the corresponding session call without any explicit effect description
from the callee. This approach gives `Input` and `Keymap` the strongest possible
purity guarantee — they become pure functions with no awareness of effect
infrastructure — and concentrates all side-effect policy in one module.

## Sketch

```elixir
# lib/tau/tui/app/input.ex  (modified — effects removed)

@spec submit(map()) :: map()
def submit(model) do
  text = Editor.text(model.editor)
  if Editor.empty?(model.editor) do
    model
  else
    if String.starts_with?(text, "/perms") do
      handle_perms_command(model, text)
    else
      new_hist = History.push(model.history, text)
      Store.append(model.history_data_dir, model.history_cwd, text)
      # No Tau.send/2 here — state transition signals the effect to the façade
      %{model | editor: Editor.new(), history: new_hist, search: nil,
                transcript: bounded_append(model.transcript, {"> " <> text, []}),
                status: :sending,
                pending_send: text}   # <- new field signals what to send
    end
  end
end

@spec cancel(map()) :: map()
def cancel(model) do
  # No Tau.cancel/1 — status transition signals the façade
  %{model | status: :cancelling}   # <- new transient status; façade fires cancel
end
```

Façade (`app.ex`) wraps each Input call:

```elixir
# lib/tau/tui/app.ex  (excerpt)

defp dispatch_input(model, fun) do
  prev = model
  next = apply(Input, fun, [model])
  fire_transition_effects(prev, next)
  # Clear transient signal fields before storing model
  %{next | pending_send: nil}
end

defp fire_transition_effects(prev, next) do
  # Submit: pending_send set
  if next.pending_send do
    Tau.send(next.session_id, next.pending_send)
  end
  # Cancel: status went to :cancelling
  if prev.status != :cancelling and next.status == :cancelling do
    Tau.cancel(next.session_id)
  end
  # Permissions mode change
  if prev.permissions_mode != next.permissions_mode do
    Tau.Session.set_permissions_mode(next.session_id, next.permissions_mode)
  end
  :ok
end
```

For `quit_or_append` in `Keymap`:

```elixir
# Add a :quitting status or a :pending_quit flag to Model
defp quit_or_append(model) do
  if Editor.empty?(model.editor) do
    %{model | status: :quitting}   # façade detects :quitting and calls stop_supervisor
  else
    model |> editor_insert("q") |> Completion.update_menu()
  end
end
```

`Model.t()` gains:
- `pending_send: nil | String.t()` — transient; cleared by façade after effect fires
- `:cancelling` and `:quitting` as valid `status` values

## Tradeoffs

### Strengths

- `Input` and `Keymap` become strictly pure: no `Tau.*`, no `spawn/1`, no
  behaviour injection, no return-type change. The `@moduledoc` caveat disappears
  completely.
- All effect policy lives in one place (the façade), making it easier to reason
  about what triggers session calls.
- No new behaviour or stub module required for tests: `Input` tests are plain
  map-transformation assertions.
- The approach generalises: any future effect can be added to the façade without
  touching the MVU helpers.

### Weaknesses

- Introduces transient signal fields (`pending_send`, `:quitting` status etc.)
  into `Model.t()` — the model struct now carries ephemeral intent state that is
  meaningful only for one façade dispatch cycle. This is a different kind of
  complecting: model + ephemeral effect signal.
- The façade's `fire_transition_effects/2` must correctly enumerate all
  transitions. A missed transition (e.g. a new function added to `Input` that
  changes `permissions_mode`) silently drops the effect — a harder bug to catch
  than an explicit missing call.
- `:cancelling` and `:quitting` as status values may conflict with the `Tau.Session`
  FSM states or the TUI rendering logic that pattern-matches on `status`.
- The `pending_send` field approach is fragile: if two effects could theoretically
  be pending at once (e.g. a steer + a followup flush), the single-field design
  breaks. Using a list `pending_effects: []` is safer but pushes toward the
  command pattern of proposal 1.
- Requires `Tau.TUI.App` façade to grow non-trivial logic — the current façade
  is intentionally thin.

### Costs

- `Model.t()` gains 1-2 transient fields and new `:cancelling`/`:quitting` status
  values.
- `app.ex` gains `fire_transition_effects/2` (~30 lines) and wrapper dispatch
  helper.
- 5 function bodies in `Input` lose their `Tau.*` calls and gain field-set
  assignments.
- Tests for the façade's effect-firing logic must verify transitions.
- Estimated diff: ~80 lines changed/added.

## Dependencies

- The `status` field type in `Model.t()` must be extended without breaking
  existing pattern matches in `View`, `Events`, and `Permission`. A grep pass
  over status consumers in `lib/tau/tui/app/` is required before implementing.
- If `model-as-bag-of-maps` is addressed first, struct enforcement makes adding
  `pending_send` and new status values safer.

## Confidence

Low-medium. The pure-function outcome is the strongest of any proposal, but the
transient-field mechanism introduces a fragility the other proposals avoid. The
`fire_transition_effects/2` exhaustiveness concern is real and has no compiler
support. A prototype of the façade dispatch + a grep of `status` consumers would
raise confidence.

## Prior art / references

- React's `useEffect` + state-transition side effects: same idiom of "façade
  inspects state change and fires effects" rather than callee declaring them.
- `:gen_statem` `state_enter` callbacks: the state machine fires entry actions on
  transition detection, not on direct call — same structural idea.
- Elm's `subscriptions` + `update` separation: the runtime (façade) owns
  all effect scheduling; `update` is always pure.
