---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/3
revision_triggered: none
---

# Validation: Load-time snapshots + string-typed collision guard for `Tau.Extensions.Loader`

## Overview

The root solution is a non-leaf synthesis of two child solutions: `unload-resilience`
(snapshot-driven unload that eliminates the four `try/rescue _ -> []` blocks) and
`atom-internment` (strings-throughout collision path with `String.to_existing_atom/1`
plus an `atom_budget_ok?/0` defence-in-depth guard). The composition claim is the
load-bearing addition the root makes beyond either child: that the two changes can
land independently, in either order, with no shared state, no ordering dependency,
and no interface negotiation. Per the validator brief this validation concentrates
on the **cross-cutting integration claims** at the synthesis boundary (composition,
ordering, no-shared-state, joint SPEC amendment), and treats the within-child
correctness claims as already validated downstream (see
`subproblems/unload-resilience/validation.md` and
`subproblems/atom-internment/validation.md`, both `withstood` / `partially_falsified
— qualifier narrowed`). Seven distinct propositions are extracted from the root
solution's Recommendation, What-changes, What-does-not-change, and Migration-sketch
sections. Each is run through full Toulmin (six fields) with an explicit named
falsification strategy. Six withstood; one is partially falsified (claim 3 — "either
order is safe") with a qualifier narrowing about merge-order test coupling that
does not invalidate the composition claim but tightens its scope.

---

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants found it
difficult to generate Toulmin structures, and their structures varied greatly even
though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to counter that
variance.

---

### Claim 1: The two child solutions touch disjoint code paths inside `loader.ex`

- **Claim (C):** "The two child solutions operate on disjoint code paths inside
  `loader.ex` (registration/unload vs. compile-time peek/collision-check) and on
  disjoint structural concerns (registry-key lifecycle vs. atom-table lifecycle)."
  (solution.md §Selected from — Composition rationale)
- **Grounds (G):** The unload-resilience change list (solution.md §What changes,
  bullets 1–6) names `register_module/1` (`loader.ex:351–388`), `unload_module/1`
  (`loader.ex:425–480`), `do_unload/1` (`loader.ex:415–423`), `try_tool_name/1`
  (`loader.ex:482–490`), and the path-based entry shape inside `register_module/1`
  /`do_unload/1`. The atom-internment change list (solution.md §What changes,
  bullets 7–12) names `peek_module_names/1` (`loader.ex:276–290`),
  `compile_with_collision_guard/1` (`loader.ex:229–253`), a new
  `name_collision?/1`, a new `atom_budget_ok?/0`, the `@atom_headroom` attribute,
  and the comment block at `loader.ex:270–275`. No function name appears in
  both lists.
- **Warrant (W):** Two edits are non-conflicting when their changed-region sets
  are disjoint (factory-loop.md §Parallel execution clause 3: "disjoint
  codepoints"). Function-level disjointness is the textbook sufficient condition
  for direct composition under Hickey's complecting lens: orthogonal concerns
  expressed at non-overlapping seams compose without interface negotiation.
- **Qualifier (Q):** Holds at the function-name granularity. A finer-grained
  view (same `loader.ex` source file, same module attribute namespace, same
  comment-block region near lines 270–275) is partially shared — see rebuttal.
- **Rebuttal (R):** Both changes edit the *same file*, so a textual merge
  conflict at the line level is possible if the unload change happens to insert
  near lines 270–275 (where atom-internment rewrites the comment block) or if
  either child renames `@module` attributes the other reads. Inspection of the
  current `loader.ex` shows the unload-path edits land in `register_module/1`
  (lines 351+) and `unload_module/1` (lines 425+); the atom-path edits land in
  `peek_module_names/1` (lines 276+) and `compile_with_collision_guard/1`
  (lines 229+). The regions are separated by ≥60 lines; a textual conflict
  requires either child to expand its scope.
- **Backing (B):** factory-loop.md §Parallel execution ("Disjoint codepoints");
  Hickey, "Simple Made Easy" (composition by direct composition requires
  disjoint state and disjoint interfaces); ADR-0022 (the SPEC-EXTENSIONS author
  ADR) establishes registration/unload and compile-time peek as separate
  contracts.

#### Falsification attempt for claim 1

- **Strategy:** Integration check — grep `loader.ex` for any function or module
  attribute named in BOTH child solutions' change lists, and inspect each
  edit-region pair for line-level overlap.
- **Attempt:** Cross-referenced each function and identifier in the two
  child-solutions' "What changes" bullets against the current `loader.ex`
  (line ranges: peek/collision-guard 229–290; register 351–388; unload
  415–480; try_tool_name 482–490). The two clusters share zero function
  names and zero module attributes. The only file-level shared surface is
  the `defmodule Tau.Extensions.Loader` shell and the `alias Tau.Settings.Cache`
  / `require Logger` / `use GenServer` header — neither child rewrites the
  header. Searched for shared module attributes: atom-internment adds
  `@atom_headroom`; unload-resilience adds none. No attribute collision.
- **Outcome:** Withstood — no shared codepoint found at function or attribute
  granularity. The rebuttal (textual proximity within the same file) is a
  *merge-time* concern, not a *semantic* one, and the line-range separation
  (≥60 lines between the unload and peek clusters) keeps the merge mechanical.
- **Action:** None.

---

### Claim 2: The two child solutions share no state, no callers, no data structures

- **Claim (C):** "They share no functions, no state, and no callers; neither
  references the other's data structures." (solution.md §Selected from —
  Composition rationale)
- **Grounds (G):** unload-resilience introduces `info.registered_keys` (a flat
  list of tagged tuples inside the `info` map stored in `state.loaded`).
  atom-internment introduces `@atom_headroom`, `atom_budget_ok?/0`, and
  changes the return type of `peek_module_names/1` from `{:ok, [atom()]}` to
  `{:ok, [String.t()]}`. Neither field is read by the other change:
  `info.registered_keys` is consumed only by the new `crash_safe_unload/2`
  helper; `peek_module_names/1`'s string return is consumed only by
  `compile_with_collision_guard/1`. The two data flows are end-to-end disjoint:
  registration → snapshot → registry unregister vs. file-read → peek → collision
  check → compile.
- **Warrant (W):** Direct composition (Hickey) is licensed when the changes
  expose new state only at seams the other change does not read. The OTP
  non-negotiable that stateful subsystems own their own state (TAU.md §OTP
  invariant 1) means a new field inside the Loader's `state.loaded` info map
  cannot be read by code outside the Loader process — by construction.
- **Qualifier (Q):** Holds for the runtime data flow. The two changes do share
  the SPEC-EXTENSIONS amendment surface (both edit §3 and the telemetry list);
  that is a documentation coupling, not a runtime coupling.
- **Rebuttal (R):** If a future refactor moved `peek_module_names/1`'s output
  into the `info` map (e.g. to dedupe at unload time), the two changes would
  share a field. No such refactor is in scope here; the rebuttal is hypothetical.
- **Backing (B):** TAU.md §OTP non-negotiables #1 ("Every stateful subsystem is
  a process under a supervisor") — by corollary, internal state shape is owned
  by that subsystem alone. Hickey, "Simple Made Easy" (state composition by
  disjoint ownership).

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — try to construct a path through
  the post-change `loader.ex` where the unload code reads atom-internment's new
  state, or the peek code reads unload's new state.
- **Attempt:** Mentally traced the two post-change call graphs.
  Unload path: `handle_cast({:unload, entry}, state) → unload_entry/2 →
  do_unload(info) → crash_safe_unload(mod_or_modules, info.registered_keys) →
  per-key Registry.unregister*`. No reference to `peek_module_names/1`,
  `name_collision?/1`, `atom_budget_ok?/0`, or `@atom_headroom`. Peek path:
  `load_entry(path) → compile_with_collision_guard(p) → peek_module_names(p)
  + atom_budget_ok?/0 + name_collision?/1 → do_compile_file/1`. No reference
  to `info.registered_keys`, `crash_safe_unload/2`, or any unload-path
  identifier. The two graphs are fully disjoint.
- **Outcome:** Withstood — no counter-example constructible from the current
  proposals.
- **Action:** None.

---

### Claim 3: The two changes may land in either order without coordination

- **Claim (C):** "Composition is therefore **direct**: each child's
  recommendation lands as written, in either order, without interface
  negotiation." (solution.md §Selected from); "The two refactors are
  independent and may land in either order — there is no shared function and
  no shared state to coordinate." (solution.md §Migration sketch)
- **Grounds (G):** Claim 1 establishes disjoint codepoints; claim 2 establishes
  disjoint state. With neither shared, there is no information either change
  needs from the other to compile, type-check, or pass its own tests.
  Telemetry events are namespaced (`[:tau, :extensions, :unload, :exception]`
  vs. `[:tau, :extensions, :atom_budget_exceeded]`); test files live in
  `test/tau/extensions/` (loader_test.exs primarily) but the new assertions
  named in each child target separate behaviours (snapshot-driven unload vs.
  atom-count delta).
- **Warrant (W):** When changes A and B are mutually independent (no read or
  write dependency in either direction), the merge graph A→B and B→A produce
  the same combined diff; ordering is therefore semantically irrelevant.
- **Qualifier (Q):** Holds for production code. Does NOT necessarily hold for
  the test file `test/tau/extensions/loader_test.exs` if both children edit
  the same test helper or `setup_all` block; merge order then matters at the
  textual level even though the runtime behaviour is order-independent.
- **Rebuttal (R):** The shared test file (`loader_test.exs`, ~740 lines) is a
  realistic merge-conflict surface. The unload-resilience child's open
  question explicitly flags "update tests that assert on `state.loaded` entry
  shape or `info` map contents" as in-scope work; atom-internment's
  proposed property test ("processing N unique module name strings interns
  zero atoms") also lands in this file. Two PRs touching the same large test
  module need rebase-after-first-merge, but rebase outcome is deterministic
  (no semantic conflict, only textual).
- **Backing (B):** factory-loop.md §Parallel execution clauses 1 ("No
  dependency"), 2 ("Disjoint files" — production source disjoint, tests
  shared but rebaseable), 3 ("Disjoint codepoints"); rebase semantics under
  git merge (when neither side modifies the other's hunks, three-way merge
  succeeds without operator intervention).

#### Falsification attempt for claim 3

- **Strategy:** Edge-case enumeration — list the cases where "either order"
  could fail: (a) compile failure if one change depends on the other's
  symbols; (b) test failure if one change's tests assume the other's
  behaviour; (c) gate failure if Gate 5.1 / 5.3 require a specific ordering;
  (d) SPEC amendment merge conflict; (e) merge conflict in shared test file.
- **Attempt:** (a) Neither change adds symbols the other consumes (claim 2
  confirms). (b) The unload-resilience tests assert on `state.loaded` info
  shape; atom-internment's tests assert on `:erlang.system_info(:atom_count)`
  deltas. Neither test class depends on the other's runtime behaviour. (c)
  Gate 5.1 (AC-to-test linkage) checks each PR's own AC tokens — both
  children have their own AC and their own gating tests; no cross-PR
  linkage. Gate 5.3 (mutation) is per-PR. (d) Both children amend
  SPEC-EXTENSIONS §3 and the telemetry section; if both PRs land §3 edits
  in adjacent regions, a textual merge conflict is possible. (e) Shared
  test file is realistic; rebase is deterministic but not zero-cost. Cases
  (d) and (e) are TEXTUAL merge concerns, not semantic ordering
  dependencies — the second-merging PR rebases and proceeds. Case (d) is
  the most likely friction point because both children may rewrite the
  D-123 entry; one of them must defer to the other's text.
- **Outcome:** Partially falsified — the claim's qualifier needs narrowing
  to "either order is **semantically** safe; **textual** merge conflicts in
  `loader_test.exs` and SPEC-EXTENSIONS.md §3 require the second-merging
  PR to rebase." The composition claim's substance (no shared state, no
  ordering dependency in production code) survives.
- **Action:** Narrow the qualifier in claim 3 as stated. No revision to
  solution.md required because solution.md §Migration sketch already
  recommends serialised landing for review-bandwidth reasons; the
  partial-falsification only formalises why that recommendation is
  pragmatic even though the in-principle independence holds.

---

### Claim 4: The two changes close both legs of the parent acceptance criterion

- **Claim (C):** "The children together cover both legs of the parent
  acceptance criterion." (solution.md §Selected from — Composition rationale,
  closing sentence); equivalently, the parent AC ((a) `unload_module/1` can
  distinguish a broken extension from an empty one and leaves no residual
  registry entries; (b) `peek_module_names/1` does not permanently intern
  filesystem-derived strings) is fully covered by the union of the two
  child changes.
