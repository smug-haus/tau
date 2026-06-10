---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Two-module split — Tau.Session.Util and Tau.Session.Hooks

## Approach

Split the eight helpers into exactly two new modules by a single, clear axis — **side-effect-free vs side-effectful**:

- `Tau.Session.Util` receives the four pure functions: `append_message/2`, `generate_event_id/0`, `current_run?/2`, and `hook_payload/3` + `transcript_path/1`. (Hook payload construction is pure — it reads struct fields and returns a map; the hook *dispatch* is elsewhere.)
- `Tau.Session.Effects` receives the three side-effectful functions: `broadcast/2`, `emit_user_message_telemetry/3`, and `transition/3`.
- `process_user_message/2` is demoted to a `defp` on `session.ex` itself (not moved to a sub-module), because it re-enters `handle_event/4` and is therefore FSM-internal coordination, not a shared utility. Removing it from the public surface means sub-modules that do not directly call it have no coupling to it.

This scheme satisfies the acceptance criterion (no `@doc false` public functions on `session.ex`) while establishing a principled two-tier: pure helpers in `Util`, effectful helpers in `Effects`.

## Rationale

The complecting mixes two kinds of utilities: pure functions that transform data or generate IDs (no side effects, trivially testable) and effectful functions that emit telemetry or publish to PubSub (side effects, harder to unit-test). Grouping them together in one module (Proposal 1's `Helpers`) obscures this distinction. Grouping them by concern (Proposal 2) distributes them across many modules. This proposal splits on the pure/effectful axis — a well-understood Elixir/functional programming partition — and uses exactly two modules, keeping the cognitive overhead low.

Demoting `process_user_message/2` to `defp` rather than moving it acknowledges that it is an FSM-internal routing function, not a shared utility. The acceptance criterion does not require that every function in `session.ex` be a public function — only that `@doc false` public functions (which create spurious API surface) are removed. Making it private removes it from the public surface without the risk of coupling a sub-module back to `handle_event/4`.

## Sketch

```
# New file: lib/tau/session/util.ex
defmodule Tau.Session.Util do
  @moduledoc """
  Pure utility functions shared across `Tau.Session` sub-modules.
  No side effects; safe to call in any context.
  """

  alias Tau.Session.Data

  @spec append_message(Data.t() | map(), Tau.Message.t()) :: Data.t() | map()
  def append_message(data, msg), do: %{data | messages: data.messages ++ [msg]}

  @spec generate_event_id() :: String.t()
  def generate_event_id do
    case Code.ensure_loaded?(Uniq.UUID) do
      true -> apply(Uniq.UUID, :uuid7, [])
      _ -> "evt_" <> (:crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false))
    end
  end

  @spec current_run?(map(), {:provider, reference()} | {:coding_agent, pid()}) :: boolean()
  def current_run?(%{stream_ref: ref}, {:provider, ref}) when is_reference(ref), do: true
  def current_run?(%{coding_agent_dispatcher: pid}, {:coding_agent, pid}) when is_pid(pid), do: true
  def current_run?(_data, _token), do: false

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
end
```

```
# New file: lib/tau/session/effects.ex
defmodule Tau.Session.Effects do
  @moduledoc """
  Effectful shared operations for `Tau.Session` sub-modules:
  PubSub broadcast and telemetry emission.

  Isolated from `Tau.Session.Util` so callers needing only pure
  utilities do not import the effects surface.
  """

  @spec broadcast(String.t(), struct()) :: :ok | {:error, term()}
  def broadcast(id, event) do
    Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{id}", event)
  end

  @spec emit_user_message(atom(), map(), atom()) :: :ok
  def emit_user_message(event, data, state) do
    :telemetry.execute(
      [:tau, :session, :user_message, event],
      %{system_time: System.system_time()},
      %{session_id: data.id, from_state: state}
    )
  end

  @spec emit_transition(String.t(), atom()) :: :ok
  def emit_transition(session_id, to) do
    :telemetry.execute([:tau, :session, :transition], %{system_time: System.system_time()}, %{
      session_id: session_id,
      to: to
    })
    :ok
  end
end
```

```
# In lib/tau/session.ex — process_user_message/2 demoted:
# Change @doc false def to defp

defp process_user_message(msg, data) do
  # … same body …
end

# All other @doc false defs removed; callsites updated:
# Tau.Session.broadcast(...)           → Tau.Session.Effects.broadcast(...)
# Tau.Session.append_message(...)      → Tau.Session.Util.append_message(...)
# Tau.Session.generate_event_id()      → Tau.Session.Util.generate_event_id()
# Tau.Session.current_run?(...)        → Tau.Session.Util.current_run?(...)
# Tau.Session.transition(...)          → Tau.Session.Effects.emit_transition(...)
# Tau.Session.emit_user_message_telemetry(...) → Tau.Session.Effects.emit_user_message(...)
# Tau.Session.hook_payload(...)        → Tau.Session.Util.hook_payload(...)
```

Sub-modules that call the old names add exactly one of:
```
alias Tau.Session.Util
alias Tau.Session.Effects
```
…depending on which helpers they use.

## Tradeoffs

### Strengths

- The pure/effectful split is a principled, well-understood axis; it mirrors Elixir community practice and Hickey's "simple" vs "complex" distinction (effects are complecting by nature).
- `process_user_message/2` becomes `defp` — it disappears from `session.ex`'s public surface without any sub-module becoming coupled to `handle_event/4`.
- Sub-modules that only need pure utilities (`Util`) do not import the effects surface; the import communicates intent.
- Two new modules is still a low cognitive overhead (compared to Proposal 2's five destinations).
- Satisfies the acceptance criterion without ambiguity.

### Weaknesses

- `Util` is still a somewhat generic name; contributors may add unrelated pure functions to it over time.
- `hook_payload/3` in `Util` co-locates with `append_message/2` and `current_run?/2` — these are not obviously related. A future reader might prefer `hook_payload/3` in a `Hooks` module (as in Proposal 2).
- Demoting `process_user_message/2` to `defp` rather than extracting it does not fully resolve its architectural ambiguity — it still calls `handle_event/4` internally. However, since this is declared out-of-scope (user-message-routing sub-problem), `defp` is a valid resting state.
- `Effects` as a module name is less conventional in Elixir codebases than, say, `Tau.Session.PubSub` or `Tau.Session.Telemetry`.

### Costs

- Two new files: `util.ex` (~55 LOC), `effects.ex` (~35 LOC).
- `session.ex`: 7 `@doc false` defs removed; 1 `def` demoted to `defp`; callsites within `session.ex` updated.
- ~6 sub-modules: alias additions + callsite updates; ~30–40 line changes.
- Total: ~130 LOC net across ~9 files (counting new files).
- No external API changes (all functions were `@doc false`).

## Dependencies

- None. All function bodies are copied verbatim; no other module needs to be refactored first.
- The `defp` demotion of `process_user_message/2` is self-contained in `session.ex`.

## Confidence

medium-high — the split axis (pure vs effectful) is principled and testable. Confidence is not "high" because `hook_payload/3` in `Util` is a weak fit next to `append_message/2`; if the selector finds that awkward, Proposal 2's `Hooks` module is the alternative for that one function.

## Prior art / references

- Elixir community idiom: "pure core, effectful shell" — see e.g. Gary Bernhardt's "Functional Core, Imperative Shell"; the Elixir equivalent separates pure transformations from `Phoenix.PubSub` / `:telemetry` calls.
- `Tau.Session.Data` (`lib/tau/session/data.ex`) — already follows the "pure data module" pattern; `Util` extends that pattern to non-struct utilities.
- The `@doc false` problem statement itself: "utilities have been left on the FSM module because there was no other home for them" — Proposal 3 creates two homes, partitioned by effect.
