---
template_version: 1
template_name: validation
parent_solution: ./solution.md
parent_problem: ./problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/3
revision_triggered: none
---

# Validation: Replace Module.create/3 with tagged struct registry values for both shell hooks and MCP tool adapters

## Overview

The solution makes five distinct propositions about the post-change world:
(1) `Tau.Hooks.Shell.build/2` and `Tau.MCP.ToolAdapter.build/5` cease calling
`Module.create/3`; (2) two new tagged structs become the registry value types;
(3) one extra clause in each of two dispatchers handles the new struct value;
(4) the supervision tree, ETS surface, and `Registry` lifetimes are unchanged;
(5) the existing test suite passes without modification. Each is validated
below using a strategy from the catalog in `validate.md`. The dominant finding
is that claim (3) is **partially falsified**: the change is not a "one
additional clause in each of two dispatchers" — the introspection surface
(`mod.name()`, `mod.description()`, `mod.parameters()`, `mod.execute/2`) is
called from at least seven sites in `lib/tau/` that all need a struct branch,
and `Tau.Tool.Validator.validate/2` is typed `module(), term()` and dispatches
on `is_atom(mod)` — so it requires its own data-driven adaptation. Claim (5)
narrows in consequence: tests of those introspection callsites will see
behaviour-equivalent values but only after their adapter modules learn the
new shape, and at least one site (`Tau.Tool.Validator`) cannot satisfy a
struct without an architectural extension (it caches resolved schemas in
`:persistent_term` keyed by module atom; a struct has no such key candidate
without a synthetic id).

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly to counter that variance.

### Claim 1: `Tau.Hooks.Shell.build/2` and `Tau.MCP.ToolAdapter.build/5` no longer call `Module.create/3`; settings reload and MCP server restart cannot grow the BEAM atom table from these sites

- **Claim (C):** "With no module compiled per configuration entry, settings
  reload and MCP server restart cannot grow the BEAM atom table or accumulate
  orphaned code generations."
- **Grounds (G):** The two `Module.create/3` callsites are localised:
  `lib/tau/hooks/shell.ex:61` and `lib/tau/mcp/tool_adapter.ex:47`. The
  random-suffix generator at `lib/tau/hooks/shell.ex:161-164` is the unique
  source of unbounded atom growth on the hook side; the MCP side uses
  `Module.concat([Tau.MCP.ToolAdapter, server_name, name])` at
  `lib/tau/mcp/server.ex:231` where `server_name` and `name` are both strings
  that become atoms inside `Module.concat/1` (atoms are permanent).
  Removing both `Module.create/3` calls and the `generate_name/0` helper
  removes the atom-growth source.
- **Warrant (W):** The Erlang atom table is permanent for the BEAM node's
  lifetime; `Module.create/3` registers a new module atom in the code server
  and inserts the module's name into the atom table. The only way to avoid
  growing the table per registration is to avoid creating atoms per
  registration. Structs carry the struct module's atom (one per struct kind)
  and field values (which can be binaries — non-atom); a tagged struct
  satisfies "fixed atom set, variable data" by construction.
- **Qualifier (Q):** Holds when no other code path in the same PR introduces
  a new per-entry atom (e.g. via `String.to_atom/1`, `Module.concat/1`, or
  `:erlang.binary_to_atom/2`). The struct's tag itself is one atom for the
  module (`Tau.Hooks.Shell.Entry`, `Tau.MCP.ToolEntry`), created once at
  compile time. Holds only if the registry keys themselves do not encode
  the per-entry identity as atoms — `Tau.Hooks.Registry` is keyed by event
  atom (closed set, see `lib/tau/registries.ex:30`) and `Tau.Tools.Registry`
  is keyed by binary tool name (`lib/tau/mcp/server.ex:227`,
  `lib/tau/tool.ex:57`), so this qualifier holds for both.
- **Rebuttal (R):** The claim would NOT hold if any callsite continued to
  derive an atom from the per-entry data. The `mcp/server.ex:231` line
  `Module.concat([Tau.MCP.ToolAdapter, server_name, name])` is the only
  current external atom source per entry and the solution explicitly
  removes (or stops using) the resulting `mod_name`. There is no second
  per-entry atom source in `hooks/shell.ex` beyond `generate_name/0`.
