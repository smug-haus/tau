---
template_version: 1
template_name: problem
node_kind: root
depth: 0
parent: —
status: decomposed
---

# Problem: tau-extensions loader safety

## Statement

`Tau.Extensions.Loader` contains two independent safety defects introduced during its initial implementation. The unload path uses four bare `try/rescue` blocks to fetch callback results from potentially-broken modules, silently substituting empty lists for any error — making it impossible to distinguish a broken module from an empty one. Separately, the collision-detection path calls `String.to_atom/1` on every `defmodule` name extracted from every `.ex` file found under `~/.tau/extensions/**`, so an adversary (or a prolific extension author) can exhaust the VM's fixed-size atom table from the filesystem.

## Context

- `lib/tau/extensions/loader.ex:425–490` — `unload_module/1`; four `try/rescue _ -> []` blocks wrapping `mod.tools/0`, `mod.hooks/0`, `mod.commands/0`, `mod.skills/0`
- `lib/tau/extensions/loader.ex:482–490` — `try_tool_name/1`; fifth `try/rescue _ -> nil` wrapping `mod.name/0`
- `lib/tau/extensions/loader.ex:276–290` — `peek_module_names/1`; `String.to_atom("Elixir." <> name)` applied to all regex-extracted names from filesystem-sourced source text
- `lib/tau/extension.ex` — `Tau.Extension` behaviour definition; four callbacks declared
- SPEC-EXTENSIONS §3 D-120, D-122, D-123, D-124
- The `crash_safe_register/2` path (lines 296–349) correctly isolates load-time failures; the unload path does not share this discipline

## Complecting hypothesis

Unload-time resilience is complected with the normal-path registry-query logic because `unload_module/1` calls the same behaviour callbacks used during load (`.tools/0`, `.hooks/0`, etc.) without first validating the module state, and then catches all exceptions as empty lists — merging "broken module" and "no registrations" into a single undistinguishable outcome.

Atom-table resource management is complected with module collision detection because `peek_module_names/1` uses `String.to_atom/1` to convert filesystem-derived strings into atoms solely to check `Code.ensure_loaded?/1`, a guard operation that does not require permanent atom internment.

## Decomposition strategy

The two defects are independent in cause, mechanism, and fix surface. They decompose cleanly along the **concern (Hickey)** axis: one sub-problem owns the unload-path `try/rescue` cluster and its resilience contract; the other owns the `String.to_atom/1` internment call and its resource-safety contract. The sub-problems share no code paths and no fix strategy, so they are mutually exclusive and collectively exhaustive of the audit lens scope.

## Sub-problems (filled by decomposer)

1. **unload-resilience** — `unload_module/1` uses four `try/rescue _ -> []` blocks that conflate broken-module and empty-list outcomes, making silent partial-unloads undetectable and unloggable.
2. **atom-internment** — `peek_module_names/1` calls `String.to_atom/1` on every regex-extracted module name from filesystem-controlled `.ex` files, leaking atoms permanently into a fixed-size VM table.

## Acceptance criterion

Both sub-problems are solved when: (a) `unload_module/1` can distinguish a broken extension from an empty one, logs broken modules, and leaves no residual registry entries on partial unload; and (b) `peek_module_names/1` resolves module names without permanently interning user-controlled strings into the atom table.

## Out of scope

- Load-time `try/rescue` in `crash_safe_register/2` (lines 296–349) — that path is correctly isolated and is not under audit
- `do_compile_file/1` (lines 255–266) — compile-error handling is correct; not under audit
- `is_extension?/1` predicate logic
- Extension CLI (`lib/tau/cli/extensions.ex`)
- Any concern outside `lib/tau/extensions/loader.ex`

## Amendment log

- (none yet)
