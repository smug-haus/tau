---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Per-server connection process — extract Http/Sse I/O into a dedicated GenServer (or gen_statem) that owns the transport and delivers lines to the Server via messages

## Approach

Introduce `Tau.MCP.Transport.ConnectionOwner` — a supervised GenServer (one per
MCP Server) that owns the transport and all blocking I/O. The `Server` no longer
holds `transport_state` or calls transport callbacks directly. Instead, `Server`
sends `{:cast_send, payload}` to its paired `ConnectionOwner`; the
`ConnectionOwner` performs the blocking Finch call (or drives the SSE stream) in
its own process and, when a response arrives, sends `{:mcp_line, line}` back to
the `Server`. The `Server`'s `handle_call({:invoke, ...})` stores `from` in
`pending` and returns `{:noreply, state}` immediately after casting to the
`ConnectionOwner` — no blocking. The `handle_info(_msg, state)` catch-all
in `Server` becomes unconditional `{:noreply, state}`. Pending-map pruning uses
`Process.monitor(from_pid)` to detect caller timeouts.

## Rationale

The complecting seam here is that the GenServer — which should manage RPC
lifecycle (correlating requests to responses, storing pending callers) — also
manages transport I/O (choosing when to do network calls, holding connection
state). Separating these into two processes gives each a clear, single
responsibility: `ConnectionOwner` owns all I/O state and blocks as needed;
`Server` owns all RPC state (pending map, tool registry, ID counter) and never
blocks. This is the classic BEAM "one concern per process" decomposition. The
catch-all drain was necessitated by the Server holding transport state; once
transport state lives in `ConnectionOwner`, the catch-all has nothing to do.

## Sketch

New module:

```elixir
defmodule Tau.MCP.Transport.ConnectionOwner do
  @moduledoc """
  Supervised GenServer owning the transport I/O for one MCP Server.
  Performs blocking send/recv in its own process; delivers parsed lines
  to its paired Server pid.
  """
  use GenServer

  def start_link({config, server_pid}) do
    GenServer.start_link(__MODULE__, {config, server_pid})
  end

  def cast_send(owner, payload) do
    GenServer.cast(owner, {:send, payload})
  end

  @impl true
  def init({config, server_pid}) do
    transport = pick_transport(config)
    {:ok, ts} = transport.connect(config)
    # For SSE, the connect/1 already spawns the stream task that sends
    # {ref, {:line, _}} to self() (the ConnectionOwner, not the Server).
    {:ok, %{transport: transport, transport_state: ts, server_pid: server_pid}}
  end

  @impl true
  def handle_cast({:send, payload}, state) do
    # Blocking Finch call here — but only blocks ConnectionOwner, not Server
    case state.transport.send(state.transport_state, payload) do
      {:ok, ts} ->
        # Http: response is already in queue; recv immediately and forward
        case state.transport.recv(ts, 0) do
          {:ok, [line | _], ts2} ->
            Process.send(state.server_pid, {:mcp_line, line}, [])
            {:noreply, %{state | transport_state: ts2}}
          _ ->
            {:noreply, %{state | transport_state: ts}}
        end
      {:error, _} = err ->
        Process.send(state.server_pid, {:mcp_error, err}, [])
        {:noreply, state}
    end
  end

  # SSE stream task sends {ref, {:line, line}} to self (ConnectionOwner)
  @impl true
  def handle_info({ref, {:line, line}}, %{transport_state: %{ref: ref}} = state) do
    Process.send(state.server_pid, {:mcp_line, line}, [])
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
```

`Server` changes:

