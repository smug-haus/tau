---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/5
revision_triggered: none
---

# Validation: Snapshot-driven unload — enrich `info` with registered keys at load time

## Overview

The solution proposes seven code changes to `loader.ex` and its tests: (1) populate
`info.registered_keys` at registration time, (2) replace the four `try/rescue _ -> []`
blocks in `unload_module/1` with a key-driven loop, (3) add a `crash_safe_unload/2`
helper, (4) thread `info` through `do_unload/1`, (5) delete `try_tool_name/1`, (6) enrich
path-based multi-module entries, and (7) update tests. Six claims are enumerated.
Falsification applied one strategy per claim; five withstood unconditionally, one
requires a qualifier narrowing (claim 5 — the assertion that no callsite outside
`loader.ex` pattern-matches on the bare info shape is unverifiable without a grep the
solution itself labels an open question, but one external test callsite was found).

## Toulmin per claim

### Claim 1: `unload_module/1`'s four `try/rescue _ -> []` blocks cause silent partial unload when a module's callbacks raise after registration

- **Claim (C):** "`unload_module/1` … wraps each call in a bare `try/rescue _ -> []`,
  silently treating any exception as an empty result list … leaving its prior registry
  entries in place — a silent partial-unload that corrupts the registry without any log
  or telemetry signal." (problem.md §Statement; solution.md §Recommendation confirms it
  as the root cause being fixed)
- **Grounds (G):** `lib/tau/extensions/loader.ex:430–434` — tools callback wrapped in
  `try do … rescue _ -> []`; `:448–451` — hooks; `:458–461` — commands; `:468–471` —
  skills. If a post-load code reload makes any callback raise, the corresponding `Enum.each`
  receives `[]` and no `Registry.unregister*` call is issued for that category.
  `lib/tau/extensions/loader.ex:397–408` confirms `do_unload(info)` is called without
  passing `info.registered_keys` (the field does not exist yet), so there is no snapshot
  fallback.
- **Warrant (W):** OTP non-negotiable #7 ("Let it crash; supervise; restart. MUST NOT
  `try/rescue` across process boundaries") implies that `try/rescue _ -> []` — which
  silently swallows exceptions across a module boundary and substitutes an empty list —
  is a correctness defect, not a defensive pattern. A silent empty result is
  indistinguishable from "registered nothing", causing the registry to accumulate stale
  entries.
- **Qualifier (Q):** Holds for any module where at least one callback was successfully
  called at load time (producing non-empty results that were registered) but subsequently
  raises. If a callback raised at load time, `crash_safe_register/2`'s outer `try/rescue`
  already skipped the entire registration, so no entries were recorded and the unload
  defect is moot.
- **Rebuttal (R):** If a module's callbacks are idempotent and always callable (i.e., the
  module is never broken between load and unload), the silent-empty-list path is never
  triggered and the claim's consequence does not materialise. The claim's correctness does
  not depend on this rebuttal — it is a defect whether or not it triggers in practice.
- **Backing (B):** OTP non-negotiables rule #7 (`TAU.md`); SPEC-EXTENSIONS D-120
  ("crash-isolated load") and D-124 ("hot reload unloads prior generation") — neither
  contract covers the unload-exception path, confirming the gap.

#### Falsification attempt for claim 1

- **Strategy:** Counter-example construction
- **Attempt:** To falsify: is there a code path where `try/rescue _ -> []` still correctly
  unregisters? For this to hold, the rescued empty list would need to be correct, meaning
  the module never registered the category in the first place. But `crash_safe_register/2`
  (lines 296–349) calls `register_module/mod` inside its own `try/rescue`; if the callbacks
  raised at registration time, the entire module is skipped with `:error` and no entry is
  inserted into `state.loaded`. Therefore any `info` entry in `state.loaded` represents a
  module whose callbacks returned non-empty results at registration time. The empty-list
  rescue at unload time produces a wrong result for any callback that was non-empty at
  registration.
- **Outcome:** Withstood. No counter-example found; the claim accurately describes the defect.
- **Action:** None.

---

### Claim 2: Enriching `info` with `registered_keys` at load time eliminates the need to re-invoke callbacks at unload time

