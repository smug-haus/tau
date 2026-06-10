---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Inline monitor-receive in start/2 with OTel init/1 as sole gate

## Approach

Remove `maybe_dispatch_cli/0` entirely. Instead, in `Tau.Application.start/2`,
after the supervisor returns `{:ok, pid}`, inline the CLI dispatch: spawn the
CLI work with `spawn_monitor/1`, then immediately block on a `receive` for the
`:DOWN` message and call `System.halt/1`. The OTel child list entry becomes
unconditional (always `Tau.OtelReporter`); `otel_reporter_spec/0` is deleted.
`max_restarts: 10, max_seconds: 60` is set on the root supervisor opts. No new
modules, no new Task.Supervisor usage.

## Rationale

`spawn_monitor/1` is the lowest-level Erlang/OTP primitive for "spawn a process
and be notified when it exits, regardless of exit reason, without linking." It
decouples crash-visibility from OTP supervision entirely — the monitor is a
private handle in the `Application.start/2` closure and cannot be accidentally
removed by a supervision tree change. Inlining the receive in `start/2` (after
the `{:ok, pid}` return to the Application controller) is the smallest change
that closes the criterion: no new module, no dependency on a named supervisor,
no `trap_exit` footgun. The OTel policy lives in exactly one place: `init/1`.

## Sketch

```elixir
# lib/tau/application.ex — start/2 only

@impl true
def start(_type, _args) do
  install_file_system_log_filter()

  children = List.flatten([
    Tau.Telemetry.Supervisor,
    Tau.OtelReporter,           # always present; init/1 returns :ignore if disabled
    {Phoenix.PubSub, name: Tau.PubSub},
    # ... all other children unchanged ...
    Tau.Sessions.Supervisor
  ])

  opts = [strategy: :rest_for_one, name: Tau.Supervisor, max_restarts: 10, max_seconds: 60]

  case Supervisor.start_link(children, opts) do
    {:ok, pid} ->
      :telemetry.execute([:tau, :app, :ready], %{system_time: System.system_time()}, %{
        version: Application.spec(:tau, :vsn) |> to_string()
      })

      case cli_argv() do
        :no_cli ->
          :ok

        {:dispatch, argv} ->
          {task_pid, ref} =
            spawn_monitor(fn ->
              exit_code =
                case Tau.CLI.main(argv) do
                  n when is_integer(n) -> n
                  _ -> 0
                end

              # exit/1 carries the code as the reason so the :DOWN message is
              # {:DOWN, ref, :process, pid, exit_code}.
              exit(exit_code)
            end)

          receive do
            {:DOWN, ^ref, :process, ^task_pid, exit_code} when is_integer(exit_code) ->
              System.halt(exit_code)

            {:DOWN, ^ref, :process, ^task_pid, :normal} ->
              System.halt(0)

            {:DOWN, ^ref, :process, ^task_pid, _reason} ->
              System.halt(1)
          end
      end

      {:ok, pid}

    other ->
      other
  end
end

# Delete: otel_reporter_spec/0
# Delete: maybe_dispatch_cli/0
```

The `{:ok, pid}` is returned after the `receive` block because the
Application controller process is what blocks — the supervisor PID is valid and
the supervision tree is running throughout. In `:no_cli` mode the `receive` is
never entered and `start/2` returns normally.

## Tradeoffs

### Strengths

- `spawn_monitor/1` is the canonical no-link, guaranteed-notification primitive —
  simpler than `Task.Supervisor.async_nolink` + `Process.monitor`, and carries
  no dependency on a named supervisor.
- No new files, no new modules, no new behaviours — the change is entirely
  self-contained in `lib/tau/application.ex`.
- The monitor handle is a private `ref` in the `start/2` scope; no other code
  can accidentally demonitor it.
- Closes (a), (b), (c) with the minimum diff.
- In `:no_cli` mode the code path is unchanged: `start/2` returns `{:ok, pid}`
  without entering the `receive` branch.

### Weaknesses

- Inlining the CLI dispatch in `start/2` makes that function longer and mixes
  the "build supervision tree" concern with the "run CLI and halt" concern.
- The blocking `receive` in `start/2` is unusual; without a comment, future
  maintainers may refactor it away thinking it is an accidental omission.
- `spawn_monitor/1` spawns an unlinked, unsupervised process — if the BEAM
  shuts down before the process finishes (e.g., another supervisor child crashes
  during CLI run), the CLI process is killed and `System.halt/1` fires with code 1.
  This is not worse than the current state but is still surprising.
- `exit(exit_code)` inside the spawned fn relies on `exit/1` with an integer
  argument being captured as-is in the `:DOWN` reason — this works in OTP
  (non-`:normal` exit reasons are propagated verbatim), but the normal-exit
  path (`exit(:normal)` or returning from the fn) would need special handling
  because `:normal` exits do send `:DOWN` with reason `:normal`, not the
  integer. The receive guard `when is_integer(exit_code)` handles this, but the
  interaction is subtle.

### Costs

- Net change: ~15 lines in `lib/tau/application.ex` (two functions deleted,
  `start/2` gains ~15 lines, the child list loses the conditional call).
- Same test updates as Proposal 1 (OTel always-in-tree, `maybe_dispatch_cli`
  call site removed).
- Requires a clear inline comment explaining the blocking `receive` idiom and
  the `exit(exit_code)` convention — otherwise a future reader will remove it.

## Dependencies

- No external dependencies beyond what is already in scope.
- `Tau.OtelReporter.init/1` must return `:ignore` when OTel is disabled
  (confirmed in existing code).
- The `{:ok, pid}` return at the end of `start/2` must follow the `receive`
  block — correct placement is critical; the Application controller must
  eventually see `{:ok, pid}` or `{:error, reason}`.

## Confidence

Medium. The `spawn_monitor` + `receive` pattern is correct vanilla OTP, but the
`exit(integer)` convention for carrying exit codes through `:DOWN` reasons is
an obscure idiom that requires documentation. Confidence rises to high after
verifying via a smoke test that normal exit and crash exit both call
`System.halt/1` with the expected code.

## Prior art / references

- `spawn_monitor/1` — Erlang/OTP `erlang:spawn_monitor/1` manual; simplest
  form of crash-visible spawn.
- `exit(reason)` carrying structured data in `:DOWN` reasons — Erlang/OTP
  process model; reason is any term, propagated verbatim in `:DOWN` unless `:normal`.
- Elixir `Application.start/2` blocking pattern — used by `IEx.App` which
  blocks the Application controller to ensure the IEx REPL drives the VM lifetime.
- `:ignore` from `GenServer.init/1` in unconditional child lists — standard OTP
  optional-child pattern.
