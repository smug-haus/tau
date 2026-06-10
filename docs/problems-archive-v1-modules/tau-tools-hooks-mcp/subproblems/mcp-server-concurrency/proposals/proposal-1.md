---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Task-per-invoke — spawn a Task for each outbound HTTP call and let it deliver the result via message

## Approach

Move the synchronous `Finch.request/2` call out of `Http.send/2` and
`Sse.send/2` and into a per-invoke `Task`. The `handle_call({:invoke, ...})`
clause spawns a monitored Task that performs the HTTP POST, then returns
`{:noreply, state}` immediately. When the Task finishes it sends
`{ref, {:result, id, line}}` to the Server process; a new `handle_info` clause
matches that message, extracts the response line, and routes it through the
existing `handle_message/2` path. The `pending` map is extended to store
`{from, task_ref}` so that a `:DOWN` message on the task ref can prune the
entry if the task crashes. The `handle_info(_msg, state)` catch-all is stripped
of the `transport.recv` side-effect and made unconditional `{:noreply, state}`.

## Rationale

The complecting seam is that `send/2` conflates "initiate the network request"
with "block until response arrives", forcing `handle_call` to block the
GenServer. Spawning a Task for the Finch call makes the send side fire-and-forget
from the GenServer's perspective: the GenServer enqueues work and returns
immediately. The async reply path (`{:line, _}` → `route_response/2`) already
exists for the Stdio transport; this proposal reuses it for Http and Sse. The
catch-all drain (lines 86–95 of `server.ex`) was a workaround for the absence of
a real async path; once the Task delivers `{:line, _}` directly, the workaround
is no longer needed and can be deleted.

## Sketch

```elixir
# lib/tau/mcp/transport/http.ex — send/2 becomes non-blocking
@impl Tau.MCP.Transport
def send(%{url: url, headers: headers} = state, payload, caller_pid, rpc_id) do
  ref = make_ref()
  Task.start(fn ->
    headers = [{"content-type", "application/json"} | headers]
    body = IO.iodata_to_binary(payload)
    result =
      case Finch.build(:post, url, headers, body) |> Finch.request(Tau.Providers.Finch) do
        {:ok, %Finch.Response{status: s, body: resp}} when s in 200..299 -> {:line, resp}
        {:ok, %Finch.Response{status: s}} -> {:error, {:http_status, s}}
        {:error, e} -> {:error, e}
      end
    Process.send(caller_pid, {ref, rpc_id, result}, [])
  end)
  {:async, ref, state}
end
```

The `Tau.MCP.Transport` behaviour gains a new optional callback (default impl
for Stdio and Sse can stay synchronous in the `send/2` arity):

```elixir
@callback send(transport_state(), payload :: binary(), caller :: pid(), id :: integer()) ::
  {:ok, transport_state()} | {:async, reference(), transport_state()} | {:error, term()}
```

`Server.handle_call/3` changes to:

```elixir
def handle_call({:invoke, tool, params}, from, state) do
  {id, state} = next_id(state)
  rpc = encode_invoke_rpc(id, tool, params)

  case state.transport.send(state.transport_state, rpc, self(), id) do
    {:async, task_ref, ts} ->
      ref = Process.monitor_task_or_ref(task_ref)  # via Process.monitor on spawned pid
      state = %{state | transport_state: ts,
                        pending: Map.put(state.pending, id, {from, ref})}
      emit_telemetry(:start, state.name, tool, id)
      {:noreply, state}

    {:ok, ts} ->
      # Stdio / synchronous transports: result already queued
      state = %{state | transport_state: ts, pending: Map.put(state.pending, id, {from, nil})}
      {:noreply, state}

    {:error, e} ->
      {:reply, {:error, e}, state}
  end
end

# New handle_info clause — task delivers response
def handle_info({task_ref, rpc_id, {:line, line}}, state) when is_reference(task_ref) do
  Process.demonitor(task_ref, [:flush])
  handle_message(line, state)
end

def handle_info({task_ref, rpc_id, {:error, reason}}, state) when is_reference(task_ref) do
  Process.demonitor(task_ref, [:flush])
  {target, pending} = Map.pop(state.pending, rpc_id)
  if target, do: GenServer.reply(elem(target, 0), {:error, reason})
  {:noreply, %{state | pending: pending}}
end

# :DOWN from crashed task — prune pending entry
def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
  case Enum.find(state.pending, fn {_, {_, r}} -> r == ref end) do
    {id, {from, _}} ->
      GenServer.reply(from, {:error, {:task_crashed, reason}})
      {:noreply, %{state | pending: Map.delete(state.pending, id)}}
    nil ->
      {:noreply, state}
  end
end

# catch-all — no longer touches transport
def handle_info(_msg, state), do: {:noreply, state}
```

Pending map shape changes: `id => from` (current) → `id => {from, monitor_ref | nil}`.

## Tradeoffs

### Strengths

- Both Http and Sse `send/2` are non-blocking; concurrent `invoke` calls proceed
  in parallel limited only by Finch's connection pool.
- Minimal diff to the existing async-reply architecture: `handle_message/2` and
  `route_response/2` are untouched.
- Task crash delivers an `{:error, ...}` to the caller instead of hanging at the
  30 s timeout; the pending entry is pruned immediately.
- The catch-all drain is removed cleanly without touching Sse logic.
- Satisfies all three acceptance-criterion clauses: (a) non-blocking send,
  (b) catch-all no longer calls recv, (c) pending pruning on crash/`:DOWN`.

### Weaknesses

- The `Tau.MCP.Transport` behaviour callback signature gains an arity-4 `send/4`
  variant (or a new callback); existing Stdio transport must be updated to declare
  the callback (or provide a default delegation).
- Task.start (fire-and-forget) with no supervisor is an unsupervised process:
  if the Server crashes mid-flight the Task orphans. Accepted here because the
  Task's only side effect is sending one message; it cannot corrupt state.
- The `pending` map value shape change (`from` → `{from, ref}`) touches all
  `route_response/2` and `:DOWN` match arms.
- Sse.send/2's synchronous POST is still used (the Finch POST is quick; only the
  SSE GET stream delivers the response). This proposal only fixes the Http
  blocking; the Sse POST is already ~instant but the Sse recv still blocks
  differently — that is not the hot path for Sse.

### Costs

- ~60–80 LOC change across `server.ex`, `transport/http.ex`, `transport/sse.ex`,
  and `mcp/transport.ex` (behaviour spec).
- All existing `handle_info` clauses in `server.ex` must be re-ordered because
  the new task-ref clause must match before the catch-all.
- Tests that mock the Http transport's `send/2` must be updated to the 4-arity
  form.

## Dependencies

- No library additions; Elixir's `Task.start/1` and `Process.monitor/1` are stdlib.
- Behaviour callback arity change must land in the same PR as the Server changes
  to avoid a compile-time mismatch.

## Confidence

Medium. The architecture is sound (Elixir task-per-request with monitored ref is
a well-established pattern). Confidence would rise to high after a prototype
confirming that `Process.monitor/1` on a bare `Task.start` pid returns a usable
ref (it does, but the task-ref / monitor-ref distinction warrants a test).

## Prior art / references

- Elixir `Task.start/1` + `Process.monitor/1` for fire-and-forget with crash
  detection: standard OTP idiom, see *Designing for Scalability with Erlang/OTP*
  (Cesarini & Vinoski) §7.
- `Finch.async_request/3` — Finch's own async API; an alternative to Task.start
  that delivers `{ref, result}` directly without spawning an explicit Task (see
  Proposal 2 for this axis).
- Pattern used in `Tau.Session` for provider stream tasks: `Task.async` + monitor.
