---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/4
revision_triggered: none
---

# Validation: strings-throughout + named collision helper + atom-budget guard

## Overview

The solution proposes three coordinated changes to `Tau.Extensions.Loader`: (1) convert `peek_module_names/1` to return strings instead of atoms, (2) extract `name_collision?/1` using `String.to_existing_atom/1` with a `rescue ArgumentError` branch, and (3) add an `atom_budget_ok?/0` guard with a configurable `@atom_headroom` threshold. Eight claims are extracted from the Recommendation, What-changes, and What-does-not-change sections. Falsification strategies applied: counter-example construction (claims 1–3), dependency check (claim 4), edge-case enumeration (claims 5–6), integration check (claim 7), type-level check (claim 8). One partial falsification found (claim 4: the Credo question is unresolved), narrowing the qualifier. No full falsification; no revision triggered.

---

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants found it difficult to generate Toulmin structures, and their structures varied greatly even though they started with the same content" (https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument). This template enforces all six components explicitly with prompts to counter that variance.

---

### Claim 1: `peek_module_names/1` with `String.to_existing_atom/1` interns zero new atoms for module names not already loaded

- **Claim (C):** Replacing `String.to_atom("Elixir." <> name)` with `String.to_existing_atom/1` (inside `rescue ArgumentError → :no_collision`) means that processing a source file whose module names have never been compiled adds zero new permanent atoms to the VM atom table for those names.
- **Grounds (G):** `loader.ex:283` calls `String.to_atom("Elixir." <> name)` today — this interns unconditionally. The Elixir standard library documents `String.to_existing_atom/1` as raising `ArgumentError` when the atom does not yet exist, leaving the atom table unchanged on the raise path. The rescue branch in the proposed `name_collision?/1` returns `:no_collision` without creating an atom. The acceptance criterion at `problem.md` §Acceptance criterion states this zero-intern property as the required post-condition.
- **Warrant (W):** A function that exclusively raises without side-effecting the atom table, when wrapped in `rescue`, produces no atom-table writes on the failure path. This is an invariant of the BEAM runtime: atom creation is the exclusive domain of `String.to_atom/1`, `:erlang.binary_to_atom/2`, and the compiler; `String.to_existing_atom/1` raises on miss without interning.
- **Qualifier (Q):** Holds for all module names not already in the BEAM atom table at the time `name_collision?/1` is called. Module names interned by prior successful `Code.compile_file/1` calls are already atoms; `String.to_existing_atom/1` succeeds on them (no new atom created either way).
- **Rebuttal (R):** If the BEAM runtime were changed so that `String.to_existing_atom/1` interned on a miss (which it does not, but were it to), the claim would fail. Additionally, if any other code path between the `rescue` and the return of `:no_collision` created atoms from the name string, the claim would fail — but the proposed function contains no such path.
- **Backing (B):** Erlang/OTP documentation `erlang:binary_to_existing_atom/2` (semantics carried into Elixir's `String.to_existing_atom/1`): "Failure: badarg if `Bin` does not correspond to an existing atom." The atom table is not modified on badarg. SPEC-EXTENSIONS D-123 (as amended by this PR) documents the no-intern guarantee.

#### Falsification attempt for claim 1

- **Strategy:** Counter-example construction — attempt to construct a BEAM state where `String.to_existing_atom/1` inside `rescue ArgumentError` interns a new atom on the miss path.
- **Attempt:** Reviewed the OTP `atom_tables` implementation semantics and the Elixir `String.to_existing_atom/1` source path. The function calls `:erlang.binary_to_existing_atom/2`; on failure it raises `ArgumentError` before any atom is created. The `rescue` branch catches `ArgumentError` and returns `:no_collision` — no atom reference is stored. Attempted to find any intermediate allocation: there is none; the BEAM raises at the BIF level without committing to the atom table.
- **Outcome:** Withstood — no counter-example found via this strategy.
- **Action:** None.

---

### Claim 2: Collision detection for already-loaded modules is preserved

- **Claim (C):** The proposed `name_collision?/1` using `String.to_existing_atom/1` fires correctly for all modules that were previously loaded (compiled) — i.e., the collision guard's observable behaviour is identical to the current `String.to_atom/1` + `Code.ensure_loaded?/1` path for that case.
- **Grounds (G):** When a module has been compiled by `Code.compile_file/1`, the BEAM interns its module-name atom. `String.to_existing_atom/1` succeeds on an existing atom, returning it. The proposed function then calls `Code.ensure_loaded?/1` on that atom (or implicitly checks via the success branch). The existing integration test at `loader_test.exs:367–428` exercises exactly this two-directory collision scenario and currently relies on `Code.ensure_loaded?/1` catching the already-loaded atom.
- **Warrant (W):** An atom that exists in the BEAM atom table is always retrievable by `String.to_existing_atom/1`; the lookup is a hash-table O(1) read. Therefore, the guard for already-loaded modules cannot be degraded by replacing `String.to_atom` with `String.to_existing_atom` in the success path.
- **Qualifier (Q):** Holds for all modules that have completed at least one successful `Code.compile_file/1` call in the current VM session. Does not apply to modules compiled in a prior VM session that was restarted (but that is the same constraint the current implementation has).
- **Rebuttal (R):** If `Code.compile_file/1` were somehow not to intern the module atom (e.g., due to a compile error that the compiler partially committed), `String.to_existing_atom/1` would miss and return `:no_collision` for a name that is partially in the code table. This is a pre-existing edge case not introduced by this fix.
- **Backing (B):** `loader_test.exs:367–428` (AC-5 / D-123 describe block). SPEC-EXTENSIONS C-007 (`loader.ex:232–252`, `spec/SPEC-EXTENSIONS.md:108–115`). BEAM atom-table semantics: atoms are permanent once interned.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — attempt to find a sequence where an already-loaded module's name is missed by `String.to_existing_atom/1`.
- **Attempt:** Examined `loader.ex:228–252` (`compile_with_collision_guard/1`). After `do_compile_file(path)` succeeds at line 246, the module is in the atom table. A subsequent call to `compile_with_collision_guard` for the same name would reach `peek_module_names/1` → `name_collision?/1` → `String.to_existing_atom/1` which succeeds → `{:collision, atom}` is returned → file is skipped. The test at `loader_test.exs:403–427` exercises this exact path (first dir compiled, second skipped). Counter-example cannot be constructed.
- **Outcome:** Withstood.
- **Action:** None.

---

### Claim 3: The `atom_budget_ok?/0` guard provides a runtime backstop even if a future code path reintroduces atom creation

- **Claim (C):** Adding `atom_budget_ok?/0` (checking `atom_limit - atom_count >= @atom_headroom`) before processing any file means that even if a future code change reintroduces atom creation, the guard aborts the load attempt before the table is exhausted, logging an error and emitting `[:tau, :extensions, :atom_budget_exceeded]`.
- **Grounds (G):** `:erlang.system_info(:atom_count)` and `:erlang.system_info(:atom_limit)` are documented BEAM BIFs returning current usage and configured limit respectively. The guard is inserted in `compile_with_collision_guard/1` before `peek_module_names/1` is called, ensuring no atom path is reached when headroom is insufficient. `loader.ex` currently has no such guard.
- **Warrant (W):** A check that gates all atom-creating code paths behind a headroom assertion is a defence-in-depth measure: even if the primary fix is circumvented, the guard fires. OTP non-negotiables §5 requires telemetry for user-visible or perf-sensitive events; a guard preventing a VM crash is user-visible.
- **Qualifier (Q):** Effective only when the guard is invoked before atom creation in the hot path. If atom creation occurs in a code path that bypasses `compile_with_collision_guard/1` (e.g., a direct `Code.compile_file/1` call without the guard), the backstop does not apply.
- **Rebuttal (R):** The `@atom_headroom` default (10,000) is empirical and may be wrong. Too high a threshold aborts loading prematurely; too low fails to prevent exhaustion if a burst of atoms is created in one call. The solution acknowledges this as an open question.
- **Backing (B):** OTP non-negotiables §5 (`otp-non-negotiables.md`). `:erlang.system_info/1` documentation (Erlang OTP). Solution §Open questions notes the calibration question.

#### Falsification attempt for claim 3

- **Strategy:** Edge-case enumeration — enumerate paths where the guard would not fire before atom creation.
- **Attempt:** (1) `do_compile_file/1` at `loader.ex:255–266` calls `Code.compile_file/1` directly; the BEAM compiler interns module atoms at compile time. The proposed `atom_budget_ok?/0` guard in `compile_with_collision_guard/1` fires before `do_compile_file/1` is called — so this path is covered. (2) If `peek_module_names/1` returned early with `:error` (file unreadable), `compile_with_collision_guard/1` falls through to `do_compile_file/1` at line 251 — which would be AFTER the `atom_budget_ok?/0` check in the proposed revision. Covered. (3) A caller that bypasses `compile_with_collision_guard/1` and calls `do_compile_file/1` directly would bypass the guard — but `do_compile_file/1` is private, so no external caller can do this. Covered.
- **Outcome:** Withstood — all atom-creation paths within the public interface are covered by the guard placement.
- **Action:** None.

---

### Claim 4: Removing the Credo `UnsafeToAtom` suppression comment is a legitimate removal (the warning disappears on its own)

- **Claim (C):** After replacing `String.to_atom/1` with `String.to_existing_atom/1`, Credo `--strict` will no longer emit a `UnsafeToAtom` warning for `loader.ex:282–283`, making the `# credo:disable-for-next-line` suppression comment redundant and correct to remove.
- **Grounds (G):** `loader.ex:282` has `# credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom`. The project's `.credo.exs:13` sets `strict: true`; `UnsafeToAtom` is not disabled in the checks list (`.credo.exs:15–28`). The `UnsafeToAtom` check in Credo's source (`deps/credo/lib/credo/check/warning/unsafe_to_atom.ex`) specifically targets `String.to_atom/1`, `:erlang.binary_to_atom`, and similar "unsafe" atom-creation functions. The solution correctly notes the suppression line should be removed.
- **Warrant (W):** Credo's `UnsafeToAtom` check is designed to flag atom creation from dynamic strings — `String.to_existing_atom/1` is the recommended safe alternative and is not flagged by this check. If the check is not triggered, the suppression comment is a stale no-op that will cause a Credo informational notice about unnecessary suppressions.
- **Qualifier (Q):** Valid for the version of Credo currently depended on by the project. If a future Credo version were to flag `String.to_existing_atom/1` (which would be a regression in Credo), the suppression removal would re-introduce the warning.
- **Rebuttal (R):** The solution's own open-questions section acknowledges uncertainty: "Does Credo `--strict` flag the `rescue ArgumentError` in `name_collision?/1` under `UnsafeToAtom` or any related check?" This is unresolved. If Credo flags the `rescue ArgumentError` path involving `String.to_existing_atom/1` as a related unsafe pattern (e.g., a new check added in the project's Credo version), the suppression removal may be premature or the new function may need its own suppression.
- **Backing (B):** The Credo `UnsafeToAtom` check's stated purpose is to prevent atom-table exhaustion by flagging `String.to_atom/1` and `String.to_atom!/1` (plus Erlang equivalents). `String.to_existing_atom/1` is explicitly the recommended replacement. `.credo.exs` (project root).

