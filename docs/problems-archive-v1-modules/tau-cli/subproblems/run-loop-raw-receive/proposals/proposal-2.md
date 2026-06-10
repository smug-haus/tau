---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Tau.CLI.RunLoop GenServer — supervised event consumer with monitored ref

## Approach

Replace the raw `receive` loops with a supervised `GenServer` (`Tau.CLI.RunLoop`)
that subscribes to the session's PubSub topic in `init/1` (satisfying D-004:
`GenServer.start_link` returns only after `init/1` completes, so the subscription
is open before `start_session` is called), handles each `Events.*` struct as a
distinct `handle_info/2` clause, and signals completion via a monitored ref.
`run_cmd/1` starts the `RunLoop` process under a one-off `Task.Supervisor`,
sends the prompt, then blocks with `receive do {:run_result, ref, code} -> code end`.
Unknown events fall into a `handle_info({_, _}, state)` wildcard clause that
logs at `:debug` but does NOT recurse on a raw-`receive` sentinel.

## Rationale

OTP NN #4 says cross-process events MUST use PubSub or monitored refs. This
proposal uses both: PubSub for the inbound event subscription (same topic as
today) and a monitored ref for the result handoff from `RunLoop` to `run_cmd/1`.
The raw `receive` pattern is replaced by `handle_info/2` pattern matching —
the canonical OTP mechanism for consuming mailbox messages. Separation of
concerns: rendering (`IO.puts`) and event-dispatching are both in `RunLoop`,
but each event type has its own `handle_info/2` clause rather than being
crammed into a single recursive function. `drain_session_end/2`'s false-positive
timeout disappears: the `RunLoop` `state.exit_code` starts at `1` and is updated
only when a `SessionEnd` with `:normal` or `:user` reason arrives.

## Sketch

```elixir
# lib/tau/cli/run_loop.ex

defmodule Tau.CLI.RunLoop do
  @moduledoc """
  Supervised GenServer that consumes PubSub events for a headless `tau run`.
  Subscribes to the session topic in init/1 (D-004 compliance).
  Reports result via {:run_result, ref, exit_code} to the caller.
  """
  use GenServer
  alias Tau.Session.Events

  defstruct [:session_id, :caller, :ref, :tool_names, exit_code: 1]

  def start_link(session_id, caller, ref) do
    GenServer.start_link(__MODULE__, {session_id, caller, ref})
  end

  @impl true
  def init({session_id, caller, ref}) do
    # D-004: subscribe here, before caller calls Tau.start_session/1.
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{session_id}")
    {:ok, %__MODULE__{session_id: session_id, caller: caller, ref: ref, tool_names: %{}}}
  end

  @impl true
  def handle_info(%Events.MessageEnd{session_id: sid, message: msg}, %{session_id: sid} = state) do
    tool_calls =
      is_list(msg.content) && Enum.any?(msg.content, &match?(%{type: :tool_call}, &1))

    cond do
      tool_calls ->
        {:noreply, state}

      msg.stop_reason in [:error, :tool_loop_aborted, :aborted, :compaction_failed] ->
        IO.puts(:stderr, "session error (#{msg.stop_reason}): #{Tau.CLI.extract_error_text(msg)}")
        Tau.stop(sid)
        {:noreply, %{state | exit_code: 1}}

      true ->
        text = Tau.CLI.extract_assistant_text(msg)
        if text != "", do: IO.puts(text)
        Tau.stop(sid)
        {:noreply, %{state | exit_code: 0}}
    end
  end

  def handle_info(%Events.SessionEnd{session_id: sid, reason: reason}, %{session_id: sid} = state) do
    code = if reason in [:normal, :user], do: 0, else: 1
    send(state.caller, {:run_result, state.ref, code})
    {:stop, :normal, state}
  end

  def handle_info(%Events.ToolStart{session_id: sid, tool_call_id: id, name: name, arguments: args},
                  %{session_id: sid} = state) do
    IO.puts(:stderr, "[tau] → #{name}(#{Tau.CLI.summarise_args(args)})")
    {:noreply, %{state | tool_names: Map.put(state.tool_names, id, name)}}
  end

  def handle_info(%Events.ToolEnd{session_id: sid, tool_call_id: id, result: result},
                  %{session_id: sid} = state) do
    name = Map.get(state.tool_names, id, "?")
    marker = if is_struct(result, Tau.Message.ToolResult) && result.is_error, do: "✗", else: "✓"
    IO.puts(:stderr, "[tau] ← #{name} #{marker}")
    {:noreply, %{state | tool_names: Map.delete(state.tool_names, id)}}
  end

  # Timeout: no SessionEnd within the drain window → exit 1 (fail-safe)
  def handle_info(:timeout, state) do
    send(state.caller, {:run_result, state.ref, 1})
    {:stop, :normal, state}
  end

  # Unknown Events.* struct: log, do not silently discard
  def handle_info(unknown, state) when is_struct(unknown) do
    require Logger
    Logger.debug("[tau] RunLoop: unhandled event #{inspect(unknown.__struct__)}")
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end

# lib/tau/cli.ex — run_cmd/1 replacement for drain_run_loop call
ref = make_ref()
{:ok, _pid} = Task.Supervisor.start_child(
  Tau.TaskSupervisor,
  fn -> Tau.CLI.RunLoop.start_link(session_id, self(), ref) end
)
# RunLoop is now subscribed; safe to start session
case Tau.start_session(start_opts) do
  {:ok, ^session_id} ->
    Tau.send(session_id, prompt)
    receive do
      {:run_result, ^ref, exit_code} -> exit_code
    after
      60_000 -> 1   # absolute wall-time safety net
    end
end
```

