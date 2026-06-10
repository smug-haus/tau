---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: root
synthesised_from: [subproblems/unload-resilience/solution.md, subproblems/atom-internment/solution.md]
selection_method: synthesis
mode: non-leaf
revision: 0
---

# Solution: Load-time snapshots + string-typed collision guard for `Tau.Extensions.Loader`

## Recommendation

Land two independent, file-local refactors of `lib/tau/extensions/loader.ex` that together close both safety defects without altering any public API. (1) **Unload path:** enrich `info` at registration time with a `registered_keys` snapshot of the exact registry tuples produced by each callback, and drive `unload_module/*` from that snapshot via a new `crash_safe_unload/2` helper that mirrors `crash_safe_register/2`'s logging-and-telemetry discipline; delete `try_tool_name/1` and the four `try/rescue _ -> []` blocks together with the load-time re-query they hide. (2) **Collision path:** change `peek_module_names/1` to return strings rather than atoms, extract `name_collision?/1` as a typed `{:collision, atom()} | :no_collision` helper backed by `String.to_existing_atom/1`, and add an `atom_budget_ok?/0` defence-in-depth guard with a `@atom_headroom` attribute and a `[:tau, :extensions, :atom_budget_exceeded]` telemetry event. The two changes share only the file they touch and the SPEC-EXTENSIONS amendment they jointly produce; they compose by direct composition with no shared state and no ordering dependency.

## Selected from

- **Synthesised from:** child solutions at `subproblems/unload-resilience/solution.md`, `subproblems/atom-internment/solution.md`
- **Composition rationale:** The two child solutions operate on disjoint code paths inside `loader.ex` (registration/unload vs. compile-time peek/collision-check) and on disjoint structural concerns (registry-key lifecycle vs. atom-table lifecycle). They share no functions, no state, and no callers; neither references the other's data structures. Composition is therefore **direct**: each child's recommendation lands as written, in either order, without interface negotiation. The only shared surface is `lib/tau/extensions/loader.ex` itself (both edit it) and `docs/spec/SPEC-EXTENSIONS.md` (both amend §3 / telemetry sections). The complecting hypothesis identified by the parent problem — that resilience and atom-resource management each got conflated with adjacent concerns — is decomplected independently by each child: unload-resilience eliminates the broken/empty-callback ambiguity by removing the callback invocation, and atom-internment eliminates the resource-safety hazard by removing the permanent atom creation. No conflict, no gap; the children together cover both legs of the parent acceptance criterion.

## What changes

Unload path (from `subproblems/unload-resilience/solution.md`):

- `lib/tau/extensions/loader.ex` — `register_module/1`: populate `info.registered_keys` as a flat list of `{:tool, name, t} | {:hook, ev} | {:command, name} | {:skill, name}` tuples for the entries actually registered.
- `lib/tau/extensions/loader.ex` — `unload_module/1` (rename to `unload_module/2`): replace four `try/rescue _ -> []` blocks with an `Enum.each` over `info.registered_keys` dispatching to the appropriate `Registry.unregister*` call per tag.
- `lib/tau/extensions/loader.ex` — add private `crash_safe_unload/2` mirroring `crash_safe_register/2`; on exception emit `Logger.warning/1` naming the module and `:telemetry.execute/3` of `[:tau, :extensions, :unload, :exception]`.
- `lib/tau/extensions/loader.ex` — `do_unload/1`: thread `info` through to `crash_safe_unload/2`.
- `lib/tau/extensions/loader.ex` — delete `try_tool_name/1`.
- `lib/tau/extensions/loader.ex` — path-based `%{path: _, modules: _}` entries: store per-module `registered_keys` snapshots so each module unloads independently.
- `test/tau/extensions/` — update tests asserting on `state.loaded` entry shape or `info` map contents.

Collision path (from `subproblems/atom-internment/solution.md`):

- `lib/tau/extensions/loader.ex` — `peek_module_names/1`: return type `{:ok, [String.t()]}`; remove `String.to_atom("Elixir." <> name)`; return strings directly.
- `lib/tau/extensions/loader.ex` — `compile_with_collision_guard/1`: pass strings to `name_collision?/1`; replace inline atom creation + `Code.ensure_loaded?/1` with a `name_collision?/1` call.
- `lib/tau/extensions/loader.ex` — add private `name_collision?(String.t()) :: {:collision, atom()} | :no_collision` using `String.to_existing_atom/1` and `rescue ArgumentError -> :no_collision`.
- `lib/tau/extensions/loader.ex` — add private `atom_budget_ok?/0` checking `(:erlang.system_info(:atom_limit) - :erlang.system_info(:atom_count)) >= @atom_headroom`; early-return on false with `Logger.error/1` and `[:tau, :extensions, :atom_budget_exceeded]` telemetry.
- `lib/tau/extensions/loader.ex` — add module attribute `@atom_headroom Application.compile_env(:tau, [:extensions, :atom_headroom], 10_000)`.
- `lib/tau/extensions/loader.ex` — rewrite the stale comment block (lines 270–275) and remove the existing Credo `UnsafeToAtom` suppression comment.