- **Claim (C):** "Enrich the `info` map stored in `state.loaded` at registration time to
  record the exact registry keys produced by each callback category … Replace the four
  `try/rescue _ -> []` blocks in `unload_module/1` with a loop over
  `info.registered_keys`, calling the appropriate `Registry.unregister*` function for
  each key — no behaviour callbacks invoked at unload time."
- **Grounds (G):** `lib/tau/extensions/loader.ex:351–388` (`register_module/1`) — at
  registration time, `mod.tools()`, `mod.hooks()`, `mod.commands()`, `mod.skills()` are
  already called; the exact keys being registered are observable in scope. The `{:ok, mod,
  %{module: mod}}` return at line 384 captures only `module`; adding `registered_keys`
  here would capture the keys without a second callback invocation.
  `lib/tau/extensions/loader.ex:400–407` (`unload_entry/2`) — already retrieves `info`
  from `state.loaded` and passes it to `do_unload/1`, so the snapshot is on the hot path.
- **Warrant (W):** Hickey's "data over code" principle: substituting a data lookup (the
  snapshot) for a re-derivation (re-invoking callbacks) removes temporal coupling — the
  correctness of unload no longer depends on the module's runtime state at unload time.
  This is a direct application of decomplecting data from behaviour.
- **Qualifier (Q):** Holds provided `registered_keys` is populated atomically in the same
  `register_module/1` call that performs registration, with no window between "registered"
  and "snapshotted". If the snapshot and the registration are separated by a process
  boundary or async step, the window creates a TOCTOU race; the solution keeps both in a
  single synchronous function, so the qualifier is satisfied by construction.
- **Rebuttal (R):** If a registry call fails partially (e.g., some tools register and then
  one raises), `crash_safe_register/2` will rescue and return `:error`, and no `info` entry
  enters `state.loaded`. The snapshot approach does not create a partial-registration
  problem; it inherits the all-or-nothing semantics of the outer `try/rescue`.
- **Backing (B):** SPEC-EXTENSIONS D-120 (crash-isolated load — load path is already
  atomic); Hickey "Simple Made Easy" (2011) — separating data from the process that
  produced it removes accidental complexity.

#### Falsification attempt for claim 2

- **Strategy:** Integration check
- **Attempt:** Does the existing `unload_entry/2` → `do_unload/1` → `unload_module/1`
  call chain actually have access to `info` at the point where `unload_module` is called?
  `lib/tau/extensions/loader.ex:400–407`: yes, `info` is the value retrieved from
  `state.loaded` and passed to `do_unload/1`. `do_unload/1` at lines 415–423 currently
  pattern-matches on `%{module: mod}` and `%{modules: modules}` and calls `unload_module`
  with only the module atom — `info` is not threaded through. The solution explicitly
  changes `do_unload/1` to thread `info` through to `crash_safe_unload/2`, which is
  consistent with the existing hot-path access. No integration gap.
- **Outcome:** Withstood. The integration point exists and `info` is already on the hot
  path; the change is structurally sound.
- **Action:** None.

---

### Claim 3: `crash_safe_unload/2` with `Logger.warning/1` and `[:tau, :extensions, :unload, :exception]` telemetry satisfies acceptance criterion (a) and (b)

- **Claim (C):** "Introduce a `crash_safe_unload/2` helper … to emit a
  `Logger.warning/1` and `[:tau, :extensions, :unload, :exception]` telemetry if a
  Registry call itself raises."
- **Grounds (G):** `lib/tau/extensions/loader.ex:296–349` — `crash_safe_register/2`
  already establishes the pattern: `try/rescue` around the registration call, then
  `Logger.warning/1` naming module + exception, then `:telemetry.execute/3` emitting
  `[:tau, :extensions, :load, :exception]`. The acceptance criterion (a)/(b) demand the
  identical structure for unload. `problem.md §Acceptance criterion`: "(a) a warning log
  naming the broken module and callback, (b) a `[:tau, :extensions, :unload, :exception]`
  telemetry event".