- **Grounds (G):** Leg (a) — unload-resilience's snapshot mechanism replaces
  the four `try/rescue _ -> []` blocks (`loader.ex:430–434, 448–451, 458–461,
  468–471`) with a key-driven loop that does not invoke the post-load
  callbacks; the snapshot is captured at registration time when the module
  is known healthy. `crash_safe_unload/2` adds `Logger.warning/1` and
  `[:tau, :extensions, :unload, :exception]` telemetry, so a broken module
  is distinguished from an empty one. Leg (b) — atom-internment's
  `peek_module_names/1` returns strings and `name_collision?/1` uses
  `String.to_existing_atom/1` with a `rescue ArgumentError` branch; the
  rescue path interns no atom.
  (Cross-referenced against child validations: leg (a) corresponds to the
  child-solution claims 1–5 in `subproblems/unload-resilience/validation.md`,
  all `withstood`; leg (b) corresponds to claims 1–3 in
  `subproblems/atom-internment/validation.md`, all `withstood`.)
- **Warrant (W):** A union of changes that each provably solve a disjoint
  leg of a conjunctive AC solves the full AC iff (i) no leg's change
  invalidates the other's invariants and (ii) the disjointness from claims
  1–2 holds.
- **Qualifier (Q):** Holds conditional on the child validations being sound
  (both report `partially_falsified` with narrowed qualifiers, no
  full-falsification). Each leg's correctness was validated downstream;
  the synthesis claim here is **integration completeness**, not per-leg
  correctness.
