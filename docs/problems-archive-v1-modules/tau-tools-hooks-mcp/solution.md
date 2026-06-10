---
template_version: 1
template_name: solution
parent_problem: ./problem.md
node_kind: root
synthesised_from:
  - subproblems/tool-result-contract/solution.md
  - subproblems/io-collectors/solution.md
  - subproblems/mcp-server-concurrency/solution.md
  - subproblems/dynamic-module-generation/solution.md
selection_method: synthesis
mode: non-leaf
revision: 0
---

# Solution: Four decomplecting moves — central tool dispatch wrapper, shared port utility, async MCP transport, data-driven hook/MCP registries

## Recommendation

Apply all four child recommendations together as a coherent module-wide
decomplecting of `lib/tau/tools/`, `lib/tau/hooks/`, and `lib/tau/mcp/`. The
moves target four orthogonal seams identified in the root problem
(result-shape contract, I/O collection, MCP concurrency, dynamic module
generation); each child solution acts on exactly one seam and they compose
without conflict on any module. The combined effect is that, after landing,
each subsystem's *public interface* (`Tau.Tool` behaviour, `Tau.Hook`
behaviour, `Tau.MCP.Transport` behaviour, `Tau.MCP.Server` API) reveals its
shape contract, collection bound, concurrency model, and dispatch mechanism
without requiring a reader to inspect sibling implementations. Concretely:
(1) `Tau.Tool.Executor.call/4` becomes the single enforcement site for the
result-shape contract; (2) `Tau.IO.Port.close_if_open/1` is the single shared
port-liveness utility and the three hand-rolled receive loops gain in-place
iolist cap guards; (3) `Tau.MCP.Transport` drops `recv/2` and the Server
adopts task-per-invoke async delivery with `Process.monitor/1` pruning; (4)
`%Tau.Hooks.Shell.Entry{}` and `%Tau.MCP.ToolEntry{}` replace
`Module.create/3` runtime generation, widening `Tau.Tool.lookup/1` to return
either a module or a `ToolEntry` struct dispatched by an added pattern-match
clause.

## Selected from

- **Synthesised from:**
  - `subproblems/tool-result-contract/solution.md` — central
    `Tau.Tool.Executor.call/4` wrapper.
  - `subproblems/io-collectors/solution.md` — in-place iolist cap guards +
    shared `Tau.IO.Port.close_if_open/1` utility.
  - `subproblems/mcp-server-concurrency/solution.md` — task-per-invoke +
    async-contract `Tau.MCP.Transport` behaviour (remove `recv/2`).
  - `subproblems/dynamic-module-generation/solution.md` — tagged struct
    registry values + pattern-matched dispatch clause.
