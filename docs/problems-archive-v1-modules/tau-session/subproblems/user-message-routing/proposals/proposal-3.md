---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Introduce a UserMessageRouter behaviour + MessageRouter module; session.ex becomes a three-clause delegation table

## Approach

Introduce a new module `Tau.Session.MessageRouter` that owns the complete
`{:user_message}` routing pipeline: all three routing phases (postpone, enqueue,
idle-dispatch) are implemented as clauses of a single `route/4` function that
matches on `{command_task, state}` tuples. The three `handle_event` clauses in
`session.ex` all delegate to `MessageRouter.route/4`. `MessageRouter` calls
`Queue` for queue operations and `SlashCommand` for classification and dispatch,
but neither `Queue` nor `SlashCommand` has knowledge of the other. A new
`Tau.Session.UserMessageRouter` behaviour with a single callback
`route/4 :: fsm_result()` makes the routing logic swappable (useful for testing
and for future headless-mode variants).

## Rationale

The complecting hypothesis names two separate concerns woven together: the
routing decision and the idle-dispatch table. Both are being moved here, but
into a dedicated coordinator module rather than into an existing module. This
avoids adding queue-routing responsibilities to `SlashCommand` (Proposal 1's
`Queue` → `SlashCommand` dependency) and avoids the 40-LOC monolith in
`dispatch_idle/2` (Proposal 2's weakness). Instead, `MessageRouter` is the
single responsible module for "what happens to a user message before it reaches
a handler?" — the two concerns are decomplected from each other AND from the
FSM. The behaviour makes the seam explicit and Dialyzer-checkable.

## Sketch

```elixir
# lib/tau/session/user_message_router.ex — new behaviour
defmodule Tau.Session.UserMessageRouter do
  @moduledoc """
  Behaviour for routing incoming {:user_message} events in Tau.Session.
  """
  @callback route(
              msg :: Tau.Message.User.t(),
              tier :: :steering | atom(),
              state :: atom(),
              data :: Tau.Session.Data.t()
            ) :: Tau.Session.Data.fsm_result()
end
```

```elixir
# lib/tau/session/message_router.ex — new module
defmodule Tau.Session.MessageRouter do
  @moduledoc """
  Default implementation of Tau.Session.UserMessageRouter.

  Routes {:user_message} events:
  - postpone when command_task != nil (ADR-0008)
  - enqueue when state != :awaiting_user (D-077/D-078)
  - classify-and-dispatch when state == :awaiting_user (D-076 dispatch table)
  """
  @behaviour Tau.Session.UserMessageRouter

  alias Tau.Session.{Queue, SlashCommand}

  @impl Tau.Session.UserMessageRouter
  def route(_msg, _tier, state, %{command_task: t} = data) when t != nil do
    Queue.handle_postpone(data, state)
  end

  def route(msg, tier, state, data) when state != :awaiting_user do
    Queue.handle_enqueue(msg, tier, state, data)
  end

  def route(msg, _tier, :awaiting_user, %{command_task: nil} = data) do
    Tau.Session.emit_user_message_telemetry(:delivered, data, :awaiting_user)
    msg
    |> SlashCommand.classify_slash_command(data.skills, data.prompt_templates, data.cwd)
    |> SlashCommand.dispatch(data)
  end
end
```

```elixir
# lib/tau/session/slash_command.ex — new dispatch/2 (same as Proposal 1 sketch)
@spec dispatch(classify_result(), Tau.Session.Data.t()) :: Tau.Session.Data.fsm_result()
def dispatch({:builtin, mod, args, msg}, data), do: handle_builtin_command(mod, args, msg, data)
def dispatch({:async, mod, args, msg}, data), do: spawn_command_task(mod, args, msg, data)
def dispatch({:skill_activation, skill, rewritten}, data) do
  data2 = Tau.Session.SkillActivation.activate_skill_via_slash(data, skill)
  Tau.Session.process_user_message(rewritten, data2)
end
def dispatch({:model_command, "", _msg}, data) do
  Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: "Current model: #{data.model}"})
  {:keep_state, data}
end
def dispatch({:model_command, model, _msg}, data) do
  Tau.Session.ModelSwap.handle_slash_model_swap(data, model)
end
def dispatch({:unknown_command, name}, data) do
  Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: "Unknown command #{name} — type /help to list available commands"})
  {:keep_state, data}
end
def dispatch({:sync, msg}, data), do: Tau.Session.process_user_message(msg, data)
```

```elixir
# lib/tau/session.ex — three clauses, three delegations
@router Application.compile_env(:tau, :user_message_router, Tau.Session.MessageRouter)

def handle_event(:cast, {:user_message, msg, tier}, state, data) do
  @router.route(msg, tier, state, data)
end
```

Note: the three `handle_event` clauses collapse to ONE, since all routing is
inside `MessageRouter.route/4`. This goes further than the acceptance criterion
(which asks for three ≤3-line clauses) but satisfies it trivially: one 1-line
clause clearly meets the ≤3-line bound.

## Tradeoffs

### Strengths

- A new `@behaviour` makes the routing contract explicit and Dialyzer-checkable.
- The `@router` compile-env injection makes the router swappable in tests —
  test suites can inject a `MockRouter` without spawning a full FSM.
- `MessageRouter` owns the three phases in one place; reading "what happens to a
  user message?" requires reading exactly one module.
- `SlashCommand.dispatch/2` decouples the six arms from both the FSM and the
  routing module — the classify → dispatch pipeline is entirely in `SlashCommand`.
- The three `handle_event` clauses in `session.ex` collapse to a single clause
  — maximal FSM façade simplicity.

### Weaknesses

- Two new modules (`UserMessageRouter` + `MessageRouter`) for logic that could
  fit in one function — introduces abstraction overhead for a problem of
  moderate size.
- The behaviour and compile-env injection add indirection that can confuse
  readers tracing `handle_event` to `MessageRouter.route/4` for the first time.
- `@router Application.compile_env(…)` is a compile-time binding — changing the
  router in a running system requires a recompile. Not a practical concern today,
  but a semantic limitation.
- The `Tau.Session.UserMessageRouter` behaviour has a single callback — minimal
  behaviours of one function can instead be function references; this may be
  over-engineering.
- Requires updating `lib/tau/application.ex` supervision doc comments to mention
  `MessageRouter` if the module performs startup work (it doesn't, but reviewers
  will ask).

### Costs

- Two new modules, one new behaviour, one new `dispatch/2` in `SlashCommand`.
- Test surface: test doubles can use the behaviour — net test complexity is
  moderate.
- PR involves 4 files: `session.ex`, new `message_router.ex`, new
  `user_message_router.ex`, `slash_command.ex`.

## Dependencies

- `SlashCommand.dispatch/2` (new, defined here) — same dependency as Proposal 1.
- `Queue.handle_postpone/2` and `Queue.handle_enqueue/4` (existing).
- `Tau.Session.emit_user_message_telemetry/3` must remain public.

## Confidence

Medium. The behaviour and module structure are established OTP patterns; the
main uncertainty is whether the behaviour abstraction is warranted given the
scope of the problem (a single FSM's routing pipeline). The prior art in Tau
for one-callback behaviours is limited.

## Prior art / references

- `Tau.Session.UserMessageRouter` modelled after `Tau.Provider` behaviour
  pattern — single-callback behaviours for swappable implementations.
- `Application.compile_env/3` injection pattern used in `Tau.Compactor.impl()`
  in `lib/tau/session/slash_command.ex` for test stubbing.
- OTP `:gen_statem` callback delegation via module attribute — used in erlang
  stdlib's `:gen_statem` example modules.
