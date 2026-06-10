---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: unload-resilience

## Statement

`unload_module/1` in `Tau.Extensions.Loader` calls all four behaviour callbacks (`mod.tools/0`, `mod.hooks/0`, `mod.commands/0`, `mod.skills/0`) and wraps each call in a bare `try/rescue _ -> []`, silently treating any exception as an empty result list. A module that was successfully registered but has since become broken (e.g. reloaded with a compile error or missing dependency) will produce empty lists on unload, leaving its prior registry entries in place — a silent partial-unload that corrupts the registry without any log or telemetry signal.

## Context

- `lib/tau/extensions/loader.ex:425–480` — `unload_module/1`: four `try/rescue _ -> []` blocks, one per callback
- `lib/tau/extensions/loader.ex:482–490` — `try_tool_name/1`: fifth `try/rescue _ -> nil` wrapping `mod.name/0`, used to resolve the tool-registry key during unload
- `lib/tau/extensions/loader.ex:296–349` — `crash_safe_register/2`: the load path correctly isolates failures with logging and telemetry; the unload path has no equivalent
- `lib/tau/extensions/loader.ex:397–408` — `unload_entry/2`: retrieves previously-stored `info` map (which records what was registered); this stored state is available but not used to drive unload
- SPEC-EXTENSIONS D-120 (crash-isolated load), D-124 (hot reload unloads prior generation)
- The loader's `state.loaded` map stores `%{module: mod}` or `%{modules: [mod]}` for every successfully-registered entry, meaning the loader already knows what it registered at load time

## Complecting hypothesis

The unload-time registry-query logic is complected with unload-time resilience because `unload_module/1` re-queries the module's callbacks at unload time to discover what to unregister, rather than using the load-time record already stored in `state.loaded`. This means a module that was correctly registered but subsequently broken cannot be cleanly unregistered — the very defect that made unload unsafe is the same one that makes the prior-generation cleanup in hot-reload (D-124) incomplete.

The logged-and-skipped contract at load time (D-120) is complected with the silent-empty-list contract at unload time because both occur within the same GenServer process, giving the impression that all failures are handled — but only load failures are logged; unload failures are invisible.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

After the fix, a call to `unload_module/1` on a module that was successfully loaded but has since become broken (callbacks raise) produces: (a) a warning log naming the broken module and callback, (b) a `[:tau, :extensions, :unload, :exception]` telemetry event, and (c) no residual registry entries for the registrations that were recorded at load time.

## Out of scope

- Load-time isolation in `crash_safe_register/2` — correctly implemented; not under this sub-problem
- `peek_module_names/1` and atom internment — exclusively owned by `atom-internment` sub-problem
- `do_compile_file/1` compile error handling
- The `is_extension?/1` guard
- Changes to the `Tau.Extension` behaviour or DSL

## Amendment log

- (none yet)
