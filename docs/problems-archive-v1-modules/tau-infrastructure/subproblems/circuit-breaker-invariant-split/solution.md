---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-2.md, proposals/proposal-3.md, proposals/proposal-4.md]
selection_method: single
revision: 0
---

# Solution: Store returns pre-increment counts

## Recommendation

Change `Store.bump_failure_count/1` and `Store.bump_success_count/1` to return
the pre-increment value using `:ets.update_counter/3`'s multi-op form, allowing
`record_outcome/5` to pass the value directly into the `State` struct without any
arithmetic adjustment. Simultaneously promote `cooldown_ms` to a keyword opt in
`State.check/2` (with `@default_cooldown_ms` as the fallback), closing the
asymmetric configurability. The `new_count - 1` comment block in the façade is
deleted entirely; no explanatory workaround remains.

## Selected from

- **Chosen:** `proposals/proposal-1.md`
- **Why chosen:** The acceptance criterion requires that the `new_count - 1`
  adjustment in `record_outcome/5` be eliminated by changing the interface on
  exactly one side — either `Store`'s return convention or `State`'s function
  signatures. Proposal 1 satisfies this most cleanly on the Store side.

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Yes | Substantial | Low | Low | Easy |
| 2 | Yes | Substantial | Medium | Medium | Easy |
| 3 | Partially | Surface | Low | Low | Easy |
| 4 | Yes | Deep | High | Medium | Hard |

**Proposal 1 vs 2:** Both eliminate the adjustment cleanly. Proposal 1 changes the
Store side; Proposal 2 changes the State side. The Store is the natural point of
change because the impedance originates there: `:ets.update_counter/3` returns
post-increment by design, and the façade only needed to correct for it. Changing
Store's return convention via the multi-op `update_counter` form is
self-contained — `State.record_failure/2`'s semantics (`count + 1` internally)
remain correct and unchanged, so State's test suite requires no updates. Proposal
2's weakness is that it shifts semantics into `State.record_failure/2` (removing
the internal `+ 1`) which changes the contract of a pure function that may have
hand-constructed test fixtures relying on pre-bump values. Proposal 1's only
downside is that `bump_*/1` now returns a pre-increment value from a function
named "bump" — addressable via spec and doc.

**Proposal 3 vs 1:** Proposal 3 is behaviour-preserving and low-cost, but it is
"surface" decomplecting: the `- 1` arithmetic is relocated to `State.from_bump/3`
rather than eliminated. The acceptance criterion asks for elimination of the
adjustment; a named wrapper that preserves the arithmetic satisfies the letter
but not the spirit. `from_bump/3` also introduces permanent dead-weight if either
Proposal 1 or 2 ever lands later.

**Proposal 4 vs 1:** Proposal 4 offers the deepest decomplecting by unifying
bump + decide in `Store`, but at the cost of turning a thin ETS wrapper into a
business-logic module, retiring `State.record_*/2` from the production path
(latent divergence risk), and requiring ETS setup in every new unit test. The OTP
non-negotiables favour pure functions as the default; Proposal 4 moves in the
opposite direction. Irreversibility is higher: once `Store` owns threshold logic,
reversing that boundary is a multi-file refactor.

## What changes

- **`lib/tau/circuit_breaker/store.ex`** — `bump_failure_count/1` and
  `bump_success_count/1` changed to use the two-element `update_counter` op list
  `[{pos, 0}, {pos, 1}]`, returning the pre-increment value. `@spec` return type
  is unchanged (`non_neg_integer()`); `@doc` updated to document pre-increment
  semantics.
- **`lib/tau/circuit_breaker.ex`** — `record_outcome/5`: remove the `new_count - 1`
  adjustment; pass the Store return value directly as the struct field value.
  Delete the comment block at lines 116–123.
- **`lib/tau/circuit_breaker/state.ex`** — `check/2` becomes `check/3` with an
  optional `cooldown_ms` keyword opt; `@default_cooldown_ms` remains as the
  fallback. No change to `record_failure/2` or `record_success/2`.
- **`docs/spec/SPEC-CIRCUIT-BREAKER.md`** — §4 B4 amended to document: (a) the new
  pre-increment return convention for `Store.bump_*/1`; (b) the new `cooldown_ms`
  opt on `State.check/3`.

## What does not change

- `State.record_failure/2` and `State.record_success/2` signatures, semantics, and
  internal arithmetic — they continue to expect a pre-increment count in the struct
  field and perform `count + 1` internally.
- D-044 ETS row layout — counter column positions 3 and 4 are unchanged; no schema
  migration.
- The public `Tau.CircuitBreaker.call/3` API contract.
- Any caller of `Store.bump_*/1` that does not inspect the return value is
  unaffected. The type signature is identical.
- All `State` tests that construct `%State{}` with pre-bump field values and call
  `record_failure/2` / `record_success/2` — those contracts are unchanged.

## Migration sketch

1. Update `Store.bump_failure_count/1` and `bump_success_count/1` to the multi-op
   `update_counter` form; update `@doc` to state "returns pre-increment count".
2. Audit existing tests that call `Store.bump_*/1` and assert on the return value
   — update assertions from post-increment to pre-increment (likely a small set;
   a `grep` for `bump_failure_count\|bump_success_count` in `test/` suffices).
3. Remove the `new_count - 1` expression and comment block in `record_outcome/5`;
   replace with direct struct field assignment from the Store return value.
4. Add `cooldown_ms` opt to `State.check/2`; update `@spec` to arity-3; verify
   all existing `check/2` call sites are unaffected (default covers them).
5. Amend SPEC-CIRCUIT-BREAKER §4 B4 in the same PR.

The change can be landed as a single PR with no prerequisite from other
subproblems.

## Open questions

- **Other callers of `bump_*/1` asserting on return value:** the proposal
  assumes these are test-only and sparse. A pre-implementation `grep` confirms
  this; if any production caller reads the return value and branches on it (not
  currently evident from the problem context), that caller must be updated.
- **`:ets.update_counter/3` multi-op atomicity:** the two-op form `[{pos, 0},
  {pos, 1}]` is documented as a single atomic call in OTP. This should be
  confirmed against the project's OTP 27.2 target before the PR is gated.
- **`State.check/3` arity change and SPEC §4 B4 wording:** the SPEC must
  distinguish "threadable with default = old behaviour" from a breaking change;
  the wording should make clear that 2-arity call sites continue to work.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Store returns pre-increment (chosen)
- `proposals/proposal-2.md` — State accepts post-increment
- `proposals/proposal-3.md` — Named converter function `State.from_bump/3`
- `proposals/proposal-4.md` — Unified `Store.bump_and_decide/3`

## Revision history

- (revision 0 — initial)
