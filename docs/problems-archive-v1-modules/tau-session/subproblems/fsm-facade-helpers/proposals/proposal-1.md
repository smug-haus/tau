---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Tau.Session.Helpers — one new shared-utility module

## Approach

Introduce a single new module `lib/tau/session/helpers.ex` that absorbs all eight `@doc false` functions verbatim from `session.ex`: `broadcast/2`, `append_message/2`, `generate_event_id/0`, `transition/3`, `emit_user_message_telemetry/3`, `hook_payload/3`, `transcript_path/1` (promoted from `defp` to `defp` inside `Helpers`, or to `def` if sub-modules need it), and `process_user_message/2`. Every callsite in `session.ex` and in sub-modules (`SlashCommand`, `ProviderTurn`, `CodingAgentTurn`, `ToolDispatch`, `Compaction`, `ModelSwap`) is updated to `Tau.Session.Helpers.<fn>(...)`. The `@doc false` annotations on `session.ex` are removed; the functions on `session.ex` themselves are removed.

`register_builtins/0` (currently the last `@doc false` function, line 1426) is also removed from `session.ex` and placed in `Helpers` if it is a shared utility, or dropped back into `session.ex` as a `defp` if it is called only from `init/1`.

## Rationale

The complecting is structural: utilities live on the `:gen_statem` module because there was no shared home at extraction time. The simplest decomplecting is to create that home. A single `Helpers` module is the minimal intervention — one file, one alias to add per sub-module, zero new abstractions. It does not impose a concern taxonomy (which may be premature) and does not require coordinating changes across multiple existing modules. The acceptance criterion is satisfied: `session.ex` has no `@doc false` functions; sub-modules call `Tau.Session.Helpers` directly.

The `process_user_message/2` placement in `Helpers` is a tactical compromise: it still calls `handle_event/4` internally, so it cannot move far from the FSM boundary. Housing it in `Helpers` documents the awkward coupling explicitly without resolving it, which is acceptable because the user-message-routing sub-problem is out of scope here.

## Sketch

```
# New file: lib/tau/session/helpers.ex
defmodule Tau.Session.Helpers do
  @moduledoc """
  Shared internal utilities used across `Tau.Session` sub-modules.
  Not part of the public `Tau.Session` API.
  """

  alias Tau.Session.Events
  alias Phoenix.PubSub

  @spec broadcast(String.t(), struct()) :: :ok | {:error, term()}
  def broadcast(id, event) do
    PubSub.broadcast(Tau.PubSub, "session:#{id}", event)
  end

  @spec append_message(map(), Tau.Message.t()) :: map()
  def append_message(data, msg), do: %{data | messages: data.messages ++ [msg]}

  @spec generate_event_id() :: String.t()
  def generate_event_id do
    case Code.ensure_loaded?(Uniq.UUID) do
      true -> apply(Uniq.UUID, :uuid7, [])
      _ -> "evt_" <> (:crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false))
    end
  end

  @spec transition(String.t(), map(), atom()) :: :ok
  def transition(id, _data, to) do
    :telemetry.execute([:tau, :session, :transition], %{system_time: System.system_time()}, %{
      session_id: id,
      to: to
    })
    :ok
  end

  @spec emit_user_message_telemetry(atom(), map(), atom()) :: :ok
  def emit_user_message_telemetry(event, data, state) do
    :telemetry.execute(
      [:tau, :session, :user_message, event],
      %{system_time: System.system_time()},
      %{session_id: data.id, from_state: state}
    )
  end

  @spec hook_payload(map(), atom(), map()) :: map()
  def hook_payload(data, event, extras) when is_map(extras) do
    Map.merge(
      %{
        session_id: data.id,
        cwd: data.cwd,
        permission_mode: Map.get(data.metadata, :permissions_mode, :default),
        hook_event_name: to_string(event),
        transcript_path: transcript_path(data),
        metadata: data.metadata || %{}
      },
      extras
    )
  end

  defp transcript_path(%{persistence: p, id: id, cwd: cwd}), do: p.path_for(id, cwd)

  # process_user_message/2 re-enters handle_event/4; it is placed here
  # to remove it from session.ex's public surface, not to resolve the
  # routing coupling (that is the user-message-routing sub-problem).
  @spec process_user_message(Tau.Message.t(), map()) :: term()
  def process_user_message(msg, data) do
    # … verbatim body from session.ex lines 1311–1341 …
  end
end
```

```
# In each sub-module, add at top:
alias Tau.Session.Helpers

# Replace every Tau.Session.broadcast(...) call:
Helpers.broadcast(id, event)

# Replace every Tau.Session.append_message(...) call:
Helpers.append_message(data, msg)
# etc.
```

File move summary:
- `lib/tau/session.ex` — remove 8 `@doc false` defs (lines ~1291–1438, minus `register_builtins/0`)
- `lib/tau/session/helpers.ex` — new file, ~80 LOC

## Tradeoffs

### Strengths

- Minimal diff surface: one new file, callsite substitutions in ~6 sub-modules, no structural reorganisation.
- Satisfies the acceptance criterion completely and atomically.
- No new taxonomy decisions: a single module is easier to understand than a partitioned set.
- `transcript_path/1` can remain `defp` inside `Helpers` — does not need to be promoted.
- Low risk of breakage: functions are moved verbatim; no logic changes.

### Weaknesses

- `Helpers` is a grab-bag module — it mixes PubSub broadcasting, telemetry emission, data mutation, UUID generation, and hook-payload construction under one roof. The concern boundary is "not session.ex" rather than a coherent responsibility.
- `process_user_message/2` in `Helpers` retains the internal `handle_event/4` call; it is still awkwardly coupled to the FSM even in the new location.
- The module name `Helpers` is a known anti-pattern signal ("Util", "Common", "Helpers" modules tend to grow into grab-bags over time).
- Offers no guidance for future contributors on where new shared utilities belong.

### Costs

- ~6 sub-modules need an `alias Tau.Session.Helpers` added and callsites updated.
- `session.ex` callsites (e.g. in the cancel clauses, in `process_user_message/2` itself) also need updating.
- Estimate: ~25–35 line changes across 7–8 files, plus the new ~80 LOC file.
- No new dependencies; no interface changes visible to external callers.

## Dependencies

- None. All eight functions are self-contained moves; no other sub-module needs to be changed first.

## Confidence

medium — the approach is straightforward, but the `process_user_message/2` placement is a known compromise that leaves FSM coupling in place. Confidence would rise to high if the user-message-routing sub-problem is solved concurrently or if `process_user_message/2` is moved out of this proposal's scope entirely.

## Prior art / references

- `docs/refactor/inventory-session.md` — the extraction plan that produced the current sub-modules; this proposal follows the same pattern of "new sub-module absorbs inline code".
- Elixir convention: `SomeApp.SomeContext.Helpers` modules appear in Phoenix-generated umbrella apps as catch-alls, which makes the name recognisable but also carries the grab-bag stigma.
- Problem context: "there was no other home for them during the extraction" — Proposal 1 is the minimal fix for that exact cause.
