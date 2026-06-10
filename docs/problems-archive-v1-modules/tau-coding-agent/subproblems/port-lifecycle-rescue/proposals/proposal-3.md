---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Monitor-and-receive — replace close_port/1 with a monitored close that is atomically safe

## Approach

Replace `close_port/1` with an implementation that uses `Port.monitor/1` and a
`receive` to detect liveness atomically. Before calling `Port.close/1`, monitor
the port; if the monitor fires before the close, the port is already dead and
`:ok` is returned; if the port is still alive, `Port.close/1` is called and the
monitor flushed. This eliminates the TOCTOU window by construction: the
monitor/close pair is the BEAM's atomic liveness-check mechanism for ports, and
no `try/catch` or `Port.info/1` pre-check is needed.

```elixir
defp close_port(nil), do: :ok

defp close_port(port) when is_port(port) do
  ref = Port.monitor(port)

  receive do
    {:DOWN, ^ref, :port, ^port, _reason} ->
      # Port already died before or during monitor setup — nothing to close
      :ok
  after
    0 ->
      # No DOWN message yet — port is live; close it, then flush the monitor
      Port.close(port)
      receive do
        {:DOWN, ^ref, :port, ^port, _reason} -> :ok
      after
        0 -> :ok
      end
  end
end

defp close_port(_), do: :ok
```

The `after 0` in the outer receive ensures the liveness check does not block.
No `try/catch`, no `Port.info/1`, no TOCTOU window.

## Rationale

`Port.info/1` followed by `Port.close/1` is a classic check-then-act race
(TOCTOU): the port can die in the OS between the two calls, which is precisely
what the `catch` was trying to handle. The BEAM's `Port.monitor/1` mechanism is
the correct tool for atomic port-liveness detection — it delivers a `:DOWN`
message to the monitoring process when the port exits, and the `:DOWN` message
may already be in the mailbox if the port died before the monitor was established.
The `after 0` receive pattern is the idiomatic BEAM idiom for "check the mailbox
right now without blocking", eliminating the race at the language/runtime level
rather than at the application level. This approach neither uses `try/catch` nor
performs a non-atomic liveness check.

## Sketch

Full replacement in `lib/tau/coding_agents/claude_code.ex`:

```elixir
defp close_port(nil), do: :ok

defp close_port(port) when is_port(port) do
  ref = Port.monitor(port)

  # Check if the port is already dead (DOWN message already in mailbox)
  receive do
    {:DOWN, ^ref, :port, ^port, _reason} ->
      :ok
  after
    0 ->
      # Port is live — close it and consume the DOWN it will now emit
      Port.close(port)
      receive do
        {:DOWN, ^ref, :port, ^port, _reason} -> :ok
      after
        5 -> :ok   # Safety valve: port teardown is async; 5ms is generous
      end
  end
end

defp close_port(_), do: :ok
```

No call-site changes. No new modules. One file changed.

Type implied by the implementation: `close_port(port :: port() | nil | term()) :: :ok`
— same as today.

## Tradeoffs

### Strengths

- Eliminates the TOCTOU window by construction — no race is possible with monitor/receive.
- No `try/catch` or `try/rescue` at all — fully satisfies the acceptance criterion.
- Unexpected errors (e.g., the monitor itself failing) propagate normally.
- The monitor flush after `Port.close/1` prevents stale `:DOWN` messages from polluting
  the caller's mailbox, which is good hygiene in a GenServer or Task context.
- Idiomatic BEAM pattern: `Port.monitor/1` + `after 0` is recognisable to OTP practitioners.

### Weaknesses

- Introduces a `receive` block in what is currently a simple synchronous function — any
  `close_port/1` call now touches the process mailbox, which can interact with other
  `receive` in the call stack in subtle ways (e.g., if the caller has a selective receive
  open elsewhere).
- The inner `after 5` safety valve is a magic number: too small risks missing the DOWN on
  a heavily loaded system; too large blocks the stream cleanup loop. The value is
  arbitrary.
- `Port.monitor/1` is only available from OTP 19+; the project is on OTP 27.2, so this is
  moot, but worth noting.
- More code than proposals 1 or 2 for a problem that may not warrant the complexity.
- If `close_port/1` is called from inside a `GenServer.handle_*` callback, the `receive`
  block will steal messages from the GenServer's mailbox before the OTP receive loop can
  process them — a subtle and hard-to-diagnose correctness issue.

### Costs

- ~20 lines of new code replacing ~12 lines.
- Increased cognitive load: the monitor/receive idiom requires OTP knowledge to read and
  maintain.
- Test surface: existing tests may need to mock port lifecycle more carefully since the
  function now interacts with the process mailbox.
- No library changes.

## Dependencies

- Must confirm `close_port/1` is never called from inside a `GenServer.handle_*` callback
  (where stealing mailbox messages would be dangerous). Current call sites are stream
  pipeline functions; they appear to run in a Task or process spawned for streaming.
- OTP 19+ (already satisfied by OTP 27.2).

## Confidence

Medium. The monitor/receive pattern is sound and idiomatic. The mailbox interaction with
GenServer callbacks is a real risk that must be ruled out before adopting this approach.
Confidence would rise to high after confirming call-site execution contexts are safe for
selective receive.

## Prior art / references

- Elixir `Port.monitor/1` documentation: the correct mechanism for atomic port-liveness
  detection.
- BEAM Wisdoms / "Learn You Some Erlang": the `receive ... after 0` pattern for non-blocking
  mailbox inspection is a well-established OTP idiom.
- Erlang/OTP source: `gen_server.erl` uses monitor + receive for client-call liveness
  (the `gen:call/4` implementation).
