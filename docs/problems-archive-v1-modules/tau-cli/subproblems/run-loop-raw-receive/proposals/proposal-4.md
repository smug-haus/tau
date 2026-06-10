---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Headless event behaviour — pluggable drain via Tau.CLI.EventHandler behaviour

## Approach

Define a new `Tau.CLI.EventHandler` behaviour with a single callback
`handle_event/2` that returns `{:continue, state} | {:halt, exit_code}`. The
default implementation (`Tau.CLI.DefaultEventHandler`) replicates the current
`drain_run_loop/2` logic per-event. `run_cmd/1` subscribes before `start_session`
(D-004), then drives the event loop via `Tau.CLI.HeadlessDrainer.run/3` — a
pure tail-recursive function that calls `Phoenix.PubSub`-received messages
through `EventHandler.handle_event/2`. The drain function itself is a single,
non-wildcard `receive` that pattern-matches on `is_struct(msg)` and passes
anything else to a `:non_event` handler clause. A missing `SessionEnd` within
the drain window causes the drain to return `{:error, :timeout}` → exit code 1.

## Rationale

This proposal replaces raw `receive` with a typed extension point: the
`Tau.CLI.EventHandler` behaviour declares the contract, and concrete
implementations are separately authored and tested. The complecting of rendering
and control flow is addressed by allowing `DefaultEventHandler` to delegate
rendering to a pure `render/1` sub-function while `handle_event/2` returns only
control signals. More importantly, the behaviour seam means future headless
consumers (batch mode, test harness, webhook sink) can plug in their own
handler without touching `cli.ex`. This is materially different from the other
proposals: it does not merely restructure the existing loop, it replaces it with
an extensibility seam aligned with OTP NN #2 ("extensibility seams MUST be
behaviours").

## Sketch

```elixir
# lib/tau/cli/event_handler.ex

defmodule Tau.CLI.EventHandler do
  @moduledoc """
  Behaviour for headless CLI event consumers. Implement this to customise
  how `tau run` processes session events without touching the drain loop.
  """
  alias Tau.Session.Events

  @type state :: term()
  @type result :: {:continue, state()} | {:halt, non_neg_integer()}

  @doc """
  Called for every Events.* struct received from PubSub.
  Return {:continue, new_state} to keep draining, {:halt, exit_code} to stop.
  """
  @callback handle_event(event :: struct(), state :: state()) :: result()

  @doc "Initial state for the handler."
  @callback init() :: state()

  @doc "Called when the drain window expires without a SessionEnd."
  @callback on_timeout(state :: state()) :: non_neg_integer()
end

# lib/tau/cli/default_event_handler.ex

defmodule Tau.CLI.DefaultEventHandler do
  @behaviour Tau.CLI.EventHandler
  alias Tau.Session.Events
  require Logger

  @impl true
  def init(), do: %{tool_names: %{}}

  @impl true
  def handle_event(%Events.MessageEnd{message: msg, session_id: sid}, state) do
    tool_calls = is_list(msg.content) && Enum.any?(msg.content, &match?(%{type: :tool_call}, &1))
    cond do
      tool_calls ->
        {:continue, state}
      msg.stop_reason in [:error, :tool_loop_aborted, :aborted, :compaction_failed] ->
        IO.puts(:stderr, "session error (#{msg.stop_reason}): #{extract_error_text(msg)}")
        Tau.stop(sid)
        {:halt, 1}
      true ->
        text = extract_assistant_text(msg)
        if text != "", do: IO.puts(text)
        Tau.stop(sid)
        {:continue, Map.put(state, :awaiting_session_end, true)}
    end
  end

  def handle_event(%Events.SessionEnd{reason: reason}, _state) do
    {:halt, if(reason in [:normal, :user], do: 0, else: 1)}
  end

  def handle_event(%Events.ToolStart{tool_call_id: id, name: name, arguments: args}, state) do
    IO.puts(:stderr, "[tau] → #{name}(#{Tau.CLI.summarise_args(args)})")
    {:continue, put_in(state, [:tool_names, id], name)}
  end

  def handle_event(%Events.ToolEnd{tool_call_id: id, result: result}, state) do
    name = get_in(state, [:tool_names, id]) || "?"
    marker = if is_struct(result, Tau.Message.ToolResult) && result.is_error, do: "✗", else: "✓"
    IO.puts(:stderr, "[tau] ← #{name} #{marker}")
    {:continue, update_in(state, [:tool_names], &Map.delete(&1, id))}
  end

  def handle_event(unknown, state) do
    Logger.debug("[tau] DefaultEventHandler: unhandled #{inspect(unknown.__struct__)}")
    {:continue, state}
  end

  @impl true
  def on_timeout(_state), do: 1

  defp extract_error_text(msg), do: Tau.CLI.extract_error_text(msg)
  defp extract_assistant_text(msg), do: Tau.CLI.extract_assistant_text(msg)
end

# lib/tau/cli/headless_drainer.ex

defmodule Tau.CLI.HeadlessDrainer do
  @moduledoc """
  Drives the headless drain loop via an EventHandler behaviour module.
  The calling process MUST already be subscribed to the session's PubSub topic.
  """
  @drain_timeout_ms 10_000

  @spec run(session_id :: String.t(), handler :: module(), state :: term()) ::
          non_neg_integer()
  def run(session_id, handler, state) do
    receive do
      msg when is_struct(msg) and :erlang.map_get(:session_id, msg) == session_id ->
        case handler.handle_event(msg, state) do
          {:continue, new_state} -> run(session_id, handler, new_state)
          {:halt, code}          -> code
        end
      msg when is_struct(msg) ->
        # Event for a different session_id — ignore, keep draining
        run(session_id, handler, state)
      _non_struct ->
        # Non-event mailbox message — ignore
        run(session_id, handler, state)
    after
      @drain_timeout_ms -> handler.on_timeout(state)
    end
  end
end

# lib/tau/cli.ex — in run_cmd/1
Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{session_id}")
# ... start_session, send ...
handler = Application.get_env(:tau, :cli_event_handler, Tau.CLI.DefaultEventHandler)
state0 = handler.init()
Tau.CLI.HeadlessDrainer.run(session_id, handler, state0)
```

