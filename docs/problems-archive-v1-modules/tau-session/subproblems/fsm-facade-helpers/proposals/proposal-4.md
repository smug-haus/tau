---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Inline all pure helpers into Tau.Session.Data; make broadcast a macro-less import

## Approach

This proposal takes the most aggressive consolidation stance: rather than creating new shared modules, it pushes as many of the eight helpers as possible into the one existing module that already owns the data shape — `Tau.Session.Data` — and handles the side-effectful remainder differently.

Specifically:

1. `append_message/2`, `generate_event_id/0`, `current_run?/2`, `hook_payload/3`, and `transcript_path/1` all move to `Tau.Session.Data`. `Data` is already the typed-struct owner; these are all pure functions that operate on or produce values from the session struct. The `Data.t()` type annotation for `append_message/2`'s input becomes available for free.

2. `broadcast/2`, `emit_user_message_telemetry/3`, and `transition/3` are replaced **inline** at every callsite in `session.ex` — they are eliminated as named functions entirely, replaced by their one-to-two-line bodies inlined where called. The argument for inlining: `broadcast/2` is `Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{id}", event)` — one line; `transition/3` is a `:telemetry.execute/3` call — two lines; `emit_user_message_telemetry/3` is a single `:telemetry.execute/3` call. None of these warrant a named function; they were `@doc false` precisely because they are wrappers over standard library calls.