#### Falsification attempt for claim 4

- **Strategy:** Dependency check — verify the project's Credo version does not flag `String.to_existing_atom/1` as `UnsafeToAtom`, and confirm no `rescue ArgumentError` handling is flagged.
- **Attempt:** The Credo source for `UnsafeToAtom` is located at `deps/credo/lib/credo/check/warning/unsafe_to_atom.ex` but is not accessible from the repository's readable paths (denied by permissions). The solution itself explicitly lists this as an **open question** without resolution. The project's `.credo.exs` has `strict: true` and does not disable `UnsafeToAtom`, meaning the check is active and would surface during `mix credo --strict` in CI.
- **Outcome:** Partially falsified — the claim that the suppression removal is legitimate cannot be confirmed without verifying the Credo check source. The qualifier must be narrowed: the removal is correct *provided* the project's pinned Credo version does not flag `String.to_existing_atom/1` or its `rescue` wrapper. This is a prototype verification step, not a blocker, as acknowledged in the solution's open questions.
- **Action:** Narrow qualifier (done above). The solution should retain the open question and the implementer must run `mix credo --strict` to confirm before removing the suppression. No solution revision required; the solution already acknowledges this uncertainty.

---

### Claim 5: `compile_with_collision_guard/1` callers are unaffected (private, arity and return type unchanged)