- **Warrant (W):** Symmetry between load and unload paths is not merely aesthetic — OTP
  non-negotiable #5 requires telemetry coverage for "everything user-visible or
  perf-sensitive". An unload failure that leaves stale registry entries is user-visible
  (tools from a broken extension remain callable). The warrant is that AC (a)/(b)
  compliance requires an observable signal for every unload exception.
- **Qualifier (Q):** Holds provided `crash_safe_unload/2` wraps `unload_module/2` at its
  call site in `do_unload/1`, not at individual registry unregister calls. If placed at
  the wrong granularity (e.g., one `try/rescue` per registry call rather than per module),
  it would emit partial telemetry for multi-category modules. The solution's description
  wraps at module granularity, which matches `crash_safe_register/2`'s semantics.
- **Rebuttal (R):** If `Registry.unregister*` never raises in practice (BEAM's built-in
  registries do not raise for unknown keys — they return `:error` tuples), then
  `crash_safe_unload/2`'s rescue branch may never trigger. In that case the telemetry
  event is dead code for existing registry calls. This does not falsify the claim — the
  helper still satisfies the AC's requirement that an exception *would* be observable; it
  is a defensive invariant.
- **Backing (B):** OTP non-negotiables #5 (`TAU.md`); SPEC-EXTENSIONS D-120
  (crash-isolated load pattern as backing authority for unload symmetry); problem.md
  §Acceptance criterion (a) and (b).

#### Falsification attempt for claim 3

- **Strategy:** Edge-case enumeration
- **Attempt:** Edge cases for AC compliance: (i) `Registry.unregister/2` for an unknown
  key — BEAM's `Registry` module returns `:error`, not an exception; the `rescue` block
  would not trigger. This is correct behaviour — the key is already absent, which is the
  post-condition. (ii) `Registry.unregister_match/3` for tools — same: returns count
  integer, not an exception. (iii) A module whose `Tau.Tool.register/1` call raised at
  load time but was partially committed to `registered_keys` before the exception — this
  cannot happen because `crash_safe_register/2`'s outer `try/rescue` ensures no
  `registered_keys` snapshot is stored if any call inside `register_module/1` raises; the
  module is skipped entirely. (iv) The warning must name the "broken module and callback"
  (AC a) — the solution says `Logger.warning/1` naming the module; it does not explicitly
  mention naming the callback. `crash_safe_register/2` (line 337) names the module and
  exception message but not the specific callback that failed. The solution mirrors this
  pattern, which may not fully satisfy AC (a)'s "naming the … callback" clause. This is a
  potential partial falsification of AC compliance.
- **Outcome:** Partially falsified on edge case (iv). The AC requires "naming the broken
  module **and callback**"; the proposed `Logger.warning/1` mirrors `crash_safe_register/2`
  which names module and exception but not the specific callback category. Since the loop
  is over `info.registered_keys` tuples (tagged with `:tool`, `:hook`, `:command`,
  `:skill`), the key tag is available in the loop body and can be included in the warning.
  This is a qualifier narrowing, not a solution revision.
- **Action:** Narrow qualifier: the claim holds provided `Logger.warning/1` in
  `crash_safe_unload/2` includes the key tag from the `registered_keys` tuple being
  processed, not just the module name. The key tag is available in the loop body; no
  structural change to the design is required.

---

### Claim 4: Deleting `try_tool_name/1` is safe once the key-driven loop replaces the callback-invocation loop

- **Claim (C):** "`try_tool_name/1`: delete (no longer called from the unload path)."
- **Grounds (G):** `lib/tau/extensions/loader.ex:482–490` — `try_tool_name/1` is a
  private function. `lib/tau/extensions/loader.ex:437–441` — its only call site is within
  `unload_module/1`'s tool loop: `tool_name = try_tool_name(t)`. Once the tool loop is
  replaced with a key-driven dispatch over `{:tool, name, t}` tuples from
  `info.registered_keys`, the `try_tool_name(t)` call becomes dead code. Grep of the file
  confirms no other call site exists.
- **Warrant (W):** Dead private functions should be deleted: they accumulate cognitive
  overhead, are excluded from Dialyzer analysis paths, and can mislead future readers into
  thinking they are part of the active contract. The module's own Credo rules enforce
  `--strict`, which flags unused private functions.
