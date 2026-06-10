---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: tool-result-contract — Result shape and enforcement boundary are declared but not enforced

## Statement

`Tau.Tool`'s behaviour contract declares that tools must never raise on user
input, and `Tau.Tool.Result` defines a `details` map intended to carry
structured metadata; but neither the raise prohibition nor the `details` schema
(specifically: the `kind` discriminator, telemetry coverage, and the `is_error`
contract) are enforced at any shared boundary. Each tool author chooses
independently which fields to populate, producing silent divergence that callers
(TUI renderers, session JSONL consumers, tests) cannot rely upon.

## Context

- `lib/tau/tool.ex:23` — moduledoc states "Tools must NEVER raise on user
  input."
- `lib/tau/tool/result.ex` — `%Result{content, details, terminate?, is_error}`;
  `details` is typed `map()` with no schema enforcement.
- `lib/tau/tools/builtin/bash.ex:131-141` — `persist_full/3` calls
  `File.mkdir_p!/1` and `File.write!/1`; either can raise, violating the
  contract.
- `lib/tau/tools/builtin/write.ex:43` — `details: %{path: full, bytes: bytes}`
  has no `:kind` key.
- `lib/tau/tools/builtin/bash.ex` — emits no `[:tau, :tool, ...]` telemetry on
  the tool boundary; only `[:tau, :tool, :bash, :stderr]` on a sub-event.
- `lib/tau/tools/builtin/read.ex:77-78` and `edit.ex` — also emit no
  `[:tau, :tool, ...]` boundary telemetry.
- `lib/tau/tools/builtin/delegate.ex` — emits `[:tau, :tool, :delegate,
  :start/:stop/:exception]` correctly.
- Flat audit cross-tool shape-drift table (`.code_audit/archive/v1-flat/
  03-tools-hooks-mcp.md` §Cross-tool shape drift) — documents the full matrix.

Behaviour interfaces are structurally sound. The gap is entirely in
implementation discipline: there is no shared wrapper, validator, or compile-
time check that enforces the three contract points (no-raise, details schema,
telemetry) across all implementations.

## Complecting hypothesis

**The raise prohibition, the details schema, and the telemetry contract are
complected with each tool's implementation** because there is no dispatch
wrapper between the FSM and `execute/2` that enforces these three properties
centrally; the FSM calls `execute/2` directly and trusts each implementation to
honour the contract independently. Each tool author therefore owns an invisible
cross-cutting responsibility that is easy to forget or implement partially.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The problem is solved when: (a) no built-in tool can raise an uncaught exception
on any reachable input path (including filesystem errors in `persist_full/3`),
(b) every tool's `details` map includes at minimum a `:kind` discriminator, and
(c) every tool emits `[:tau, :tool, <name>, :start]` and `[:tau, :tool, <name>,
:stop/:exception]` telemetry on the execution boundary — all three verifiable by
inspection or a test that exercises the contract at the dispatch layer rather
than within individual tools.

## Out of scope

- Path-traversal and sandbox enforcement — a separate security finding
  (`resolve/2` in `local.ex`); does not affect the shape contract.
- The fake unified diff in `Edit.render_diff/2` — a functional defect in the
  diff content, not a result-shape contract issue.
- `Agent` and `Delegate` telemetry namespaces (they emit on sub-namespaces of
  `[:tau, :tool, ...]` rather than the canonical `[:tau, :tool, :agent, ...]`
  form) — the direction of fix (rename vs. alias) is a proposal decision, not
  a problem statement.
- `Tau.Hook`'s result shape — covered by the `io-collectors` sub-problem
  (hook shell dispatch) and the flat audit; not a `Tau.Tool.Result` concern.
- MCP `ToolAdapter`'s result construction — covered by the
  `mcp-server-concurrency` sub-problem; MCP tools are proxies to a remote
  server, not implementations of `Tau.Tool.execute/2` in the same sense.

## Amendment log

- (none yet)