- **Rebuttal (R):** If a third defect existed in `unload_module/1` or
  `peek_module_names/1` that the parent AC failed to name, neither child
  would address it. The parent AC is the canonical statement of what counts
  as solved; out-of-scope defects do not falsify this claim.
- **Backing (B):** problem.md §Acceptance criterion ("(a) … (b) …" — explicit
  conjunctive form); SPEC-EXTENSIONS D-122, D-123, D-124 (the invariants the
  two legs strengthen).

#### Falsification attempt for claim 4

- **Strategy:** Edge-case enumeration over the AC text — list the failure
  modes the AC implicitly excludes, check each is covered by the union.
- **Attempt:** AC leg (a) enumerates three sub-properties: (a1) distinguish
  broken from empty — covered by `Logger.warning/1` + telemetry on
  exception path; (a2) logs broken modules — covered by `Logger.warning/1`
  in `crash_safe_unload/2`; (a3) no residual registry entries on partial
  unload — covered by the snapshot mechanism (registry unregister is driven
  by load-time keys, not by re-querying a potentially-broken module). AC
  leg (b) names one sub-property: no permanent atom internment from
  user-controlled strings — covered by `String.to_existing_atom/1` rescue
  path. Cross-check: does the snapshot mechanism's `Registry.unregister*`
  call need to intern an atom? Inspected `unload_module/1`'s current calls
  (`loader.ex:440, 453, 465, 477`): the registry keys are `tool_name`
  (a string returned by `mod.name()`), `ev` (an atom passed from `mod.hooks/0`),
  `name` (a string from `mod.commands/0`), and `name` (a string from
  `mod.skills/0`). Atoms come from the extension module's compiled return
  values, not from filesystem strings — leg (b)'s no-intern guarantee is
  preserved by the snapshot mechanism. No cross-leg invalidation found.
