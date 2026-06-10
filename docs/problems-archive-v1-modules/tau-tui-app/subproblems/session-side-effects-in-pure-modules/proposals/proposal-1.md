---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Command pattern — pure functions return `{model, [cmd]}` pairs

## Approach

Introduce a `Tau.TUI.App.Cmd` type (a tagged union) and change every public
function in `Input` and `quit_or_append/1` in `Keymap` to return
`{model, [Tau.TUI.App.Cmd.t()]}` instead of `model`. A thin dispatch layer in
`Tau.TUI.App` (the existing façade) pattern-matches each command tag and executes
the corresponding `Tau.*` or `spawn/1` call. The pure functions in `Input` and
`Keymap` become total functions with no process dependencies.

## Rationale

The complecting hypothesis names the problem exactly: each function computes a
new model state AND fires a side effect atomically. The command pattern physically
separates the two concerns — the pure function says *what* the effect should be
(a value), and the façade says *when and how* to execute it. The `Input` and
`Keymap` modules become testable against `{model, [cmd]}` tuples with no
processes running. The effect semantics (which `Tau.*` call, what args) are now
explicit in the cmd values, making them inspectable in tests and in the process
mailbox if needed.

## Sketch

```elixir
# lib/tau/tui/app/cmd.ex  (new)
defmodule Tau.TUI.App.Cmd do
  @type t ::
    {:send, session_id :: term(), text :: String.t()}
    | {:cancel, session_id :: term()}
    | {:steer, session_id :: term(), text :: String.t()}
    | {:set_permissions_mode, session_id :: term(), mode :: atom()}
    | :stop_tui_supervisor

  @spec execute(t()) :: :ok
  def execute({:send, sid, text}),             do: Tau.send(sid, text)
  def execute({:cancel, sid}),                 do: Tau.cancel(sid)
  def execute({:steer, sid, text}),            do: Tau.steer(sid, text)
  def execute({:set_permissions_mode, sid, m}),do: Tau.Session.set_permissions_mode(sid, m)
  def execute(:stop_tui_supervisor) do
    spawn(fn ->
      Tau.TUI.Supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} -> Supervisor.stop(pid) end)
    end)
    :ok
  end
end
```

```elixir
# lib/tau/tui/app/input.ex  (modified — excerpt)

@spec submit(map()) :: {map(), [Cmd.t()]}
def submit(model) do
  text = Editor.text(model.editor)
  if Editor.empty?(model.editor) do
    {model, []}
  else
    if String.starts_with?(text, "/perms") do
      handle_perms_command(model, text)
    else
      new_hist = History.push(model.history, text)
      Store.append(model.history_data_dir, model.history_cwd, text)
      new_model = %{model | editor: Editor.new(), history: new_hist,
                            search: nil,
                            transcript: bounded_append(model.transcript, {"> " <> text, []}),
                            status: :sending}
      {new_model, [{:send, model.session_id, text}]}
    end
  end
end

@spec cancel(map()) :: {map(), [Cmd.t()]}
def cancel(model) do
  {%{model | status: :idle}, [{:cancel, model.session_id}]}
end

@spec steer(map()) :: {map(), [Cmd.t()]}
def steer(model) do
  text = Editor.text(model.editor)
  if Editor.empty?(model.editor) do
    {model, []}
  else
    new_model = %{model | editor: Editor.new(), search: nil,
                          transcript: bounded_append(model.transcript, {"[queued steer] " <> text, []})}
    {new_model, [{:steer, model.session_id, text}]}
  end
end
```

```elixir
# lib/tau/tui/app.ex  (façade — dispatch loop addition)
defp run_input(model, fun) do
  {new_model, cmds} = apply(Input, fun, [model])
  Enum.each(cmds, &Cmd.execute/1)
  new_model
end
```

`Keymap.quit_or_append/1` becomes:

```elixir
defp quit_or_append(model) do
  if Editor.empty?(model.editor) do
    {model, [:stop_tui_supervisor]}
  else
    {model |> editor_insert("q") |> Completion.update_menu(), []}
  end
end
```

The `Keymap` functions are `defp`, so the calling chain in `Tau.TUI.App` handles
dispatch; the `{model, cmds}` pair propagates up through the public call boundary.

## Tradeoffs

### Strengths

- Pure functions become trivially unit-testable: assert on `{model, [cmd]}` with
  no process infrastructure.
- Effect semantics are explicit and inspectable (the cmd list is a value, not a
  side effect in a log).
- Pattern: well-established in Elm, Erlang's `gen_statem` reply tuples, and
  Redux-style architectures; reviewers will recognise it.
- The façade (`app.ex`) already exists as the dispatch boundary — the execution
  hook is structurally available.

### Weaknesses

- Every public `Input` function call site changes signature: returns `{model, cmds}`
  instead of `model`. Callers inside `Keymap` that currently delegate to
  `Input.submit/1` must be updated.
- `Keymap` uses `defp` for `quit_or_append/1`, so the `{model, cmds}` return must
  propagate through the entire private call chain in `Keymap` up to its own public
  `handle/2` function — non-trivial refactor.
- `Store.append/3` in `submit/1` is also a side effect (disk I/O / history
  persistence) that is left in the pure path by this proposal — a partial
  decoupling, not a complete one. The problem statement names only `Tau.*` and
  `spawn/1`; history store writes are in-scope but arguably less urgent.
- Adds a new module (`Cmd`) that must be understood by anyone reading the codebase.

### Costs

- Modifies every public function signature in `Input` (5 functions) and the
  internal call chain in `Keymap`.
- The façade `app.ex` gains dispatch boilerplate.
- Tests that currently call `Input.submit(model)` expecting `model` must be
  updated to destructure `{model, _cmds}`.
- Estimated diff: ~120 lines changed, ~40 lines added (Cmd module + dispatch).

## Dependencies

- No behaviour or supervision changes required.
- `Store.append/3` may be left in place (partial clean-up acceptable per
  the problem statement's focus on `Tau.*` and `spawn/1`).

## Confidence

Medium. The pattern is well-understood and the sketch is concrete, but the
`Keymap` private-function propagation path was not fully traced and may have
additional call chains. A prototype pass over `keymap.ex` would raise confidence
to high.

## Prior art / references

- Elm Architecture commands (`Cmd msg`): https://guide.elm-lang.org/effects/
- `:gen_statem` reply tuples — OTP standard; same "actions list" idiom.
- `Phoenix.LiveView` handle_event returning `{:noreply, socket}` — same
  structural pattern at a different abstraction level.