- **Qualifier (Q):** Holds provided the tool-key capture in `register_module/1` is
  implemented as `{:tool, tool_name, t}` where `tool_name` is `t.name()` (the value
  `try_tool_name/1` was computing at unload time). If the snapshot stores only `{:tool,
  t}` (the struct, without pre-resolving the name), `try_tool_name/1` would still be
  needed in the unload loop to recover the name. The solution description says the tuple
  form is `{:tool, name, t}` — pre-resolved.
- **Rebuttal (R):** `try_tool_name/1` also guards against modules where `name/0` raises or
  is missing via `Code.ensure_loaded?/mod` and `function_exported?/2`. If the snapshot
  captures the name at load time (when the module was healthy), the guard is no longer
  needed at unload time — this is the intended benefit.
- **Backing (B):** Credo `--strict` (project CLAUDE.md); OTP non-negotiable #8 ("Pure
  functions are the default; processes are the exception") — removing dead code reduces
  surface area.

#### Falsification attempt for claim 4

- **Strategy:** Dependency check
- **Attempt:** Verify no other call site exists for `try_tool_name/1`. Full-text search
  of `lib/tau/extensions/loader.ex` for `try_tool_name` yields exactly two occurrences:
  the definition (line 482) and the call site (line 437). No external callers via grep
  of `lib/` and `test/`. The function is private (`defp`), so it cannot be called
  externally. Deletion is safe once line 437's call is removed.
- **Outcome:** Withstood. `try_tool_name/1` has exactly one call site; deletion is safe
  after the call is removed.
- **Action:** None.

---

### Claim 5: All registry consumers outside `loader.ex` are unaffected because registry value shapes are unchanged

- **Claim (C):** "All registry consumers outside `loader.ex` (`Tau.Tool.lookup/1`, hook
  dispatch, command dispatch, skill dispatch) — registry value shapes are unchanged."
- **Grounds (G):** The proposed change adds `registered_keys` to the `info` map stored in
  `state.loaded` (internal GenServer state), not to the registry values themselves. Registry
  registrations remain: `Tau.Tool.register(t)` stores `t` under `mod.name()`;
  `Registry.register(Tau.Hooks.Registry, ev, h)` stores `h` under `ev`; etc. None of these
  value shapes change.
  However: `test/tau/extensions/loader_test.exs:235` — `assert entry.info[:modules] == []`
  — accesses `info` retrieved from `Loader.list/0`. `Loader.list/0` returns
  `%{key: term(), info: map()}` where `info` is the map from `state.loaded`. After the
  change, `info` will also contain `registered_keys`. Tests accessing `info` by key
  (`:modules`) are unaffected; tests asserting on the complete `info` shape would break.
- **Warrant (W):** Adding a key to a map is backwards-compatible for consumers that
  pattern-match on named keys or access by key; it is not backwards-compatible for
  consumers that assert exact map equality (e.g., `assert info == %{module: mod}`). The
  solution acknowledges this in "What changes" — tests "assert on `state.loaded` entry
  shape" must be updated.
- **Qualifier (Q):** Holds for all *production* consumers and for tests that access `info`
  by key. Does NOT hold for any test or code asserting exact map equality on the `info`
  shape. The solution explicitly scopes test updates as required; this qualifier is not a
  revision trigger.
- **Rebuttal (R):** If any test outside `loader_test.exs` pattern-matches the full info
  shape, it will silently pass with extra keys (in ExUnit, `assert %{module: mod} = info`
  ignores extra keys) — so the blast radius is actually smaller than a strict equality
  assertion. The only tests that would break are those using `assert info == %{...}` (strict
  equality). `loader_test.exs:235` uses bracket access (`entry.info[:modules]`), not strict
  equality — so it is already compatible.
