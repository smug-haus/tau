---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Thin effect-wrapper layer — extract effectful shells, keep pure cores unchanged

## Approach

Introduce a thin `Tau.TUI.App.InputEffects` module (and inline adjustments to
`Keymap`) that owns every `Tau.*` call and `spawn/1`. The existing `Input`
functions are split in-place: the pure state-transformation body is moved into a
private `_pure_*` function with the same logic but no side effects; the public
function becomes a two-line shell that calls the private pure core and then fires
the effect. `InputEffects` re-exports the effectful versions as delegations.
`Input` itself can optionally be made a pure module (all public functions pure,
`@moduledoc` updated). No return-type change; callers see `model` as before.

## Rationale

The complecting hypothesis says a caller cannot get the model state without
triggering the side effect. This proposal breaks that link without changing any
return type or call-site signature. Tests of the pure state transformation call
the renamed private (`_pure_*`) functions directly — or, if privacy is a concern,
a companion `InputPure` module is extracted with those pure functions public. The
effectful behaviour is preserved in `InputEffects` (or the public `Input` shell),
and the pure logic is reachable for testing without any live process. This is the
smallest-surface change that satisfies the acceptance criterion.

## Sketch

```elixir
# lib/tau/tui/app/input.ex  (modified — no return-type change)

# Public shell (effectful, existing callers unchanged)
@spec submit(map()) :: map()
def submit(model) do
  text = Editor.text(model.editor)
  if Editor.empty?(model.editor) do
    model
  else
    if String.starts_with?(text, "/perms") do
      handle_perms_command(model, text)
    else
      # Side effect here — isolated to one line
      Tau.send(model.session_id, text)
      pure_submit_state(model, text)
    end
  end
end

# Pure core — contains ALL state logic; testable without a session
@spec pure_submit_state(map(), String.t()) :: map()
def pure_submit_state(model, text) do
  new_hist = History.push(model.history, text)
  Store.append(model.history_data_dir, model.history_cwd, text)
  %{model | editor: Editor.new(), history: new_hist, search: nil,
            transcript: bounded_append(model.transcript, {"> " <> text, []}),
            status: :sending}
end

@spec cancel(map()) :: map()
def cancel(model) do
  Tau.cancel(model.session_id)   # isolated effect
  pure_cancel_state(model)
end

@spec pure_cancel_state(map()) :: map()
def pure_cancel_state(model), do: %{model | status: :idle}

@spec steer(map()) :: map()
def steer(model) do
  text = Editor.text(model.editor)
  if Editor.empty?(model.editor) do
    model
  else
    Tau.steer(model.session_id, text)   # isolated effect
    pure_steer_state(model, text)
  end
end

@spec pure_steer_state(map(), String.t()) :: map()
def pure_steer_state(model, text) do
  %{model | editor: Editor.new(), search: nil,
            transcript: bounded_append(model.transcript, {"[queued steer] " <> text, []})}
end
```

`handle_perms_command/2` similarly:

```elixir
# Effect-bearing branch (line 112) becomes:
#   Tau.Session.set_permissions_mode(model.session_id, mode)  <- effect isolated
#   pure_perms_mode_state(model_cleared, mode)               <- pure state

@spec pure_perms_mode_state(map(), atom()) :: map()
def pure_perms_mode_state(model, mode), do: %{model | permissions_mode: mode}
```

`Keymap.quit_or_append/1` (private, harder to expose):

```elixir
# lib/tau/tui/app/keymap.ex  — no change to defp visibility, but split body:
defp quit_or_append(model) do
  if Editor.empty?(model.editor) do
    do_stop_tui_supervisor()    # <-- extracted to named defp, isolated effect
    model
  else
    model |> editor_insert("q") |> Completion.update_menu()
  end
end

defp do_stop_tui_supervisor do
  spawn(fn ->
    Tau.TUI.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} -> Supervisor.stop(pid) end)
  end)
end
```

For unit tests, `Input.pure_cancel_state/1`, `Input.pure_steer_state/2`, etc. are
the test surface. No new type or dispatch module needed.

## Tradeoffs

### Strengths

- Zero call-site change: every existing caller of `Input.submit/1`, `Input.cancel/1`
  etc. continues to work unmodified. Façade unchanged. 
- Acceptance criterion is directly satisfied: pure model transformation is
  separable and reachable without a live session.
- Smallest diff of any proposal: only the body of each effectful function is
  reorganised, not its signature or its callers.
- `@moduledoc` can now honestly drop the "except for side-effectful calls"
  caveat from the pure functions.
- Easy to review: each function becomes a 2-line shell + a 5-10 line pure core.

### Weaknesses

- The effect remains co-located with the pure function in the same module file —
  the boundary is logical (naming convention), not physical (module boundary).
  A future author can accidentally re-entangle them.
- `pure_*` functions must be `def` (public) to be testable — there is no Elixir
  mechanism to expose them to tests while keeping them module-private. This
  pollutes the public API surface with implementation details.
- `Keymap.quit_or_append/1` is `defp` — its pure "did nothing to model" path is
  trivial and the `do_stop_tui_supervisor` extraction helps naming clarity but
  does not expose a testable pure core (the quit path doesn't change model at all,
  so the "pure" result is just `model` returned unchanged).
- Does not enforce the pure/effectful split at compile time. No type or contract
  prevents future inline mixing.

### Costs

- Modifies 5 function bodies in `Input`, adds 5 `pure_*` companion functions.
- Adds `do_stop_tui_supervisor/0` private function to `Keymap`.
- No new modules, no call-site changes.
- Estimated diff: ~60 lines added, ~20 lines changed.

## Dependencies

- None. No other module changes, no supervision or behaviour changes.

## Confidence

High. The transformation is mechanical: split each function body into effect line
+ pure body, name the pure body. The test surface is well-defined. The pattern
is a straightforward extraction within one module.

## Prior art / references

- "Functional core, imperative shell" (Gary Bernhardt, Boundaries talk 2012):
  https://www.destroyallsoftware.com/talks/boundaries — same pattern at module
  granularity.
- Standard Elixir idiom: separate `do_*` private helpers for named sub-steps.
