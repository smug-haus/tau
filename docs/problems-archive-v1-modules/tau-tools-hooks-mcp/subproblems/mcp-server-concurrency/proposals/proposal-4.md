---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: handle_continue-based non-blocking send — defer the transport I/O to handle_continue so the GenServer caller returns before the network call

## Approach

Keep the GenServer single-process architecture and the synchronous transport
callbacks, but eliminate the blocking `handle_call` by returning
`{:noreply, state, {:continue, {:send_invoke, id, rpc}}}` instead of calling
`transport.send/2` inside `handle_call`. The `handle_continue/2` callback then
performs the Finch call and, on completion, either queues the response line for
`handle_message/2` (Http) or simply returns (Sse — the SSE task delivers the
line as a message anyway). Pending entries are pruned via
`Process.send_after(self(), {:invoke_timeout, id}, @timeout)` with
`Process.cancel_timer/1` on successful reply. The `handle_info(_msg, state)`
catch-all is stripped of the `transport.recv` call and returns `{:noreply,
state}` unconditionally.

## Rationale

`:noreply` + `{:continue, ...}` is the standard OTP mechanism for deferring
work that should not block the caller without reaching for a separate process.
`handle_continue/2` runs immediately after the `handle_call` reply is sent —
before any other message in the mailbox — so the caller's `GenServer.call`
returns with control while the blocking I/O happens in the next scheduler slice.
Crucially, `handle_continue` executes serially in the same GenServer loop, so
no extra process, supervision wiring, or message-passing machinery is required.
The catch-all drain is eliminated because it was compensating for a send that
blocked the GenServer; once send happens in `handle_continue` and the response
is immediately available (Http) or message-driven (Sse), there is nothing to
drain.

Note: `handle_continue` does NOT actually let another `handle_call` run between
the original `handle_call` return and `handle_continue` execution. The caller
*receives* the reply immediately (i.e., its `GenServer.call` returns), but the
Server processes `handle_continue` before any other message. Therefore this
proposal does NOT achieve true concurrency between multiple simultaneous `invoke`
calls — it only unblocks the *caller* from the network round-trip, not the
Server's own serialisation.

## Sketch

```elixir
# server.ex — handle_call returns immediately with {:continue, ...}
@impl true
def handle_call({:invoke, tool, params}, from, state) do
  {id, state} = next_id(state)
  rpc = encode_invoke_rpc(id, tool, params)
  timer_ref = Process.send_after(self(), {:invoke_timeout, id}, @timeout)
  state = %{state | pending: Map.put(state.pending, id, {from, timer_ref})}
  emit_telemetry(:start, state.name, tool, id)
  {:noreply, state, {:continue, {:send_invoke, id, rpc}}}
end

# handle_continue performs the blocking I/O
@impl true
def handle_continue({:send_invoke, id, rpc}, state) do
  case state.transport.send(state.transport_state, rpc) do
    {:ok, ts} ->
      state = %{state | transport_state: ts}
      # Http: response is now synchronously in the queue; drain it now
      case state.transport.recv(ts, 0) do
        {:ok, [line | _], ts2} ->
          {:noreply, state |> Map.put(:transport_state, ts2) |> handle_message_return(line)}
        _ ->
          {:noreply, state}
      end

    {:error, e} ->
      case Map.pop(state.pending, id) do
        {{from, timer_ref}, pending} ->
          Process.cancel_timer(timer_ref)
          GenServer.reply(from, {:error, e})
          {:noreply, %{state | pending: pending}}
        {nil, _} ->
          {:noreply, state}
      end
  end
end

# timeout prune
@impl true
def handle_info({:invoke_timeout, id}, state) do
  case Map.pop(state.pending, id) do
    {{from, _timer_ref}, pending} ->
      GenServer.reply(from, {:error, :timeout})
      {:noreply, %{state | pending: pending}}
    {nil, _} ->
      {:noreply, state}
  end
end

# catch-all — no recv, no side effects
@impl true
def handle_info(_msg, state), do: {:noreply, state}

# Helper: inline handle_message result into handle_continue return
defp handle_message_return(state, line) do
  case handle_message(line, state) do
    {:noreply, new_state} -> new_state
    {:stop, _, new_state} -> new_state  # propagate stop via handle_continue
  end
end
```

Pending map shape: `id => {from, timer_ref}` (current `id => from` changes to
carry the cancel-able timer ref).

`handle_message/2` and `route_response/2` need minor updates: they now call
`Process.cancel_timer(timer_ref)` when a successful reply is sent, requiring
them to receive `timer_ref` from the `pending` map (current shape: `id => from`
→ new shape: `id => {from, timer_ref}`).

## Tradeoffs

### Strengths

- Minimal structural change: no new processes, no supervision wiring, no
  behaviour-callback signature changes.
- The caller's `GenServer.call` is unblocked from the network I/O latency —
  the 30 s timeout now starts from the time `handle_call` returns, not from
  when the Finch call completes.
- Catch-all drain is removed cleanly.
- Pending pruning via `send_after` + `cancel_timer` is explicit and well-
  understood.
- No unsupervised processes.

### Weaknesses

- Does NOT achieve concurrent `invoke` calls: `handle_continue` runs
  before the next message, so a second `invoke` still waits for the first
  `handle_continue`'s Finch call to complete. The Server remains serialised
  for Http. (This is the fundamental limitation of `handle_continue` for this
  use case — it is documented explicitly in the OTP docs: "handle_continue is
  called immediately after handle_call / handle_cast before processing the next
  message".)
- For the acceptance criterion clause (a) — "concurrent `invoke` calls proceed
  without one blocking the other" — this proposal satisfies the caller-side
  requirement (callers return from `GenServer.call` concurrently) but NOT the
  server-side throughput requirement (the GenServer still serialises Http I/O).
  Whether this satisfies the acceptance criterion depends on how "blocking the
  other" is interpreted.
- Deferred Http `recv/2` in `handle_continue` is still synchronous; if the
  test asserts two concurrent invokes both complete in parallel (not just
  return fast), this proposal fails.
- Pending map shape change (`from` → `{from, timer_ref}`) touches
  `route_response/2` and all `reply_to` callers.

### Costs

- ~40–60 LOC change confined to `server.ex`; transport modules untouched.
- The `handle_continue` callback must be added; it is boilerplate-compatible.
- Test that issues two concurrent slow-Http invokes and asserts both complete
  without blocking will fail under this proposal unless the mock transport
  is instant (at which point the test is vacuous). Tests must be designed to
  distinguish caller unblocking from server parallelism.

## Dependencies

- `handle_continue/2` is available since Elixir 1.7 / OTP 21; no upgrade needed.
- No new dependencies.

## Confidence

High for the code change itself (straightforward OTP pattern). Low for
satisfying the acceptance criterion's concurrency clause — this proposal
explicitly does not achieve server-side parallelism for Http. Confidence in
"correct for the stated problem" is medium: if the acceptance criterion
requires both callers to complete concurrently (as implied by "issues two
concurrent `invoke` calls and asserts both complete without one blocking the
other"), this proposal fails the test.

## Prior art / references

- OTP `handle_continue/2` documentation: https://hexdocs.pm/elixir/GenServer.html#c:handle_continue/2
  — explicitly notes it executes before any other message is processed.
- *The little Elixir & OTP Guidebook* (Tan Wei Hao) §8 — `handle_continue`
  for deferred initialisation; same semantics apply to deferred I/O.
- Contrast with Proposal 1 (Task-per-invoke) and Proposal 3 (ConnectionOwner)
  which achieve true server-side parallelism at higher structural cost.
