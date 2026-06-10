---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Data-shape change — `MessageEndResult` intermediate struct

## Approach

Introduce a new private struct `%Tau.TUI.App.Events.MessageEndResult{}` that
represents the fully-computed output of processing a `%MessageEnd{}` event,
before it is merged into the model. The three concerns become three functions
that each return a field-set of the struct rather than mutating the model
directly. `on_message_end/2` becomes a pipeline that (1) constructs an empty
`%MessageEndResult{}`, (2) pipelines it through `with_transcript_lines/3`,
`with_cost_counters/2`, and `with_warn_level/2`, and (3) applies the struct
to the model in a single `merge_result/2` step. The `try/rescue` remains in
`with_cost_counters/2` only.

## Rationale

The current `on_message_end/2` co-locates four concerns because they all need
to write to the model, so it is convenient to thread the model through all of
them. The intermediate struct breaks this coupling at the data-shape level: each
builder function produces a partial result, not a model mutation. This makes the
data dependency between concerns explicit (none of them reads from another's
output, which the struct makes structurally visible). It also means each builder
function can be tested with only the inputs it actually needs — no live model
with ETS backing required. The approach axis is: **data-shape change;
behaviour-preserving; atomic**.

## Sketch

```elixir
# lib/tau/tui/app/events.ex  (additions within the existing module)

# Intermediate accumulator — not part of public API.
defmodule __MODULE__.MessageEndResult do
  @enforce_keys [:transcript_lines, :session_counters, :context_tokens, :warn_level]
  defstruct [:transcript_lines, :session_counters, :context_tokens, :warn_level]

  @type t :: %__MODULE__{
    transcript_lines: [{String.t(), keyword()}],
    session_counters: map(),
    context_tokens:   non_neg_integer(),
    warn_level:       :ok | :warn | :error
  }
end

alias __MODULE__.MessageEndResult

defp on_message_end(model, %{message: msg} = e) do
  result =
    %MessageEndResult{
      transcript_lines: [],
      session_counters: %{},
      context_tokens:   0,
      warn_level:       :ok
    }
    |> with_transcript_lines(msg.content, model.subagents)
    |> with_cost_counters(model.session_id)
    |> with_warn_level(e.message, model)

  merge_result(model, result)
end

# --- builders ---

@spec with_transcript_lines(MessageEndResult.t(), [map()], term()) :: MessageEndResult.t()
defp with_transcript_lines(result, content_blocks, subagents) do
  lines = Enum.flat_map(content_blocks, fn block ->
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
  %{result | transcript_lines: lines}
end

@spec with_cost_counters(MessageEndResult.t(), term()) :: MessageEndResult.t()
defp with_cost_counters(result, session_id) do
  %{result | session_counters: cost_for_session(session_id)}
end

# D-168/D-169: context_tokens = latest turn's input_tokens; emit telemetry on transition.
@spec with_warn_level(MessageEndResult.t(), map(), map()) :: MessageEndResult.t()
defp with_warn_level(result, session_msg, model) do
  turn_input_tokens = get_in(session_msg, [Access.key(:usage, %{}), :input_tokens]) || 0
  pct = StatusBar.context_pct(
    turn_input_tokens,
    Map.get(model, :context_window) ||
      Application.get_env(:tau, :compaction_threshold_tokens, 120_000)
  )
  new_warn  = StatusBar.warn_level(pct)
  prior_warn = Map.get(model, :warn_level, :ok)

  if new_warn != prior_warn do
    :telemetry.execute([:tau, :tui, :status, :update],
      %{system_time: System.system_time()},
      %{context_pct: pct, warn_level: new_warn, session_id: model.session_id})
  end

  %{result | context_tokens: turn_input_tokens, warn_level: new_warn}
end

# Apply all fields from result to model in one place.
@spec merge_result(map(), MessageEndResult.t()) :: map()
defp merge_result(model, result) do
  model
  |> Map.put(:status, :idle)
  |> Map.put(:transcript, bounded_append_many(model.transcript, result.transcript_lines))
  |> Map.put(:last_assistant, nil)
  |> Map.put(:usage, result.session_counters)
  |> Map.put(:context_tokens, result.context_tokens)
  |> Map.put(:warn_level, result.warn_level)
end
```

## Tradeoffs

### Strengths

- Each builder function has an explicit type contract — the `@enforce_keys`
  struct prevents partial construction from compiling silently.
- `with_transcript_lines/3` takes only `content_blocks` and `subagents` — no
  ETS or model threading; satisfies criterion (a).
- `with_warn_level/3` takes only `session_msg` and `model` (for prior warn) —
  no Markdown or ETS; satisfies criterion (b).
- `cost_for_session/1` remains the sole `try/rescue` site; criterion (c) is met.
- `merge_result/2` is the single callsite where model mutation happens; easier
  to audit for correctness.
- Stays in one file; no new module boundaries; minimal churn for consumers.

### Weaknesses

- `MessageEndResult` is an internal struct that exists only to make a single
  private function pipeline cleaner. Reviewers unfamiliar with the pattern may
  question whether a struct is over-engineering for a single function.
- The struct is defined as a nested module (`__MODULE__.MessageEndResult`),
  which works in Elixir but is an uncommon pattern and may surprise readers.
  An alternative is a plain map with known keys, but that loses the compile-time
  enforcement.
- `with_warn_level/3` still receives `model` as its third argument, which
  partially re-threads the model. Acceptance criterion (b) is met (no Markdown
  content block), but the model is still a dependency.
- Pattern is internal; if `Events` is later split into smaller modules, the
  private struct has no natural new home.

### Costs

- ~50 lines added to `events.ex`; the function is split into 4 named helpers
  plus a struct definition.
- No new files; no new public APIs; no consumer changes.
- `mix dialyzer` will validate the struct field types; adds compile-time
  checking but no runtime cost.
- New unit tests can drive `with_transcript_lines/3` and `with_warn_level/3`
  in isolation.

## Dependencies

- Elixir 1.18.1 `@enforce_keys` — already in use in the project.
- No other sub-problem resolution required.

## Confidence

Medium. The pattern is standard Elixir; the open question is whether the nested
`__MODULE__.MessageEndResult` struct name is acceptable to the project's Credo
or style conventions. Can be verified with `mix credo --strict` in < 5 minutes.

## Prior art / references

- Elixir `Ecto.Changeset` uses an intermediate struct to accumulate
  transformation results before applying them; this proposal borrows the
  accumulator pattern.
- `Tau.TUI.App.Completion` and `Tau.TUI.App.History` return plain structs that
  are merged back into the model — the "partial result struct" pattern already
  exists in the codebase at the module level.
