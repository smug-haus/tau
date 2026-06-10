---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: API-breaking split — `on_message_end/2` replaced by two event clauses

## Approach

Treat the transcript-construction concern and the cost/warn-level concern as
two logically independent reactions to `%MessageEnd{}`. Replace the single
`on_message_end/2` handler with two separate `update/2` clauses (or two
`update_session_event/2` sub-clauses): `on_message_end_transcript/2` and
`on_message_end_counters/2`. Both clauses match the same `%MessageEnd{}` struct;
the dispatcher in `update/2` calls them in sequence. Each clause is responsible
for exactly one concern and writes only the model fields it owns:
`on_message_end_transcript/2` writes `:transcript` and `:last_assistant`;
`on_message_end_counters/2` writes `:usage`, `:context_tokens`, `:warn_level`,
and `:status`. The `try/rescue` ETS read is entirely inside
`on_message_end_counters/2`.

## Rationale

The hypothesis is that transcript construction and session-counter aggregation
are triggered by the same event but are independent reactions. This proposal
makes that independence structural by refusing to combine them into one function
at all. Each clause has a narrow type signature: `on_message_end_transcript/2`
depends only on `model.subagents` and `msg.content`; `on_message_end_counters/2`
depends only on `model.session_id`, `model.context_window`, `model.warn_level`,
and the usage field on the message. Neither reads from the other's output — the
independence is now enforced at the function signature level. The `status: :idle`
write is the only shared concern; it is assigned to `on_message_end_counters/2`
as the "final" handler. Axis: **API-breaking (function boundary); control-flow
restructuring; behaviour-preserving at the model level**.

## Sketch

```elixir
# lib/tau/tui/app/events.ex  (on_message_end/2 replaced)

# Dispatcher — replaces the single on_message_end/2 call in update_session_event/2
defp on_message_end(model, e) do
  model
  |> on_message_end_transcript(e)
  |> on_message_end_counters(e)
end

# Concern 1: build transcript lines and clear last_assistant.
# Reads: msg.content, model.subagents.
# Writes: model.transcript, model.last_assistant.
@spec on_message_end_transcript(map(), map()) :: map()
defp on_message_end_transcript(model, %{message: msg}) do
  lines =
    msg.content
    |> Enum.flat_map(fn block ->
      case block do
        %{type: :text,      text: t}              -> [{"[assistant]", []} | Markdown.render(t)]
        %{type: :thinking,  text: t} when t != "" -> [{"[thinking] " <> t, []}]
        %{type: :tool_call, id: tcid, name: n} when is_binary(tcid) ->
          if SubagentTree.tool_call_owned?(model.subagents, tcid), do: [],
                                                                   else: [{"[tool_call] " <> n <> "(...)", []}]
        %{type: :tool_call, name: n}              -> [{"[tool_call] " <> n <> "(...)", []}]
        _                                          -> []
      end
    end)

  model
  |> Map.put(:transcript, bounded_append_many(model.transcript, lines))
  |> Map.put(:last_assistant, nil)
end

# Concern 2: read cost counters, compute warn level, emit telemetry, finalize status.
# Reads: model.session_id, model.context_window, model.warn_level, message.usage.
# Writes: model.usage, model.context_tokens, model.warn_level, model.status.
# The only try/rescue site in this handler set.
@spec on_message_end_counters(map(), map()) :: map()
defp on_message_end_counters(model, %{message: session_msg}) do
  session_counters  = cost_for_session(model.session_id)
  turn_input_tokens = get_in(session_msg, [Access.key(:usage, %{}), :input_tokens]) || 0
  context_window    = Map.get(model, :context_window) ||
                        Application.get_env(:tau, :compaction_threshold_tokens, 120_000)
  pct               = StatusBar.context_pct(turn_input_tokens, context_window)
  new_warn          = StatusBar.warn_level(pct)
  prior_warn        = Map.get(model, :warn_level, :ok)

  if new_warn != prior_warn do
    :telemetry.execute([:tau, :tui, :status, :update],
      %{system_time: System.system_time()},
      %{context_pct: pct, warn_level: new_warn, session_id: model.session_id})
  end

  model
  |> Map.put(:status, :idle)
  |> Map.put(:usage, session_counters)
  |> Map.put(:context_tokens, turn_input_tokens)
  |> Map.put(:warn_level, new_warn)
end
```

## Tradeoffs

### Strengths

- `on_message_end_transcript/2` has no ETS or telemetry dependency; it is
  testable with `model.subagents` and `msg.content` only — satisfies criterion (a).
- `on_message_end_counters/2` has no Markdown content block dependency; it is
  testable with only `model.session_id`, `model.warn_level`, and a usage map —
  satisfies criterion (b).
- `cost_for_session/1` is called only inside `on_message_end_counters/2` — the
  `try/rescue` site is isolated to a bounded scope; satisfies criterion (c).
- The `on_message_end/2` dispatcher makes the call-order explicit and auditable.
- Model writes per function are minimal and non-overlapping; field ownership is
  documented in the `@spec` comments.

### Weaknesses

- `on_message_end_counters/2` still combines ETS read, warn computation, and
  telemetry emit in one function body — it decomplects these from the transcript
  concern but does not separate them from each other. If the acceptance criterion
  is interpreted as requiring each of the four original concerns to be
  independently testable, this proposal leaves ETS and telemetry coupled.
- The `status: :idle` write is assigned to `on_message_end_counters/2` by
  convention, not enforcement — a future author could move it to the transcript
  handler without a compiler error, re-coupling the concerns.
- The two-clause approach will look unusual to readers expecting a single
  handler per event type; the shared `on_message_end/2` dispatcher mitigates
  this but adds a level of indirection.
- Calling two functions in sequence on the model threads the model through both;
  if `on_message_end_counters/2` reads fields set by `on_message_end_transcript/2`
  (or vice versa), the independence assumption is broken. (Currently they do not
  — but this is a fragile invariant.)

### Costs

- ~30 lines of refactor; existing single-function LOC is redistributed across
  two functions plus a thin dispatcher.
- No new modules; no public API changes; no consumer changes.
- Test: two independent unit tests can now drive each sub-handler directly with
  minimal setup.
- `mix dialyzer` enforces the `@spec` contracts on both functions.

## Dependencies

- No other sub-problem resolution required.
- The dispatcher's field-ownership comments are convention; a future code review
  checklist item can verify them.

## Confidence

Medium-high. The refactor is mechanical and the independence of the two concerns
is verifiable by inspecting field reads/writes in the current implementation.
Confidence raises to high after a compile cycle confirms no cross-reads.

## Prior art / references

- Elm `update` pattern: handling the same message type in two reducers is a
  common pattern in message-driven MVU architectures when concerns are logically
  independent but event-triggered simultaneously.
- Tau `Tau.TUI.App.Permission` precedent: `on_permission_request/2` and
  key-routing are split across `Permission` and `Events`/`Keymap` precisely
  because they react to the same input but own different model fields.