- **Composition rationale:** the four children act on disjoint module sets
  along disjoint axes, confirmed by the root problem's MECE decomposition.
  No child's "What changes" list collides with another's at the function
  level. The non-trivial composition points are:

  1. **`Tau.Tool.Executor` × `%Tau.MCP.ToolEntry{}` dispatch.** The
     result-contract child scopes its wrapper to
     `Tau.Session.ToolDispatch.run_tool_validated/6` invoking
     `mod.execute/2` — the compile-time tool path. The dynamic-module-
     generation child adds a second dispatch clause matching
     `%Tau.MCP.ToolEntry{}` that calls
     `Tau.MCP.ToolAdapter.invoke_remote/3` directly, bypassing the
     executor. *Resolution:* `run_tool_validated/6` invokes
     `Tau.Tool.Executor.call/4` on **both** branches; the executor's
     `(mod_or_entry, args, ctx, started)` signature accepts either a module
     atom (calls `mod.execute/2`) or a `%ToolEntry{}` (calls
     `Tau.MCP.ToolAdapter.invoke_remote/3`). This preserves the
     contract-enforcement guarantee uniformly across compile-time and
     runtime-registered tools and keeps telemetry coverage symmetric. The
     executor's per-tool telemetry naming for `%ToolEntry{}` uses the
     fallback `[:tau, :tool, :dynamic, ...]` namespace already documented
     in the result-contract solution as the runtime-registered case —
     this is exactly that case, not a new one.

  2. **`Tau.Tool.Executor` × `%Tau.Hooks.Shell.Entry{}` dispatch.** The
     hook dispatch path (`Tau.Hooks.Dispatcher.run_one/3`) is a separate
     dispatch entry point — it is not routed through
     `Tau.Tool.Executor`, which targets tools, not hooks. Hooks have
     their own contract (`Tau.Hook` behaviour). *Resolution:* no
     interaction; the new `%Entry{}` clause delegates to
     `Tau.Hooks.Shell.run_command/5` as the dynamic-module-generation
     child specifies, and the executor stays out of the hook path.

  3. **`Tau.IO.Port.close_if_open/1` × MCP transport `recv/2` removal.**
     The io-collectors child replaces the `try/catch Port.close/1` at
     `lib/tau/mcp/transport/stdio.ex:82` with
     `Tau.IO.Port.close_if_open/1`. The mcp-server-concurrency child
     removes `recv/2` from the `Tau.MCP.Transport` behaviour entirely
     and removes its implementation in stdio. *Resolution:* the io-
     collectors fix to `recv/2`'s `{:noeol, partial}` branch and its
     `close/1` site is preserved *until* `recv/2` is removed, then both
     drop out together. Sequencing (see Migration sketch) ensures the
     io-collectors fix lands first or the `recv/2` removal lands first
     — either order works because they touch different concerns of the
     same function, and the final state is the same: `recv/2` is gone,
     `close/1` uses `Tau.IO.Port.close_if_open/1`.

  4. **`Tau.MCP.Server` × `%ToolEntry{}` registry value.** The dynamic-
     module-generation child notes that `Tau.MCP.Server.terminate/2`'s
     `Registry.unregister/2` calls remain and no `:code.delete/1` is
     needed. The mcp-server-concurrency child rewrites
     `handle_call({:invoke, ...})` to be non-blocking; the new
     `pending` map shape (`id => {from, monitor_ref}`) is orthogonal to
     the registry's value type. *Resolution:* no interaction; the two
     changes touch different fields of the Server state.

  No child's change to a public behaviour (`Tau.Tool`, `Tau.Hook`,
  `Tau.MCP.Transport`) is contradicted by another. The composition is
  direct.

## What changes

**Tool result contract** (see child solution for full detail):

- New `lib/tau/tool/executor.ex` defining `Tau.Tool.Executor.call/4`.
- `lib/tau/session/tool_dispatch.ex` — `run_tool_validated/6` routes both
  module-tool and `%ToolEntry{}`-tool branches through the executor (the
  union dispatch is the synthesis-level composition; the child solution
  scoped it to the module branch only).
- `lib/tau/tools/builtin/bash.ex` — `persist_full/3` uses non-raising
  `File.mkdir_p/1` / `File.write/1`.
- New unit tests under `test/tau/tool/executor_test.exs`.

**I/O collectors** (see child solution for full detail):

- New `lib/tau/io/port.ex` defining `Tau.IO.Port.close_if_open/1`.
- `lib/tau/tools/operations/local.ex` — `collect_port/3` iolist + running
  byte counter + in-loop cap guard; replace `try/catch Port.close/1` with
  the shared utility.
- `lib/tau/hooks/shell.ex` — `collect/3` same iolist + cap pattern; replace
  `try/catch`.
- `lib/tau/mcp/transport/stdio.ex` — if `recv/2` is retained at this point
  in the sequence, add the `{:noeol, partial}` cap guard; replace `close/1`
  `try/catch`. If `recv/2` is already removed, only the `close/1` site
  remains.

**MCP server concurrency** (see child solution for full detail):

- `lib/tau/mcp/transport.ex` — remove the `recv/2` callback from the
  behaviour; update `send/2` (or new `send/4`) docstring to state the
  non-blocking contract.
- `lib/tau/mcp/transport/{http,sse,stdio}.ex` — remove `recv/2`; rewrite
  `Http.send/2` to `Task.start/1` + message delivery.
- `lib/tau/mcp/server.ex` — non-blocking `handle_call({:invoke, ...})`;
  new `handle_info` clauses for task results and `:DOWN` pruning; strip
  the `transport.recv` side-effect from the catch-all.
- Test additions under `test/tau/mcp/` for concurrent-invoke wall-time
  assertion.

**Dynamic module generation** (see child solution for full detail):