- **Backing (B):** Elixir pattern-matching semantics (structural subtyping on maps);
  SPEC-EXTENSIONS §4 ("public API of `Tau.Extensions.Loader` — no exported function
  signatures change" as stated in solution.md §What does not change).

#### Falsification attempt for claim 5

- **Strategy:** Dependency check
- **Attempt:** Check whether any consumer outside `loader.ex` uses the bare `info` shape
  with strict equality. Grep of `lib/` and `test/` for `state.loaded` and `entry.info`
  patterns: `test/tau/extensions/loader_test.exs:235` is the only external consumer found.
  It uses `entry.info[:modules]` (keyword-style access) — compatible with a richer map.
  However, the solution's own §Open questions acknowledges: "Does any external code …
  pattern-match on the bare `%{module: mod}` info shape?" This is explicitly unresolved by
  the proposer, which is an admission that the claim's scope is not yet fully bounded.
  The single test callsite found is compatible; a comprehensive grep is needed before
  implementation to confirm no other callsite exists, but none was found in this pass.
- **Outcome:** Partially falsified (scope unconfirmed, not falsified). The claim holds for
  all callsites found, but the solution's own open question flags the blast-radius grep as
  pre-implementation work. The qualifier is narrowed: claim holds for all currently
  identified consumers; implementer must run the blast-radius grep before opening the PR.
- **Action:** Narrow qualifier in place. Record as pre-implementation gate: the implementer
  MUST grep `lib/` and `test/` for `state.loaded` / `entry.info` / `\.info\[` patterns
  before opening the PR and confirm no exact-equality assertions on the info shape exist
  outside `loader_test.exs`.

---

### Claim 6: The path-based entry (`%{path: _, modules: [mod1, mod2, …]}`) enrichment stores `registered_keys` per module, enabling independent per-module unload

- **Claim (C):** "path-based entry handling (`%{path: _, modules: _}`): enrich to store
  per-module `registered_keys` snapshots so multi-module path entries can unload each
  module independently."
- **Grounds (G):** `lib/tau/extensions/loader.ex:198–223` (`load_entry/1` for binary
  paths) — builds `%{path: path, modules: registered}` where `registered` is a list of
  module atoms. `lib/tau/extensions/loader.ex:419–421` (`do_unload/1` for `%{modules:
  modules}`) — iterates `modules` and calls `unload_module/1` on each atom, with no `info`
  at the per-module level. For the snapshot approach to work, the per-module `registered_keys`
  must be retrievable when `unload_module/2` is called; currently, there is no per-module
  info map in the path entry.
- **Warrant (W):** The `%{modules: [mod1, mod2]}` case in `do_unload/1` calls
  `unload_module` with a bare atom. For the snapshot approach, `unload_module/2` needs the
  per-module `info` (specifically its `registered_keys`). Since each module is registered
  independently via `crash_safe_register/2` (line 216), each registration already produces
  a per-module `info` map. Storing a list of `{mod, info}` pairs instead of bare `[mod]`
  in `%{modules: registered}` is the minimal change that threads per-module info to the
  unload path.
- **Qualifier (Q):** The solution description is intentionally high-level about the exact
  shape ("store per-module `registered_keys` snapshots"). The §Open questions section
  explicitly flags the path-based shape as the "highest-complexity part". This qualifier
  acknowledges the claim's correctness depends on a specific structural choice (pairs vs.
  bare atoms in the modules list) that is deferred to implementation.
- **Rebuttal (R):** An alternative is to keep `%{modules: [mod]}` (bare atoms) and maintain
  a secondary `per_module_keys` map keyed by `{path, mod}` in `state`. This satisfies the
  claim but is more complex; the proposal's approach of enriching the `modules` list is
  the simpler path. If the alternative is chosen, the claim still holds — the AC (c) is
  satisfied either way.
- **Backing (B):** SPEC-EXTENSIONS D-124 (hot reload unloads prior generation — the
  hot-reload case for path entries is the primary motivation); solution.md §Migration
  sketch ("The path-based multi-module enrichment … is the highest-complexity part").

#### Falsification attempt for claim 6

- **Strategy:** Integration check
- **Attempt:** Does `crash_safe_register/2` (called per-module at line 216) already return
  the per-module `info`? `lib/tau/extensions/loader.ex:318` — yes: `{:ok, key, info}` is
  returned. Line 216: `case crash_safe_register(mod, path) do {:ok, _key, _info} -> [mod]
  _error -> [] end` — the `_info` is currently discarded. Changing this to `[{mod, info}]`
  and updating `%{path: path, modules: registered}` to `%{path: path, modules: registered}`
  where `registered` is now a list of `{mod, info}` tuples (or a map) is the minimal
  structural change. The integration point is present; the `_info` discard is the exact
  gap the claim addresses. No deeper structural change is required.
