---
template_version: 1
template_name: problem
node_kind: internal
depth: 0
parent: —
status: decomposed
---

# Problem: tau-tools-hooks-mcp — Three subsystems, four complecting seams

## Statement

The tool-execution surface (built-in tools, hook dispatcher, MCP server
integration) shares three independent responsibilities — result-shape contract,
I/O collection, and concurrency model — that are woven together inconsistently
across the files. No single consumer can reason about what a tool result looks
like, whether a collector is bounded, or whether an MCP call serialises its
server, without reading implementation details scattered across all three
subsystems. Untangling these seams would allow each subsystem to be understood,
tested, and changed independently.

## Context

Source under audit:

- `lib/tau/tool.ex`, `lib/tau/tool/result.ex` — behaviour + result struct
- `lib/tau/tools/builtin/` — six built-in tool implementations
- `lib/tau/tools/operations/local.ex` — filesystem + process backend
- `lib/tau/hook.ex`, `lib/tau/hooks/dispatcher.ex`, `lib/tau/hooks/shell.ex` — hook behaviour + shell adapter
- `lib/tau/mcp/server.ex`, `lib/tau/mcp/tool_adapter.ex`, `lib/tau/mcp/reconciler.ex` — MCP server GenServer + registry
- `lib/tau/mcp/transport/{stdio,http,sse}.ex` — three transport implementations

Prior evidence: `.code_audit/archive/v1-flat/03-tools-hooks-mcp.md` — full
flat audit with severity-ranked findings. Behaviour interfaces (`Tau.Tool`,
`Tau.Hook`, `Tau.MCP.Transport`) are structurally sound; problems are
concentrated in the implementations.

## Complecting hypothesis

1. **Result-shape contract is complected with each tool's implementation**
   because `details.kind`, telemetry spans, and the "must never raise" rule are
   enforced nowhere central — each tool author chose independently whether to
   include them, producing silent drift.

2. **I/O collection strategy is complected with process lifecycle** because
   `local.ex`'s `bash/2`, `hooks/shell.ex`'s `collect/3`, and
   `mcp/transport/stdio.ex`'s `recv/2` each hand-roll `receive` loops that
   accumulate in unbounded binaries (`acc <> data`), making the truncation
   policy, the memory bound, and the cancellation path each tool's individual
   concern.

3. **MCP server concurrency is complected with transport state management**
   because `Http.send/2` blocks the GenServer for the full HTTP round-trip
   (serialising all tool calls), while the SSE transport's out-of-band
   `handle_info(_msg)` drain can silently consume queued responses that belong
   to pending callers.

## Decomposition strategy

Four MECE sub-problems, each isolating one complecting concern by the
**concern (Hickey)** axis:

- **tool-result-contract** — the shape and enforcement boundary that all tool
  implementations must satisfy (details schema, telemetry, raise prohibition).
  Covers all of `lib/tau/tools/builtin/`, `lib/tau/tool/result.ex`.
- **io-collectors** — the mechanics of binary accumulation and bounded
  collection in the three hand-rolled receive loops (Bash stdout, shell-hook
  stdout, MCP stdio). Covers `local.ex`, `hooks/shell.ex`,
  `mcp/transport/stdio.ex`.
- **mcp-server-concurrency** — the MCP server's synchrony model: how `invoke`
  calls serialise the GenServer when transports block, and how the
  `handle_info(_msg)` clause drains the SSE queue out of band. Covers
  `mcp/server.ex`, `mcp/transport/http.ex`, `mcp/transport/sse.ex`.
- **dynamic-module-generation** — the pattern of compiling one anonymous module
  per hook entry and per MCP tool at runtime via `Module.create/3`, leaking
  atoms on every reload. Covers `hooks/shell.ex`, `mcp/tool_adapter.ex`.

This axis yields MECE because: no finding about result shape touches the I/O
collector mechanics; no I/O collector concern touches MCP server concurrency;
no concurrency concern touches dynamic module generation. Each sub-problem
is actionable without first resolving any sibling.

## Sub-problems (filled by decomposer)

1. **tool-result-contract** — The `Tau.Tool.Result` contract (details schema,
   telemetry coverage, raise prohibition) is declared on the behaviour but not
   enforced; individual tool implementations silently diverge.
2. **io-collectors** — Three hand-rolled `receive`/binary-accumulation loops
   across Bash, shell hooks, and MCP stdio accumulate without a byte cap inside
   the loop, risking OOM on large outputs and duplicating port-close error
   handling.
3. **mcp-server-concurrency** — The MCP `Server` GenServer serialises all tool
   invocations because transports perform synchronous network I/O inside
   `send/2`, and the `handle_info(_msg, state)` catch-all drains the SSE queue
   out of band.
4. **dynamic-module-generation** — Shell hooks and MCP tool adapters each
   compile one anonymous module per config entry at settings-load time via
   `Module.create/3`, growing the atom table and module code table on every
   reload without ever purging prior versions.

## Acceptance criterion

The problem is solved when each of the four sub-problems has a validated
proposal that, taken together, would allow a reader of `lib/tau/tools/`,
`lib/tau/hooks/`, and `lib/tau/mcp/` to identify the shape contract, collection
bound, concurrency model, and dispatch mechanism for each subsystem from its
public interface alone, without reading implementation details of siblings.

## Out of scope

- Path-traversal and sandbox enforcement (`resolve/2` in `local.ex`) — a
  security concern separate from the complecting analysis; tracked in the flat
  audit as a distinct finding.
- Fake unified diff in `Edit` (`render_diff/2`) — functional defect, not a
  complecting issue.
- `Agent.parse_mode/1` using `try/rescue` for atom lookup — a single-site
  anti-idiom, not a systemic complecting seam.
- MCP server `pending` map unbounded growth on timeout — a resource-leak bug in
  the concurrency sub-problem, but the bounded-collection fix lives in
  `io-collectors`.
- ENV variable leakage into Bash subprocesses — a security / policy concern,
  out of scope for this structural audit.

## Amendment log

- (none yet)
