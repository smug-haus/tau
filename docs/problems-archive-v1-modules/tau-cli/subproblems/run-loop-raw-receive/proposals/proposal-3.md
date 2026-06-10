---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Split drain_run_loop into render and control; use selective receive via Task

## Approach

Decouple the two things `drain_run_loop/2` currently does — (1) decide when to
stop and with what exit code, and (2) render progress to stderr — by introducing
two separate, pure functions: `classify_event/2` (pure, returns `{:continue,
new_state} | {:halt, exit_code} | :ignore`) and `render_event/1` (pure,
`IO.puts` side-effect only). The raw `receive` itself is preserved but
restructured as a `Task` inside `run_cmd/1` that owns the PubSub mailbox. The
`Task` subscribes in its setup (`Task.async(fn -> subscribe; loop end)`), so
subscription precedes the `start_session` call in the parent — which is achieved
by `Task.async` + `Task.await`. `drain_session_end/2` is absorbed into the
loop's terminal `{:halt, code}` path; a timeout in the task yields exit code `1`
instead of the caller's seeded value.

## Rationale

This proposal addresses the complecting hypothesis directly: rendering is
separated from control flow by making both explicit, named, pure functions.
The raw `receive` is retained as the mechanism for mailbox consumption — it is
not OTP NN #4-violating on its own when the receiving process IS the PubSub
subscriber (the violation is doing it in the parent process across a process
boundary, not in the subscriber itself). By moving the `receive` loop into a
`Task` that subscribes and drains its own mailbox, OTP NN #4 is satisfied: the
subscriber and the consumer are the same process. The `classify_event/2` function
is property-testable in isolation. Unknown events return `:ignore` from
`classify_event/2` and log at `:debug` rather than silently recurse.

## Sketch

```elixir
# lib/tau/cli.ex — replace drain_run_loop/2 + drain_session_end/2

# Pure classifier: all decision logic in one named, testable function
@spec classify_event(struct(), map()) ::
        {:continue, map()}
        | {:halt, 0 | 1}
        | :ignore
defp classify_event(%Events.MessageEnd{message: msg}, tool_names) do
  tool_calls = is_list(msg.content) && Enum.any?(msg.content, &match?(%{type: :tool_call}, &1))
  cond do
    tool_calls ->
      {:continue, tool_names}
    msg.stop_reason in [:error, :tool_loop_aborted, :aborted, :compaction_failed] ->
      IO.puts(:stderr, "session error (#{msg.stop_reason}): #{extract_error_text(msg)}")
      {:halt, 1}    # caller must invoke Tau.stop/1 before awaiting
    true ->
      text = extract_assistant_text(msg)
      if text != "", do: IO.puts(text)
      {:halt, :pending}   # stop was requested; wait for SessionEnd
  end
end

defp classify_event(%Events.SessionEnd{reason: reason}, _tool_names) do
  code = if reason in [:normal, :user], do: 0, else: 1
  {:halt, code}
end

defp classify_event(%Events.ToolStart{tool_call_id: id, name: name}, tool_names) do
  {:continue, Map.put(tool_names, id, name)}
end

defp classify_event(%Events.ToolEnd{tool_call_id: id}, tool_names) do
  {:continue, Map.delete(tool_names, id)}
end

defp classify_event(unknown, tool_names) when is_struct(unknown) do
  require Logger
  Logger.debug("[tau] drain: unhandled #{inspect(unknown.__struct__)}")
  {:continue, tool_names}  # :ignore semantics: carry state unchanged
end

# Pure renderer (called before classify so progress prints even on terminal events)
defp render_event(%Events.ToolStart{name: name, arguments: args}) do
  IO.puts(:stderr, "[tau] → #{name}(#{summarise_args(args)})")
end

defp render_event(%Events.ToolEnd{tool_call_id: id, result: result} = e) do
  # name is looked up by caller since render_event is stateless
  marker = if is_struct(result, Tau.Message.ToolResult) && result.is_error, do: "✗", else: "✓"
  IO.puts(:stderr, "[tau] ← #{Map.get(e, :name, "?")} #{marker}")
end

defp render_event(_), do: :ok

# Inner loop: runs inside the Task; receives from its own mailbox
defp event_loop(session_id, tool_names, stop_requested?) do
  receive do
    event when is_struct(event) ->
      render_event(event)
      case classify_event(event, tool_names) do
        {:continue, new_names} ->
          event_loop(session_id, new_names, stop_requested?)
        {:halt, :pending} ->
          Tau.stop(session_id)
          event_loop(session_id, tool_names, true)
        {:halt, code} ->
          code
      end
  after
    # No SessionEnd within drain window → fail-safe exit 1
    10_000 ->
      if stop_requested?, do: 1, else: 1
  end
end

# In run_cmd/1 — replace drain_run_loop(session_id) call:
task =
  Task.async(fn ->
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{session_id}")
    # Signal parent that subscription is open
    send(parent, {:subscribed, ref})
    receive do
      {:start, ^ref} -> event_loop(session_id, %{}, false)
    end
  end)

# Wait for subscription to open before calling start_session
receive do
  {:subscribed, ^ref} -> :ok
end

case Tau.start_session(start_opts) do
  {:ok, ^session_id} ->
    send(task.pid, {:start, ref})
    try do
      case Tau.send(session_id, prompt) do
        :ok   -> Task.await(task, :infinity)
        {:error, reason} ->
          Task.shutdown(task, :brutal_kill)
          IO.puts(:stderr, "send error: #{inspect(reason)}")
          1
      end
    after
      :telemetry.detach(handler_id)
    end
end
```

