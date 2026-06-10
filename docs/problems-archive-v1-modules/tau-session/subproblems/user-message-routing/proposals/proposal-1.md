---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Queue.route/3 returns a discriminated action; session.ex clauses become one-liners

## Approach

Add a single pure function `Tau.Session.Queue.route/3` that takes `(msg, tier,
fsm_state_and_data)` and returns one of three tagged tuples:
`{:postpone, fsm_result}`, `{:enqueue, fsm_result}`, or
`{:deliver, classify_result}` — where `classify_result` is the return value of
`SlashCommand.classify_slash_command/4`. The three `handle_event` clauses in
`session.ex` collapse to: one that matches `command_task != nil` and delegates
to `Queue.handle_postpone/2` (already exists); one that matches
`state != :awaiting_user` and delegates to `Queue.handle_enqueue/4` (already
exists); and a third that matches `:awaiting_user` and calls
`Queue.route/3` then a new `SlashCommand.dispatch/2` function on the
`{:deliver, classify_result}` branch. The idle-dispatch clause's six `case`
arms move into `SlashCommand.dispatch/2`.

## Rationale

The complecting is that "should this message queue?" and "what kind of message is
this?" are resolved in the same FSM clause body. `Queue.route/3` resolves the
routing decision in one place and surfaces a typed result to the FSM; the FSM
clause body becomes a pattern-match on that result rather than a nested `case`.
`SlashCommand.dispatch/2` owns the six arms that are the natural complement to
`classify_slash_command/4` — both live in `SlashCommand`, which already has
`handle_builtin_command/4` and `spawn_command_task/4`. The FSM façade becomes a
pure delegation table; the queue and slash-command modules own their full
concern.

## Sketch

```elixir
# lib/tau/session/queue.ex — new function
@spec route(Tau.Message.User.t(), :steering | atom(), atom(), Tau.Session.Data.t()) ::
        {:postpone, Tau.Session.Data.fsm_result()}
        | {:enqueue, Tau.Session.Data.fsm_result()}
        | {:deliver, Tau.Session.SlashCommand.classify_result()}
def route(msg, _tier, _state, %{command_task: t} = data) when t != nil do
  {:postpone, handle_postpone(data, :awaiting_user)}
end
def route(msg, tier, state, data) when state != :awaiting_user do
  {:enqueue, handle_enqueue(msg, tier, state, data)}
end
def route(msg, _tier, :awaiting_user, %{command_task: nil} = data) do
  result = Tau.Session.SlashCommand.classify_slash_command(
    msg, data.skills, data.prompt_templates, data.cwd
  )
  {:deliver, result}
end
```

```elixir
# lib/tau/session/slash_command.ex — new function
@spec dispatch(classify_result(), Tau.Session.Data.t()) :: Tau.Session.Data.fsm_result()
def dispatch({:builtin, mod, args, msg}, data), do: handle_builtin_command(mod, args, msg, data)
def dispatch({:async, mod, args, msg}, data), do: spawn_command_task(mod, args, msg, data)
def dispatch({:skill_activation, skill, rewritten_msg}, data) do
  data2 = Tau.Session.SkillActivation.activate_skill_via_slash(data, skill)
  Tau.Session.process_user_message(rewritten_msg, data2)
end
def dispatch({:model_command, "", _msg}, data) do
  Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: "Current model: #{data.model}"})
  {:keep_state, data}
end
def dispatch({:model_command, new_model, _msg}, data) do
  Tau.Session.ModelSwap.handle_slash_model_swap(data, new_model)
end
def dispatch({:unknown_command, name}, data) do
  notice = "Unknown command #{name} — type /help to list available commands"
  Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})
  {:keep_state, data}
end
def dispatch({:sync, msg}, data) do
  Tau.Session.process_user_message(msg, data)
end
```

```elixir
# lib/tau/session.ex — the three handle_event clauses after the change
def handle_event(:cast, {:user_message, _, _tier}, state, %{command_task: t} = data)
    when t != nil do
  Queue.handle_postpone(data, state)
end

def handle_event(:cast, {:user_message, msg, tier}, state, data)
    when state != :awaiting_user do
  Queue.handle_enqueue(msg, tier, state, data)
end

def handle_event(:cast, {:user_message, msg, _tier}, :awaiting_user, %{command_task: nil} = data) do
  emit_user_message_telemetry(:delivered, data, :awaiting_user)
  {:deliver, result} = Queue.route(msg, :followup, :awaiting_user, data)
  SlashCommand.dispatch(result, data)
end
```

Note: the third clause still calls `emit_user_message_telemetry(:delivered, …)`
before delegating — this is the one piece of telemetry that belongs to the
"message is being delivered" event, distinct from the routing logic. It can be
moved into `Queue.route/3` in a follow-on step; leaving it visible in `session.ex`
for now preserves the existing telemetry contract without the audit touching
telemetry semantics.

## Tradeoffs

### Strengths

- The three `handle_event` clauses each become ≤3 lines; the acceptance
  criterion is met atomically in one PR.
- `Queue.route/3` is a pure function (no side effects in the routing decision
  itself), testable in isolation.
- `SlashCommand.dispatch/2` is colocated with `classify_slash_command/4` and
  `handle_builtin_command/4` — the full slash-command lifecycle lives in one
  module.
- The `{:deliver, result}` tagged tuple provides a typed seam; the return type of
  `Queue.route/3` is machine-checkable with Dialyzer.

### Weaknesses

- `Queue.route/3` calls `SlashCommand.classify_slash_command/4` in its `:deliver`
  branch, creating a cross-module call from `Queue` → `SlashCommand`. This adds a
  dependency that did not previously exist.
- The `:deliver` arm in `session.ex` still calls `emit_user_message_telemetry`
  inline (one LOC), which is not a full delegation. A perfectionist reading of
  the acceptance criterion may count this as "inline telemetry emission in
  session.ex".
- `Queue.route/3`'s guard clauses duplicate the existing `handle_postpone` /
  `handle_enqueue` guards — three functions now encode the same three-way branch.

### Costs

- Two new public functions (`Queue.route/3`, `SlashCommand.dispatch/2`):
  moderate test surface addition.
- Callers of the idle-dispatch clause's six arms in tests will need to be
  traced to confirm they still reach the right path; no signatures break.
- One PR; no migration.

## Dependencies

- `Tau.Session.Queue.handle_postpone/2` and `handle_enqueue/4` (both already
  present in `queue.ex`) are the foundation for the non-idle clauses; no
  changes needed there.
- `Tau.Session.emit_user_message_telemetry/3` must remain public until the
  telemetry call in the idle clause is moved; it's already `@doc false` public.

## Confidence

Medium. The sketch is concrete and matches existing module boundaries; the
`Queue` → `SlashCommand` dependency is the structural uncertainty — it's
directionally odd (queue routing should not know about slash commands). That
concern is addressed in Proposal 2.

## Prior art / references

- Existing `Queue.handle_postpone/2` and `Queue.handle_enqueue/4` in
  `lib/tau/session/queue.ex` — pattern already established for the non-idle
  clauses.
- `SlashCommand.handle_builtin_command/4` and `spawn_command_task/4` — the
  dispatch table arms are already partially in `SlashCommand`.
- Hickey, "Simple Made Easy" — separating routing decisions from dispatch
  actions as the canonical decomplecting move.