- **Outcome:** Withstood — both legs are covered, with no cross-leg
  invariant violation.
- **Action:** None.

---

### Claim 5: Public API of `Tau.Extensions.Loader` is preserved

- **Claim (C):** "Public API of `Tau.Extensions.Loader` — no exported
  function signatures change." (solution.md §What does not change, bullet 1)
- **Grounds (G):** The public API consists of `start_link/1` (loader.ex:35),
  `reload/1` (loader.ex:50), `unload/1` (loader.ex:58), `reload_all/0`
  (loader.ex:65), `list/0` (loader.ex:74), plus the three `@impl true`
  GenServer callbacks. The unload-resilience change list renames
  `unload_module/1` → `unload_module/2` (PRIVATE — the public `unload/1`
  cast handler is unchanged); adds `crash_safe_unload/2` (PRIVATE); deletes
  `try_tool_name/1` (PRIVATE). The atom-internment change list modifies
  `peek_module_names/1` (PRIVATE), adds `name_collision?/1` (PRIVATE),
  `atom_budget_ok?/0` (PRIVATE), and `@atom_headroom` (PRIVATE attribute).
  Zero public functions are added, removed, or modified.
- **Warrant (W):** A function is "public" if it is reachable via the
  `Tau.Extensions.Loader.<name>` notation from an external caller — i.e.
  it is documented with `@doc` and exported via `def`. Private functions
  (`defp`) are by definition not public API; their signature changes do
  not constitute API changes (Hickey: encapsulation principle).
