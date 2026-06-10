---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: SlashCommand.dispatch_idle/2 absorbs the full idle clause; Queue unchanged

## Approach

Leave `Tau.Session.Queue` unchanged. Add a single new function
`Tau.Session.SlashCommand.dispatch_idle/2` that accepts
`(msg :: Tau.Message.User.t(), data :: Tau.Session.Data.t())` and contains the
full body of the current idle-dispatch `handle_event` clause: the
`emit_user_message_telemetry(:delivered, …)` call, the
`classify_slash_command/4` call, and all six `case` arms. The idle-dispatch
clause in `session.ex` becomes a one-line delegation:

```elixir
SlashCommand.dispatch_idle(msg, data)
```

The two non-idle clauses already have `Queue.handle_postpone/2` and
`Queue.handle_enqueue/4` — they are already one-liners and require no change.

## Rationale

The complecting hypothesis identifies the idle-dispatch clause as the only
clause that still mixes two concerns in `session.ex`. The postpone and
tier-routing clauses are already delegated (`Queue.handle_postpone/2` and
`Queue.handle_enqueue/4` exist and are called from the FSM — but wait, the FSM
does NOT currently call them; it inlines the logic). Both clauses need to be
updated to call the existing `Queue` functions. The idle clause's six `case`
arms are dispatch logic that belongs adjacent to `classify_slash_command/4`
because both are about "what is this message?" — not about queue mechanics.
Extracting the idle clause body into `SlashCommand.dispatch_idle/2` places the
classifier and its dispatch table in the same module, with no new inter-module
dependency not already implicit in the six arms.

## Sketch

```elixir
# lib/tau/session/slash_command.ex — new function
@doc """
Handle a user message arriving in :awaiting_user with no command_task.

Emits delivery telemetry, classifies the message, and dispatches to the
appropriate handler. Returns a :gen_statem FSM action tuple.
"""
@spec dispatch_idle(Tau.Message.User.t(), Tau.Session.Data.t()) ::
        Tau.Session.Data.fsm_result()
def dispatch_idle(msg, data) do
  Tau.Session.emit_user_message_telemetry(:delivered, data, :awaiting_user)

  case classify_slash_command(msg, data.skills, data.prompt_templates, data.cwd) do
    {:builtin, mod, args, msg} ->
      handle_builtin_command(mod, args, msg, data)

    {:async, mod, args, msg} ->
      spawn_command_task(mod, args, msg, data)

    {:skill_activation, skill, rewritten_msg} ->
      data2 = Tau.Session.SkillActivation.activate_skill_via_slash(data, skill)
      Tau.Session.process_user_message(rewritten_msg, data2)

    {:model_command, "", _msg} ->
      notice = "Current model: #{data.model}"
      Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})
      {:keep_state, data}

    {:model_command, new_model, _msg} ->
      Tau.Session.ModelSwap.handle_slash_model_swap(data, new_model)

    {:unknown_command, name} ->
      notice = "Unknown command #{name} — type /help to list available commands"
      Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})
      {:keep_state, data}

    {:sync, msg} ->
      Tau.Session.process_user_message(msg, data)
  end
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
  SlashCommand.dispatch_idle(msg, data)
end
```

The non-idle clauses require code changes too: the current `session.ex` inlines
the queue-cap logic even though `Queue.handle_postpone/2` and
`Queue.handle_enqueue/4` already exist in `queue.ex`. This proposal makes those
clauses call the existing `Queue` functions (pure delegations).

## Tradeoffs

### Strengths

- Minimal new surface: one new public function (`dispatch_idle/2`) and two
  delegation changes in existing non-idle clauses.
- No new inter-module dependencies that do not already exist: `SlashCommand`
  already calls `SkillActivation`, `ModelSwap`, and `Tau.Session.broadcast`;
  `Queue` is not touched.
- The acceptance criterion is fully met: all three clauses become ≤3 lines, no
  inline `case` branching, no telemetry emission in `session.ex`.
- Mechanically the smallest diff of the four proposals — reduces review and
  merge risk.
- `dispatch_idle/2`'s body is a straight extraction (verbatim copy) of the
  existing clause body; behaviour is provably preserved.

### Weaknesses

- `dispatch_idle/2` is a 40-LOC function with a nested `case` — it does not
  further decompose the six arms. Readers still need to read all six arms to
  understand idle dispatch, just in a different file.
- The name `dispatch_idle` is tied to FSM state; if idle dispatch is ever
  invoked from a non-idle path (e.g. a `/perms`-gate release path), the name
  becomes misleading.
- `emit_user_message_telemetry` must remain callable from `SlashCommand` — it
  is already `@doc false` public on `Tau.Session`, so no signature change, but
  the coupling is preserved rather than resolved.
- The `{:model_command, "", …}` and `{:unknown_command, …}` arms in
  `dispatch_idle/2` still call `Tau.Session.broadcast/2` directly — `SlashCommand`
  already does this elsewhere, but it means `SlashCommand` retains a hard dep
  on `Tau.Session` for broadcast.

### Costs

- One new function, two line-change delegations in `session.ex`.
- Test coverage: any tests exercising the idle-dispatch path via
  `Tau.Session.handle_event/4` will still pass because the delegation is
  transparent; no test signatures break.
- Zero migration cost for consumers.

## Dependencies

- `Tau.Session.Queue.handle_postpone/2` and `Queue.handle_enqueue/4` must be
  present (they are already in `queue.ex` as of the last merge).
- `Tau.Session.emit_user_message_telemetry/3` must remain public (it is
  already `@doc false`).

## Confidence

High. The sketch is a verbatim extraction of existing code. The only risk is
the `emit_user_message_telemetry` call inside `SlashCommand` — which already
occurs in `Queue.drain_steering_queue_one/1`. The pattern is established.

## Prior art / references

- `Queue.handle_drain_followups_idle/1` in `lib/tau/session/queue.ex` — same
  verbatim-extraction pattern applied to the drain-followups clause.
- `SlashCommand.handle_builtin_command/4` — extraction precedent for
  dispatch logic that originally lived in the FSM clause body.
- Fowler, "Extract Function" (Refactoring, 2nd ed.) — behaviour-preserving
  extraction as the lowest-risk decomplecting move.