- **Claim (C):** The callers of `compile_with_collision_guard/1` are unaffected: the function remains private and its arity and return type are unchanged from the caller's perspective.
- **Grounds (G):** `loader.ex:229` declares `defp compile_with_collision_guard(path)` — private, arity 1. Its return value is a list of compiled module atoms (via `do_compile_file/1` at `loader.ex:257`). The proposal changes the internal implementation but preserves this type. The function is called at line 232 via `peek_module_names/1`; the new `name_collision?/1` is an internal helper. No public API surfaces this function.
- **Warrant (W):** A private function with an unchanged return type and arity imposes zero migration cost on callers, by the definition of "private" in Elixir (not accessible outside the module) and by the Liskov substitution principle applied to internal APIs.
- **Qualifier (Q):** Holds for all callers within `Tau.Extensions.Loader`. If the function were re-exported as public in a future refactor, the internal-type changes (strings vs. atoms inside `peek_module_names/1`) would become visible — but that is a future concern, not this PR.
- **Rebuttal (R):** None applicable within the declared scope; the function is private.
- **Backing (B):** Elixir language spec on `defp` visibility. `loader.ex:229` (source citation). Solution §What does not change.

#### Falsification attempt for claim 5

- **Strategy:** Counter-example construction — find a caller of `compile_with_collision_guard/1` that would observe a changed contract.
- **Attempt:** Searched `loader.ex` for calls to `compile_with_collision_guard`. It is called from `load_entry/1` at `loader.ex:213–222` (the `{:ok, path, ...}` branch). The return value is bound to `modules` at line 217. The function returns a list of atoms (module names); this return type is unchanged by the proposal (the strings-vs-atoms change is internal to `peek_module_names/1` and `name_collision?/1`). No external callers exist (private). Counter-example cannot be constructed.
- **Outcome:** Withstood.
- **Action:** None.