Shared spec amendment (jointly produced):

- `docs/spec/SPEC-EXTENSIONS.md` — §3: record `@atom_headroom` as a configurable invariant; amend D-123 to reflect the no-intern guarantee; add D-NNN (or amend D-122/D-124) to record the load-time-snapshot unload invariant. Telemetry section: add `[:tau, :extensions, :unload, :exception]` and `[:tau, :extensions, :atom_budget_exceeded]` events.

## What does not change

- Public API of `Tau.Extensions.Loader` — no exported function signatures change.
- The `Tau.Extension` behaviour and DSL — callback signatures and semantics unchanged.
- `crash_safe_register/2` and the load-time isolation path — explicitly out of scope; preserved as the model for `crash_safe_unload/2`.
- `do_compile_file/1` — compile-error handling preserved.
- `is_extension?/1` — unchanged.
- All registry consumers outside `loader.ex` (`Tau.Tool.lookup/1`, hook / command / skill dispatch) — registry value shapes unchanged.
- Collision-detection semantics for already-loaded modules — `String.to_existing_atom/1` succeeds for atoms interned by prior `Code.compile_file/1` successes, so the collision guard fires correctly for all previously-loaded modules.
- `lib/tau/cli/extensions.ex` and any concern outside `lib/tau/extensions/loader.ex` — out of scope per the parent problem.

## Migration sketch

The two refactors are independent and may land in either order — there is no shared function and no shared state to coordinate. The recommended sequence is **two sibling PRs that may be opened in parallel**, each scoped to its child solution's `What changes` list plus the corresponding SPEC-EXTENSIONS amendments. Each PR is gateable independently because the cross-cutting concerns (telemetry events, SPEC D-NNN entries) are namespaced (`:unload, :exception` vs. `:atom_budget_exceeded`; D-122/D-124 lineage vs. D-123 lineage). If serialised for review-bandwidth reasons, `unload-resilience` should land first because its scope is larger (touches `register_module/1`, `do_unload/1`, and the path-based entry shape) and its tests are the more substantive `state.loaded` rework; `atom-internment` then lands as a smaller, mechanically simpler follow-up. The combined acceptance criterion is checked in the second-merging PR by a regression-test run that exercises both: (a) a broken extension is logged and unloads cleanly with no residual registry entries (D-124 hot-reload property test); (b) processing N unique unloaded module-name strings interns zero atoms (property test asserted via `:erlang.system_info(:atom_count)` deltas).

## Open questions

- (Inherited from `unload-resilience`) `Tau.Tool.register/1`'s actual return contract — `:ok | :error` vs. unconditional `:ok` vs. raise — must be verified before the `registered_keys` capture for the `:tool` tag is written; the snapshot must record only keys actually registered.
- (Inherited from `unload-resilience`) Grep `lib/` and `test/` for `state.loaded` / `entry.info` pattern-match callsites to confirm the enriched `info` shape's blast radius before the PR opens; any external matcher must accept the new `registered_keys` field.
- (Inherited from `unload-resilience`) Path-based `%{path: _, modules: [mod1, mod2, ...]}` entries: the current `info` shape per path vs. per module must be re-read; the snapshot must be per-module to support independent unload.
- (Inherited from `atom-internment`) Whether Credo `--strict` flags the `rescue ArgumentError` in `name_collision?/1`; if so, the response is a targeted `# credo:disable-for-next-line` with rationale, not removing the guard.
- (Inherited from `atom-internment`) Calibration of `@atom_headroom`'s 10_000 default against a baseline atom count audit of the deployed application.
- (Inherited from `atom-internment`) Whether `[:tau, :extensions, :atom_budget_exceeded]` should be a paired `:start`/`:stop` span or a single `:execute`; OTP non-negotiables §5 requires pairing for perf-sensitive events but this is a one-time guard so a single `:execute` is defensible.
- (Coordination, parent-level) SPEC-EXTENSIONS D-NNN allocation for the new unload-snapshot invariant and the no-intern guarantee — single new D-NNN per concern or amendments to existing D-122/D-123/D-124. Resolved by the spec author at amendment time; not a blocker for either child's implementation.

## Linked sub-problems / proposals

- `subproblems/unload-resilience/` → "Enrich `info` with `registered_keys` at registration; drive unload from the snapshot via `crash_safe_unload/2`; delete `try_tool_name/1` and the four `try/rescue _ -> []` blocks."
- `subproblems/atom-internment/` → "Return strings from `peek_module_names/1`; check collisions with `String.to_existing_atom/1` via a typed `name_collision?/1` helper; add an `atom_budget_ok?/0` defence-in-depth guard with `@atom_headroom` and an `:atom_budget_exceeded` telemetry event."

## Revision history

- (revision 0 — initial)