- **Backing (B):** Erlang/OTP documentation on the atom table size
  limit (default 1,048,576; permanent for VM lifetime) —
  https://www.erlang.org/doc/efficiency_guide/advanced.html#system-limits;
  `:code.purge/1` does not free the atom (a separately-documented
  Erlang VM property — atoms are never reclaimed without
  `+e<n>+exit-on-atom-limit`).

#### Falsification attempt for claim 1

- **Strategy:** counter-example construction + dependency check.
- **Attempt:** Searched for any other call to `Module.create/3`,
  `String.to_atom`, `Module.concat` on per-entry inputs, or
  `:erlang.binary_to_atom` in `lib/tau/hooks/` and `lib/tau/mcp/` —
  `grep -rn "Module.create\|String.to_atom\|binary_to_atom" lib/tau/hooks
  lib/tau/mcp` returned only the two callsites the solution targets. Also
  verified that `Hooks.Shell.build/2` is presently called from zero
  callsites in `lib/` or `test/` (`grep -rn "Hooks.Shell.build\|Shell.build"
  lib test` is empty); the shell-hook atom-growth path is therefore
  presently vacuous and the solution closes a latent rather than active leak
  at that site, but the leak is real on the MCP side
  (`lib/tau/mcp/server.ex:206-207` calls `register_tool/2` per discovered
  tool on every server restart).
- **Outcome:** withstood.
- **Action:** none.

### Claim 2: Introduce `%Tau.Hooks.Shell.Entry{}` and `%Tau.MCP.ToolEntry{}` structs as the registry value types

- **Claim (C):** "Introduce two plain structs … and store them as the
  registry values that the dispatchers consume."
- **Grounds (G):** `lib/tau/registries.ex:57-58` configures
  `Tau.Tools.Registry` and `Tau.Hooks.Registry` as Elixir `Registry` instances
  with `keys: :duplicate`. `Registry.register/3`'s third argument is the
  arbitrary stored value — `lib/tau/tool.ex:57` stores a module atom;
  `lib/tau/mcp/server.ex:233` stores a module atom. Both are free to store
  any term, including a struct.