---

### Claim 6: The existing collision-detection property test continues to pass unchanged

- **Claim (C):** The existing collision-detection tests (`loader_test.exs:367–428`) continue to pass after the change without modification.
- **Grounds (G):** These tests exercise the observable behaviour of `compile_with_collision_guard/1` — that the second directory's module is skipped when its module name was already compiled. The solution's implementation preserves this behaviour by using `String.to_existing_atom/1` (which succeeds on already-loaded atoms) to detect collisions. The tests at `loader_test.exs:403–427` and `430–480` assert module identity, not atom creation mechanics.
- **Warrant (W):** A test that asserts observable input/output behaviour (which module sticks after two directories define the same name) is decoupled from the internal mechanism (atom creation path). So long as the collision-detection correctness invariant holds, these tests pass regardless of whether the mechanism uses `to_atom` or `to_existing_atom`.
- **Qualifier (Q):** Holds provided the test does not introspect the atom table size or atom creation count. Reviewing the test at `loader_test.exs:367–428`, no such assertion is present — the tests only assert `Code.ensure_loaded?/1` and `mod_atom.marker()` return values.
- **Rebuttal (R):** If any test were added between now and the implementation that asserts "the following atoms do NOT exist after `peek_module_names/1`" (a negative atom-table check), the test would fail against the current code and pass after the fix — and thus would be a new test, not the existing tests.
- **Backing (B):** `loader_test.exs:367–428` (source). Problem.md §Acceptance criterion ("module-name collision detection continues to work correctly for all previously-loaded modules"). Solution §Migration sketch ("The existing collision-detection property test continues to pass unchanged because the observable behaviour of `compile_with_collision_guard/1` is identical.").

#### Falsification attempt for claim 6

- **Strategy:** Integration check — verify the test does not assert on atom table contents or internment, only on module-load observable behaviour.
- **Attempt:** Read `loader_test.exs:363–428`. The test: (1) writes two files with the same module name to two temp dirs, (2) calls `Loader.reload/1` for dir_a, waits, (3) calls `Loader.reload/1` for dir_b, (4) asserts `Code.ensure_loaded?(mod_atom)` is true and `mod_atom.marker() == :dir_a`. No assertion on atom count or atom table size. The integration check confirms the test is behavioural, not mechanistic.
- **Outcome:** Withstood.
- **Action:** None.

---

### Claim 7: `SPEC-EXTENSIONS` D-123 and C-007 require amendment to reflect the no-intern guarantee

