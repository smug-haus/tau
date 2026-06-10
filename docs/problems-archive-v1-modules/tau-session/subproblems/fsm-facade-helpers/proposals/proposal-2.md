---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Distribute helpers into existing modules by concern

## Approach

Rather than creating a new shared module, move each `@doc false` function to the existing sub-module that most coherently owns it, based on concern:

- `append_message/2`, `generate_event_id/0`, `current_run?/2` → `Tau.Session.Data` (pure data operations on the session struct)
- `broadcast/2` → `Tau.Session.Events` (promoted from a thin wrapper to a `def` on the events module; Events already owns the event structs and the PubSub topic name)
- `emit_user_message_telemetry/3` and `transition/3` → `Tau.Session.Journal` (Journal already handles persistence telemetry; transition and user-message telemetry fit the same observability concern)
- `hook_payload/3` and `transcript_path/1` → a new `Tau.Session.Hooks` module (hook payload construction is distinct from both data manipulation and broadcasting; it has its own protocol — the Phase 10 hook contract)
- `process_user_message/2` → `Tau.Session.Queue` (it is a routing function called at the queue/dispatch boundary; Queue is the natural coordinator between message intake and turn start)

No new grab-bag module is introduced. Every function lands in a module with a coherent, named responsibility.

## Rationale

The problem statement identifies that the extraction of sub-modules did not simultaneously introduce a shared utility module. Distributing to existing modules rather than creating a new one respects the concern taxonomy already established by the extraction — each sub-module exists because it owns a named concern. `Data` owns struct operations; `Events` owns the broadcast surface; `Journal` owns observability; a new `Hooks` module owns the hook-contract adapter; `Queue` owns the message-routing boundary. This distribution means each sub-module's imports become self-documenting: a module that imports `Tau.Session.Data` is doing data operations; one that imports `Tau.Session.Events` is broadcasting.

`process_user_message/2` moving to `Queue` is the most consequential placement: it still calls `handle_event/4` internally, making `Queue` coupled back to the FSM. However, `Queue` is already the natural boundary for routing decisions, and this placement at least names the coupling explicitly in a module whose purpose is coordination.

## Sketch

```
# lib/tau/session/data.ex — add three functions

@spec append_message(t(), Tau.Message.t()) :: t()
def append_message(%__MODULE__{} = data, msg),
  do: %{data | messages: data.messages ++ [msg]}

@spec generate_event_id() :: String.t()
def generate_event_id do
  case Code.ensure_loaded?(Uniq.UUID) do
    true -> apply(Uniq.UUID, :uuid7, [])
    _ -> "evt_" <> (:crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false))
  end
end

@spec current_run?(t(), {:provider, reference()} | {:coding_agent, pid()}) :: boolean()
def current_run?(%__MODULE__{stream_ref: ref}, {:provider, ref}) when is_reference(ref), do: true
def current_run?(%__MODULE__{coding_agent_dispatcher: pid}, {:coding_agent, pid}) when is_pid(pid), do: true
def current_run?(_data, _token), do: false
```

```
# lib/tau/session/events.ex — add one function

@doc """
Broadcast `event` on the PubSub topic for `session_id`.
"""
@spec broadcast(String.t(), struct()) :: :ok | {:error, term()}
def broadcast(session_id, event) do
  Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{session_id}", event)
end
```

```
# lib/tau/session/journal.ex — add two telemetry helpers

@spec emit_transition(String.t(), atom()) :: :ok
def emit_transition(session_id, to) do
  :telemetry.execute([:tau, :session, :transition], %{system_time: System.system_time()}, %{
    session_id: session_id,
    to: to
  })
  :ok
end

@spec emit_user_message(atom(), map(), atom()) :: :ok
def emit_user_message(event, data, state) do
  :telemetry.execute(
    [:tau, :session, :user_message, event],
    %{system_time: System.system_time()},
    %{session_id: data.id, from_state: state}
  )
end
```

```
# New file: lib/tau/session/hooks.ex

defmodule Tau.Session.Hooks do
  @moduledoc """
  Hook-payload builders for `Tau.Session`.
  Implements the Phase 10 hook contract: every payload carries
  session_id, cwd, permission_mode, hook_event_name, transcript_path,
  and metadata, merged with the event-specific extras map.
  """

  @spec payload(map(), atom(), map()) :: map()
  def payload(data, event, extras) when is_map(extras) do
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
end
```