- **Warrant (W):** `Registry` value semantics are term-opaque — the registry
  does not introspect stored values. A struct is a tagged map, which is a
  legal term. Pattern-matching on the registry value's struct tag at the
  dispatcher is a Hickey-aligned composition (the registry remains the
  lookup mechanism; the value's *shape* drives dispatch).
- **Qualifier (Q):** Holds for all current consumers of the registries that
  read the value as an opaque term and pass it forward. Does NOT hold for
  any consumer that pattern-matches `is_atom(mod)` and assumes the value is
  a `Tau.Tool` / `Tau.Hook` callback module — those callsites are enumerated
  in claim 3 and need an additional clause.
- **Rebuttal (R):** Would not hold if a `Registry.match/3` call expected a
  specific value shape via pattern (`Registry.match/3` does accept a match
  pattern). `grep -rn "Registry.match" lib/tau/` finds zero usages against
  either registry — confirmed.
- **Backing (B):** Elixir `Registry` documentation — values are arbitrary
  terms, with no schema. https://hexdocs.pm/elixir/Registry.html.

#### Falsification attempt for claim 2

- **Strategy:** dependency check (does the substrate accept the value type?)
  + edge-case enumeration (do any callsites rely on the value being an atom?).
- **Attempt:** Verified `Registry` API contract via hexdocs; enumerated
  callsites by `grep -rn "Registry.register\|Registry.lookup\|Registry.match\|
  Registry.select" lib/tau/` and filtered to the two registries. All current
  read sites (`hooks/dispatcher.ex:76`, `tool.ex:48`, `tool.ex:68`,
  `mcp/server.ex:121`) consume the value either as opaque (the unregister
  call on `mcp/server.ex:121` reads keys, not values) or by passing it
  forward; none rely on it being an atom at the registry level. The
  atom-dependence appears one layer further out, at the dispatcher.
- **Outcome:** withstood.
- **Action:** none.

### Claim 3: One additional clause in `Tau.Hooks.Dispatcher.run_one/3` and one additional clause in `Tau.Session.dispatch_tool/3` is sufficient to route the struct values; the existing `is_atom(mod)` clause is unchanged

- **Claim (C):** "Extend `Tau.Hooks.Dispatcher.run_one/3` and the session FSM
  tool-dispatch path with one additional clause each, pattern-matching on the
  struct tag and delegating to the already-public
  `Tau.Hooks.Shell.run_command/5` and
  `Tau.MCP.ToolAdapter.invoke_remote/3`."
- **Grounds (G):** `lib/tau/hooks/dispatcher.ex:31` defines `run_one/3` with
  a single `mod, event, payload` head; it calls `mod.handle(event, payload)`
  at line 46. `lib/tau/session/tool_dispatch.ex:624-696` performs the
  module-atom dispatch via `Tau.Tool.lookup(name)` → `Tau.Tool.Validator.validate(mod, args)`
  → `mod.execute(args, ctx)`. Adding a `%Entry{}` clause to `run_one/3` is
  straightforward; adding a `%ToolEntry{}` clause to `dispatch_tool/3` (in
  practice `run_tool_validated/6` and `run_tool/4`) is also localised IF the
  consumer surface ends at these two call frames.
- **Warrant (W):** OTP non-negotiable #2: "Extensibility seams MUST be
  behaviours. Pattern match on atoms and structs." Pattern-matching the
  registry value's struct tag at the consumer boundary is the canonical
  shape. The leap from G to C presupposes that ONLY these two callsites
  consume the registered value as a callback target.
- **Qualifier (Q):** Holds when the only consumers of the registry value
  are these two dispatchers. Does NOT hold if other call paths read the
  registry value and invoke a callback on it directly.
- **Rebuttal (R):** Pre-emptive concession — there ARE other consumer call
  paths today that assume the registered value is a module:
  (i) `lib/tau/tool.ex:48` `Tau.Tool.lookup/1` returns the raw value (the
  solution acknowledges this in "What changes" by widening the return type);
  (ii) `lib/tau/providers/shared/tool_spec.ex:53-58` `extract/1` clauses
  call `mod.name/0`, `mod.description/0`, `mod.parameters/0` on every tool
  consumed in `adapt/2`;
  (iii) `lib/tau/session/skill_activation.ex:357` calls `mod.name()`,
  `mod.description()`, `mod.parameters()` on the result of
  `Tau.Tool.lookup/1`;
  (iv) `lib/tau/tui/app/completion.ex:29` calls `mod.description()` after
  `function_exported?(mod, :description, 0)`;
  (v) `lib/tau/tool.ex:57` `register/1` is typed `module()` and calls
  `mod.name()` to compute the registry key;
  (vi) `lib/tau/extensions/loader.ex:484` calls `mod.name()`;
  (vii) `lib/tau/commands/catalog.ex:69` calls `mod.description()`;
  (viii) `lib/tau/tool/validator.ex:42` `validate/2` is typed
  `module(), term()`, guards on `is_atom(mod)`, calls `mod.parameters/0`
  (line 86) AND caches the resolved schema in `:persistent_term` keyed by
  the module atom (line 81, 92, 99) — a struct has no equivalent unique key.
  These eight callsites must learn the struct shape, not "one additional
  clause each in two dispatchers."
- **Backing (B):** Tau CLAUDE.md OTP non-negotiable #2 and #3 (pattern-match
  on atoms and structs; no GenServer wrapping stateless logic). The full
  enumeration above is from `grep -rn` over `lib/tau/`; the solution's "any
  callsite that iterates registered tools" Open Question (#1) acknowledges
  this enumeration was not done at proposal time.

#### Falsification attempt for claim 3

- **Strategy:** edge-case enumeration over consumers of `Tau.Tool.lookup/1`,
  `Tau.Tools.Registry`, and `Tau.Hooks.Registry`.