- **Outcome:** Withstood. The integration point exists; the per-module `info` is already
  produced and currently discarded. The change is structurally sound.
- **Action:** None.

---

## Cross-claim consistency

Claims 1–6 are mutually consistent:

- Claims 1 and 2 are directly coupled: claim 1 diagnoses the root cause; claim 2 names the
  fix. No tension.
- Claim 3 (observability helper) and claim 4 (deletion of `try_tool_name/1`) operate on
  different parts of the unload path and do not conflict.
- Claim 5 (registry consumer blast radius) and claim 6 (path-entry enrichment) both
  concern the info shape but at different levels: claim 5 concerns external consumers of
  the `state.loaded` info map (via `Loader.list/0`); claim 6 concerns the internal
  `%{modules: [...]}` sub-structure. No tension.
- The partial falsification of claim 5 (blast-radius grep deferred to implementation) does
  not affect claims 1–4 or 6, which do not depend on the exact shape of external consumers.

One potential tension: claim 6 changes the internal shape of `%{modules: registered}` from
`[mod_atom]` to (likely) `[{mod, info}]` or a map. Claim 5 asserts registry value shapes
are unchanged. These are consistent because claim 5 is about **registry values** (what is
stored in `Tau.Tools.Registry`, `Tau.Hooks.Registry`, etc.) not about the `state.loaded`
internal shape. The `%{modules: registered}` field lives in `state.loaded`, not in the
registries. No inconsistency.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `try/rescue _ -> []` causes silent partial unload | Counter-example construction | Withstood | None |
| 2 | Snapshot at load time eliminates unload callback re-invocation | Integration check | Withstood | None |
| 3 | `crash_safe_unload/2` satisfies AC (a)/(b) | Edge-case enumeration | Partially falsified | Narrow qualifier: warning MUST name key tag, not only module |
| 4 | Deleting `try_tool_name/1` is safe | Dependency check | Withstood | None |
| 5 | Registry consumers outside `loader.ex` unaffected | Dependency check | Partially falsified | Narrow qualifier: implementer must run blast-radius grep before PR |
| 6 | Path-based entry enrichment enables per-module unload | Integration check | Withstood | None |

## Revision required

No full revision triggered. Two claims require qualifier narrowings; neither falsifies
the solution's viability.

- **Claim 3 — narrowed qualifier:** `crash_safe_unload/2`'s `Logger.warning/1` MUST include
  the key tag (`:tool`, `:hook`, `:command`, `:skill`) from the `registered_keys` tuple
  being processed, so AC (a)'s "naming the broken module **and callback**" clause is
  satisfied. The key tag is available in the loop body at no additional cost.
- **Claim 5 — narrowed qualifier:** Implementer MUST grep `lib/` and `test/` for
  `state.loaded`, `entry.info`, and `\.info\[` patterns and confirm no exact-equality
  assertions exist on the info map shape outside `loader_test.exs` before opening the PR.
  The solution's §Open questions already flags this; this validation records it as a
  mandatory pre-PR gate, not a follow-up.

## Outstanding doubts

- `Tau.Tool.register/1`'s return contract is `{:ok, pid()} | {:error, term()}` per
  `lib/tau/tool.ex:55`. The `registered_keys` capture logic must treat `{:ok, _}` as
  "key recorded" and `:error` (or an exception) as "key not recorded". This is consistent
  with the solution but worth explicit test coverage.
- The `do_unload(_info), do: :ok` catch-all clause (line 423) handles unknown info shapes.
  After enrichment, any `state.loaded` entry that was inserted before this change (e.g.
  from a stale ETS snapshot surviving a hot-upgrade) would hit this clause and silently
  skip unload. The solution acknowledges this with "a fallback clause in `unload_module/2`
  that logs a warning and skips" — the warning is important; a silent skip would
  reintroduce the observability gap the fix closes.