```
# lib/tau/session/queue.ex — add process_user_message/2
# (retains the handle_event/4 back-call; the routing coupling is
#  documented but not resolved — that is the user-message-routing sub-problem)

@spec process_user_message(Tau.Message.t(), map()) :: term()
def process_user_message(msg, data) do
  # … verbatim body …
end
```

Callsite renames in sub-modules and session.ex:

| Old call | New call |
|---|---|
| `Tau.Session.broadcast(id, event)` | `Tau.Session.Events.broadcast(id, event)` |
| `Tau.Session.append_message(data, msg)` | `Tau.Session.Data.append_message(data, msg)` |
| `Tau.Session.generate_event_id()` | `Tau.Session.Data.generate_event_id()` |
| `Tau.Session.current_run?(data, token)` | `Tau.Session.Data.current_run?(data, token)` |
| `Tau.Session.transition(id, data, to)` | `Tau.Session.Journal.emit_transition(id, to)` |
| `Tau.Session.emit_user_message_telemetry(e, d, s)` | `Tau.Session.Journal.emit_user_message(e, d, s)` |
| `Tau.Session.hook_payload(data, event, extras)` | `Tau.Session.Hooks.payload(data, event, extras)` |
| `Tau.Session.process_user_message(msg, data)` | `Tau.Session.Queue.process_user_message(msg, data)` |

## Tradeoffs

### Strengths

- No new grab-bag module — each function lands in a named-concern module.
- `Tau.Session.Data` gains typed function signatures on the struct (since `Data` is already a `defstruct`); `append_message/2` can be strengthened from `map()` to `Data.t()` input/output.
- `Tau.Session.Events.broadcast/2` is a natural fit — Events already owns the topic name implicitly; making broadcast a function on Events makes the topic a single point of definition.
- Sub-module imports become self-documenting: `alias Tau.Session.Data` signals data operations; `alias Tau.Session.Events` signals broadcasting.
- Satisfies the acceptance criterion: `session.ex` loses all `@doc false` defs.

### Weaknesses

- Higher coordination cost: changes touch four existing modules plus one new module (`Hooks`), and all six sub-module callsites, in a single PR.
- `Tau.Session.Journal` is a debatable home for `transition/3` and `emit_user_message_telemetry/3` — Journal owns persistence telemetry; adding FSM-transition telemetry blurs its scope. An alternative is a new `Tau.Session.Telemetry` module (but that is scope creep from this proposal).
- `process_user_message/2` in `Queue` retains the `handle_event/4` back-call; `Queue` becomes coupled to the FSM module in a way its other functions are not.
- Renaming `transition/3` to `emit_transition/2` and `hook_payload/3` to `Hooks.payload/3` are minor API-shape changes; callers must update signatures, not just module prefixes.

### Costs

- ~6 sub-modules + `session.ex` updated for callsites: ~40–55 line changes.
- `data.ex` gains ~15 LOC; `events.ex` gains ~8 LOC; `journal.ex` gains ~15 LOC.
- New file `hooks.ex` ~35 LOC.
- Total: ~75 LOC net across ~9 files.
- No external API changes; all moved functions were already `@doc false`.

## Dependencies

- `Tau.Session.Data` must already be a proper `defstruct` (it is, per `data.ex` line 96) — verified.
- `Tau.Session.Journal` must exist and be importable from `session.ex` and sub-modules (it is, per the extraction inventory).
- No new library dependencies.

## Confidence

medium — the concern mapping is defensible but `Journal` as home for transition telemetry is debatable. Confidence would rise to high if a `Tau.Session.Telemetry` module were introduced for the two telemetry helpers (but that would add a fifth destination, which may be worth it or may be over-decomposition).

## Prior art / references

- `Tau.Session.Data` (`lib/tau/session/data.ex`) — already owns struct initialisation; adding pure struct operations is a direct extension of its stated purpose.
- `Tau.Session.Events` (`lib/tau/session/events.ex`) — already defines the event structs broadcast on `"session:<id>"`; `broadcast/2` is the natural complement.
- Elixir/OTP idiom: placing `broadcast/2` on the events module mirrors how `Phoenix.Channel` places `broadcast/3` on the channel module rather than on a separate utility.
- `docs/refactor/inventory-session.md` — the extraction plan that defines the concern taxonomy this proposal extends.