- `lib/tau/hooks/shell.ex` — define `%Tau.Hooks.Shell.Entry{}`; `build/2`
  returns the struct; remove `Module.create/3` and `generate_name/0`.
- `lib/tau/mcp/tool_adapter.ex` — define `%Tau.MCP.ToolEntry{}`; `build/5`
  returns the struct; `invoke_remote/3` stays as the dispatch helper.
- `lib/tau/hooks/dispatcher.ex` — add `run_one/3` clause matching
  `%Entry{}` delegating to `Tau.Hooks.Shell.run_command/5`.
- `lib/tau/session.ex` (or `lib/tau/session/tool_dispatch.ex` if the
  dispatch lives there) — add `dispatch_tool/3` clause matching
  `%ToolEntry{}`; route through `Tau.Tool.Executor.call/4` per
  composition note (1) above.
- `lib/tau/tool.ex` — `lookup/1` return type widens to
  `{:ok, module() | Tau.MCP.ToolEntry.t()} | :error`.
- Confirm via grep all callsites iterating registered tools and
  introspecting `mod.name/0` / `mod.description/0` / `mod.parameters/0`;
  add the `%ToolEntry{}` branch where applicable.

## What does not change

- The four public behaviours' core shapes are preserved where the child
  solutions are explicit about preservation:
  - `Tau.Tool` callback signatures (`name/0`, `description/0`,
    `parameters/0`, `execute/2`, `execution_mode/0`, `streams_updates?/0`).
  - `Tau.Tool.Result` struct definition (`content`, `details`,
    `terminate?`, `is_error`); `details` remains `map()`.
  - `Tau.Hook` behaviour and its compile-time-module dispatch clause in
    `Tau.Hooks.Dispatcher.run_one/3` (`is_atom(mod)`).
  - `Tau.MCP.Transport` `send/2` (or `send/4`) and `close/1` shape;
    `recv/2` is removed because no remaining caller needs it after the
    concurrency fix.
- The supervision tree — no new GenServers, no new ETS tables, no new
  supervised workers across all four moves. (This is an explicit
  composition guarantee: the result-contract wrapper is a pure function;
  the port utility is a pure function; the task-per-invoke uses
  `Task.start/1`; the registry-value struct change replaces dynamic
  modules with data.)
- `Tau.Hooks.Registry` / `Tau.Tools.Registry` modules and their lifetime
  semantics; only stored value types change.
- `Tau.Hooks.Shell.run_command/5` and `Tau.MCP.ToolAdapter.invoke_remote/3`
  signatures.
- The session-side `Tau.Message.ToolResult` wire type and JSONL persistence
  format.
- The existing `[:tau, :tool, :execute, :start/:stop/:exception]` session-
  level telemetry (per-tool events are additive).
- The 30-second MCP `@timeout` per-call cap; SSE `Task.async` lifecycle
  (explicit OOS in mcp-server-concurrency child).
- Path-traversal / sandbox enforcement, the fake unified diff in `Edit`,
  `Agent.parse_mode/1`'s `try/rescue`, ENV variable leakage into Bash —
  all explicit OOS per root `problem.md`.

## Migration sketch

The four moves can land as four independent PRs in this dependency order;
they do not require a single mega-PR.

1. **PR-A — `Tau.IO.Port` + io-collectors.** Add `lib/tau/io/port.ex`;
   apply in-place iolist cap fixes to `local.ex`, `hooks/shell.ex`,
   `mcp/transport/stdio.ex`. Self-contained; no cross-subsystem dependency.
   Smallest blast radius — land first to validate the shared-utility
   pattern.
2. **PR-B — `Tau.Tool.Executor` (module-tool branch only).** Add
   `lib/tau/tool/executor.ex`; route the existing
   `run_tool_validated/6` module-call through it; rewrite `Bash.persist_full/3`
   to non-raising. Lands before PR-D so the union dispatch in PR-D has the
   executor to call.
3. **PR-C — MCP transport async + `recv/2` removal.** Update
   `transport.ex` behaviour, remove `recv/2` from all three transport
   modules, rewrite `Http.send/2` async, update `server.ex` handle_call
   and handle_info clauses. After PR-A: the io-collectors fix to
   `recv/2`'s `{:noeol, partial}` branch becomes dead code and is
   removed as part of the `recv/2` deletion (the `close/1` site retains
   `Tau.IO.Port.close_if_open/1`). Independent of PR-B and PR-D.