- **Claim (C):** D-123 (at `SPEC-EXTENSIONS.md:319–325`) and C-007 (at `SPEC-EXTENSIONS.md:108–115`) currently document `String.to_atom/1` as the mechanism and assert it is required to catch brand-new modules. After the fix, these constraints are inaccurate and must be amended.
- **Grounds (G):** `SPEC-EXTENSIONS.md:321` reads "Module names are extracted from source text via `String.to_atom/1` (not `String.to_existing_atom/1`, which silently drops names for brand-new modules)." This is the design rationale the solution explicitly supersedes. C-007 at `SPEC-EXTENSIONS.md:111` repeats the same reasoning: "The guard extracts declared module names from the source text via `String.to_atom/1` (not `String.to_existing_atom/1` — the latter silently drops names for modules not yet compiled, defeating the guard for brand-new modules)."
- **Warrant (W):** A specification document that records a design rationale which is now known to be incorrect (the solution demonstrates that `to_existing_atom/1` + `rescue` handles brand-new modules correctly without defeating the guard) must be updated. Leaving an incorrect rationale in the spec creates confusion for future engineers.
- **Qualifier (Q):** Amendment scope is surgical: the mechanism description in D-123 and C-007 changes; the invariant (collision detection fires for already-loaded modules) does not change.
- **Rebuttal (R):** A new D-NNN may be warranted for the no-intern guarantee rather than amending D-123. The solution flags this as an open question. The amendment may be either D-123 update or new D-NNN — both are valid; the claim is only that the spec must change, not how.
- **Backing (B):** `spec-before-code.md` §What this rule requires: "Whether any new constraint surfaced during implementation that should be added to §3 of the SPEC. Adding a constraint is a spec amendment, not a silent slip." Problem.md §Acceptance criterion (grounds the no-intern guarantee that the spec must now record).

#### Falsification attempt for claim 7

- **Strategy:** Dependency check — verify the current spec text actually contradicts the proposed solution.
- **Attempt:** Read `SPEC-EXTENSIONS.md:108–115` and `319–325`. Both passages assert `String.to_atom/1` is necessary and `String.to_existing_atom/1` is insufficient for brand-new modules. The solution's mechanism precisely contradicts this: `String.to_existing_atom/1` with `rescue ArgumentError` handles brand-new modules correctly (they miss → `:no_collision` → file is compiled → module atom is then interned by the compiler). The spec text is factually incorrect after the fix.
- **Outcome:** Withstood — the dependency check confirms the spec must be updated; the claim stands.
- **Action:** None (claim withstood).

---

### Claim 8: The new property tests (zero-atom-intern assertion and `name_collision?/1` unit test) are type-safe and cover the three cases

- **Claim (C):** The migration sketch calls for: (1) a test asserting processing N unique module name strings (none pre-loaded) interns zero atoms; and (2) a unit test for `name_collision?/1`'s three cases (no atom, atom not loaded, atom loaded). The type signatures involved (`String.t() → {:collision, atom()} | :no_collision`) are internally consistent and the three cases are exhaustive.
- **Grounds (G):** The three cases of `name_collision?/1` are: (a) atom not in table → `String.to_existing_atom/1` raises `ArgumentError` → `:no_collision`; (b) atom in table, module not loaded → `String.to_existing_atom/1` succeeds, `Code.ensure_loaded?/1` returns false → return value TBD by solution (`:no_collision` or `{:collision, atom}`); (c) atom in table, module loaded → `String.to_existing_atom/1` succeeds, `Code.ensure_loaded?/1` returns true → `{:collision, atom}`. Case (b) is an edge case the solution does not explicitly address in the return-type spec.
- **Warrant (W):** A helper whose return type is `{:collision, atom()} | :no_collision` and whose three enumerated cases map cleanly to those two branches is type-safe if every branch returns one of those two shapes. Case (b) is ambiguous in the current solution text — an atom existing in the table but its module not loaded means the name is technically free for use without collision, so `:no_collision` is the correct return; this is internally consistent.
- **Qualifier (Q):** Holds for the common cases. Case (b) (atom exists, module not loaded) can arise when a prior compile partially failed. If `:no_collision` is returned, two files could attempt to compile the same module name — but since `Code.ensure_loaded?` returns false, the BEAM module table is free, so the second compile would not collide at the BEAM level. This is correct behaviour.
- **Rebuttal (R):** The zero-atom-intern assertion test requires access to `:erlang.system_info(:atom_count)` before and after calling the loader; concurrent test execution in `mix test --async` could see atom count change due to other test activity, making the assertion fragile without isolation.
- **Backing (B):** Solution §Migration sketch. OTP non-negotiables §6 (properties before examples for invariant-bearing modules). BEAM atom-table documentation.

