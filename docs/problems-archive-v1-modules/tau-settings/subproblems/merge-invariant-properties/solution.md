---
template_version: 1
template_name: solution
parent_problem: ../../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-2.md, proposals/proposal-4.md]
selection_method: hybrid
revision: 0
---

# Solution: Standalone property file + rule-table production refactor

## Recommendation

Combine proposal-4's production data-shape change (replace `list_keys/0`
with an `@merge_rules` module attribute and expose `merge_rules/0`) with
proposal-2's standalone `loader_property_test.exs` file. The production
refactor eliminates the `list_keys/0` / `:concat`-dispatch divergence
surface and introduces `merge_rules/0` as the inspectable, testable
contract; the standalone test file provides a prose `@moduledoc` contract
statement, rule-table property tests derived mechanically from
`merge_rules/0`, and algebraic-law properties (associativity,
idempotency, scalar override) using a structurally-coherent generator.
The shared `SettingsGenerators` support module from proposal-2 is NOT
included — the coherent-triple generator in proposal-4 is self-contained
and sufficient; a shared module adds naming/placement overhead with no
current payoff.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-2.md` + `proposals/proposal-4.md`
- **Why chosen:** Proposal-2 is the only proposal that directly addresses
  the complecting hypothesis (coincidental examples vs. contractual
  specification) by using a prose `@moduledoc` contract and a file
  boundary to separate examples from properties; it also names the
  acceptance criterion's explicit alternative (`loader_property_test.exs`).
  Proposal-4 adds a production data-shape change that eliminates an
  actual defect — the possibility that `list_keys/0` and the `:concat`
  dispatch branch diverge — and produces `merge_rules/0`, which makes
  the rule-table property tests in the test file mechanically stronger
  (they test dispatch, not just outcomes). Proposal-1 is strictly
  dominated by proposal-2 (same approach, same tests, no prose contract,
  generator with a known structural-coherence bug). Proposal-3 introduces
  a `@behaviour` for a function with one implementation and no near-term
  second — speculative extensibility the problem statement does not
  require, and Hickey would call premature aggregation.

  The hybrid is more than the sum of its parts: proposal-4's
  `merge_rules/0` makes proposal-2's rule-table property test possible
  (it can iterate over `Loader.merge_rules()` rather than hard-coding
  the key list in the test); proposal-2's standalone file gives
  proposal-4's properties a proper prose home rather than inline
  comments. Neither proposal alone produces both the production
  correctness improvement and the specification artefact.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Partially | Surface | Low | Low | Easy |
| 2 | Yes | Substantial | Low | Low | Easy |
| 3 | Yes | Surface | Medium | Medium | Hard |
| 4 | Yes | Deep | Medium | Low | Easy |
| Hybrid 2+4 | Yes | Deep | Medium | Low | Easy |

Proposal-1 scores Partially because its generator has an acknowledged
structural-coherence defect that could make the associativity property
vacuously true. Proposal-3 scores Medium risk and Hard reversibility
because it adds a production `@behaviour` module to the public API that
must be maintained regardless of whether a second implementation ever
appears. The hybrid is the only option that scores Deep decomplecting
depth (eliminating the divergence surface) at Low risk and Easy
reversibility (the production change is ~10 lines in one file; the test
file can be reverted independently).

## What changes

- `lib/tau/settings/loader.ex`:
  - Replace `list_keys/0` (returns a hardcoded list) with a
    `@merge_rules` module attribute (`%{atom() => :concat}`) covering
    the same 7 keys.
  - Add `def merge_rules/0` (public) returning `@merge_rules`.
  - Rewrite `merge_value/3` list-dispatch clause to use
    `Map.get(@merge_rules, k, :override)` instead of `if k in list_keys()`.
  - `list_keys/0` is retained as `def list_keys, do: Map.keys(@merge_rules)`
    if any other callsite references it; otherwise deleted.
- `test/tau/settings/loader_property_test.exs` (new file):
  - `@moduledoc` with prose contract: states associativity,
    list-key concatenation, scalar override, idempotency as invariants,
    and explicitly states commutativity is NOT an invariant.
  - `@moduletag :property` so `mix test --only property` selects the
    whole file.
  - `describe "rule-table contract"` block with one property: iterates
    `Loader.merge_rules()`, selects `:concat` keys, verifies
    `merge(%{k => xs}, %{k => ys})[k] == xs ++ ys` for arbitrary lists.
  - `describe "algebraic laws"` block with three properties using a
    local `coherent_triple/0` generator (proposal-4's pattern):
    associativity, idempotency, scalar override.
  - No shared support module; the `coherent_triple/0` generator lives
    in the test module.

## What does not change

- `test/tau/settings/loader_test.exs` — the four existing example tests
  are untouched.
- `Loader.load/1`, `Loader.paths/1`, source-tracking, watcher/cache
  logic — out of scope.
- `list_keys/0` public API is preserved (derived from `@merge_rules`)
  if callsites reference it; its behaviour is identical.
- `mix.exs` — `ExUnitProperties` and `StreamData` are already dev deps.
- No shared `test/support/settings_generators.ex` module is introduced.

## Migration sketch

1. Add `@merge_rules` attribute to `loader.ex`; derive `merge_rules/0`
   and rewrite `list_keys/0` from it; update `merge_value/3` dispatch
   clause. Run `mix test test/tau/settings/loader_test.exs` — all four
   example tests must pass unchanged.
2. Create `test/tau/settings/loader_property_test.exs` with the
   `@moduledoc` contract and the three `property/2` blocks. Run
   `mix test --only property test/tau/settings/loader_property_test.exs`
   — all properties must pass.
3. Run the full suite: `mix test` — no regressions. Run
   `mix compile --warnings-as-errors` to confirm the `@merge_rules`
   attribute type is clean.

## Open questions

- Does any callsite outside `loader.ex` reference `list_keys/0` by
  name? If yes, the derived definition is a drop-in. If the codebase
  has no external callers, `list_keys/0` may be deleted (saving a
  public API surface). A grep is required before implementation.
- The `coherent_triple/0` generator uses `StreamData.fixed_map/1` with
  a map of generators. Verify the project's pinned `stream_data` version
  supports this API before committing.
- Proposal-4's `coherent_triple/0` sketch uses
  `StreamData.tuple({gen, gen, gen})` to generate three values from the
  same generator instance per key. This is the correct approach for
  structural coherence; confirm the generator produces non-degenerate
  inputs (non-empty maps) on a prototype run before declaring the
  property tests non-vacuous.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Inline property block in `loader_test.exs`:
  minimal footprint but generator has a structural-coherence defect and
  no prose contract.
- `proposals/proposal-2.md` — Standalone `loader_property_test.exs` with
  prose `@moduledoc` contract: directly decomplects specification from
  coincidental examples; base of the hybrid.
- `proposals/proposal-3.md` — `MergeBehaviour` + `@impl` annotation:
  introduces speculative extensibility for a single-implementation
  boundary; exceeds the acceptance criterion's scope.
- `proposals/proposal-4.md` — Data-shape refactor + rule-table tests:
  eliminates `list_keys/0` / dispatch divergence surface; provides
  `merge_rules/0` that makes the hybrid's rule-table property tests
  mechanically correct.

## Revision history

- (revision 0 — initial)
