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

# Validation: Standalone property file + rule-table production refactor

## Overview

The solution proposes (1) a production data-shape change in `loader.ex` —
replacing a private `list_keys/0` function with an `@merge_rules` module
attribute and a public `merge_rules/0` accessor — and (2) a new standalone
`test/tau/settings/loader_property_test.exs` with a prose `@moduledoc`
contract and four property blocks. Seven claims are extracted from the
Recommendation and What-changes sections. Falsification strategies used:
dependency check (claims 1, 3, 6), counter-example construction (claims 2,
4), edge-case enumeration (claims 5, 7), type-level check (claim 3).
Outcome: six claims withstood; claim 5 partially falsified (qualifier
narrowed; no revision required).

---

## Toulmin per claim

### Claim 1: `merge_rules/0` eliminates the divergence surface between `list_keys/0` and the `:concat`-dispatch branch

- **Claim (C):** Replacing `list_keys/0` + `if k in list_keys()` dispatch
  with a single `@merge_rules` attribute consulted by both `merge_rules/0`
  and `merge_value/3` eliminates the possibility that the key list and the
  dispatch logic diverge.
- **Grounds (G):** `loader.ex:44` shows `if k in list_keys()` calling a
  private function; `loader.ex:88-98` shows `list_keys/0` returning a
  hardcoded list. These are two independently editable code sites. The
  proposed `Map.get(@merge_rules, k, :override)` dispatch reads from the
  same attribute that `merge_rules/0` returns, making them one site.
- **Warrant (W):** Single-source-of-truth: when a logical fact (the set of
  concat keys) is represented exactly once in source, no edit can produce
  a partial update that leaves only one site changed.
- **Qualifier (Q):** Holds for the `list_keys/0` / `:concat`-dispatch
  divergence surface specifically. A future maintainer who adds a second
  dispatch strategy (beyond `:concat`) and hand-codes it in a separate
  clause rather than extending `@merge_rules` could reintroduce a
  divergence surface — but that is outside the scope of this change.
- **Rebuttal (R):** If `merge_value/3` grows additional clauses that hard-
  code key-set checks (e.g., for a hypothetical `:dedupe` strategy), the
  single-source property breaks again. The refactor prevents the *current*
  divergence; it does not prevent all future forms.
- **Backing (B):** OTP NN #8 (pure functions as default); general principle
  that single-representation of a fact is a prerequisite for verifiable
  invariants (see also Hickey, "Simple Made Easy" — the distinction between
  complecting coincidental co-location and genuine conceptual unity).

#### Falsification attempt for claim 1

- **Strategy:** Dependency check — verify the proposed single-source path
  is structurally closed (no second site in the module that could hold a
  divergent copy of the key set).
- **Attempt:** Searched `loader.ex` for all uses of `list_keys` and all
  list-dispatch patterns. `list_keys` appears only at `loader.ex:44`
  (dispatch) and `loader.ex:88` (definition). No other list-key check
  exists in the file. The proposed `Map.get(@merge_rules, k, :override)`
  dispatch eliminates both sites in favour of the attribute, leaving zero
  independent sites.
- **Outcome:** Withstood — no second site found; the single-source property
  holds structurally.
- **Action:** None.

---

### Claim 2: The rule-table property test in `loader_property_test.exs` is mechanically stronger than hard-coding the key list in the test

- **Claim (C):** Iterating `Loader.merge_rules()` in the property test —
  rather than re-listing the 7 keys in the test — means the test
  automatically exercises any future key added to `@merge_rules` without a
  test-file edit.
- **Grounds (G):** The existing example test at `loader_test.exs:22-27`
  hard-codes `:hooks` and `:extensions`; if a new list-key is added to
  `list_keys/0`, the example test still passes even if the new key is
  accidentally not dispatched as `:concat`. The proposed property iterates
  `Loader.merge_rules()` and therefore catches any key the attribute
  contains.
- **Warrant (W):** A test that derives its own oracle from the production
  data structure under test is stronger than a test that independently
  enumerates a subset: the former cannot be stale; the latter can.
- **Qualifier (Q):** Holds only once `merge_rules/0` is public and returns
  the full key set. If a key is intentionally omitted from `@merge_rules`
  (e.g., a key that concatenates by a different rule), the test would also
  omit it — but that is consistent behaviour, not a defect.