- **Attempt:** Ran `grep -rn "Tau\.Tool\.lookup\|Tau\.Tool\.list\|
  Tau\.Tool\.register" lib test` and `grep -rn "mod\.\(name\|description\|
  parameters\|execute\|execution_mode\|streams_updates?\)" lib test`.
  Catalogued each call frame and assessed whether the consumer would
  observe a struct-vs-atom difference. Findings enumerated in the
  Rebuttal above.
- **Outcome:** partially falsified.
- **Action:** narrow the Qualifier on the original claim from "one
  additional clause in each of two dispatchers" to "one additional clause
  in each of the two **callback** dispatchers, PLUS struct-aware updates
  to ~7 introspection callsites (`Tau.Tool.Validator`, `Providers.Shared.ToolSpec`,
  `Session.SkillActivation`, `TUI.App.Completion`, `Tool.register/1`,
  `Extensions.Loader`, `Commands.Catalog`)." The `:persistent_term` cache
  in `Tau.Tool.Validator` needs a deliberate decision: key by `{:struct,
  namespaced_name}` for `ToolEntry`-shaped tools, or skip caching for
  the struct branch (parameters are still compile-time constant for an
  MCP tool relative to its registration lifetime). This narrowing does
  not invalidate the solution; it inflates the migration cost from
  "medium" to "medium-high" and surfaces a design decision (the cache
  key) that the proposal deferred to implementation. **No revision of
  `solution.md` is triggered** — the Open Questions section already
  flags this enumeration as a "confidence on Proposal 1's 'medium'
  rating is gated on this grep" — but the narrowed Qualifier MUST be
  carried into the parent's claim.

### Claim 4: The supervision tree is unchanged; no new GenServers, ETS tables, or supervised workers are introduced

- **Claim (C):** "The supervision tree — no new GenServers, no new ETS
  tables, no new supervised workers."
- **Grounds (G):** The solution proposes only struct definitions and
  function-clause additions; structs are compile-time constructs with no
  runtime supervision. `Tau.Hooks.Registry` and `Tau.Tools.Registry`
  already exist (`lib/tau/registries.ex:57-58`). No new `start_link/1`,
  no new `child_spec/1`, no new `:ets.new/2`.
- **Warrant (W):** OTP non-negotiable #3: "MUST NOT wrap stateless logic
  in a GenServer." Conversely, structs + pure functions + existing
  registries require no additional process supervision. The supervision
  tree is the set of `child_spec` entries under `Tau.Application`; adding
  none preserves the tree.
- **Qualifier (Q):** Holds unconditionally for the changes the solution
  describes (struct defs + dispatcher clauses + introspection-callsite
  updates). Would fail only if the implementer added incidental machinery.
- **Rebuttal (R):** None — the claim is structural: the solution does
  not add `child_spec`, `start_link`, or `:ets.new` calls. Rebuttal would
  require the solution to silently introduce one of these.
- **Backing (B):** Tau supervision tree definition at
  `lib/tau/application.ex`; the proposal does not list a change to it.

#### Falsification attempt for claim 4

- **Strategy:** counter-example construction.
- **Attempt:** Asked "could the struct branch in the dispatcher require
  per-entry process state to support hot-reload?" The current MCP tool
  adapter is stateless across `invoke/3` calls (forwards immediately to
  `Tau.MCP.Server.invoke/3`); the shell-hook callback is stateless
  (`run_command/5` is pure-ish — opens a port, blocks, parses). Neither
  requires per-entry process state. No counter-example found.
- **Outcome:** withstood.
- **Action:** none.

### Claim 5: The existing test suite passes without modification

- **Claim (C):** "The existing dispatch functions are behaviour-preserving,
  so no test changes are required."
- **Grounds (G):** `Tau.Hooks.Shell.run_command/5` and
  `Tau.MCP.ToolAdapter.invoke_remote/3` are existing public functions
  with unchanged signatures; their internal behaviour is unchanged. The
  dispatchers' module-atom clauses are preserved verbatim. Tests of the
  registries' lifetimes, the hook event dispatch order, and the MCP
  invoke path do not pattern-match on the stored value type explicitly
  (verified: `grep -rn "Tau.Hooks.Shell.Generated\|Tau.MCP.ToolAdapter\."
  test/` returns no tests that hard-bind the dynamic module name).