- **Qualifier (Q):** Holds for the function-call API. The `list/0` return
  shape is technically part of the observable API (its return type is
  `[%{key: term(), info: map()}]`); if unload-resilience adds a
  `registered_keys` field to `info`, external consumers that pattern-match
  on `info` will see a wider map. See rebuttal.
- **Rebuttal (R):** The unload-resilience child solution's open question 3
  explicitly flags this: "Does any external code (outside `loader.ex` and
  its tests) pattern-match on the bare `%{module: mod}` info shape from
  `state.loaded`?" A grep over `lib/` and `test/` (executed during this
  validation) finds zero hits for `entry.info` or `state.loaded` outside
  `loader.ex` and `loader_test.exs`. Test-file pattern-match on the
  enriched `info` map is in-scope rework for the child PR. No external
  production code consumer was found.
- **Backing (B):** TAU.md §OTP non-negotiable #2 (behaviours as
  extensibility seams — pattern-match on atoms and structs at the API
  boundary); the actual `list/0` return type is unstructured (it returns
  a `map()`), so consumers either accept arbitrary fields or risk
  brittleness. The pattern is to add fields, not to break shapes.

#### Falsification attempt for claim 5

- **Strategy:** Dependency check — grep the codebase for any caller of
  `Tau.Extensions.Loader.<public-fn>` whose call signature would break
  under the proposed changes.
- **Attempt:** Searched `lib/` and `test/` for `Tau.Extensions.Loader.`
  call sites and for `Loader.` (after `alias`). Public functions are
  invoked from `lib/tau/cli/extensions.ex` (the CLI handlers) and from
  `test/tau/extensions/loader_test.exs`. None of the proposed changes
  modify the public-function arity or return type at the
  `[%{key, info}]` shape; the only widening is the new `registered_keys`
  field inside `info`. Map widening is not a breaking change under
  Elixir's pattern-match semantics (a `%{module: mod}` match still
  succeeds on `%{module: mod, registered_keys: [...]}`).
- **Outcome:** Withstood — no breaking change found.
- **Action:** None.

---

### Claim 6: Telemetry events are namespaced so the two PRs do not collide

- **Claim (C):** "the cross-cutting concerns (telemetry events, SPEC D-NNN
  entries) are namespaced (`:unload, :exception` vs. `:atom_budget_exceeded`;
  D-122/D-124 lineage vs. D-123 lineage)." (solution.md §Migration sketch)
- **Grounds (G):** Unload-resilience adds `[:tau, :extensions, :unload,
  :exception]` (solution.md §What changes, bullet 3). Atom-internment adds
  `[:tau, :extensions, :atom_budget_exceeded]` (solution.md §What changes,
  bullet 10). The event-name lists are disjoint as strings; neither child
  defines the other's event. The existing telemetry inventory in
  `loader.ex` (`[:tau, :extensions, :load, :start | :stop | :exception]`
  and `[:tau, :extensions, :reloaded]`) is preserved by both children.
- **Warrant (W):** Telemetry events compose by namespace disjointness:
  `:telemetry.execute/3` is keyed by the full event-name list, so two
  distinct lists never collide at the handler level. Adding new event
  names is additive; existing handlers see no change.
- **Qualifier (Q):** Holds at the event-name level. Test-side handler
  ID collisions (both children might use `"loader-test-#{unique_id()}"`
  patterns) are a test-hygiene concern, not a runtime concern.