- **Rebuttal (R):** If `Loader.merge_rules()` itself has a bug (returns
  fewer keys than `@merge_rules`), the property test would silently
  under-test. The `@merge_rules` attribute approach makes this unlikely
  since `merge_rules/0` is defined as `def merge_rules, do: @merge_rules`.
- **Backing (B):** `problem.md` §Acceptance criterion — "exercises the
  associativity of three-layer merge, the list-key concatenation contract
  under arbitrary list inputs, and the scalar override invariant"; the
  criterion implicitly requires that the tests remain accurate as the key
  set evolves.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — construct a scenario where
  iterating `merge_rules()` does NOT provide stronger coverage than a
  hard-coded list.
- **Attempt:** The only scenario where a hard-coded test list beats
  `merge_rules()` iteration is if a key is in the desired-contract set but
  NOT in `@merge_rules`. This would mean `@merge_rules` is wrong — a
  production bug, not a test-coverage defect. In that case both approaches
  fail equally (neither catches the missing key).
- **Outcome:** Withstood — no scenario found where a hard-coded key list
  provides strictly stronger coverage for the purpose of detecting
  regression; the production-derived iteration is at least as strong and
  typically stronger.
- **Action:** None.

---

### Claim 3: `mix.exs` requires no changes; `ExUnitProperties` and `StreamData` are already dev deps

- **Claim (C):** The hybrid solution requires no `mix.exs` changes because
  `stream_data` is already a dev dependency.
- **Grounds (G):** `mix.exs:129` — `{:stream_data, "~> 1.1", only: [:test,
  :dev]}`. `mix.lock` shows `stream_data 1.3.0` is resolved. The project
  already uses `ExUnitProperties` and `StreamData` in
  `test/tau/settings/vault/env_test.exs:11,56` and
  `test/tau/providers/rate_limiter/token_bucket_property_test.exs:23`.
- **Warrant (W):** A dependency already declared in `mix.exs` and present
  in `mix.lock` is available to any test file without further configuration.
- **Qualifier (Q):** Universal — no edge case where the dep would be
  unavailable to the new test file in the standard project layout.
- **Rebuttal (R):** None applicable. The dep is declared with `only: [:test,
  :dev]`, which covers the test environment where this file runs.
- **Backing (B):** `mix.exs:129` (cited above); `mix.lock` `stream_data`
  entry (version 1.3.0).

#### Falsification attempt for claim 3

- **Strategy:** Dependency check + type-level check — verify `StreamData.fixed_map/1` and `StreamData.tuple/1` are available in version 1.3.0 (the locked version).
- **Attempt:** Confirmed `stream_data 1.3.0` in `mix.lock`. Searched
  existing test files for `StreamData.fixed_map` — found usage at
  `test/tau/providers/shared/tool_spec/gemini_subset_test.exs:130` and
  `test/tau/providers/shared/tool_spec_test.exs:160,168,177`, and for
  `StreamData.tuple` at
  `test/tau/providers/rate_limiter/token_bucket_property_test.exs:23` and
  `test/tau/circuit_breaker/state_property_test.exs:45`. Both APIs are
  actively used in the project at the locked version. The solution's open
  question about `StreamData.fixed_map/1` compatibility is resolved: it is
  confirmed available.
- **Outcome:** Withstood — both APIs are confirmed available at the locked
  version.
- **Action:** None. The solution's open question about `fixed_map`
  compatibility can be closed.

---

### Claim 4: Associativity, idempotency, and scalar-override are sound invariants for `Loader.merge/2` as currently implemented

- **Claim (C):** The three algebraic laws selected for property testing
  (associativity of three-layer merge, idempotency of identical layers,
  scalar override) are true invariants of the current implementation.
- **Grounds (G):** `loader.ex:37-51` — `merge/2` delegates conflict
  resolution to `merge_value/3`. `merge_value/3` has three clauses:
  (a) both maps → recurse; (b) both lists at a known key → concat; (c)
  otherwise → `v2`. Clause (c) implements scalar override unconditionally.
  Idempotency: `merge(a, a)` — for scalar keys, `v2 = a[k]`; for list
  keys, `a[k] ++ a[k]` (NOT idempotent for list keys). For map keys,
  `merge(v1, v1)` is recursive with the same property.