- **Warrant (W):** Behaviour-preserving refactors leave observable
  outputs unchanged for fixed inputs. Tests that exercise the public
  API (`Tau.Hooks.Dispatcher.run/2`, `Tau.Session.dispatch_tool/3`,
  `Tau.MCP.Server.invoke/3`) without reaching into the implementation
  detail of "which module type is stored in the registry" will pass
  unchanged.
- **Qualifier (Q):** Holds for the dispatcher-level test suites. Does
  NOT hold for any test that asserts the registry value's type
  (e.g. `assert is_atom(value)`), nor for any test that exercises the
  introspection callsites enumerated in claim 3 with a struct-shaped
  registry value before those callsites learn the new shape.
- **Rebuttal (R):** Tests that exercise `Tau.Tool.lookup/1` and then call
  `mod.name()` directly on the result would break if `lookup/1`'s return
  type widens to `module() | %ToolEntry{}` and they receive a
  `ToolEntry`. The current test set
  (`test/tau/extensions/loader_test.exs:173`, `:285`, `:675`, `:718`
  asserts `{:ok, HelloWorldExt.HelloTool}`) only registers compile-time
  extension tool modules, so the atom branch of the union is exercised —
  no break. But any new MCP-flavoured test would have to know the new
  shape.
- **Backing (B):** Hickey, "Simple Made Easy" — preserving the substrate
  while changing the value type is a composition, not a complecting. The
  test surface depends on the substrate (the registries' lifecycle) and
  the public dispatch contracts, both preserved.

#### Falsification attempt for claim 5

- **Strategy:** edge-case enumeration over the test suite.
- **Attempt:** `grep -rn "Tools\.Registry\|Tau.Tool.lookup\|Tau.Tool.list\|
  Tau.Tool.register" test/` found tests that:
  - assert atom-tagged extension tool modules
    (`extensions/loader_test.exs`) — these continue to work because
    extension tools remain `module()`-typed,
  - assert `Tau.Tool.list/0` returns a list of binary names
    (`qa/tool_exposure_test.exs:106`,
    `cli/headless_run_tool_exposure_test.exs:220`,
    `session/active_skill_tool_exposure_test.exs:131`) — `list/0`'s
    contract is "names", which is independent of the value type.
  - The `payload_test.exs:36` test registers a `CapturingHook` atom
    against `Tau.Hooks.Registry` directly — exercises the atom branch
    only, untouched by the struct branch addition.
  No test today asserts that the registry value type IS an atom in a way
  that would fail if a struct were stored. The single
  conditional risk is the `Tau.Tool.Validator.validate(mod, args)` guard
  `when is_atom(mod)` — if a caller invokes `validate/2` with a
  `%ToolEntry{}`, the function clause does not match and dispatch
  raises `FunctionClauseError`. This is not a test that exists today,
  but the live dispatch path at `tool_dispatch.ex:626` does call
  `Tau.Tool.Validator.validate(mod, args)` on the lookup result — so
  the runtime path is broken until `validate/2` learns the struct shape.
- **Outcome:** partially falsified (already absorbed into claim 3's
  narrowed Qualifier).
- **Action:** narrow Qualifier to "the existing test suite passes
  without modification, **subject to** the introspection-callsite
  updates listed in claim 3 landing in the same PR — without them,
  `Tau.Tool.Validator.validate/2` raises `FunctionClauseError` on the
  first MCP tool dispatch."

## Cross-claim consistency

Claims 1, 2, and 4 are mutually consistent and unconditional: remove the
two `Module.create/3` sites, replace the registry value with a struct, add
no new processes. Claims 3 and 5 are linked: the dispatch path is correct
only when the introspection callsites are co-updated, which is exactly
what the solution's "What changes" section calls out in its last bullet
("any callsite that iterates registered tools and invokes `mod.name/0` …
confirm via grep and add the `%ToolEntry{}` branch"). The validation
elevates this bullet from a checklist item to a load-bearing precondition
on AC (c) — the test suite passes only if the bullet is executed
exhaustively. The solution's Open Question #1 explicitly defers this
enumeration to implementer time; the validator has now performed it (the
seven-callsite list under claim 3's Rebuttal), and it is captured here so
the parent inherits the narrowed Qualifier.

There is no internal contradiction between any pair of claims. The only
elevated cost is the migration cost from "medium" to "medium-high",
which does not alter the comparative scoring against Proposals 2, 3, 4
(Proposal 2 still admits unbounded atom growth on novel configs; Proposals
3 and 4 still add stateful surface). The selector's choice stands.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | No atom growth from these two sites | counter-example + dependency check | withstood | none |
| 2 | Structs can be registry values | dependency + edge-case | withstood | none |
| 3 | One extra dispatcher clause each | edge-case enumeration | partially falsified | narrow Qualifier — ~7 introspection sites also need struct branches; `Tau.Tool.Validator` needs a cache-key decision |
| 4 | Supervision tree unchanged | counter-example construction | withstood | none |
| 5 | No test changes required | edge-case enumeration | partially falsified | narrow Qualifier — passes only if claim-3 callsites are co-updated in same PR |

## Revision required

None. Both partial falsifications narrow Qualifiers in place; neither
falsifies the solution wholesale.

- **Target file:** n/a
- **Revision kind:** n/a
- **Rationale:** The solution remains the best of the four proposals
  against the acceptance criterion (Proposals 2/3/4 all introduce new
  hazards or break stable public shapes; Proposal 1 closes the leak with
  the lowest residual cost). The narrowed Qualifier on claim 3 increases
  the implementer's grep-and-edit surface from "two dispatchers" to
  "two dispatchers + ~7 introspection callsites + one
  `:persistent_term` cache-key decision in `Tau.Tool.Validator`" — that
  is a concrete checklist the implementer can execute, not a defect in
  the design.

## Outstanding doubts

- **`Tau.Tool.Validator` `:persistent_term` cache key for the struct
  branch.** The current cache is keyed by module atom
  (`:persistent_term.get({Tau.Tool.Validator, mod})`,
  `lib/tau/tool/validator.ex:90`). A struct has no module atom for the
  individual tool. The implementer must choose: (a) key by
  `{Tau.Tool.Validator, struct_tag, namespaced_name}` (a binary in the
  key — `:persistent_term` accepts any term — but binary atoms remain
  permanent so the binary's *atom-ness* is irrelevant; the binary
  itself is not interned), (b) skip caching for the struct branch
  (cheaper than a defective key; parameters are still constant per
  registration lifetime so re-resolution per call is the cost), or
  (c) cache in an ETS table owned by the MCP server (couples cache
  lifetime to server lifetime — Erlang-idiomatic but adds surface).
  Option (b) is the simplest path and matches the
  "no new stateful surface" claim 4; option (a) preserves the
  cache benefit and is also stateless. This decision belongs to the
  implementer but is non-trivial and should be made explicit in the
  PR description.
- **`Tau.Hooks.Shell.build/2` has zero current callers.** The solution
  describes the call as happening "at settings-load time" but no code
  in `lib/` invokes `Hooks.Shell.build/2` today. The shell-hook
  atom-leak path is therefore presently latent — the fix prevents a
  future caller from introducing the leak, but it does not close an
  active leak on the hook side. The active leak is exclusively at the
  MCP side. The parent should note this asymmetry — the solution still
  applies, but its urgency is unequal across the two sites.
- **`Tau.MCP.ToolAdapter.build/5`'s `mod_name` argument retention.**
  The solution's Open Question #2 flags this. From the validator's
  side: removing it requires updating `mcp/server.ex:231-232` (drop the
  `Module.concat([...])` line; pass only `server_name, key, description,
  parameters` to `build/4`). The cleaner option is preferable since
  retaining `mod_name` continues to create the per-entry atom at
  `Module.concat/1` even though `build/5` no longer uses it — i.e.
  "ignore the unused arg" would silently defeat AC (a) on the MCP side.
  The validator's recommendation: drop the argument and update the
  one caller, do not keep it for arity compat.
