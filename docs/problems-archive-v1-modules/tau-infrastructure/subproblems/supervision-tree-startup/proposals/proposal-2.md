---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Tau.CLIRunner supervised GenServer with trap_exit

## Approach

Extract the CLI dispatch into a new supervised `Tau.CLIRunner` GenServer that
is the last child in `Tau.Application`'s tree. `CLIRunner.init/1` spawns
`Tau.CLI.main/1` in a linked process and calls `Process.flag(:trap_exit, true)`,
so any exit from the CLI process — normal or crash — arrives as an `{:EXIT,
pid, reason}` message handled in `handle_info/2`, which extracts the exit code
and calls `System.halt/1`. Remove `otel_reporter_spec/0` and always include
`Tau.OtelReporter` in the child list (passthrough to `init/1`'s `:ignore`).
Set `max_restarts: 10, max_seconds: 60` on the root supervisor.

## Rationale

Making `Tau.CLIRunner` a supervised GenServer gives the CLI runner a named,
observable process with a well-defined lifecycle under OTP supervision. The
`trap_exit` + `handle_info` pattern is the canonical OTP way to observe linked
process exits without coupling the observer's crash to the observed process's
crash. Because `CLIRunner` is a proper child in the supervision tree, its
startup and shutdown are logged by the supervisor, making post-mortem
debugging straightforward. The OTel change is the same deletion/passthrough as
Proposal 1 — relying on `init/1`'s `:ignore` as the single gate.

## Sketch

```elixir
# lib/tau/cli_runner.ex  (new file)
defmodule Tau.CLIRunner do
  @moduledoc """
  Supervised entry point for the CLI. Spawns Tau.CLI.main/1 in a linked
  process; traps its exit and calls System.halt/1 with the correct exit code.
  Returns :ignore when there is no CLI to dispatch (server / embedded mode).
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    case Tau.Application.cli_argv() do
      :no_cli ->
        :ignore

      {:dispatch, argv} ->
        Process.flag(:trap_exit, true)
        pid = spawn_link(fn -> run(argv) end)
        {:ok, %{cli_pid: pid}}
    end
  end

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, %{cli_pid: pid} = state) do
    exit_code =
      case reason do
        {:exit_code, n} when is_integer(n) -> n
        :normal -> 0
        _ -> 1
      end

    System.halt(exit_code)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp run(argv) do
    exit_code =
      case Tau.CLI.main(argv) do
        n when is_integer(n) -> n
        _ -> 0
      end

    exit({:exit_code, exit_code})
  end
end
```

```elixir
# lib/tau/application.ex — child list changes

# Remove: otel_reporter_spec(),
# Add:    Tau.OtelReporter,   (unconditional; init/1 returns :ignore if disabled)
# Remove: the maybe_dispatch_cli() call after Supervisor.start_link
# Add at end of children list (after Sessions.Supervisor):
#         Tau.CLIRunner

# Remove: defp otel_reporter_spec/0
# Remove: defp maybe_dispatch_cli/0

opts = [strategy: :rest_for_one, name: Tau.Supervisor, max_restarts: 10, max_seconds: 60]
```

The `Tau.Application.cli_argv/0` function is already public (`@doc false`),
so `Tau.CLIRunner.init/1` can call it without making it part of the public API.

## Tradeoffs

### Strengths

- `System.halt/1` is guaranteed on both normal and crash exits — closes (a).
- `Tau.CLIRunner` is a named, supervised process visible in `Supervisor.which_children/1`
  and in crash logs — far more observable than a bare `Task.start/1`.
- The linked-spawn + `trap_exit` pattern is a first-class OTP idiom (OTP Design
  Principles §"Processes in a Supervision Tree"); readers familiar with OTP will
  immediately understand the contract.
- Returning `:ignore` from `init/1` in non-CLI mode means the supervisor skip is
  explicit and logged, and no process is resident in server mode.
- Closing (b): `otel_reporter_spec/0` deleted; single gate at `OtelReporter.init/1`.
- Closing (c): `max_restarts: 10 / max_seconds: 60` documented.

### Weaknesses

- New file (`lib/tau/cli_runner.ex`) and new module adds surface area; a reviewer
  must understand why a GenServer (stateful primitive) is wrapping what is
  conceptually a one-shot task.
- `trap_exit` in a GenServer is a footgun if `CLIRunner` ever becomes long-lived
  or if someone starts linking other processes to it — any linked exit will now
  arrive as `handle_info` rather than crashing the GenServer.
- `Tau.CLIRunner` is the last child under `:rest_for_one`; if any earlier child
  crashes and cascades, `CLIRunner` is also killed mid-run, and `System.halt/1`
  fires with exit code 1 (crash reason) rather than the CLI's intended code.
  This is an improvement over the current silent hang but may confuse operators.
- The `exit({:exit_code, n})` convention requires the wrapping `run/1` function;
  if someone calls `Tau.CLI.main/1` directly and it calls `System.halt/1`
  internally, the exit propagation short-circuits the structured code.

### Costs

- One new file (`lib/tau/cli_runner.ex`, ~40 lines).
- ~10 lines removed from `lib/tau/application.ex` (two functions deleted, one
  child entry changed, one call site removed).
- Any tests that assert on `maybe_dispatch_cli/0` or on `Task.start/1` being
  called must be updated.
- Tests that check `Tau.OtelReporter` is absent when OTel is disabled need
  updating (same as Proposal 1).

## Dependencies

- `Tau.Application.cli_argv/0` must remain public (it already is, `@doc false`).
- `Tau.OtelReporter.init/1` must honour `:ignore` when disabled (confirmed).
- `Tau.CLIRunner` must be placed after `Tau.Sessions.Supervisor` in the child
  list to preserve the boot order documented in `application.ex`'s moduledoc.

## Confidence

Medium-high. The linked-spawn + `trap_exit` pattern is well-established OTP; the
`exit({:exit_code, n})` tagged-tuple convention is a small extra commitment.
Confidence rises to high if a unit test confirms `handle_info({:EXIT, ...})`
dispatches to `System.halt/1` with the correct code.

## Prior art / references

- OTP Design Principles §"Processes in a Supervision Tree" — the trap_exit +
  handle_info(:EXIT) idiom for linked process observation.
- Elixir `GenServer` docs §"Handling exits" — documents `Process.flag(:trap_exit)`.
- `:ignore` from `GenServer.init/1` — `Supervisor` docs §"Child specification";
  child is started and immediately removed from the tree, no restart.
- Similar pattern in Erlang `escript` wrappers that boot a supervision tree then
  hand off to a linked worker process.