```elixir
# State: add connection_owner pid; remove transport, transport_state
defstruct [:name, :connection_owner, :pending, :next_id, :tools,
           :capabilities, :registered_keys, :buffered_requests]

# handle_call — fire and forget to ConnectionOwner
def handle_call({:invoke, tool, params}, from, state) do
  {id, state} = next_id(state)
  rpc = encode_invoke_rpc(id, tool, params)
  Tau.MCP.Transport.ConnectionOwner.cast_send(state.connection_owner, rpc)
  ref = Process.monitor(elem(from, 0))   # monitor the caller
  state = %{state | pending: Map.put(state.pending, id, {from, ref})}
  emit_telemetry(:start, state.name, tool, id)
  {:noreply, state}
end

# Inbound line from ConnectionOwner
def handle_info({:mcp_line, line}, state), do: handle_message(line, state)

# Caller timed out — prune pending entry
def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
  case Enum.find(state.pending, fn {_, {_, r}} -> r == ref end) do
    {id, _} -> {:noreply, %{state | pending: Map.delete(state.pending, id)}}
    nil -> {:noreply, state}
  end
end

# catch-all — truly unconditional
def handle_info(_msg, state), do: {:noreply, state}
```

Supervision: `Tau.MCP.Server` starts `ConnectionOwner` via `start_link` in its
own `init/1` (using `Supervisor.start_child` on a local inline supervisor, or
simply `Process.link`; a proper approach is a two-child supervisor:
`{ConnectionOwner, {config, self()}}` and `{Server, config}`).

## Tradeoffs

### Strengths

- `Server` can now handle arbitrarily many concurrent `invoke` calls without any
  of them blocking each other; all serialisation happens in `ConnectionOwner`
  (which is acceptable because one HTTP connection is inherently sequential).
- Separation of concerns is maximal: all transport state (url, headers, Finch
  options, SSE task) lives in `ConnectionOwner`; all RPC state lives in `Server`.
- The transport behaviour's `send/2` and `recv/2` may remain synchronous —
  only the owner process blocks, never the Server.
- The catch-all drain is eliminated because `Server` no longer has transport
  state to drain.
- Pending-map pruning via `Process.monitor(caller)` is simple and correct: the
  monitor fires if the caller crashes or times out and is GC'd.

### Weaknesses

- Introducing a second process per MCP server adds supervision complexity: the
  application supervisor (or `Tau.MCP.Reconciler`) must be updated to manage
  `ConnectionOwner` alongside `Server`.
- If `ConnectionOwner` crashes, `Server` loses its outbound channel. The two must
  be linked or monitored, and `Server` must handle `{:DOWN, _, _, owner_pid, _}`
  by restarting or stopping itself.
- Http transport is still serialised within `ConnectionOwner` — concurrent
  invocations queue behind the single `GenServer.cast` inbox. True concurrency
  would require a pool of `ConnectionOwner`s. This proposal makes the Server
  non-blocking but does not make the Http transport parallel.
- `Process.monitor(elem(from, 0))` monitors the caller's pid extracted from the
  GenServer `from` tuple. This is an undocumented detail of `from` (it is
  `{pid, tag}`); it works but is not part of the public API.
- Pending map scan on `:DOWN` is O(n) in the number of concurrent invocations;
  acceptable for small n but worth noting.

### Costs

- New module `lib/tau/mcp/transport/connection_owner.ex` (~80 LOC).
- `Server` drops `transport`/`transport_state` fields; all existing `handle_info`
  and `handle_call` transport-touching clauses are rewritten.
- Reconciler and/or application supervisor changes to start `ConnectionOwner`.
- ~150–180 LOC total change.
- Test doubles for the Server must now either stub `ConnectionOwner` or use an
  in-process fake that sends `{:mcp_line, ...}` directly.

## Dependencies

- No new library dependencies.
- The `Tau.MCP.Reconciler` must be updated to start and monitor
  `ConnectionOwner` alongside `Server` — a dependency within the same PR.

## Confidence

Medium. Process-per-concern is the canonical BEAM idiom and well-understood.
Confidence on the supervision wiring is medium (two-process pairs supervised
together require care); prior art in `Tau.Session` (GenServer + linked task
stream) is analogous.

## Prior art / references

- OTP design principle "one process per concern": *Programming Erlang* (Armstrong)
  §15 — stateful resource owners as dedicated processes.
- `Tau.Session` + provider stream task: similar pattern where a GenServer owns
  RPC state and a separate process owns I/O.
- Elixir `Finch.Pool` architecture: pool of connection-owner processes behind a
  coordinator, exactly analogous to what a `ConnectionOwner` pool would look like.
