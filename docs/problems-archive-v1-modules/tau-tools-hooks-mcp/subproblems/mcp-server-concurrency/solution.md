---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-2.md]
selection_method: hybrid
revision: 0
---

# Solution: Task-per-invoke with async-contract behaviour enforcement

## Recommendation

Replace the synchronous `send/2` path in `Http` and `Sse` transports with a
per-invoke `Task.start/1` that delivers `{ref, rpc_id, result}` to the Server;
simultaneously upgrade the `Tau.MCP.Transport` behaviour to document and enforce
the non-blocking contract and remove `recv/2` from the specification. The Server's
`handle_call({:invoke, ...})` returns `{:noreply, state}` immediately; a new
`handle_info` clause matches task results; the catch-all is stripped of the
`transport.recv` side-effect unconditionally; and timed-out callers' entries are
pruned via `Process.monitor/1` on the caller pid stored alongside `from` in the
`pending` map. This satisfies all three acceptance-criterion clauses — (a) non-
blocking send, (b) unconditional catch-all, (c) pending pruning on `:DOWN` — while
keeping the Http delivery path simple (one level of async indirection, not two)
and expressing the correct contract in the behaviour so future transport
implementors cannot reintroduce the serialisation bug.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-1.md` (Task-per-invoke delivery) +
  `proposals/proposal-2.md` (async-contract behaviour enforcement, `recv/2`
  removal).
- **Why chosen:** Proposal 1 satisfies all three AC clauses with the smallest
  diff (~60–80 LOC) and the simplest Http delivery path (one Task, one message).
  Its weakness is that it leaves `recv/2` as dead behaviour surface and does not
  prevent future transports from reimplementing the synchronous anti-pattern.
  Proposal 2 corrects the behaviour contract root-cause (removes `recv/2`,
  documents the non-blocking requirement) but introduces double async indirection
  for Http (`Finch.async_request` + bridge Task) for no gain over a plain
  `Task.start`; it also requires `cancel_timer` discipline on every success path.
  Proposal 3 (ConnectionOwner) achieves maximal separation but still serialises
  Http within the single owner and adds a new supervised process pair, making it
  the right long-term refactor if Http parallelism is needed but overcomplicated
  for this fix. Proposal 4 explicitly fails AC clause (a) for server-side
  concurrency and is excluded. The hybrid takes Proposal 1's delivery mechanism
  (plain `Task.start` → `{ref, rpc_id, result}` message, monitor the task pid for
  `:DOWN` crash pruning) and Proposal 2's behaviour-level changes (remove `recv/2`
  callback; update docstring to state the non-blocking contract as an implementor
  obligation). The combination is more than the sum: P1 gives the correct runtime
  fix; P2 gives the structural guarantee that prevents regression.

## What changes

- **`lib/tau/mcp/transport.ex`** — remove the `recv/2` callback from the
  behaviour spec and its default implementation (if any); update the `send/2`
  (or add `send/4` per P1 sketch) callback doc to state "MUST NOT block for the
  network round-trip; response delivered via message to the Server process".
- **`lib/tau/mcp/transport/http.ex`** — rewrite `send/2` (or introduce `send/4`)
  to `Task.start/1` the `Finch.request` call and send `{ref, rpc_id, result}` to
  the caller pid; remove `recv/2` implementation.
- **`lib/tau/mcp/transport/sse.ex`** — the `Finch.request` in `send/2` is already
  fast (initiates the POST); verify and document it as non-blocking; remove
  `recv/2` implementation.
- **`lib/tau/mcp/transport/stdio.ex`** — remove `recv/2` implementation; verify
  the existing message-delivery path already conforms.
- **`lib/tau/mcp/server.ex`**:
  - `handle_call({:invoke, ...})`: return `{:noreply, state}` immediately after
    delegating to transport; store `{from, monitor_ref}` in `pending` (monitor
    the Task pid returned by `Http.send`; monitor the caller pid for Sse/Stdio).
  - Add `handle_info({ref, rpc_id, {:line, line}}, state)` clause to receive task
    result and route via existing `handle_message/2`.
  - Add `handle_info({ref, rpc_id, {:error, reason}}, state)` clause to reply
    error and prune `pending`.
  - Add `handle_info({:DOWN, ref, :process, _pid, reason}, state)` clause to
    prune `pending` on task crash or caller timeout.
  - Strip `transport.recv` from `handle_info(_msg, state)` catch-all; return
    `{:noreply, state}` unconditionally.
- **`test/tau/mcp/`** — update mock transport's `send/2` to 4-arity form (or
  the new async-delivery form); add test asserting two concurrent slow-Http
  invokes both complete without one blocking the other (slow transport mock
  sleeps 100 ms; both calls complete in ~100 ms wall time, not ~200 ms).

## What does not change

- `handle_message/2` and `route_response/2` logic in `server.ex` — only the
  pending-map value shape changes (`id => from` → `id => {from, monitor_ref}`);
  the routing logic is untouched.
- `Tau.MCP.Reconciler` — no new processes to start or supervise.
- `Tau.MCP.Transport.Stdio` — delivery mechanism already message-based; only
  `recv/2` removal is needed.
- The 30-second `@timeout` per-call cap — out of scope per the problem statement.
- The SSE task lifecycle / `Task.async` leak — explicitly out of scope per
  problem.md.
- The `pending` map's O(n) scan for `:DOWN` matching — acceptable for the
  expected concurrency level; the pending map is already bounded by the
  `@timeout`.

## Migration sketch

1. Update `transport.ex` behaviour first (remove `recv/2`, update docs); this is
   a compile-time-detectable break — all three transport modules will warn until
   updated.
2. Remove `recv/2` from all three transport modules in the same commit.
3. Rewrite `Http.send/2` → async Task delivery; update the callback arity if
   P1's 4-arity form is adopted (otherwise keep 2-arity and pass caller pid via
   transport state set during `connect/1`).
4. Update `server.ex`: pending map shape, new `handle_info` clauses, strip
   catch-all side-effect.
5. Add the concurrent-invoke test; verify it fails before step 3 and passes after.
6. Update any existing mock-transport test doubles that referenced `recv/2`.

The whole change is self-contained in `lib/tau/mcp/` and `test/tau/mcp/` — no
supervisor or application changes.

## Open questions

- **Arity of the `send` callback:** Proposal 1 proposes `send/4` (adds `caller_pid`
  and `rpc_id`); the hybrid can alternatively pass `caller_pid` via transport state
  set in `connect/1` and keep `send/2`. The 4-arity form is more explicit but
  breaks the existing `Stdio` and `Sse` implementations more broadly; the
  transport-state approach avoids arity proliferation. Decision should be made
  before implementation starts.
- **`Task.start` vs `Task.Supervisor.start_child`:** P1 accepts unsupervised
  `Task.start`; the `:DOWN` monitor on the task pid handles crash detection. If the
  Server crashes mid-flight the orphaned Task's only side effect is sending an
  undelivered message — benign. Confirm this is the accepted tradeoff before
  landing, given the project's OTP non-negotiable on supervised processes.
- **`Finch.async_request` vs `Task.start`:** P2 uses `Finch.async_request/3`;
  this hybrid recommends `Task.start` + `Finch.request` (synchronous inside the
  Task) for simpler tracing and a single level of async. If Finch's connection
  pool benefits (backpressure, pool limit) are important, `Finch.async_request`
  is worth revisiting.
- **Sse concurrent-invoke semantics:** SSE is an event-stream protocol; multiple
  concurrent invokes over a single SSE connection interleave responses as server-
  push events. Confirm whether `rpc_id` correlation in `handle_message/2` already
  handles out-of-order responses before declaring the fix complete for Sse.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Task-per-invoke: spawn a Task per outbound HTTP
  call; task delivers result as message; monitor for crash pruning.
- `proposals/proposal-2.md` — Async transport contract: enforce non-blocking
  `send/2` at the behaviour level; remove `recv/2`; use `Finch.async_request`.
- `proposals/proposal-3.md` — ConnectionOwner: separate GenServer per MCP server
  for all transport I/O. Not selected: adds supervision complexity; Http still
  serialises within the owner; overcomplicated for this fix.
- `proposals/proposal-4.md` — `handle_continue`-based deferral. Not selected:
  explicitly does not achieve server-side parallelism; fails AC clause (a) by its
  own admission.

## Revision history

- (revision 0 — initial)
