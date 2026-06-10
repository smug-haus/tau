---
template_version: 1
template_name: solution
parent_problem: ./problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md]
selection_method: single
revision: 0
---

# Solution: Replace Module.create/3 with tagged struct registry values for both shell hooks and MCP tool adapters

## Recommendation

Eliminate `Module.create/3` at both `Tau.Hooks.Shell.build/2` and
`Tau.MCP.ToolAdapter.build/5`. Introduce two plain structs —
`%Tau.Hooks.Shell.Entry{cmd, matcher, timeout_ms, events}` and
`%Tau.MCP.ToolEntry{server_name, namespaced_name, description, parameters}` —
and store them as the registry values that the dispatchers consume. Extend
`Tau.Hooks.Dispatcher.run_one/3` and the session FSM tool-dispatch path with
one additional clause each, pattern-matching on the struct tag and delegating
to the already-public `Tau.Hooks.Shell.run_command/5` and
`Tau.MCP.ToolAdapter.invoke_remote/3`. With no module compiled per
configuration entry, settings reload and MCP server restart cannot grow the
BEAM atom table or accumulate orphaned code generations; the existing dispatch
functions are behaviour-preserving, so no test changes are required.

## Selected from

- **Chosen:** `proposals/proposal-1.md` (single).
- **Why chosen:** Scoring against the acceptance criterion:

  | # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
  |---|-----|---------------------|----------------|------|---------------|
  | 1 | Yes | Deep | Medium | Low | Easy |
  | 2 | Partially | Surface | Low | Medium | Easy |
  | 3 | Yes | Substantial | High | Medium | Hard |
  | 4 | Yes | Substantial | High | Medium | Hard |

  Proposal 1 strictly satisfies criterion (a) — zero atoms created per reload,
  not merely "bounded growth" as Proposal 2 admits — and vacuously satisfies
  (b) because there are no compiled modules to leak. Decomplecting depth is
  Deep: it removes `Module.create/3` rather than adding machinery around it
  (Proposal 2 keeps the module-per-entry model; Proposals 3 and 4 add new
  stateful processes/ETS tables to manage the per-entry data). Under the
  Hickey-aligned tie-breakers in `select.md`, Proposal 1 wins on every axis
  the protocol enumerates: decomplecting depth over cost, pure over stateful,
  composition (the struct composes into existing pattern-matched dispatch)
  over aggregation (Proposals 3 and 4 introduce new owners/contexts whose
  lifecycle must be reasoned about separately). Proposal 2's "soft-purge of
  in-flight invocations" hazard is a regression in risk for a configuration
  reload path that previously had none. Proposals 3 and 4 break the
  `Tau.Tool.Context` and `Tau.Tool.lookup/1` public shapes respectively, both
  hard-to-reverse. Proposal 1's single behaviour cost — branching in the
  session FSM dispatch path — is the same cost Proposals 3 and 4 also pay
  (they too touch the FSM); Proposal 1 pays it without the extra GenServer
  or ETS-owner state.

## What changes

- `lib/tau/hooks/shell.ex` — define `Tau.Hooks.Shell.Entry` struct;
  rewrite `build/2` to return an `%Entry{}` rather than generating and
  returning a module atom; delete `generate_name/0` and the surrounding
  `Module.create/3` invocation.
- `lib/tau/mcp/tool_adapter.ex` — define `Tau.MCP.ToolEntry` struct;
  rewrite `build/5` to return a `%ToolEntry{}`; retain
  `invoke_remote/3` and `render_blocks/1` unchanged (the dispatch
  helpers stay public and are now the sole dispatch path for MCP tools).
  The `mod_name` argument to `build/5` becomes unused; either retain it
  for arity compat or update `lib/tau/mcp/server.ex` to drop it.
- `lib/tau/hooks/dispatcher.ex` — add a `run_one/3` clause matching on
  `%Tau.Hooks.Shell.Entry{}` that calls `Tau.Hooks.Shell.run_command/5`
  with the entry's fields; the existing `is_atom(mod)` clause is
  unchanged and continues to serve behaviour-module hooks.
- `lib/tau/session.ex` — add one `dispatch_tool/3` clause matching
  `%Tau.MCP.ToolEntry{}` that strips the `mcp__<server>__` prefix from
  `namespaced_name` and calls `Tau.MCP.ToolAdapter.invoke_remote/3`;
  the existing `is_atom(mod)` clause is unchanged. This change is
  SPEC-USER-TURN gated; the PR description must cite the relevant
  D-NNN under that SPEC.
