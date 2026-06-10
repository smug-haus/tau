---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: New `Tau.TUI.App.Transcript` module + explicit `StatusBar.Transition` data shape

## Approach

Extract transcript-line construction into a new public module
`Tau.TUI.App.Transcript`, and introduce a data-shape `StatusBar.Transition.t()`
struct (or a tagged tuple) that carries the warn-level computation result and
the telemetry-emit decision. `on_message_end/2` in `Events` becomes a two-step
orchestration: (1) call `Transcript.from_message/2` to get lines, (2) call a
private `apply_cost_counters/2` that reads ETS and returns a partial model
update, (3) call `StatusBar.maybe_emit/3` which is a new `StatusBar` function
that both computes the new level and conditionally fires telemetry.
The `try/rescue` moves into `Tau.TUI.App.Transcript` or remains in `Events` in
a single-purpose `cost_for_session/1` helper; there is no ambiguity about its
scope.

## Rationale

Creating `Tau.TUI.App.Transcript` as its own module enforces the extraction by
the module system: callers outside `Events` can now depend on it directly.
Naming `StatusBar.maybe_emit/3` puts telemetry emit in the module that owns
the StatusBar concept, not in the generic events handler. The cost ETS access
stays in `Events` as a single named helper; it cannot silently spread because
the transcript module has no `session_id` access. Each concern now has a module
boundary around it, satisfying the acceptance criterion at the type-system level
rather than by naming convention. Axis: **sub-module extraction, data-shape +
interface change, behaviour-preserving**.

## Sketch

```elixir
# NEW: lib/tau/tui/app/transcript.ex

defmodule Tau.TUI.App.Transcript do
  @moduledoc """
  Converts a `%MessageEnd{}` content block list into styled transcript lines
  for the TUI pane.  Pure: no ETS, no telemetry, no session side effects.
  """
  alias Tau.TUI.Render.Markdown
  alias Tau.TUI.SubagentTree

  @type styled_line :: {String.t(), keyword()}

  @doc """
  Returns the list of styled lines to append to `model.transcript`.
  `subagents` is `model.subagents`; `content` is `message.content`.
  """
  @spec from_message([map()], term()) :: [styled_line()]
  def from_message(content_blocks, subagents) do
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
end
```

```elixir
# AMENDED: lib/tau/tui/status_bar.ex  (additive)

@doc """
Computes the warn level for `input_tokens` within `context_window`, emits
`[:tau, :tui, :status, :update]` telemetry IFF the level differs from
`prior_warn`, and returns the new warn level.  Pure side effect: telemetry
only; no ETS, no process state.
"""
@spec maybe_emit(non_neg_integer(), non_neg_integer(), atom()) :: atom()
def maybe_emit(input_tokens, context_window, prior_warn) do
  pct      = context_pct(input_tokens, context_window)
  new_warn = warn_level(pct)
  if new_warn != prior_warn do
    :telemetry.execute([:tau, :tui, :status, :update],
      %{system_time: System.system_time()},
      %{context_pct: pct, warn_level: new_warn})
  end
  new_warn
end
```

```elixir
# AMENDED: lib/tau/tui/app/events.ex  (on_message_end/2 only)

alias Tau.TUI.App.Transcript

defp on_message_end(model, %{message: msg} = e) do
  transcript_lines  = Transcript.from_message(msg.content, model.subagents)
  session_counters  = cost_for_session(model.session_id)
  turn_input_tokens = get_in(e.message, [Access.key(:usage, %{}), :input_tokens]) || 0
  context_window    = Map.get(model, :context_window) ||
                        Application.get_env(:tau, :compaction_threshold_tokens, 120_000)
  new_warn = StatusBar.maybe_emit(turn_input_tokens, context_window, model.warn_level)

  model
  |> Map.put(:status, :idle)
  |> Map.put(:transcript, bounded_append_many(model.transcript, transcript_lines))
  |> Map.put(:last_assistant, nil)
  |> Map.put(:usage, session_counters)
  |> Map.put(:context_tokens, turn_input_tokens)
  |> Map.put(:warn_level, new_warn)
end
```

## Tradeoffs

### Strengths

- `Tau.TUI.App.Transcript` is publicly testable without a live process, ETS
  table, or telemetry handler — satisfies acceptance criterion (a) definitively.
- `StatusBar.maybe_emit/3` groups the telemetry concern with the module that
  owns the StatusBar concept, making the emit testable via `:telemetry.attach`
  without any markdown or ETS state.
- Module system enforces the boundary: `Transcript` cannot accidentally call
  `Tau.Cost` (it has no alias).
- `cost_for_session/1` in `Events` remains the sole `try/rescue` site;
  criterion (c) is met.

### Weaknesses

- Adding `maybe_emit/3` to `StatusBar` adds a side-effecting function to what
  is currently (presumably) a pure computation module — mixing concerns at the
  `StatusBar` level if callers outside `Events` ever use it without telemetry.
- `StatusBar.maybe_emit/3` omits `session_id` from the telemetry metadata
  compared to the current implementation (the current emit includes
  `session_id: model.session_id`). Restoring it requires passing `session_id`
  as a fourth argument, or accepting metadata regression.
- New module (`Transcript`) requires a new file and `mix format` pass; small
  bureaucratic overhead.
- `StatusBar` amendment touches a SPEC-TUI-HEADLESS module; requires checking
  whether the new function needs a D-NNN.

### Costs

- 1 new file: `lib/tau/tui/app/transcript.ex` (~35 LOC).
- 1 amended file: `lib/tau/tui/status_bar.ex` (~12 LOC added).
- 1 amended file: `lib/tau/tui/app/events.ex` (~10 LOC changed).
- Test files: 1 new unit test module for `Transcript`; 1 new test for
  `StatusBar.maybe_emit/3`.
- SPEC-TUI-HEADLESS Appendix B must add `Transcript` to the source map.

## Dependencies

- No sibling sub-problem resolution required.
- `StatusBar` module must not have a `maybe_emit` function already (verify
  before landing).

## Confidence

Medium. The module split is idiomatic Elixir; the `StatusBar.maybe_emit/3`
design decision (where does `session_id` live?) is the open question that lowers
confidence below high. A prototype resolves it in < 30 minutes.

## Prior art / references

- Phoenix LiveView component extraction pattern: rendering concerns extracted
  to dedicated component modules with explicit assigns contracts.
- Tau precedent: `Tau.TUI.SubagentTree` was extracted from `Events` under a
  similar rationale (concerns owned by a dedicated module).