3. `process_user_message/2` is demoted to `defp` on `session.ex` (same as Proposal 3's treatment) — it re-enters `handle_event/4` and is FSM-internal; it does not belong in any shared module.

The net result: `Tau.Session.Data` gains five new public functions; `session.ex` loses all eight `@doc false` defs; three calls become inline expressions; `process_user_message/2` becomes private.

## Rationale

The complecting hypothesis says helpers are on the FSM module because there was no shared home. But the problem statement also notes that `Tau.Session.Data` "is the natural home for pure data-manipulation utilities (`append_message`, `generate_event_id`, `current_run?`)". This proposal takes that note at face value and extends it: `hook_payload/3` is also a pure builder (it reads struct fields, builds a map); it belongs in the same module. The session data struct and the hook payload both describe session state — consolidating them in `Data` avoids a new module.

The inlining of the three effectful wrappers is justified by their triviality: a function whose body is one standard-library call is noise, not abstraction. Inlining removes the naming overhead, makes the callsite directly readable (the reader sees `Phoenix.PubSub.broadcast(...)` without needing to know what `broadcast/2` wraps), and eliminates the sub-module import surface for these calls.

## Sketch

```
# lib/tau/session/data.ex — add five public functions after the defstruct/type block

@doc """
Append `msg` to the session's message list.
"""
@spec append_message(t(), Tau.Message.t()) :: t()
def append_message(%__MODULE__{} = data, msg),
  do: %{data | messages: data.messages ++ [msg]}

@doc """
Generate a unique event ID. Uses Uniq.UUID v7 when available; falls
back to a URL-safe random binary prefixed with "evt_".
"""
@spec generate_event_id() :: String.t()
def generate_event_id do
  case Code.ensure_loaded?(Uniq.UUID) do
    true -> apply(Uniq.UUID, :uuid7, [])
    _ -> "evt_" <> (:crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false))
  end
end

@doc """
Returns true when `token` identifies the currently active provider
stream or coding-agent dispatcher for `data`.
"""
@spec current_run?(t(), {:provider, reference()} | {:coding_agent, pid()}) :: boolean()
def current_run?(%__MODULE__{stream_ref: ref}, {:provider, ref}) when is_reference(ref), do: true
def current_run?(%__MODULE__{coding_agent_dispatcher: pid}, {:coding_agent, pid}) when is_pid(pid), do: true
def current_run?(_data, _token), do: false

@doc """
Build the Phase 10 hook-contract payload for `event` on `data`,
merging in the event-specific `extras` map.
"""
@spec hook_payload(t(), atom(), map()) :: map()
def hook_payload(%__MODULE__{} = data, event, extras) when is_map(extras) do
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

defp transcript_path(%__MODULE__{persistence: p, id: id, cwd: cwd}), do: p.path_for(id, cwd)
```

```
# lib/tau/session.ex — replace three named wrappers with inline bodies

# BEFORE:
Tau.Session.broadcast(data.id, %Events.Cancelled{...})
Tau.Session.transition(data.id, data, :awaiting_user)
Tau.Session.emit_user_message_telemetry(:enqueued, data, state)

# AFTER:
Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{data.id}", %Events.Cancelled{...})
:telemetry.execute([:tau, :session, :transition], %{system_time: System.system_time()},
  %{session_id: data.id, to: :awaiting_user})
:telemetry.execute([:tau, :session, :user_message, :enqueued], %{system_time: System.system_time()},
  %{session_id: data.id, from_state: state})
```

```
# lib/tau/session.ex — demotion of process_user_message/2:
defp process_user_message(msg, data) do ... end   # was @doc false def

# Remove from session.ex entirely:
# @doc false def broadcast/2
# @doc false def transition/3
# @doc false def emit_user_message_telemetry/3
# @doc false def append_message/2
# @doc false def generate_event_id/0
# @doc false def current_run?/2
# @doc false def hook_payload/3
```

Sub-module callsite changes:
| Old | New |
|---|---|
| `Tau.Session.append_message(data, msg)` | `Tau.Session.Data.append_message(data, msg)` |
| `Tau.Session.generate_event_id()` | `Tau.Session.Data.generate_event_id()` |
| `Tau.Session.current_run?(data, token)` | `Tau.Session.Data.current_run?(data, token)` |
| `Tau.Session.hook_payload(data, event, extras)` | `Tau.Session.Data.hook_payload(data, event, extras)` |
| `Tau.Session.broadcast(id, event)` | `Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{id}", event)` |
| `Tau.Session.transition(id, data, to)` | `:telemetry.execute([:tau, :session, :transition], ...)` inline |
| `Tau.Session.emit_user_message_telemetry(e, d, s)` | `:telemetry.execute([:tau, :session, :user_message, e], ...)` inline |

## Tradeoffs

### Strengths

- No new files: `Data` absorbs five helpers; three helpers are inlined away; zero new modules to maintain.
- `Data` gains typed `@spec` annotations with `t()` — `append_message/2` and `current_run?/2` now pattern-match against `%__MODULE__{}` structs rather than `map()`, enabling Dialyzer to catch struct-field mismatches.
- Inlining trivial wrappers (`broadcast/2`, `transition/3`) makes callsites more transparent — the reader sees the PubSub/telemetry call directly, without an indirection that reveals nothing.
- Satisfies the acceptance criterion: `session.ex` has no `@doc false` public functions.
- `hook_payload/3` in `Data` makes sense: it reads session struct fields to build an external payload — it is a data projection function.

### Weaknesses

- `Tau.Session.Data` grows from its current 369 LOC to approximately 430 LOC with the five additions. "Everything in Data" risks turning `Data` into the new grab-bag, just under a better name.
- Inlining the three effectful calls trades named abstraction for verbosity: every `broadcast` callsite now repeats `Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{id}", ...)` — the topic string `"session:#{id}"` is no longer defined in one place, creating a duplication risk if the topic format ever changes.
- `hook_payload/3` co-locates with struct-definition and struct-manipulation in `Data`, which is semantically reasonable but may surprise contributors who look for hook-related code in a module named `Hooks` or `Events`.
- The inlining of `transition/3` and `emit_user_message_telemetry/3` produces longer individual callsite lines; the caller must pass `System.system_time()` directly, repeating the measurement idiom at each callsite.
- Sub-modules that currently call `Tau.Session.broadcast(...)` must change to the full `Phoenix.PubSub.broadcast(...)` form — this makes sub-module source noisier with the PubSub boilerplate.

### Costs

- `data.ex`: +~65 LOC (five functions + type annotations).
- `session.ex`: 8 `@doc false` defs removed; 3 sets of callsites expanded inline (net ~+10 LOC to `session.ex` after the function removals).
- ~6 sub-modules: alias updates + callsite changes; some callsites become multi-line where `broadcast/2` was one token.
- Estimate: ~80 LOC net across ~8 files. No new files; one file (`data.ex`) grows meaningfully.
- No external API changes.

## Dependencies

- `Tau.Session.Data` must already be a `defstruct` (confirmed, line 96 of `data.ex`).
- No library upgrades required.
- Should be done after — or in the same PR as — any SPEC-USER-TURN changes that add fields to `Data.t()`, to avoid merge conflicts on `data.ex`.

## Confidence

medium — the Data consolidation is well-grounded (problem.md itself names Data as the natural home for pure utilities), but the inlining decision is opinionated. Confidence would rise to high if a search of callsites confirms each of the three effectful functions is called ≤ 4 times total across the codebase (inlining is less costly with few callsites).

## Prior art / references

- Problem statement context: "Tau.Session.Data … is the natural home for pure data-manipulation utilities (append_message, generate_event_id, current_run?)" — directly endorses this proposal's consolidation into `Data`.
- Elixir OTP idiom: trivial one-liner wrappers over well-known APIs (`Phoenix.PubSub.broadcast/3`, `:telemetry.execute/3`) are often left inline in mature codebases once the function they originally abstracted becomes universally familiar.
- The `defstruct` + typed-spec pattern already used in `Tau.Session.Data` (`data.ex` lines 20–94) — this proposal extends the same pattern with additional functions.
