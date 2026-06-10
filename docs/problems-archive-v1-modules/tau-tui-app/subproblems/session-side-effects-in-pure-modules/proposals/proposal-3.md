---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Behaviour-injected effect adapter — pass a session adapter struct through the model

## Approach

Introduce a `Tau.TUI.App.SessionAdapter` behaviour with callbacks matching the
`Tau.*` surface used by `Input` and `Keymap`: `send/2`, `cancel/1`, `steer/2`,
`set_permissions_mode/2`, `stop_supervisor/0`. Add a `session_adapter` field to
`Model.t()` (defaulting to `Tau.TUI.App.SessionAdapter.Live`). Every `Tau.*` call
in `Input` and the `spawn/1` in `Keymap` is replaced with a call through
`model.session_adapter`. In tests, inject `Tau.TUI.App.SessionAdapter.Stub` (a
no-op or capture-to-agent implementation). The pure model transformation is
unchanged in structure; the seam is the adapter struct stored in the model.

## Rationale

Rather than changing function return types (proposal 1) or exposing private
pure-body functions (proposal 2), this proposal moves the seam to the model's
data: the adapter is a value carried alongside the session ID. The complecting is
resolved because `Input` and `Keymap` no longer reach module globals (`Tau`,
`Tau.Session`, `DynamicSupervisor`); they call through the adapter, which is
replaceable at the model boundary. This matches OTP's "inject dependencies as
data" idiom and keeps function signatures `model → model` throughout — no
call-site changes.

## Sketch

```elixir
# lib/tau/tui/app/session_adapter.ex  (new)
defmodule Tau.TUI.App.SessionAdapter do
  @callback send(session_id :: term(), text :: String.t()) :: :ok
  @callback cancel(session_id :: term()) :: :ok
  @callback steer(session_id :: term(), text :: String.t()) :: :ok
  @callback set_permissions_mode(session_id :: term(), mode :: atom()) :: :ok
  @callback stop_supervisor() :: :ok
end

defmodule Tau.TUI.App.SessionAdapter.Live do
  @behaviour Tau.TUI.App.SessionAdapter
  def send(sid, text),                 do: Tau.send(sid, text)
  def cancel(sid),                     do: Tau.cancel(sid)
  def steer(sid, text),                do: Tau.steer(sid, text)
  def set_permissions_mode(sid, mode), do: Tau.Session.set_permissions_mode(sid, mode)
  def stop_supervisor do
    spawn(fn ->
      Tau.TUI.Supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} -> Supervisor.stop(pid) end)
    end)
    :ok
  end
end

defmodule Tau.TUI.App.SessionAdapter.Stub do
  @behaviour Tau.TUI.App.SessionAdapter
  # No-op stubs; or use Agent to capture calls for assertion
  def send(_sid, _text),                 do: :ok
  def cancel(_sid),                      do: :ok
  def steer(_sid, _text),                do: :ok
  def set_permissions_mode(_sid, _mode), do: :ok
  def stop_supervisor(),                 do: :ok
end
```

`Model.t()` gains a field:

```elixir
# lib/tau/tui/app/model.ex  (struct addition)
defstruct [
  # ... existing fields ...
  session_adapter: Tau.TUI.App.SessionAdapter.Live,
]
```

`Input.cancel/1` becomes:

```elixir
def cancel(model) do
  model.session_adapter.cancel(model.session_id)
  %{model | status: :idle}
end
```

`Input.submit/1` (effectful line):

```elixir
model.session_adapter.send(model.session_id, text)
```

`Keymap.quit_or_append/1`:

```elixir
defp quit_or_append(model) do
  if Editor.empty?(model.editor) do
    model.session_adapter.stop_supervisor()
    model
  else
    model |> editor_insert("q") |> Completion.update_menu()
  end
end
```

Test setup:

```elixir
# In test
model = Model.new(...) |> Map.put(:session_adapter, Tau.TUI.App.SessionAdapter.Stub)
{new_model} = Input.cancel(model)
assert new_model.status == :idle
# No process infrastructure needed
```

## Tradeoffs

### Strengths

- Function signatures remain `model → model`; call sites are unchanged.
- The seam is explicit in the type: `Model.t()` carries the adapter, visible to
  any reader of the struct definition.
- Stub is a proper `@behaviour` implementation — the compiler enforces callback
  completeness.
- Decouples `Input` and `Keymap` from global module references (`Tau`,
  `Tau.Session`, `DynamicSupervisor`) — the modules become testable in isolation
  and the adapter could be swapped for replay, simulation, or multiple session
  targets.
- No new `Cmd` dispatch infrastructure; no return-type change propagation.

### Weaknesses

- `Model.t()` grows a field for an effect dependency — mixing a session-lifecycle
  concern into the MVU data struct. This is arguably a violation of model purity
  in a different direction.
- The `model-as-bag-of-maps` sibling problem (struct discipline) is not resolved
  by this proposal; if that problem is fixed first, the struct shape change here
  is easy. If this is fixed first, the model field must be handled carefully when
  that problem is addressed.
- Using a module (atom) as the adapter value (`session_adapter: SomeMod`) means
  the adapter is not truly a value — it's a module reference. A proper OTP
  approach would use a `{module, state}` tuple, but that adds complexity the
  callbacks here don't need.
- Production code path through `model.session_adapter.send(...)` uses dynamic
  dispatch (apply), which Dialyzer may not type-check fully through a struct field
  unless the type annotation is precise.
- `Keymap.quit_or_append/1` accesses `model.session_adapter` inside a `defp` —
  if the `Model` type annotation on private functions is loose, this could be
  silently wrong.

### Costs

- New `session_adapter.ex` file (~50 lines).
- `model.ex` struct gets one new field + `@type t()` update.
- Each `Tau.*` call site in `Input` and `Keymap` is replaced with
  `model.session_adapter.<cb>(...)` — ~6 callsite edits.
- Test helpers must inject the stub into model construction.
- Estimated diff: ~70 lines added, ~15 lines changed.

## Dependencies

- `Model.t()` struct must be updated before `Input` and `Keymap` can reference
  the new field. If `model-as-bag-of-maps` is being addressed in parallel, the
  two changes must not conflict on the struct definition.
- `Bootstrap.init/1` or `Model.new/3` must inject `SessionAdapter.Live` as the
  default — no additional process setup required.

## Confidence

Medium. The pattern is sound and the sketch is concrete. The Dialyzer concern
on dynamic dispatch through struct fields is real and may require an explicit
`@type adapter :: module()` annotation and careful spec on `Model.t()`. A type
check pass would raise confidence to high.

## Prior art / references

- OTP "inject dependencies as data" idiom: standard pattern in BEAM codebases
  for replacing module-level global calls with data-carried callbacks.
- Plug's `adapter:` field in `%Plug.Conn{}` — same structural placement of an
  effect adapter inside the primary data struct.
- Mox (José Valim): https://github.com/dashbitco/mox — the Elixir idiomatic
  approach to behaviour-based test doubles, which this proposal's Stub implements.