The `drain_session_end/2` function is deleted. The `RunLoop` GenServer's
10-second `:timeout` (passed as `{:noreply, state, 10_000}` on the final
`handle_info` after `Tau.stop/1`) provides the drain window; a missing
`SessionEnd` causes `handle_info(:timeout, state)` to fire and reply with `1`.

## Tradeoffs

### Strengths

- Fully OTP-compliant: `handle_info/2` replaces raw `receive`, and the
  subscription opens in `init/1` before the caller proceeds.
- Each event type is its own `handle_info/2` clause — adding a new handled
  event is a one-clause addition, not a modification of a recursive function.
- Unknown `Events.*` structs hit a named clause with a `Logger.debug` call,
  not a wildcard recurse.
- Timeout produces exit code `1` (fail-safe), not the caller-seeded value.
- `Tau.CLI.RunLoop` is independently testable: you can `GenServer.start_link`
  it in tests, send `Events.*` structs directly, and assert on replies.

### Weaknesses

- Introduces a new supervised process and a new module file for what is
  currently a ~60-line set of private functions.
- The caller still uses a raw `receive` for the final `{:run_result, ref,
  exit_code}` handoff — technically complying with OTP NN #4 (the
  result-signalling is a monitored ref, not a PubSub event), but it is a
  raw `receive` in `run_cmd/1`.
- `Tau.TaskSupervisor` must exist in the application's supervision tree; if it
  does not, a `DynamicSupervisor` must be added first.
- `summarise_args/1` and `extract_error_text/1` / `extract_assistant_text/1`
  must be made `@doc false` public (they already are per the code) or duplicated.
- Progress rendering remains coupled to event handling (same concern as Proposal 1).

### Costs

- One new file: `lib/tau/cli/run_loop.ex` (~70 lines).
- `drain_run_loop/2` and `drain_session_end/2` deleted (~60 lines).
- `run_cmd/1` loses 2 private function calls, gains ~10 lines of supervisor/ref
  wiring.
- Tests for the raw-`receive` functions must be replaced with tests for
  `RunLoop` GenServer behaviour.
- `Tau.TaskSupervisor` dependency: verify it exists in `lib/tau/application.ex`.

## Dependencies

- `Tau.TaskSupervisor` (or equivalent `DynamicSupervisor`) must be present in
  the application supervision tree.
- `Tau.CLI.extract_error_text/1`, `Tau.CLI.extract_assistant_text/1`, and
  `Tau.CLI.summarise_args/1` must remain accessible from the new module (they
  are already `@doc false` public).

## Confidence

Medium. The GenServer structure is straightforward; the D-004 compliance via
`init/1` subscription is clean. Confidence would be high after confirming
`Tau.TaskSupervisor` is available and verifying that `handle_info(:timeout)` is
reachable when the `{:noreply, state, timeout_ms}` tuple is returned from the
right clause.

## Prior art / references

- OTP NN #4 — "Cross-process events MUST use Phoenix.PubSub or monitored refs."
- `Tau.TUI.App` — existing pattern of a supervised GenServer consuming PubSub events via `handle_info/2`.
- Elixir `GenServer` docs — `handle_info/2` and the `{:noreply, state, timeout}` 3-tuple.
