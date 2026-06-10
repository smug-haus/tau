---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: dynamic-module-generation — Runtime Module.create/3 per config entry leaks atoms and defeats hot-reload

## Statement

`Tau.Hooks.Shell.build/2` compiles one anonymous module per declarative hook
entry at settings-load time using `Module.create/3`, and
`Tau.MCP.ToolAdapter.build/5` does the same for each MCP tool discovered via
`tools/list`. Each generated module name includes a random suffix
(`Module.concat([..., "Generated_#{random}"])`) or a namespaced path that encodes
a mutable server-name + tool-name pair. Because neither site ever calls
`Module.delete/1` on the prior generation, a settings reload or an MCP server
restart produces an unbounded accumulation of loaded-but-orphaned BEAM modules
and their corresponding atom-table entries, which are permanent for the lifetime
of the BEAM node.

## Context

- `lib/tau/hooks/shell.ex:38-63` — `build/2` calls `Module.create/3` with a
  random-suffix module name on every invocation. `generate_name/0` uses
  `:crypto.strong_rand_bytes(6) |> Base.url_encode64` — each call produces a
  unique atom.
- `lib/tau/hooks/shell.ex:40-41` — `Module.create/3` is called after `quote`
  but there is no corresponding `Module.delete/1`, `:code.purge/1`, or
  `:code.delete/1` anywhere in the codebase.
- `lib/tau/mcp/tool_adapter.ex:21-49` — `build/5` does the same: `mod_name =
  Module.concat([Tau.MCP.ToolAdapter, server_name, name])`. On MCP server
  restart (e.g. after a network drop) `build/5` is called again with the same
  `mod_name`, overwriting the prior version in-memory but leaving the old code
  generation loaded.
- `lib/tau/mcp/server.ex:120-124` — `terminate/2` calls
  `Registry.unregister/2` for each registered key, but does NOT call
  `:code.delete/1` or `Module.delete/1` on the generated adapter modules.
- Flat audit major findings: `hooks/shell.ex:38-63` and
  `mcp/tool_adapter.ex:21-49` — "Reloading settings creates fresh modules
  without ever purging the old ones... The `Module.concat([..., "Generated_#
  {random}"])` pattern guarantees atom-table growth."
- The dispatch benefit of one-module-per-entry is the same as a
  pattern-matched `Dispatcher.run_command(cmd, matcher, ...)` keyed on a plain
  map: the extra indirection adds no value.

## Complecting hypothesis

**The hook dispatch mechanism is complected with the hook's identity** because
`Hooks.Dispatcher` looks up hooks by module in the registry, requiring each
hook to be a distinct module — which in turn forces `build/2` to compile a new
module per entry rather than treating a hook as a tagged data structure. The
same complecting applies to MCP tool adapters: the `Tau.Tool` behaviour requires
`name/0`, `description/0`, and `parameters/0` to be functions, but all three
values are constant at registration time and could be stored in a registry value
rather than burned into a compiled module.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The problem is solved when: (a) settings reload (whether triggered by
`Tau.MCP.Reconciler.reload/0` or by the file watcher) does not add any new
entries to the BEAM atom table for hook or MCP tool identifiers; (b) MCP server
restart does not leave orphaned module code generations in the BEAM code server
(verifiable via `:code.all_loaded/0` before and after a simulated restart); and
(c) the Hooks dispatcher and MCP tool dispatch continue to pass their existing
tests without modification to the test suite.

## Out of scope

- Hook shell-injection risk via `{:spawn, cmd}` — a security concern in
  `Hooks.Shell.do_run/4`; does not interact with the module-generation pattern.
- The `matches?/2` stub (always returns `true`) — an incomplete feature in
  `Hooks.Shell`; fixing it does not require changing the module-generation
  approach.
- The MCP `server.ex` concurrency model — covered by `mcp-server-concurrency`;
  the module-generation fix can proceed independently of how `invoke/3` is
  parallelised.
- Whether `Tau.Tool` behaviour should be restructured to support data-driven
  dispatch more broadly (e.g. for extension tools) — that is a behaviour design
  question outside the scope of the module-leak fix.

## Amendment log

- (none yet)