- **Rebuttal (R):** If a future telemetry-aggregator subscribed to
  `[:tau, :extensions, :_, :exception]` wildcards (which the standard
  `:telemetry` library does not support — wildcards are not first-class),
  the namespace argument would partially weaken. The current OTel reporter
  (per SPEC-OTEL-REPORTER) subscribes by exact event list, so wildcards
  are not in play.
- **Backing (B):** `:telemetry` library contract — event names are
  matched by full list equality; OTP non-negotiable #5 (telemetry events
  for everything user-visible or perf-sensitive); SPEC-OTEL-REPORTER §3
  (event subscription is by exact match).

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — find a handler in the
  codebase that would match both new events ambiguously, or find an
  existing event whose name the new ones shadow.
- **Attempt:** Grepped `lib/` and `test/` for `:telemetry.attach` and
  `:telemetry.attach_many` calls. All attach calls cite explicit event
  lists; none uses a wildcard pattern. No event named
  `[:tau, :extensions, :unload, :exception]` or
  `[:tau, :extensions, :atom_budget_exceeded]` exists in the current
  codebase. No shadowing or accidental match found.
- **Outcome:** Withstood — namespace disjointness holds.
- **Action:** None.

---

### Claim 7: The joint SPEC-EXTENSIONS amendment is the only documentation surface that requires coordination

- **Claim (C):** "The only shared surface is `lib/tau/extensions/loader.ex`
  itself (both edit it) and `docs/spec/SPEC-EXTENSIONS.md` (both amend §3 /
  telemetry sections)." (solution.md §Selected from — Composition rationale)
- **Grounds (G):** Beyond the two surfaces named (the production file and
  the SPEC), no other file appears in both child solutions' change lists.
  Tests live in `test/tau/extensions/` but in distinct describe-blocks
  (one targets snapshot unload, the other targets atom-count deltas).
  ADRs are not touched by either child. The CLI module
  `lib/tau/cli/extensions.ex` is explicitly out of scope per problem.md
  §Out of scope.
- **Warrant (W):** Documentation coupling (both PRs amend the same SPEC §)
  is a textual merge concern resolvable by ordering the merges (the
  second-merging PR rebases its SPEC edit). Production-code coupling
  would be more serious; absent it, the documentation amendment is the
  highest-friction shared surface.
- **Qualifier (Q):** Holds for the in-scope file set per problem.md.
  Out-of-scope concerns (e.g. extension CLI, settings schema) are
  excluded by the problem statement.