- **Warrant (W):** Algebraic properties must hold at all types handled by
  the function. An idempotency claim that holds for scalars but fails for
  list keys is a false invariant unless qualified.
- **Qualifier (Q):** Associativity holds universally for this merge
  (argument below). Idempotency holds only for settings maps with NO list
  keys, or when the list keys are empty. Scalar override holds universally.
- **Rebuttal (R):** See claim 5 for the idempotency qualification — the
  solution text does not restrict idempotency to scalar-only or empty-list
  contexts, which would make the property test as written either incorrect
  or vacuous depending on the generator.
- **Backing (B):** `loader.ex:43-49` — the concat clause; `problem.md`
  §Statement — explicitly names idempotency as an invariant without
  qualification.

#### Falsification attempt for claim 4

- **Strategy:** Counter-example construction for idempotency.
- **Attempt:** Let `a = %{hooks: [%{e: 1}]}`. Then
  `merge(a, a) = %{hooks: [%{e: 1}, %{e: 1}]}` ≠ `a`. Idempotency
  (`merge(a, a) == a`) fails for any non-empty list at a list key. This
  is a concrete falsifying instance.
- **Outcome:** Partially falsified — idempotency does NOT hold universally;
  it fails for maps containing non-empty lists at concat keys. Associativity
  and scalar override are unaffected and withstand the attempt.
- **Action:** Narrow qualifier (see claim 5 for full treatment). No revision
  to `solution.md` required — the property test design can accommodate this
  by restricting the `coherent_triple/0` generator to scalar-only maps when
  testing idempotency, or by reframing the idempotency property to test
  `merge(a, %{}) == a` (left identity) instead. The narrowed claim survives.

---

### Claim 5: Idempotency is a valid invariant for `Loader.merge/2`

- **Claim (C):** "idempotency of identical layers" is listed as one of the
  three property tests in the `describe "algebraic laws"` block.
- **Grounds (G):** `problem.md` §Statement — "idempotency of identical
  layers" named as an invariant. `loader.ex:43-49` — list concat clause
  shows `v1 ++ v2` for list keys, meaning `merge(a, a)` at a list key
  yields a doubled list. The example test at `loader_test.exs:19-26` uses
  `%{hooks: [%{e: 1}]}` — a map with a non-empty list key.
- **Warrant (W):** For an operation `f` to be idempotent, `f(x, x) = x`
  must hold for all `x` in the domain. `Loader.merge/2`'s domain includes
  maps with non-empty list values at concat keys; for these, the operation
  is not idempotent.
- **Qualifier (Q):** Idempotency holds only for the sub-domain of settings
  maps where all concat-key values are empty lists (or absent). It does NOT
  hold universally over the type `map()`.
- **Rebuttal (R):** The `coherent_triple/0` generator may generate maps with
  empty lists, in which case the idempotency property test passes vacuously
  for list keys, hiding the non-idempotency. Alternatively, if it generates
  non-empty lists, the test will fail. Either outcome is a defect in the
  claimed property.
- **Backing (B):** `loader.ex:43-49` (concat clause — cited above);
  `problem.md` §Statement (names idempotency without qualification).

#### Falsification attempt for claim 5

- **Strategy:** Edge-case enumeration — enumerate the map shapes where
  idempotency fails.
- **Attempt:** Any map `a` with `a[:hooks]` non-empty produces
  `merge(a, a)[:hooks] = a[:hooks] ++ a[:hooks]` ≠ `a[:hooks]`. Same for
  any of the 7 concat keys with a non-empty list. The domain is broad:
  typical real settings maps have non-empty `:hooks`, `:allow`, `:deny`
  entries.
- **Outcome:** Partially falsified — the unqualified claim "idempotency of
  identical layers is an invariant" is false for the full domain. The
  narrowed survivor: idempotency holds for `merge(a, a)` iff every concat
  key in `a` has an empty-list or absent value. Alternatively, the claim
  is reframed as "left identity: `merge(%{}, a) == a`" which IS a true
  invariant.
- **Action:** Narrow qualifier — the property test MUST either (a) restrict
  the generator to scalar-only maps for the idempotency check, or (b)
  replace "idempotency of identical layers" with "left identity
  (`merge(%{}, a) == a`)" which is the true invariant the implementation
  exhibits. No `solution.md` revision required; the test file
  implementation must respect this constraint, and the `@moduledoc`
  contract statement must be corrected. This is a qualifier narrowing only.