- `lib/tau/tool.ex` — `lookup/1` return type widens to
  `{:ok, module() | Tau.MCP.ToolEntry.t()} | :error`. Storage in
  `Tau.Tools.Registry` is the struct, not a module atom.
- Any callsite that iterates registered tools and invokes `mod.name/0`,
  `mod.description/0`, or `mod.parameters/0` on a looked-up value
  (introspection, help generation, schema export) — confirm via grep and
  add the `%ToolEntry{}` branch reading the struct field directly.

## What does not change

- `Tau.Hook` behaviour and the compile-time hook-module dispatch path
  (`is_atom(mod)` clause in `Hooks.Dispatcher.run_one/3`).
- `Tau.Tool` behaviour and the compile-time tool-module dispatch path
  (`is_atom(mod)` clause in `Session.dispatch_tool/3`); the behaviour
  callbacks `name/0`, `description/0`, `parameters/0`, `execution_mode/0`
  remain valid for compile-time tools.
- `Tau.Hooks.Registry` and `Tau.Tools.Registry` modules and their lifetime
  semantics — only the *value type* stored in them changes.
- `Tau.Hooks.Shell.run_command/5` and `Tau.MCP.ToolAdapter.invoke_remote/3`
  signatures — both are already public and behaviour-preserving.
- `Tau.MCP.Server.terminate/2` — `Registry.unregister/2` calls remain;
  no new `:code.delete/1` work is needed because no compiled modules
  exist to delete.
- The supervision tree — no new GenServers, no new ETS tables, no new
  supervised workers (this is the key axis on which Proposal 1 wins over
  Proposals 3 and 4).
- The existing test suite for `Hooks.Dispatcher`, `Tau.Tool`, `MCP.Server`,
  and the session FSM tool-dispatch path — required by acceptance
  criterion (c).

## Migration sketch

The change is atomic across the affected files: `Tau.Hooks.Shell.build/2`,
`Tau.Hooks.Dispatcher.run_one/3`, `Tau.MCP.ToolAdapter.build/5`,
`Tau.Tool.lookup/1`, and `Tau.Session.dispatch_tool/3` must land in one PR
because any intermediate state where the registry value type does not match
the dispatcher's pattern would be broken. The sequence within the PR is:
(1) introduce the `Entry` and `ToolEntry` structs; (2) update both
`build` functions to return structs; (3) update the dispatchers to
pattern-match on the structs; (4) update introspection callsites identified
by grep. SPEC-USER-TURN gating applies for the `lib/tau/session.ex`
touch — cite the D-NNN advanced. SPEC-before-code requirement: if no
existing D-NNN covers "tool dispatch is data-driven for MCP tools",
register one in SPEC-USER-TURN §3 in the same PR.

## Open questions

- Exact count and location of `mod.name/0` / `mod.description/0` /
  `mod.parameters/0` callsites that iterate the tools registry — the
  confidence on Proposal 1's "medium" rating is gated on this grep.
- Whether `Tau.MCP.ToolAdapter.build/5`'s first arg (`mod_name`) is
  retained for arity compat or removed with a coordinated update of
  `Tau.MCP.Server.register_tool/2`. The lower-churn option is to keep
  and ignore it; the cleaner option requires a one-line server update.
- Which D-NNN under SPEC-USER-TURN this change advances or amends —
  selection-time decision is "this must be cited"; the actual D-NNN
  choice is for the implementer working from the live SPEC.
- Whether the same data-driven pattern should apply to future
  extension-loaded tools (out-of-scope per parent `problem.md`, but the
  Entry/ToolEntry precedent shapes the answer).

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Data-driven dispatch via tagged structs (CHOSEN).
- `proposals/proposal-2.md` — Stable deterministic module names + explicit
  purge. Rejected: only partially satisfies criterion (a) (atom growth
  proportional to distinct configs ever seen, not zero), surface-level
  decomplecting (retains module-per-entry), and introduces a new
  soft-purge-of-in-flight-invocations hazard.
- `proposals/proposal-3.md` — Single shared dispatcher + ETS config tables.
  Rejected: adds two new supervised workers and two new ETS tables,
  breaks `Tau.Tool.Context` (hard reversibility), and pollutes the hook
  payload map with a `:__hook_key__` side-channel.
- `proposals/proposal-4.md` — GenServer-owned stores per subsystem.
  Rejected: adds two new GenServers on the hot dispatch path
  (serialisation point), breaks `Tau.Tool.lookup/1` return shape (hard
  reversibility), and adds stateful surface where Proposal 1 removes it.

## Revision history

- (revision 0 — initial)
