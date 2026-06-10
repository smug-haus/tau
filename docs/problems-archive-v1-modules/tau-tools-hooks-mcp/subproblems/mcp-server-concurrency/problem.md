---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: mcp-server-concurrency — MCP server serialises all tool calls because transports block the GenServer

## Statement

`Tau.MCP.Server` is a GenServer that accepts concurrent `handle_call({:invoke,
...})` requests and stores their `from` pids in a `pending` map, intending to
reply asynchronously when a `{:line, _}` message arrives. In practice the Http
and SSE transports perform synchronous network I/O inside `send/2` (called from
`handle_call`), blocking the GenServer for the full round-trip of every request
— effectively serialising all tool invocations. Additionally, the SSE transport
queues incoming server-push events into a process mailbox, and `Server`'s
`handle_info(_msg, state)` catch-all drains the SSE queue on every unrecognised
message, meaning a stray BEAM message (`:DOWN`, a PubSub broadcast) can consume
a response that belongs to a pending caller.

## Context

- `lib/tau/mcp/server.ex:98-117` — `handle_call({:invoke, ...})`: sends the
  RPC, stores `from` in `pending`, returns `:noreply`. Intent is asynchronous
  reply via `handle_info({:line, ...})`.
- `lib/tau/mcp/transport/http.ex:24-38` — `send/2` calls
  `Finch.request(Tau.Providers.Finch)` synchronously, then enqueues the
  response body. `recv/2` pops from the queue synchronously. `handle_call`
  therefore blocks until the HTTP server responds.
- `lib/tau/mcp/transport/sse.ex:62-70` — `send/2` calls `Finch.request/2`
  synchronously; same blocking pattern.
- `lib/tau/mcp/server.ex:86-95` — `handle_info(_msg, state)` catch-all calls
  `state.transport.recv(state.transport_state, 0)` on every unrecognised
  message. For SSE this can drain a `{:line, line}` before the explicit
  `handle_info({:line, line}, state)` clause has a chance to match, routing the
  decoded response to no pending caller.
- `lib/tau/mcp/server.ex:101-117` — `pending` map is never pruned when a caller
  times out (`GenServer.call` at 30s). Stale `from` values accumulate.
- Flat audit critical findings: `server.ex:86-95` (phantom recv), `http.ex:
  18-21,41-46` (synchronous send), `sse.ex:62-70` (same), `server.ex:101-117`
  (pending map not pruned).

## Complecting hypothesis

**The MCP server's concurrency model is complected with the transport's I/O
strategy** because the server was designed for an async transport contract (send
queues a request; recv retrieves the response later) but all three current
transport implementations conflate send and receive into a single synchronous
call inside `send/2`. The server's `handle_info(_msg)` catch-all was apparently
added to handle messages arriving out-of-band from a truly async transport, but
for the SSE transport it creates a race between explicit `{:line, _}` handling
and the catch-all drain.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The problem is solved when: (a) `Http.send/2` and `Sse.send/2` do not block the
calling process for the network round-trip (either by delegating the HTTP call
to a spawned task and delivering the result via message, or by restructuring
`handle_call` to perform the send in a spawned task); (b) the `handle_info(_msg,
state)` catch-all in `Server` does not call `transport.recv` — it returns
`{:noreply, state}` unconditionally; (c) timed-out callers' entries are removed
from `pending` (either via `Process.monitor(from_pid)` in the server or via a
per-entry timer) — all three verifiable by a test that issues two concurrent
`invoke` calls against a mock slow HTTP transport and asserts both complete
without one blocking the other.

## Out of scope

- The SSE task leak on consumer crash (unlinked `Task.async`) — this is a
  lifecycle/supervisor concern, not the serialisation/drain-race concern. It is
  a related finding but requires its own fix (switch to `Task.Supervisor` or add
  a monitor); mixing it into this problem would widen the scope past one coherent
  shippable unit.
- MCP tool registration duplication on server restart (stale `Module.create/3`
  modules) — covered by the `dynamic-module-generation` sub-problem.
- The `@timeout 30_000` per-call cap with no per-call override — a UX
  limitation, not a correctness bug; noted in the flat audit as an info finding.
- `Tau.MCP.Reconciler` — its diff-start/stop logic is idiomatic; no concurrency
  concern there.

## Amendment log

- (none yet)