`drain_run_loop/2` and `drain_session_end/2` are deleted. The wildcard `_ ->`
clause in the drain becomes `_non_struct ->` with no recursion into event
handling. Unknown `Events.*` structs are handled by `DefaultEventHandler`'s
wildcard `handle_event/2` clause with a `Logger.debug` call.

## Tradeoffs

### Strengths

- OTP NN #2 satisfied: extensibility is via a behaviour, not an ad-hoc function.
- `HeadlessDrainer.run/3` is a single, non-growing function; new event types are
  handled by implementing `handle_event/2`, not by modifying the drain loop.
- Test harness implementations become trivial: a test handler that collects events
  into a list can be passed in via `Application.put_env(:tau, :cli_event_handler, ...)`.
- `on_timeout/1` callback explicitly addresses the `drain_session_end/2`
  false-positive: the handler controls what a timeout means, and the default
  returns `1`.
- Unknown `Events.*` structs are never silently discarded; any handler must
  provide a fallback clause.
- Behaviour module is a stable seam for future headless modes (batch, webhook,
  test).

### Weaknesses

- Three new files (`event_handler.ex`, `default_event_handler.ex`,
  `headless_drainer.ex`) for what is currently ~60 lines of private functions.
  This may be over-engineering for a single callsite.
- `HeadlessDrainer.run/3` still contains a raw `receive` loop — the loop is
  now justified (it is the subscriber process's own mailbox), but it is
  still a raw `receive`, which may draw OTP purist objections.
- `Application.get_env/3` for plugging the handler is a runtime configuration
  mechanism; an alternative (passing handler explicitly in `run_cmd/1`'s opts)
  is cleaner but requires plumbing through the CLI argument chain.
- Pattern-matching on `:erlang.map_get(:session_id, msg)` in a `when` guard
  will crash (and the clause will be skipped) if a struct lacks a `session_id`
  field — must add a `Map.get/3` guard or a separate clause.

### Costs

- Three new source files: ~150 lines total.
- `drain_run_loop/2` and `drain_session_end/2` deleted: ~60 lines removed.
- Net addition: ~90 lines.
- All existing tests of `drain_run_loop/2` / `drain_session_end/2` replaced
  by behaviour-module unit tests and `HeadlessDrainer` integration tests.
- Future event authors must be made aware of `DefaultEventHandler` as a
  secondary location needing updates alongside `Tau.TUI.App`.

## Dependencies

- `Tau.CLI.extract_error_text/1`, `extract_assistant_text/1`, `summarise_args/1`
  must remain accessible from `DefaultEventHandler` (already `@doc false` public).
- Application config key `:cli_event_handler` documented in `config/config.exs`
  or passed explicitly through `run_cmd/1` opts.

## Confidence

Low–medium. The behaviour design is sound and the drain loop is simpler. The
risk is the `:erlang.map_get` guard and the three-file overhead for a
single callsite. Confidence would rise to medium after confirming (a) the guard
clause handles structs without `session_id` cleanly, and (b) a test implementation
of `EventHandler` successfully intercepts events without changes to `run_cmd/1`.

## Prior art / references

- OTP NN #2 — "Extensibility seams MUST be behaviours."
- `Tau.Provider` behaviour — same pattern: a callback module is configured and dispatched by a driver (the session FSM); handlers plug in without touching the driver.
- Plug (`Plug.Conn` + `Plug` behaviour) — analogous extensibility: a pipeline driver calls handler callbacks; the driver doesn't know or care what the handler does.
- `Tau.CLI.MCP` / `Tau.CLI.Extensions` — parallel concern: those modules also have `safe_list/0` wrappers over supervised callees; the behaviour pattern could eventually extend there too.
