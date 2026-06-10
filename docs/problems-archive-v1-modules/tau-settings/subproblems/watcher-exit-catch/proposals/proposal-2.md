---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Extract FileSystem startup into a monitored helper process

## Approach

Move the `FileSystem.start_link/1` call out of `maybe_start_watcher/1` and into a
short-lived helper process spawned with `Task.async/1` (or bare `spawn_monitor`).
The helper attempts `FileSystem.start_link(dirs: dirs)`; `maybe_start_watcher/1`
awaits the result via `receive` with a timeout. If the helper exits abnormally, the
monitor delivers a `{:DOWN, ref, :process, pid, reason}` message; `maybe_start_watcher/1`
matches this as a soft-failure tuple. No `catch :exit` is needed because the exit is
caught at the inter-process message boundary, not inside the Watcher's own process.

## Rationale

The core complection is that the Watcher process's startup path interleaves two
concerns: (1) receiving OTP crash signals from `FileSystem` and (2) mapping
soft-failures to degraded-mode state. Proposal 1 resolves this by letting crashes
propagate, which is correct when the supervisor's restart policy allows it. This
proposal takes a different stance: the Watcher *intentionally* wants to survive a
`FileSystem` crash and enter degraded mode. It achieves that without violating OTP NN
#7 by never calling `FileSystem.start_link/1` inside its own process — the call runs
in a sacrificial helper, and the Watcher observes the outcome via message, not exit
propagation. The Watcher process never has an `:exit` to catch.

## Sketch

```elixir
defp maybe_start_watcher(dirs) do
  cond do
    not Code.ensure_loaded?(FileSystem) ->
      {:error, :file_system_not_loaded}

    dirs == [] ->
      {:error, :no_dirs}

    true ->
      start_via_helper(dirs)
  end
end

defp start_via_helper(dirs) do
  ref = make_ref()
  caller = self()

  {_task_pid, mon} =
    spawn_monitor(fn ->
      result =
        case FileSystem.start_link(dirs: dirs) do
          {:ok, pid} ->
            FileSystem.subscribe(pid)
            {:ok, pid}

          other ->
            {:error, other}
        end

      send(caller, {ref, result})
    end)

  receive do
    {^ref, result} ->
      # Helper exited normally after sending result; flush the DOWN message.
      receive do
        {:DOWN, ^mon, :process, _, _} -> :ok
      after 0 -> :ok
      end

      result

    {:DOWN, ^mon, :process, _, reason} ->
      # Helper exited abnormally (FileSystem crashed during start_link).
      {:error, {:fs_start_exit, reason}}
  after
    5_000 ->
      {:error, :fs_start_timeout}
  end
end
```

`init/1` and its callers are unchanged. Degraded-mode telemetry fires for both
`{:error, {:fs_start_exit, _}}` and `{:error, :fs_start_timeout}` via the
existing `other ->` arm.

## Tradeoffs

### Strengths

- Explicitly models the Watcher's *intent*: it wants to survive a FileSystem crash
  and operate in degraded mode. Proposal 1 pushes that intent onto the supervisor
  restart policy; this proposal keeps it local and visible.
- Strictly OTP-compliant: no `catch :exit` inside any process. The exit is
  observed as a monitor message at an inter-process boundary.
- Works regardless of the supervisor's restart strategy for the Watcher.
- Distinguishes `FileSystem` crash reasons (`:fs_start_exit`) from soft failures
  (`:error, other`) in telemetry — useful for observability.

### Weaknesses

- Significantly more complex than Proposal 1: introduces an extra process,
  a `receive` block with a timeout, and two message shapes. Code is harder
  to audit at a glance.
- The 5-second timeout is arbitrary. If `FileSystem.start_link/1` legitimately
  blocks (rare but possible on network filesystems), the Watcher enters
  degraded mode incorrectly. Tuning this is context-dependent.
- The helper process holds the `FileSystem` pid briefly; if the Watcher crashes
  after the helper exits successfully, the `FileSystem` subscription is orphaned.
  This is the same as the current behaviour but is now less visible.
- More code surface = more test burden. The timeout path is hard to test
  deterministically.
- Spawning a process per Watcher init is a side-effect in an otherwise-pure
  startup path — makes the call not referentially testable without full OTP.

### Costs

- ~30 lines added; one file changed.
- No new dependencies.
- Test coverage of the new `start_via_helper/1` requires either a test double
  for `FileSystem` or a mock process — non-trivial.

## Dependencies

- None external. The pattern uses only OTP primitives (`spawn_monitor`, `receive`).

## Confidence

medium — the pattern is correct OTP; the complexity cost is real. Confidence
would rise with a prototype or with an established precedent elsewhere in the
Tau codebase for this approach.

## Prior art / references

- OTP design principle: process monitors as crash-observation without coupling
  the observer's lifecycle to the crashed process.
- Erlang/OTP docs: `Process.monitor/1` and `receive` for inter-process
  error propagation.
- Tau's own `Tau.Session` uses monitored refs for cross-process coordination
  (OTP NN #4).