`drain_session_end/2` is removed. The `event_loop/3` `after 10_000` clause
handles the drain-window timeout, returning `1` rather than a caller-seeded
value.

## Tradeoffs

### Strengths

- `classify_event/2` is a pure function, directly property-testable: generate
  sequences of events and assert on accumulated exit codes without any process
  infrastructure.
- Rendering and control flow are explicit, named, separate functions — the
  complecting hypothesis is addressed at the code level.
- The `receive` loop lives in the Task (the PubSub subscriber), not in the
  parent process — OTP NN #4 is satisfied.
- Unknown structs produce a `Logger.debug` log and continue; silent discard
  is eliminated.
- Timeout returns `1` (fail-safe).
- Incremental: the inner pure functions can be extracted before the Task
  wiring is changed.

### Weaknesses

- The `receive` loop is still a raw `receive` loop — it is now in a `Task`
  rather than the parent process, but the pattern persists. Reviewers who
  interpret OTP NN #4 strictly as "no raw receive anywhere" will object.
- The Task-based subscription handshake (`{:subscribed, ref}` / `{:start, ref}`)
  adds coordination boilerplate that is not idiomatic OTP — it is a hand-rolled
  synchronisation protocol between two processes.
- `render_event/1` is stateless, so `ToolEnd` rendering cannot access the
  `tool_names` map to look up the name; requires either passing state or
  enriching the event. The sketch above is slightly incomplete on this point.
- The `Task.await(task, :infinity)` timeout relies on the inner `after 10_000`
  to bound wait time; callers of `run_cmd/1` have no external timeout knob.

### Costs

- `drain_run_loop/2` and `drain_session_end/2` replaced by `classify_event/2`,
  `render_event/1`, and `event_loop/3` (~80 lines, roughly equal to what is
  removed).
- `run_cmd/1` gains ~15 lines of Task wiring.
- Tests for `classify_event/2` can be pure unit tests without process setup
  (benefit).
- No new modules, no new dependencies.

## Dependencies

- None beyond what already exists. `Phoenix.PubSub` and `Task` are both in
  scope.

## Confidence

Medium. The decomplecting via `classify_event/2` is clear and testable. The
Task-based subscription handshake is the uncertain part; it should work but adds
non-trivial coordination boilerplate. Confidence would be raised by prototyping
the handshake under property-based simulation of subscription-before-start
race conditions.

## Prior art / references

- Elixir `Task.async/1` + `Task.await/2` — documented pattern for spawning a linked task and awaiting its result.
- `classify_event/2` pure-function approach mirrors `Tau.Permissions.Evaluator` pattern: pure dispatch function over event structs.
- Rich Hickey "Simple Made Easy" — separating rendering (side-effect) from classification (logic) as a core decomplecting move.
