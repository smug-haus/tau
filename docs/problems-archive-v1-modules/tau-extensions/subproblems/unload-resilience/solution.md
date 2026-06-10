---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md]
selection_method: single
revision: 0
---

# Solution: Snapshot-driven unload — enrich `info` with registered keys at load time

## Recommendation

Enrich the `info` map stored in `state.loaded` at registration time to record the exact
registry keys produced by each callback category (`tools`, `hooks`, `commands`, `skills`).
Replace the four `try/rescue _ -> []` blocks in `unload_module/1` with a loop over
`info.registered_keys`, calling the appropriate `Registry.unregister*` function for each
key — no behaviour callbacks invoked at unload time. Introduce a `crash_safe_unload/2`
helper mirroring `crash_safe_register/2` to emit a `Logger.warning/1` and
`[:tau, :extensions, :unload, :exception]` telemetry if a Registry call itself raises.
Delete `try_tool_name/1`, which becomes unused once callback invocation is removed from
the unload path.

## Selected from

- **Chosen:** `proposals/proposal-1.md`
- **Why chosen:** Proposal 1 is the only candidate that fully satisfies all three legs of
  the acceptance criterion, including (c) — no residual registry entries — for the
  hot-reload scenario (D-124) that is the stated motivation. Proposal 2 explicitly cannot
  satisfy (c) when a module that previously returned non-empty callback results becomes
  broken via hot-reload; its author rates its confidence as low for exactly this reason.
  Proposal 3 satisfies (c) but at a blast radius disproportionate to the problem: wrapping
  all registry values in `{:extension_entry, mod, _}` requires atomic updates to every
  registry consumer outside `loader.ex`, introduces a non-enforced structural convention,
  and risks silent runtime type errors at any missed callsite. Proposal 4 satisfies all
  three requirements but introduces `Task.async/yield/shutdown` complexity in a GenServer
  callback to address a liveness concern (blocking callbacks) that is out of scope of the
  acceptance criterion; it also inherits the full info-enrichment work of Proposal 1 as a
  prerequisite, making it a strict superset of Proposal 1's cost without an in-scope gain.
  Proposal 1 decomplects the root cause directly — re-querying a potentially-broken module
  at unload time — by eliminating the re-query entirely in favour of a load-time snapshot.
  It is reversible (the `registered_keys` field is internal to `state.loaded`), has the
  smallest blast radius of the proposals that satisfy (c), and mirrors the existing
  `crash_safe_register/2` discipline exactly.

## What changes

- `lib/tau/extensions/loader.ex` — `register_module/1`: populate `info.registered_keys`
  as a flat list of `{:tool, name, t} | {:hook, ev} | {:command, name} | {:skill, name}`
  tuples at registration time, capturing only the keys for entries that were actually
  registered.
- `lib/tau/extensions/loader.ex` — `unload_module/1` (rename to `unload_module/2`):
  replace four `try/rescue _ -> []` blocks with a `Enum.each` over `info.registered_keys`,
  dispatching to the appropriate `Registry.unregister*` call per key tag.
- `lib/tau/extensions/loader.ex` — new `crash_safe_unload/2` private helper: wraps
  `unload_module/2` with `try/rescue`; on exception emits `Logger.warning/1` naming the
  module and emits `[:tau, :extensions, :unload, :exception]` telemetry.
- `lib/tau/extensions/loader.ex` — `do_unload/1`: thread `info` through to
  `crash_safe_unload/2`.
- `lib/tau/extensions/loader.ex` — `try_tool_name/1`: delete (no longer called from the
  unload path).
- `lib/tau/extensions/loader.ex` — path-based entry handling (`%{path: _, modules: _}`):
  enrich to store per-module `registered_keys` snapshots so multi-module path entries can
  unload each module independently.
- `test/tau/extensions/` — update tests that assert on `state.loaded` entry shape or
  inspect `info` maps to handle the enriched `registered_keys` field.

## What does not change

- `crash_safe_register/2` and the load-time isolation path — correctly implemented;
  explicitly out of scope.
- The `Tau.Extension` behaviour or DSL — no callback signatures change.
- All registry consumers outside `loader.ex` (`Tau.Tool.lookup/1`, hook dispatch, command
  dispatch, skill dispatch) — registry value shapes are unchanged.
- `peek_module_names/1` and atom internment — owned by the `atom-internment` sub-problem.
- `do_compile_file/1` and `is_extension?/1` — out of scope.
- The public API of `Tau.Extensions.Loader` — no exported function signatures change.

## Migration sketch

The change is self-contained within `loader.ex` and its test file. The natural sequence:
first enrich `register_module/1` to build and return `registered_keys` in `info` (unit
testable immediately against a healthy module); then update `do_unload/1` to thread `info`
to a new `crash_safe_unload/2`; then replace `unload_module/1`'s body with the key-driven
loop; then delete `try_tool_name/1`. The path-based multi-module enrichment (`%{modules:
[...]}`) is the highest-complexity part and can be addressed in the same commit once the
single-module path is working. No migration of existing `state.loaded` entries is required
because the Loader is restarted on hot-reload (D-124); stale entries without `registered_keys`
can be handled by a fallback clause in `unload_module/2` that logs a warning and skips.

## Open questions

- What is `Tau.Tool.register/1`'s actual return contract? Proposal 1 assumes it returns
  `:ok | :error` to determine whether a tool key was actually registered. If it raises on
  failure or returns `:ok` unconditionally, the `registered_keys` capture logic must be
  adjusted. Verify before implementing the tool-key branch.
- Does any external code (outside `loader.ex` and its tests) pattern-match on the bare
  `%{module: mod}` info shape from `state.loaded`? If so, those callsites must accept the
  enriched shape. A grep over `lib/` and `test/` for `state.loaded` / `entry.info` access
  patterns should confirm the blast radius before the PR opens.
- For path-based entries (`%{path: _, modules: [mod1, mod2, ...]}`), what is the current
  `info` shape stored per path vs. per module? The enrichment must store `registered_keys`
  per module, not per path entry, to support independent per-module unload.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Snapshot-driven unload: enrich `info` with registered keys
  at load time; drive unload entirely from the snapshot. **Selected.**
- `proposals/proposal-2.md` — Per-callback safe-call wrapper: add logging and telemetry to
  existing `try/rescue` blocks; does not satisfy AC (c) for hot-reload case.
- `proposals/proposal-3.md` — Registry ownership unregister: tag registry values with
  `{:extension_entry, mod, _}` and use `Registry.select/2` at unload; satisfies AC but
  blast radius is disproportionate.
- `proposals/proposal-4.md` — Isolated unload sub-process: delegate callback queries to a
  `Task` with timeout fallback to snapshot; satisfies AC but adds out-of-scope complexity
  and inherits Proposal 1's enrichment as a prerequisite.

## Revision history

- (revision 0 — initial)