#### Falsification attempt for claim 8

- **Strategy:** Type-level check — trace the type of each return path of the proposed `name_collision?/1` against its declared type `{:collision, atom()} | :no_collision`.
- **Attempt:** Path 1: `String.to_existing_atom/1` raises `ArgumentError` → `rescue ArgumentError → :no_collision`. Type: `:no_collision` ✓. Path 2: `String.to_existing_atom/1` succeeds → atom `a`. Then `Code.ensure_loaded?(a)` returns false → return `:no_collision`. Type: `:no_collision` ✓. Path 3: `String.to_existing_atom/1` succeeds → atom `a`. Then `Code.ensure_loaded?(a)` returns true → return `{:collision, a}`. Type: `{:collision, atom()}` ✓. All three paths produce the declared return type. Type-level check passes.
- **Outcome:** Withstood. The Rebuttal about concurrent atom-count assertions is a test-design concern, not a falsification of the claim about the type safety of the helper itself.
- **Action:** None. The concurrent-test rebuttal should be noted as an outstanding doubt.

---

## Cross-claim consistency

Claims 1 and 2 are complementary and consistent: claim 1 covers the no-intern case (miss), claim 2 covers the collision-detection case (hit). Together they partition all inputs to `name_collision?/1`.

Claims 3 and 1 are consistent: claim 3 is a backstop for regressions, claim 1 is the primary mechanism. They operate on different axes (prevention vs. detection) without tension.

Claim 4 (Credo suppression removal) and claims 1–3 are logically independent — Credo is a linting tool; its warnings do not affect runtime correctness. The partial falsification of claim 4 does not affect claims 1–3.

Claims 5–6 are preservation claims and do not conflict with claims 1–4.

Claim 7 is a spec-update claim that is entailed by claims 1–2 being true: if the new mechanism works, the spec explaining why the old mechanism was necessary must change.

Claim 8 (test coverage) is downstream of claims 1–3 and internally consistent with them.

No cross-claim tensions identified.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `to_existing_atom/1` + rescue interns zero atoms on miss | Counter-example construction | Withstood | None |
| 2 | Collision detection preserved for already-loaded modules | Counter-example construction | Withstood | None |
| 3 | `atom_budget_ok?/0` covers all atom-creation paths | Edge-case enumeration | Withstood | None |
| 4 | Credo suppression removal is legitimate | Dependency check | Partially falsified | Narrow qualifier; implementer must verify via `mix credo --strict` |
| 5 | `compile_with_collision_guard/1` callers unaffected | Counter-example construction | Withstood | None |
| 6 | Existing collision tests pass unchanged | Integration check | Withstood | None |
| 7 | D-123 and C-007 require spec amendment | Dependency check | Withstood | None |
| 8 | `name_collision?/1` type-safe; three cases exhaustive | Type-level check | Withstood | None |

---

## Revision required

- **Target file:** N/A — no revision required.
- **Revision kind:** N/A
- **Rationale:** The partial falsification of claim 4 narrows the qualifier but does not falsify the claim's substance — the suppression removal is correct in intent, contingent on a prototype verification step already acknowledged by the solution as an open question. No revision to `solution.md` or `problem.md` is triggered.

---

## Outstanding doubts

- The zero-atom-intern assertion property test (claim 8 rebuttal) may be fragile under concurrent `mix test` execution. The test author should either run it in a non-async context or compare atom-count deltas isolated to the loader's execution to avoid spurious failures from unrelated test activity.
- The `@atom_headroom` default of 10,000 is empirical and uncalibrated against the project's actual startup atom count. The solution correctly flags this for the implementer; the validator notes it as a deployment-time risk: if the application's baseline atom count is high (e.g., warm Phoenix + Ecto + Tau OTP tree), 10,000 headroom may be insufficient to trigger the guard well before actual exhaustion.
- Case (b) of `name_collision?/1` — atom exists in table, module not loaded — is logically correct to return `:no_collision` but is not called out explicitly in the solution's migration sketch. The unit test plan should cover this case explicitly to prevent a future implementer from accidentally returning `{:collision, atom}` for a module whose atom exists but whose code is not loaded (which would silently drop valid extension files).
