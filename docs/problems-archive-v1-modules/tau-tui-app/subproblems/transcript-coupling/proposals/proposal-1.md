---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Extract three named private functions inside `Events`

## Approach

Split `on_message_end/2` into three composed private helpers, all still in
`Tau.TUI.App.Events`:

- `build_transcript_lines/2` — takes `msg.content` and `model.subagents`;
  returns `[{text, attrs}]`; has no ETS or telemetry dependency.
- `read_cost_counters/1` — takes `session_id`; wraps `cost_for_session/1`
  (the existing `try/rescue` helper, unchanged); returns the counters map.
- `compute_and_emit_warn/3` — takes `new_context_tokens`, `model.context_window`,
  and `model.warn_level`; computes `pct` and `new_warn`; fires telemetry if the
  level changed; returns `{new_warn, pct}`.

`on_message_end/2` becomes an orchestrator: call the three helpers in order,
then assemble the updated model fields with a single `Map.merge/2` or a chain
of struct field assignments.

## Rationale

The four concerns share no data: transcript line building reads only `msg.content`
and `model.subagents`; the cost read uses only `session_id`; the warn computation
uses only the token counts and the prior warn level. Splitting them into named
helpers separates the type signatures and makes each independently callable from
a unit test. The `try/rescue` for ETS unavailability remains in `cost_for_session/1`
(already isolated) and is not widened. No module boundaries move, so there is no
ripple through consumers. The diversity axis is: **extraction within the same
file, control-flow change, behaviour-preserving, incremental**.

## Sketch

```elixir
# lib/tau/tui/app/events.ex  (changed section only)

defp on_message_end(model, %{message: msg} = e) do
  transcript_lines  = build_transcript_lines(msg.content, model.subagents)
  session_counters  = read_cost_counters(model.session_id)
  turn_input_tokens = get_in(e.message, [Access.key(:usage, %{}), :input_tokens]) || 0
  {new_warn, _pct}  = compute_and_emit_warn(turn_input_tokens, model, model.warn_level)

  model
  |> Map.put(:status, :idle)
  |> Map.put(:transcript, bounded_append_many(model.transcript, transcript_lines))
  |> Map.put(:last_assistant, nil)
  |> Map.put(:usage, session_counters)
  |> Map.put(:context_tokens, turn_input_tokens)
  |> Map.put(:warn_level, new_warn)
end

# Pure: no ETS, no telemetry
@spec build_transcript_lines([map()], term()) :: [{String.t(), keyword()}]
defp build_transcript_lines(content_blocks, subagents) do
  Enum.flat_map(content_blocks, fn block ->
    case block do
      %{type: :text,      text: t}              -> [{"[assistant]", []} | Markdown.render(t)]
      %{type: :thinking,  text: t} when t != "" -> [{"[thinking] " <> t, []}]
      %{type: :tool_call, id: tcid, name: n} when is_binary(tcid) ->
        if SubagentTree.tool_call_owned?(subagents, tcid), do: [],
                                                           else: [{"[tool_call] " <> n <> "(...)", []}]
      %{type: :tool_call, name: n}              -> [{"[tool_call] " <> n <> "(...)", []}]
      _                                          -> []
    end
  end)
end

# Isolated ETS access; try/rescue stays here only
@spec read_cost_counters(term()) :: map()
defp read_cost_counters(session_id), do: cost_for_session(session_id)

# Pure computation + conditional side effect
@spec compute_and_emit_warn(non_neg_integer(), map(), atom()) :: {atom(), float()}
defp compute_and_emit_warn(input_tokens, model, prior_warn) do
  pct      = StatusBar.context_pct(input_tokens,
               Map.get(model, :context_window) ||
                 Application.get_env(:tau, :compaction_threshold_tokens, 120_000))
  new_warn = StatusBar.warn_level(pct)

  if new_warn != prior_warn do
    :telemetry.execute([:tau, :tui, :status, :update],
      %{system_time: System.system_time()},
      %{context_pct: pct, warn_level: new_warn, session_id: model.session_id})
  end

  {new_warn, pct}
end
```

## Tradeoffs

### Strengths

- Zero-disruption: no public API changes, no new modules, no moved files.
- `build_transcript_lines/2` is now testable with a plain list and a stub tree;
  no ETS setup required.
- `compute_and_emit_warn/3` is testable by asserting telemetry events and the
  returned `{warn, pct}` tuple.
- The `try/rescue` stays confined to one named private function.
- Acceptance criterion (a), (b), (c) all satisfied.

### Weaknesses

- Concerns are still in the same file; a future author can re-couple by inlining
  helpers back into `on_message_end/2` with no friction.
- `compute_and_emit_warn/3` still mixes computation and telemetry side effect;
  they remain in one function, just named.
- `build_transcript_lines/2` is not reusable outside `Events` (private);
  extraction would require making it public or moving the module.
- Offers no enforcement mechanism — the separation is convention, not type-level.

### Costs

- ~20 lines of refactor to split the function; ~0 lines of new logic.
- Existing tests (if any) require no changes; new unit tests are unblocked.
- No consumer changes; no SPEC amendment required (D-168/D-169 contract unchanged).

## Dependencies

- No other sub-problem resolution required.
- `cost_for_session/1` private helper already exists; no change needed.

## Confidence

Medium. The refactor is mechanical and reversible, but without running
`mix test` the exact struct-field access pattern cannot be verified.
Confidence raises to high after a compile-and-test cycle.

## Prior art / references

- Elixir community convention: private helper extraction within a single module
  for testability (see José Valim's "Testing Elixir" Chapter 3 patterns).
- The existing `cost_for_session/1` helper in this file is a prior instance of
  this pattern (ETS access isolated in a named private function).