4. **PR-D — Tagged-struct registries.** Define `%Entry{}` and
   `%ToolEntry{}`; rewrite `build/2` / `build/5` to return structs; add
   dispatcher clauses; widen `Tau.Tool.lookup/1`. The session dispatch
   clause for `%ToolEntry{}` routes through `Tau.Tool.Executor.call/4`
   from PR-B — this is the synthesis-level composition point. Land after
   PR-B.

SPEC-USER-TURN is gated for PR-B and PR-D (both touch
`lib/tau/session/tool_dispatch.ex` and/or `lib/tau/session.ex`); the PRs
cite the relevant `AC-N` / `D-NNN` per `spec-before-code.md`. PR-A and
PR-C are confined to non-session files and do not need SPEC-USER-TURN
gating; PR-C does touch MCP behaviour state and likely warrants a new
`D-NNN` describing the async contract (the child solution's "remove
`recv/2`" is the corresponding SPEC §3 amendment that lands in the same
PR per `spec-before-code.md`).

Each PR is independently reversible by reverting its commits; nothing in
the sequence forces an irreversible coupling.

## Open questions

Inherited from children (not resolved at the synthesis level):

- **Result-contract:** `ensure_kind/1` warning policy in `:dev`/`:test`;
  runtime-registered tools' telemetry granularity (the synthesis pins
  these to the `[:tau, :tool, :dynamic, ...]` fallback for `%ToolEntry{}`,
  but the broader question for extension-loaded tools remains); whether
  to add the contract-test follow-up; downstream consumers of
  `details.full_output_path` and the `nil`-on-error degradation.
- **I/O collectors:** `@max_bytes` direction of dependency between
  `local.ex` and `bash.ex`; `hooks/shell.ex` cap value; existing
  `truncate/3` test assertions on exact byte counts; UTF-8 boundary
  policy.
- **MCP concurrency:** `send/2` vs `send/4` arity decision;
  `Task.start` vs `Task.Supervisor.start_child` (per OTP non-negotiable
  on supervised processes); `Finch.async_request` vs `Task.start` +
  `Finch.request`; SSE concurrent-invoke ordering semantics.
- **Dynamic-module:** exact count of `mod.name/0` / `mod.description/0` /
  `mod.parameters/0` introspection callsites; whether `build/5`'s
  unused `mod_name` arg is retained for arity compat; the precise
  `D-NNN` under SPEC-USER-TURN this advances; future
  extension-loaded-tools pattern.

Synthesis-level open question (not in any child):

- **Executor coverage of the hook path.** The synthesis explicitly
  scopes `Tau.Tool.Executor` to the tool dispatch path, not the hook
  dispatch path. Hooks have their own `Tau.Hook` behaviour and their
  own raise / kind / telemetry expectations. Whether a parallel
  `Tau.Hook.Executor` should exist is a follow-up question — out of
  scope here because the root acceptance criterion only requires that
  each subsystem be reasonable *from its public interface*; the hook
  contract is currently defined by `Tau.Hook` and not by `Tau.Tool`.

## Linked sub-problems / proposals

- `subproblems/tool-result-contract/` → "Central `Tau.Tool.Executor`
  dispatch wrapper enforces the three contract properties (raise
  rescue, `:kind` injection, per-tool telemetry)."
- `subproblems/io-collectors/` → "In-place iolist cap guards across the
  three sites, plus a single shared `Tau.IO.Port.close_if_open/1`
  utility for port-liveness."
- `subproblems/mcp-server-concurrency/` → "Task-per-invoke async
  delivery + remove `recv/2` from the `Tau.MCP.Transport` behaviour;
  monitor caller / task pids for pending-map pruning; strip
  `transport.recv` from the catch-all."
- `subproblems/dynamic-module-generation/` → "Replace `Module.create/3`
  with tagged struct registry values (`%Tau.Hooks.Shell.Entry{}`,
  `%Tau.MCP.ToolEntry{}`) dispatched by pattern-match clauses."

## Revision history

- (revision 0 — initial)