- **Rebuttal (R):** If the SPEC amendment requires a new D-NNN block
  (rather than amending D-122/D-123/D-124 in place), the two children
  might race to claim the next free D-NNN identifier. The CLAUDE.md
  D-NNN allocation rule ("Before authoring a new D-NNN, verify the
  identifier is free across the whole repo") mitigates this: the
  second-merging PR re-checks freshness and picks a new ID if needed.
- **Backing (B):** CLAUDE.md ("The runtime-invariant namespace is D-NNN,
  partitioned across SPECs … verify the identifier is free across the
  whole repo"); spec-before-code.md §"What this rule requires"
  (amendments live in the same PR as the change introducing them).

#### Falsification attempt for claim 7

- **Strategy:** Integration check — enumerate every file in either child's
  change list, identify the intersection, verify no third shared file
  was missed.
- **Attempt:** Listed all file paths from `subproblems/unload-resilience/
  solution.md` §What changes (lib/tau/extensions/loader.ex; test/tau/
  extensions/) and `subproblems/atom-internment/solution.md` §What changes
  (lib/tau/extensions/loader.ex; docs/spec/SPEC-EXTENSIONS.md). The root
  solution.md §What changes preserves the union: loader.ex, test/tau/
  extensions/, docs/spec/SPEC-EXTENSIONS.md. Intersection: loader.ex AND
  SPEC-EXTENSIONS.md (atom-internment explicitly edits the SPEC;
  unload-resilience's change list does not mention SPEC but the root
  rolls in a SPEC amendment for the unload invariant, making SPEC a
  shared surface at the synthesis level). The test directory is shared
  but at the file level the two children edit distinct test functions —
  no test function is renamed or deleted by both. No third shared file.
- **Outcome:** Withstood — only `loader.ex` and `SPEC-EXTENSIONS.md` are
  jointly edited; the SPEC amendment coordination is the load-bearing
  shared concern the claim names.
- **Action:** None.

---

## Cross-claim consistency

Claims 1, 2, 3, and 7 form a consistent integration story: the children are
disjoint at the production-code level (1, 2), order-independent at runtime
(3), and the only joint surface is documentation (7). Claim 4 builds on
1–3: the disjointness implies independence of the leg-(a) and leg-(b) fixes,
so their union covers the conjunctive AC. Claim 5 (public API preserved)
and claim 6 (telemetry namespacing) are local properties of each child that
the synthesis preserves. The partial falsification of claim 3 (textual
merge conflict in `loader_test.exs` and SPEC §3) is consistent with claim 7
(SPEC is a shared surface): the qualifier narrowing on claim 3 simply
formalises the merge-time friction claim 7 already anticipates. No
internal tension found.

A subtle consistency check: claim 4's coverage argument assumes claim 2's
no-shared-state holds. If a future refactor folded `peek_module_names/1`'s
output into the `info` map, claim 2 would weaken and claim 4 would need
re-validation. This is noted as an outstanding doubt below.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Disjoint codepoints | Integration check (grep + line-range inspection) | withstood | None |
| 2 | No shared state / callers / data | Counter-example construction (post-change call graphs) | withstood | None |
| 3 | Either-order merge safe | Edge-case enumeration (compile / test / gate / SPEC / test-file) | partially falsified | Narrow qualifier: semantic independence holds; textual rebase needed in `loader_test.exs` and SPEC §3 |
| 4 | Children cover both AC legs | Edge-case enumeration over AC text | withstood | None |
| 5 | Public API preserved | Dependency check (grep callers) | withstood | None |
| 6 | Telemetry namespaced | Counter-example construction (handler ambiguity search) | withstood | None |
| 7 | Only SPEC + loader.ex shared | Integration check (file-set intersection) | withstood | None |

---

## Revision required

None. The single partial-falsification (claim 3) narrows a qualifier in
place; no revision to solution.md or problem.md is needed. The qualifier
narrowing is consistent with the migration sketch's existing
recommendation to land the two PRs serially for review-bandwidth reasons.

- **Target file:** n/a
- **Revision kind:** n/a — in-place qualifier narrowing only
- **Rationale:** The composition claim's substance (no shared state, no
  semantic ordering dependency) survives intact; the narrowing acknowledges
  that two PRs touching the same large test file and the same SPEC § will
  require the second to rebase. That is normal git workflow, not a
  composition defect.

---

## Outstanding doubts

- **`Tau.Tool.register/1`'s contract for snapshot capture.** The
  unload-resilience child solution's open question 1 flags that
  `Tau.Tool.register/1` returns `{:ok, pid()} | {:error, term()}`
  (confirmed at `lib/tau/tool.ex:55–58`). The snapshot mechanism must
  record only keys actually registered. This was inherited as an open
  question; it is implementation-detail-level work for the unload-resilience
  PR but is not a synthesis-level concern. If the implementer captures the
  `{:error, _}` case as "not snapshotted", the unload path will leave no
  stale entry; if they capture unconditionally, the unload path might
  attempt to unregister an entry that never registered (a no-op for
  `Registry.unregister*`, so benign — but a logging hazard).
- **Cross-leg invariant preservation under future refactor.** If a future
  refactor introduced a feedback loop where atom-internment's
  `name_collision?/1` consulted `state.loaded`'s `info.registered_keys`
  (e.g. to dedupe by registered key), claims 2 and 4 would both need
  re-validation. No such refactor is in scope, but the synthesis's
  decomplecting depth depends on this remaining true.
- **`@atom_headroom` default calibration.** Inherited from
  atom-internment's open questions: 10_000 is unaudited against the
  deployed atom-count baseline. Not a synthesis concern but propagates
  to the parent.
- **D-NNN allocation race.** Two PRs concurrently authoring SPEC
  amendments to `docs/spec/SPEC-EXTENSIONS.md` §3 / §6 might race for the
  next free D-NNN identifier. The CLAUDE.md verification rule
  ("verify the identifier is free across the whole repo") handles this
  for sequential merges; under genuinely parallel merges, the
  second-merging PR re-checks at rebase time.

---
