---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Push close responsibility to the Port owner — link/demonitor-driven cleanup, no close_port/1

## Approach

Delete `close_port/1` entirely. Instead of actively closing the port at stream
cleanup, let the port's OS process exit naturally when the BEAM process that owns
it exits or when the stream's `after_fun` sends an explicit `{:command, ...}` to
the port instructing the subprocess to exit. Because ports are owned by the
process that opened them, the port closes automatically when the owner exits;
`port_done/1` and the cancel branch in `port_next/2` need only ensure the
subprocess receives a termination signal (via stdin or OS signal), not that they
call `Port.close/1` themselves.

Concrete changes:
1. `port_done/1`: send `{port, {:command, "exit"}}` or `Port.command(port, ...)` to signal
   the subprocess to terminate, then `Port.demonitor/2` if a monitor was set. Do not call
   `Port.close/1`.
2. Cancel branch in `port_next/2`: set the cancel flag (already done) and let `port_done/1`
   handle teardown on its natural invocation.
3. Remove `close_port/1` (all three clauses).

```elixir
# port_done/1 replacement sketch
defp port_done(%{port: port, tempfile: tempfile, janitor: janitor}) do
  # Signal subprocess to exit cleanly; port self-closes when the OS process exits
  if port && Port.info(port) do
    Port.command(port, "\x04")   # EOF / ctrl-D — the subprocess reads and exits
  end
  # ... tempfile cleanup, janitor notification unchanged ...
  :ok
end
```

## Rationale

The complecting hypothesis is that `close_port/1` conflates port liveness testing with
port closing. This proposal decomplects by changing the model: instead of the Elixir
process imposing a close on an OS-level port, it signals the subprocess to self-terminate,
then relies on BEAM's port-ownership semantics (port closes when the owner process exits,
or when the OS process exits). This removes the TOCTOU window not by improving the close
logic but by eliminating the close call entirely at the application layer. The only
`Port.info/1` remaining in `port_done/1` is a guard to avoid sending a command to a dead
port — which is an idiomatic guard-clause usage (no TOCTOU: a dead port receiving a
stale command is safe because the subprocess has already exited).

## Sketch

`lib/tau/coding_agents/claude_code.ex` — deletions and changes:

```diff
- defp close_port(nil), do: :ok
-
- defp close_port(port) when is_port(port) do
-   try do
-     if Port.info(port) do
-       Port.close(port)
-     end
-   catch
-     _, _ -> :ok
-   end
-   :ok
- end
-
- defp close_port(_), do: :ok
```

`port_done/1` replacement:

```diff
  defp port_done(%{port: port, tempfile: tempfile, janitor: janitor}) do
-   close_port(port)
+   # Signal subprocess to exit; BEAM closes the port when the OS process exits
+   if is_port(port) && Port.info(port) do
+     Port.command(port, <<4>>)   # EOF byte — subprocess interprets and exits
+   end
    if tempfile, do: File.rm(tempfile)
    notify_janitor(janitor)
    :ok
  end
```

Cancel branch in `port_next/2` — remove explicit close (cancel flag set; `port_done/1`
will run when the stream halts):

```diff
- close_port(acc.port)
```

## Tradeoffs

### Strengths

- Eliminates `close_port/1` entirely — no liveness-check/close complecting can recur.
- No `try/catch`, no TOCTOU, no `Port.info` guard that creates a race.
- Leverages BEAM ownership semantics: the simplest correct program is the one that does
  not attempt to do what the runtime already does.
- Satisfies the acceptance criterion (no `try/catch`; no TOCTOU window).

### Weaknesses

- The "signal subprocess to exit" mechanism is subprocess-dependent: the subprocess must
  honour the EOF byte or whatever signal is sent. If the subprocess ignores EOF, the port
  may linger. The current `Port.close/1` is a hard close; this proposal replaces it with
  a soft request.
- `Port.command/2` on a dead port raises `ArgumentError` — the guard `Port.info(port)` in
  `port_done/1` reintroduces a TOCTOU window, though a less consequential one (sending to
  a dead port is harmless; Port.close on a dead port is the error).
- The cancel branch currently calls `close_port/1` to eagerly free the OS subprocess;
  removing it means the subprocess may linger until `port_done/1` runs, which depends on
  the stream pipeline draining. In a high-cancel-rate scenario this could accumulate
  zombie OS processes.
- API-breaking change relative to the current model: callers that depend on the port
  being closed synchronously after `close_port/1` returns would be broken (though no
  such callers exist today).
- Requires understanding the subprocess protocol (how it handles EOF), which is not
  captured in this proposal.

### Costs

- Larger changeset than proposals 1–3: `port_done/1` changes, cancel branch changes,
  `close_port/1` deleted — 3 sites in 1 file.
- Risk of OS subprocess accumulation in the cancel path needs a targeted test.
- The subprocess EOF signal needs to be verified against the Claude Code CLI's stdin
  handling; if `<<4>>` is wrong, the mechanism is broken.

## Dependencies

- Must determine the correct termination signal for the Claude Code subprocess (EOF byte,
  SIGTERM via `Port.close`, or another mechanism). This requires reading the subprocess
  invocation in `start_port/2` and the CLI's signal handling.
- If the subprocess does not honour EOF, an OS-signal approach via `:os.cmd/1` or an
  explicit `Port.close/1` elsewhere is needed as a fallback.

## Confidence

Low. The approach is architecturally sound (leverage ownership over active close), but
the subprocess signal mechanism is unverified and the accumulation risk in the cancel
path is concrete. Confidence would rise to medium after verifying the subprocess
termination protocol and adding a test for cancel-path teardown.

## Prior art / references

- BEAM port ownership semantics: Erlang/OTP documentation, §Ports and Port Drivers —
  ports close automatically when the controlling process exits.
- Unix EOF / `SIGPIPE`: standard subprocess termination via stdin closure.
- Erlang `port_close/1` documentation: "The port terminates, and if the process that owns
  the port is alive, it receives a `{'EXIT', Port, normal}` message."
