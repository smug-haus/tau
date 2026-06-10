---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-3.md]
selection_method: single
revision: 0
---

# Solution: strings-throughout + named collision helper + atom-budget guard

## Recommendation

Replace `peek_module_names/1` with a pure string-returning variant (no atom creation), extract the collision check into a named `name_collision?/1` helper that returns `{:collision, atom} | :no_collision` using `String.to_existing_atom/1` (interning nothing on a miss), and add an `atom_budget_ok?/0` defence-in-depth guard that checks `:erlang.system_info(:atom_count)` against `:erlang.system_info(:atom_limit)` before any file is processed. This eliminates the permanent-atom side-effect from the peek path for all module names that are not already loaded, satisfies the acceptance criterion exactly, and adds observability and a runtime backstop without changing any public API or altering the collision-detection semantics for already-loaded modules.

## Selected from

- **Chosen:** `proposals/proposal-3.md`
- **Why chosen:** Proposal 3 is a strict superset of Proposal 1 in decomplecting depth and testability. Both satisfy the acceptance criterion via the same core mechanism (`String.to_existing_atom/1` returning no-op on a miss), but Proposal 3 extracts the guard into `name_collision?/1` with an explicit typed contract (`{:collision, atom} | :no_collision`), making the unit independently testable and its invariant visible at the type level. The atom-budget guard is additive — it does not change the primary fix's correctness but adds a runtime backstop that fires even if a future code path reintroduces atom creation. Proposal 2 over-solves (compiles before checking collisions, introducing post-compile purge atomicity risk) without satisfying the AC more cleanly. Proposal 4 is API-breaking, blunt, and carries unresolved dependencies (`existing_registry_snapshot/0`). Proposal 3 does not force a choice between Proposals 1 and 3 — it IS Proposal 1 with the `rescue`-inline concern addressed by extraction.

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Yes | Substantial | Low | Low | Easy |
| 2 | Yes | Deep | Medium | Medium | Medium |
| 3 | Yes | Deep | Low | Low | Easy |
| 4 | Yes | Deep | High | Medium | Hard |

Proposal 3 wins on Fit + Decomplecting depth without being defeated on cost, risk, or reversibility.

## What changes

- `lib/tau/extensions/loader.ex` — `peek_module_names/1`: return type changes from `{:ok, [atom()]}` to `{:ok, [String.t()]}`; the `String.to_atom("Elixir." <> name)` call is removed; strings are returned directly.
- `lib/tau/extensions/loader.ex` — `compile_with_collision_guard/1`: updated to pass name strings to `name_collision?/1`; the inline atom-creation and `Code.ensure_loaded?/1` call replaced by `name_collision?/1` calls.
- `lib/tau/extensions/loader.ex` — add private `name_collision?(String.t()) :: {:collision, atom()} | :no_collision` using `String.to_existing_atom/1` + `rescue ArgumentError → :no_collision`.
- `lib/tau/extensions/loader.ex` — add private `atom_budget_ok?/0` checking `(:erlang.system_info(:atom_limit) - :erlang.system_info(:atom_count)) >= @atom_headroom`; early-return with `Logger.error` + telemetry event `[:tau, :extensions, :atom_budget_exceeded]` when false.
- `lib/tau/extensions/loader.ex` — add module attribute `@atom_headroom Application.compile_env(:tau, [:extensions, :atom_headroom], 10_000)`.
- `lib/tau/extensions/loader.ex` — rewrite the comment block at lines 270–275 (currently rationalising `String.to_atom/1`) to document the new `String.to_existing_atom/1` invariant.
- `lib/tau/extensions/loader.ex` — remove the existing Credo `UnsafeToAtom` suppression comment (the warning disappears legitimately).
- `docs/spec/SPEC-EXTENSIONS.md` — §3: add `@atom_headroom` as a configurable invariant; §4 or telemetry section: record the `[:tau, :extensions, :atom_budget_exceeded]` event; update D-123 to reflect the new no-intern guarantee.

## What does not change

- `do_compile_file/1` — unmodified; compile errors remain handled by existing path.
- Public API of `Tau.Extensions.Loader` — no public function signatures change.
- Callers of `compile_with_collision_guard/1` — the function remains private and its arity and return type are unchanged from the caller's perspective.
- Collision-detection semantics for already-loaded modules — `String.to_existing_atom/1` succeeds for atoms that exist (because `Code.compile_file/1` interned them on their first successful load), so the collision guard fires correctly for all previously-loaded modules.
- The `Tau.Extension` behaviour and DSL — explicitly out of scope.
- `unload_module/1` and `do_compile_file/1` error handling — owned by adjacent sub-problems.

## Migration sketch

Introduce the changes in a single PR touching only `lib/tau/extensions/loader.ex` and `docs/spec/SPEC-EXTENSIONS.md`: (1) update `peek_module_names/1` to return strings, (2) add `name_collision?/1`, (3) add `atom_budget_ok?/0` and `@atom_headroom`, (4) update `compile_with_collision_guard/1` to call both, (5) rewrite the stale comment block, (6) remove the Credo suppression, (7) amend SPEC-EXTENSIONS D-123 and add the telemetry event entry. Property tests: add a test asserting that processing N unique module name strings (none pre-loaded) interns zero atoms; add a unit test for `name_collision?/1`'s three cases (no atom, atom not loaded, atom loaded). The existing collision-detection property test continues to pass unchanged because the observable behaviour of `compile_with_collision_guard/1` is identical.

## Open questions

- Does Credo `--strict` flag the `rescue ArgumentError` in `name_collision?/1` under the `Credo.Check.Warning.UnsafeToAtom` or any related check? Proposal 1 noted this as a prototype verification step; the same applies here. If Credo flags it, a `# credo:disable-for-next-line` with a rationale comment is the correct response (not removing the guard).
- Is a default `@atom_headroom` of 10_000 well-calibrated for this application's atom budget in a typical deployed state? The proposal acknowledges the value is empirical. A brief audit of baseline atom count at startup is recommended before picking the default.
- Should the `[:tau, :extensions, :atom_budget_exceeded]` telemetry event be paired with a `[:tau, :extensions, :atom_budget_exceeded, :start]` / `[:tau, :extensions, :atom_budget_exceeded, :stop]` span or is a single `:execute` sufficient? OTP non-negotiables §5 requires pairing for perf-sensitive events; this is a one-time guard, so a single `:execute` is defensible.
- SPEC-EXTENSIONS D-123 currently covers the module-name collision guard (C-007). Does the no-intern guarantee require a new D-NNN or an amendment to D-123? This is a clarification for the spec author, not a blocker for the implementation.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Defer atom creation via `String.to_existing_atom/1`; inline rescue; minimal changes. Core mechanism identical to the chosen solution; rejected in favour of Proposal 3's named-helper extraction and budget guard.
- `proposals/proposal-2.md` — Eliminate peek entirely; post-compile purge via `:code.purge/1`. More accurate collision detection but introduces compile-before-check cost and purge atomicity risk.
- `proposals/proposal-3.md` — **Selected.** Strings throughout; `name_collision?/1` with explicit return type; `atom_budget_ok?/0` defence-in-depth guard; telemetry event on budget breach.
- `proposals/proposal-4.md` — Directory-level module quota + post-compile collision; API-breaking; blunt instrument; unresolved registry snapshot dependency.

## Revision history

- (revision 0 — initial)