---

### Claim 6: `list_keys/0` is private and has no external callers; it may be deleted or derived

- **Claim (C):** "list_keys/0 is retained as `def list_keys, do:
  Map.keys(@merge_rules)` if any other callsite references it; otherwise
  deleted."
- **Grounds (G):** `loader.ex:88` defines `list_keys/0` as `defp` (private).
  Grep of `lib/` for `list_keys` returns only `loader.ex:44` (dispatch
  caller) and `loader.ex:88` (definition). `test/tau/settings/schema_test.exs:26`
  defines a local `list_keys` variable — it does not call `Loader.list_keys/0`.
  No external caller exists.
- **Warrant (W):** A private function with no callers outside its own module
  can be deleted without breaking the public API. If it were called
  externally, it would need to be retained or a public wrapper provided.
- **Qualifier (Q):** Holds as of current HEAD. A concurrent branch could
  add a caller, but the solution already handles this with "if any other
  callsite references it."
- **Rebuttal (R):** The solution preserves `list_keys/0` as a public derived
  function if callsites exist — this is a reasonable hedge. The grep
  confirms no callsites exist today, so deletion is safe.
- **Backing (B):** Grep result — `lib/tau/settings/loader.ex:44,88` are
  the only occurrences; `test/tau/settings/schema_test.exs:26` is a local
  variable, not a call to `Loader.list_keys/0`.

#### Falsification attempt for claim 6

- **Strategy:** Dependency check — search the full codebase for
  `Loader.list_keys` and `Settings.Loader.list_keys`.
- **Attempt:** Ran grep over `lib/` and `test/` for `list_keys`. Results:
  `loader.ex:44` (internal call to private function), `loader.ex:88`
  (definition), `schema_test.exs:26` (local variable — not a module call).
  No other occurrences.
- **Outcome:** Withstood — no external callers; the function is safely
  deletable.
- **Action:** None. Open question in solution.md about external callers is
  resolved: none exist; `list_keys/0` may be deleted.

---

### Claim 7: The `coherent_triple/0` generator using `StreamData.tuple/1` produces non-degenerate (non-empty-map) inputs

- **Claim (C):** The solution asserts the `coherent_triple/0` generator
  produces "non-degenerate inputs (non-empty maps)" and proposes confirming
  this on a prototype run. The implicit claim is that the proposed generator
  pattern is sound.
- **Grounds (G):** The solution cites "proposal-4's pattern" using
  `StreamData.tuple({gen, gen, gen})` to generate three values from the
  same generator instance per key. `StreamData.tuple/1` is confirmed
  available in the locked version (1.3.0) — used at
  `test/tau/providers/rate_limiter/token_bucket_property_test.exs:23` and
  `test/tau/circuit_breaker/state_property_test.exs:45`.
- **Warrant (W):** `StreamData.tuple/1` generates a tuple by running each
  member generator independently. If the map generator is defined to
  produce fixed-key maps with independently-generated values, the triple
  `{a, b, c}` has no structural coupling across `a`, `b`, `c` beyond
  shared key shape — which is the desired coherence property (all three
  maps have the same keys, different values).
- **Qualifier (Q):** The generator produces non-empty maps iff the
  underlying value generators produce at least one entry. If the map is
  constructed with `StreamData.fixed_map/1` over a fixed key set (which
  is the pattern used in the codebase), all maps in the triple will have
  the same non-empty key set by construction.
- **Rebuttal (R):** If the generator uses `StreamData.map_of/2` rather than
  `StreamData.fixed_map/1`, it can produce empty maps. This is an
  implementation choice the solution leaves open. The solution's open
  question ("verify non-degenerate inputs on a prototype run") is an
  appropriate hedge.
- **Backing (B):** `test/tau/providers/shared/tool_spec_test.exs:160` —
  example of `StreamData.fixed_map/1` producing structurally coherent
  maps in this codebase. `StreamData` 1.3.0 docs (stream_data hex package).

#### Falsification attempt for claim 7

- **Strategy:** Edge-case enumeration — enumerate generator shapes that
  produce degenerate (empty) maps.
- **Attempt:** A `StreamData.map_of(key_gen, val_gen)` can produce `%{}`.
  A `StreamData.fixed_map(%{k1: gen1, k2: gen2})` cannot produce an empty
  map — it always produces exactly the declared keys. The claim that the
  generator is non-degenerate is conditional on using `fixed_map` or
  equivalent; the solution leaves the exact generator shape to the
  implementer.
- **Outcome:** Withstood with qualifier — using `StreamData.fixed_map/1`
  (the pattern already established in this codebase) guarantees non-empty
  maps. The open question in solution.md is appropriately flagging this
  implementation constraint.
- **Action:** None. The implementer must use `StreamData.fixed_map/1` (not
  `map_of`) for the per-key value generators to guarantee structural
  coherence and non-degeneracy.

---

## Cross-claim consistency

**Claims 1 and 6** interact: claim 1 says the `@merge_rules` attribute is
the single source for both `merge_rules/0` and `merge_value/3` dispatch;
claim 6 says `list_keys/0` may be deleted. These are consistent — once
`@merge_rules` drives dispatch, `list_keys/0` becomes derivable (or
deletable). No tension.

**Claims 4 and 5** interact: claim 4 establishes that idempotency is
partially falsified for non-empty list inputs; claim 5 narrows the
idempotency qualifier. These are consistent — claim 4 scopes the discovery;
claim 5 handles the resolution. The narrowed qualifier in claim 5 (restrict
to scalar-only maps, or reframe as left-identity) is coherent with the
overall property test design. No internal inconsistency, but the
`@moduledoc` contract statement in the proposed test file must use the
narrowed form.

**Claims 2 and 3**: independent and consistent.

**Claims 6 and 7**: independent and consistent.

No unresolvable tensions found.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `merge_rules/0` eliminates divergence surface | Dependency check | Withstood | None |
| 2 | Rule-table property mechanically stronger than hard-coded key list | Counter-example construction | Withstood | None |
| 3 | No `mix.exs` change needed; StreamData already available | Dependency check + type-level check | Withstood | None; open question in solution.md resolved |
| 4 | Associativity, idempotency, scalar-override are sound invariants | Counter-example construction | Partially falsified (idempotency) | Narrow qualifier — see claim 5 |
| 5 | Idempotency of identical layers is a valid test | Edge-case enumeration | Partially falsified | Narrow: restrict to scalar maps OR reframe as left-identity `merge(%{}, a) == a` |
| 6 | `list_keys/0` has no external callers | Dependency check | Withstood | None; open question resolved |
| 7 | `coherent_triple/0` produces non-degenerate maps | Edge-case enumeration | Withstood (with qualifier) | Implementer must use `fixed_map`, not `map_of` |

---

## Revision required

No revision to `solution.md` or `problem.md` is triggered. The partial
falsification of claims 4 and 5 (idempotency) requires a qualifier
narrowing only:

- **Target file:** `test/tau/settings/loader_property_test.exs` (the to-be-
  created file — not yet in the codebase)
- **Revision kind:** Implementation constraint — the idempotency property
  test MUST be written as either (a) a left-identity test
  (`merge(%{}, a) == a`) or (b) a test that restricts its generator to
  scalar-only maps. The unqualified "idempotency of identical layers"
  framing in the solution's `@moduledoc` description must be corrected to
  "left identity" or "idempotency for scalar-only maps."
- **Rationale:** The problem.md names idempotency as an invariant without
  qualification; the `@moduledoc` contract statement the solution proposes
  must not repeat that unqualified claim. Correcting it in the test file
  at implementation time (not in solution.md) is sufficient — the
  structural design of the solution is sound.

---

## Outstanding doubts

- The associativity property's coherent-triple generator must produce
  structurally coherent inputs (same keys across all three maps, but
  different values). The solution cites proposal-4's pattern but does not
  show the generator code. If the three maps in the triple have different
  key sets, the associativity property may pass vacuously (e.g., because
  no key conflicts occur across layers). The implementer must ensure the
  generator produces key overlap, not just shape similarity.
- The solution defers the `coherent_triple/0` generator's non-vacuity
  verification to "a prototype run." This is an unresolved implementation
  risk — the property test could pass for the wrong reason (no generated
  inputs trigger the conflict paths). A prototype run is strongly
  recommended before declaring the properties non-vacuous.
