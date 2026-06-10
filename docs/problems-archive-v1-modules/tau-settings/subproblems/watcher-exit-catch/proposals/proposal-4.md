---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Move FileSystem startup to a supervised child and handle :DOWN in Watcher

## Approach

Restructure `Tau.Settings.Watcher` so that `FileSystem` is started as a separate,
supervised child process rather than via `start_link` inside `init/1`. The Watcher's
`init/1` starts `FileSystem` with `start_link` and immediately monitors the resulting
pid. No `try/rescue/catch` is used. If `FileSystem` fails to start (returning
`{:error, reason}`), the Watcher enters degraded mode directly from `init/1`'s
pattern match. If `FileSystem` crashes *after* a successful start, the Watcher
receives a `{:DOWN, ref, :process, pid, reason}` message in `handle_info/2` and
transitions to degraded mode at that point, emitting telemetry. The `catch :exit`
arm is simply deleted — if `FileSystem.start_link/1` itself exits synchronously
during `init/1`, the exit propagates and the supervisor handles the Watcher restart.

## Rationale

The current code conflates two distinct temporal states: (a) `FileSystem` fails to
start at all (synchronous startup failure), and (b) `FileSystem` crashes after
successful startup (asynchronous runtime failure). The `catch :exit` nominally
addresses only case (a), but it also silently swallows case (b)'s symptom when the
two coincide. By adding a `Process.monitor/1` call after a successful start, the
Watcher handles case (b) explicitly via `handle_info/2`. This separates the two
concerns at the control-flow level: startup failure = pattern-match on `start_link`
return; runtime failure = monitor `DOWN` message. The `catch :exit` becomes
unnecessary for both cases and is removed.

## Sketch

```elixir
@impl true
def init(opts) do
  dirs = resolve_dirs(opts)   # extracted from current init/1 — same logic

  {watcher_pid, mon} =
    case maybe_start_watcher(dirs) do
      {:ok, pid} ->
        {pid, Process.monitor(pid)}

      other ->
        emit_degraded_telemetry(other)
        {nil, nil}
    end

  {:ok, %{watcher: watcher_pid, watcher_mon: mon, dirs: dirs, debounce: nil}}
end

# No try/rescue/catch — returns {:ok, pid} | {:error, reason}
defp maybe_start_watcher(dirs) do
  cond do
    not Code.ensure_loaded?(FileSystem) ->
      {:error, :file_system_not_loaded}

    dirs == [] ->
      {:error, :no_dirs}

    true ->
      case FileSystem.start_link(dirs: dirs) do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          {:ok, pid}

        other ->
          {:error, other}
      end
  end
end

@impl true
def handle_info({:DOWN, ref, :process, _pid, reason}, %{watcher_mon: ref} = state) do
  Logger.debug("Tau.Settings.Watcher: FileSystem exited — #{inspect(reason)}")
  emit_degraded_telemetry({:exit, reason})
  {:noreply, %{state | watcher: nil, watcher_mon: nil}}
end

# existing handle_info clauses unchanged below...
```

```elixir
defp emit_degraded_telemetry(reason) do
  Logger.debug("Tau.Settings.Watcher disabled: #{inspect(reason)}")
  :telemetry.execute(
    [:tau, :settings, :watcher_degraded],
    %{system_time_native: System.system_time(:native)},
    %{reason: reason}
  )
end
```

State shape gains one field: `watcher_mon: reference() | nil`.

## Tradeoffs

### Strengths

- Handles *both* startup failure and runtime crash explicitly — more complete
  than Proposal 1 (which only removes the catch) and without the helper-process
  complexity of Proposal 2.
- The Watcher's degraded-mode semantics become richer: it can re-enter degraded
  mode at runtime if `FileSystem` crashes, not just at startup.
- OTP NN #7 compliant: no `catch :exit`, no `try/rescue` across process
  boundaries.
- `emit_degraded_telemetry/1` is extracted as a named function, making telemetry
  emission independently testable.
- Monitor-based crash observation is the canonical OTP pattern (OTP NN #4).

### Weaknesses

- Adds a new state field (`watcher_mon`) — slightly more state to track and
  propagate. Any code that pattern-matches `Watcher` state (e.g. in tests that
  inspect GenServer state) must be updated.
- The `handle_info({:DOWN, ...})` clause introduces a new code path that has no
  test in the current suite and would require a more complex test setup
  (starting a real `FileSystem` and then killing it, or mocking the monitor
  message).
- If `FileSystem.start_link/1` exits synchronously during `init/1` (not returns
  `{:error, _}`, but actually exits), the exit still propagates to the
  supervisor — same as Proposal 1. The monitor only covers post-startup crashes.
  This is correct OTP behaviour, but it means degraded-mode telemetry does NOT
  fire for synchronous `:exit` from `start_link`. That gap is acceptable (an
  exit from `start_link` is a true crash, not a soft failure) but should be
  documented.
- Slightly more code than Proposal 1: ~15 lines added, 5 lines removed.

### Costs

- 1 file changed: `lib/tau/settings/watcher.ex`.
- State shape change (`watcher_mon` field) — no external consumers of Watcher
  state in the codebase (GenServer state is private), so migration cost is zero.
- Existing tests are unaffected.
- New test for the `{:DOWN, ...}` path would require either a real `FileSystem`
  start+kill sequence or injecting a monitor message via `send/2` in test.

## Dependencies

- `Process.monitor/1` — standard OTP primitive, no library dependency.
- Assumption: no external module accesses `Tau.Settings.Watcher`'s internal
  state directly. This holds for GenServers by OTP convention.

## Confidence

high — `Process.monitor/1` + `handle_info({:DOWN, ...})` is the idiomatic OTP
pattern for supervised dependencies that are not direct children in the same
supervision tree. Prior art in Tau: session monitoring uses the same pattern.

## Prior art / references

- OTP NN #4: "Cross-process events MUST use `Phoenix.PubSub` or monitored refs."
- Elixir `Process.monitor/1` docs — canonical crash observation mechanism.
- Tau `Tau.Session` — uses `Process.monitor` for coding-agent lifecycle.
- *Programming Erlang* (Armstrong, 2nd ed.) §13: monitor-based fault isolation
  as the correct alternative to catching exits.
