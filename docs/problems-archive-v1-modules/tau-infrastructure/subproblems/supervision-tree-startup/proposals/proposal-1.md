---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Task.Supervisor child + OTel always-in-tree passthrough + relaxed restart bounds

## Approach

Replace the bare `Task.start/1` in `maybe_dispatch_cli/0` with
`Task.Supervisor.start_child/3` under the existing `Tau.Tools.TaskSupervisor`,
using `Task.Supervisor.async_nolink/3` with a `Process.monitor` on the returned
task PID so that `Tau.Application.start/2` receives a `{:DOWN, ref, :process,
pid, reason}` message and can call `System.halt/1` with the correct exit code.
Remove `otel_reporter_spec/0`'s conditional entirely: always include
`Tau.OtelReporter` in the child list and let `Tau.OtelReporter.init/1`'s
existing `:ignore` path be the sole gate for "OTel disabled." Change the
supervisor `opts` to `[strategy: :rest_for_one, name: Tau.Supervisor,
max_restarts: 10, max_seconds: 60]`.

## Rationale

`Task.start/1` is fire-and-forget — the caller has no handle on the result.
Adding a `Process.monitor` after `Task.Supervisor.async_nolink/3` gives the
`Application.start/2` process a direct `:DOWN` message on any exit, normal or
crash, without linking (which would crash the supervisor) and without requiring a
new supervised module. The OTel dual-gate is removed by trusting `init/1`'s
`:ignore` return, which is the canonical OTP mechanism for conditional startup;
`otel_reporter_spec/0` reading env at supervisor build time is the second gate.
Relaxing `max_restarts: 10 / max_seconds: 60` reduces the probability of
spurious halts from transient SQLite locks or Finch init jitter during cold start.

## Sketch

```elixir
# lib/tau/application.ex

# In start/2, after Supervisor.start_link:
{:ok, pid} ->
  :telemetry.execute([:tau, :app, :ready], ...)
  maybe_dispatch_cli()
  {:ok, pid}

# Replace otel_reporter_spec/0:
#   Remove the function; change the child list from:
#     otel_reporter_spec(),
#   to:
#     Tau.OtelReporter,
#   (always include; OtelReporter.init/1 returns :ignore when disabled)

# Change opts:
opts = [strategy: :rest_for_one, name: Tau.Supervisor, max_restarts: 10, max_seconds: 60]

# Replace maybe_dispatch_cli/0:
defp maybe_dispatch_cli do
  case cli_argv() do
    :no_cli ->
      :ok

    {:dispatch, argv} ->
      %Task{pid: pid} =
        Task.Supervisor.async_nolink(Tau.Tools.TaskSupervisor, fn ->
          exit_code =
            case Tau.CLI.main(argv) do
              n when is_integer(n) -> n
              _ -> 0
            end

          exit_code
        end)

      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, {:exit, code}} when is_integer(code) ->
          System.halt(code)

        {:DOWN, ^ref, :process, ^pid, :normal} ->
          # Task returned a value — task result carries exit_code via {:exit, code}
          # so :normal means the task exited cleanly with 0 implicitly.
          System.halt(0)

        {:DOWN, ^ref, :process, ^pid, _reason} ->
          # Crash or unexpected exit — non-zero.
          System.halt(1)
      end
  end
end
```

Note: the `Task.Supervisor.async_nolink` + `Process.monitor` pattern blocks
`Application.start/2` after returning `{:ok, pid}`. In practice `start/2` has
already returned the supervisor PID before `maybe_dispatch_cli/0` blocks, so
the VM is live; the blocker is the calling process (the Application controller
process), not the supervisor process itself. This is consistent with how
Burrito-built binaries are designed to block on CLI work.

## Tradeoffs

### Strengths

- `System.halt/1` is guaranteed to fire on both normal and crash exits — closes
  the acceptance criterion (a) directly.
- Reuses `Tau.Tools.TaskSupervisor` — no new supervised module, no supervision
  tree change beyond removing the conditional.
- The OTel change is a deletion (remove `otel_reporter_spec/0`) — smallest
  possible footprint; relies entirely on existing OTP `:ignore` semantics,
  closing criterion (b).
- `max_restarts: 10 / max_seconds: 60` is a documented, defensible relaxation
  for transient init failures, closing criterion (c).

### Weaknesses

- Blocking `Application.start/2`'s caller process (the Application controller)
  with a `receive` loop is atypical — readers unfamiliar with the Burrito
  pattern may find it alarming.
- `Task.Supervisor.async_nolink` requires the supervisor to be started before
  this call; if the task supervisor's position in the child list changes, this
  breaks silently.
- The `:DOWN` message shape from `async_nolink` wraps the return value in
  `{:exit, value}` only if the task calls `exit/1` explicitly; a plain return
  from the fn body sends `{:DOWN, ..., :normal}` with no embedded code. The
  sketch above must use `exit(exit_code)` inside the task, not `exit_code` as
  the return value, or the normal-exit branch always halts with 0 regardless of
  `Tau.CLI.main/1`'s return.
- Does not address `Task.Supervisor.async_nolink`'s behaviour on supervisor
  shutdown — if `Tau.Tools.TaskSupervisor` is stopped before the task finishes,
  the task is killed and the `:DOWN` reason is `:killed`, which maps to halt(1).

### Costs

- ~15 lines changed in `lib/tau/application.ex`.
- One function deleted (`otel_reporter_spec/0`).
- The blocking `receive` must be documented; a reader who encounters it for the
  first time will likely want to understand why `start/2`'s caller blocks.
- Tests that assert `Tau.OtelReporter` is absent from the supervision tree when
  OTel is disabled will need to change — the child is now always present, just
  ignored at init time.

## Dependencies

- `Tau.Tools.TaskSupervisor` must remain in the child list above
  `maybe_dispatch_cli/0`'s call site — currently true, no order change needed.
- `Tau.OtelReporter.init/1` must return `{:stop, :ignore}` or `:ignore` when
  disabled — confirmed in place (the existing dual-gate relies on it).

## Confidence

Medium. The `async_nolink` + `Process.monitor` + `receive` pattern is correct
OTP but the exit-code-carrying subtlety (must `exit/1` inside the task, not
return) is a trap. A small prototype in IEx confirms the `:DOWN` message shape.
Confidence would rise to high after running the existing binary smoke test
(`mix test --only smoke`) against the patched version.

## Prior art / references

- OTP `Process.monitor/1` + `receive` — standard Erlang/OTP crash-detection
  idiom; documented in LYSE "Errors and Processes".
- `Task.Supervisor.async_nolink/3` — Elixir docs §"Supervised tasks and
  dynamic supervisors"; used in Elixir stdlib's own test helpers.
- `:ignore` from `init/1` — OTP Design Principles §"Starting a GenServer";
  `Supervisor` skips the child on `:ignore`.
- `max_restarts` / `max_seconds` guidance — OTP `supervisor(3)` manual,
  §"Intensity and Period".
