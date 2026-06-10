---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: atom-internment

## Statement

`peek_module_names/1` in `Tau.Extensions.Loader` converts every module name extracted from user-controlled `.ex` files under `~/.tau/extensions/**` into a permanent VM atom via `String.to_atom/1`. Elixir's atom table is a fixed-size global resource (default ~1 M atoms); once exhausted the VM crashes. Because each `defmodule` declaration in each scanned extension file creates a new permanent atom regardless of whether the module is ever compiled or loaded, a malicious or pathological extension directory can exhaust the atom table by declaring many uniquely-named modules — without any of those modules needing to load successfully.

## Context

- `lib/tau/extensions/loader.ex:276–290` — `peek_module_names/1`; regex scan over raw source text, then `String.to_atom("Elixir." <> name)` for each match
- `lib/tau/extensions/loader.ex:228–253` — `compile_with_collision_guard/1`: calls `peek_module_names/1` before every `Code.compile_file/1`; purpose is to detect module-name collisions via `Code.ensure_loaded?/1`
- The in-code comment at line 270–275 acknowledges `String.to_atom/1` is used because `String.to_existing_atom/1` would fail on never-before-compiled modules; this reasoning conflates "must intern now" with "must use `String.to_atom`"
- `Code.ensure_loaded?/1` accepts an atom; there is no API-level reason the atom must be permanent — the goal is simply to check whether the BEAM already has the module loaded
- SPEC-EXTENSIONS D-123 (module-name collision guard, C-007)
- Elixir default atom limit: `:erlang.system_info(:atom_limit)` ≈ 1_048_576; each unique extension defmodule name consumes one slot permanently

## Complecting hypothesis

Module collision detection is complected with atom-table resource management because `peek_module_names/1` uses `String.to_atom/1` both to produce atoms for `Code.ensure_loaded?/1` and to permanently intern those strings — a side-effect that is unnecessary for the guard's purpose. The collision check only needs to know "is this name already loaded?"; it does not need the atom to persist beyond the check.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

After the fix, processing an extension directory containing N uniquely-named `defmodule` declarations that are not already loaded adds zero new permanent atoms to the VM atom table for module names that do not ultimately compile successfully; module-name collision detection continues to work correctly for all previously-loaded modules.

## Out of scope

- `unload_module/1` `try/rescue` blocks — exclusively owned by `unload-resilience` sub-problem
- `do_compile_file/1` — compile errors are handled correctly; not under audit
- Performance of the regex scan itself (not a safety concern)
- Sandboxing or capability-limiting of extension code at compile time (a separate, larger concern)
- Changes to the `Tau.Extension` behaviour or DSL

## Amendment log

- (none yet)
