---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Settings.Loader.merge/2 has no property tests for permissions-array invariants

## Statement

`Tau.Settings.Loader.merge/2` is the upstream feed for `Tau.Permissions.RuleSet`:
it deep-merges layered settings maps and concatenates `allow`, `deny`, and `ask`
arrays from each layer. The concatenation order determines which rules the
evaluator sees first, and because `Evaluator.evaluate/5` uses first-match-wins
semantics for deny and allow, merge order is a correctness-bearing contract.
`test/tau/settings/loader_test.exs` has only example tests (no properties), so
the invariants — array concatenation preserves order within each layer, repeated
merge is idempotent for map keys, and a permissions block absent from one layer
is treated as an empty list not nil — are not mechanically enforced.

## Context

- `lib/tau/settings/loader.ex`: `merge/2` (exact implementation not read;
  test evidence shows it deep-merges nested maps and concatenates list-valued
  keys like `hooks`, `extensions`, and permissions arrays).
- `test/tau/settings/loader_test.exs` line 27–31: example test showing deny
  rules from two layers concatenate correctly. No `StreamData` import; no
  `property` blocks.
- `lib/tau/permissions/rule_set.ex` line 45–48: `compile_from_settings/1`
  calls `Tau.Settings.Cache.get()` then `Tau.Permissions.Parser.compile/1`.
  The permissions block is fetched from the merged settings; if merge silently
  drops or reorders entries, `Parser.compile/1` and `Evaluator.evaluate/5`
  receive a corrupted rule-set with no observable signal at the permissions
  layer.
- `CLAUDE.md` OTP NN #6: "Invariant-bearing modules MUST have properties before
  examples." `Settings.Loader.merge/2` is named in the audit brief as one of the
  two missing property targets.

## Complecting hypothesis

`Settings.Loader.merge/2`'s permissions-array concatenation is complected with
`Evaluator`'s first-match-wins semantics because the evaluator's correctness
depends on the merge contract (layer B's deny entries appear after layer A's),
yet this contract is only expressed as two discrete example tests — not as a
property that survives arbitrary inputs, making the coupling invisible at the
test boundary.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`test/tau/settings/loader_test.exs` (or a new `property_test.exs` sibling)
contains at least two StreamData properties: one asserting that
`merge(a, b)[:permissions][:deny]` is a prefix-then-suffix concatenation of
`a[:permissions][:deny]` and `b[:permissions][:deny]` for arbitrary
list-valued permission arrays; and one asserting that merging any settings map
with an empty map is an identity (`merge(x, %{}) == x` for all map shapes that
include a permissions block).

## Out of scope

- Matcher unit tests — covered by `matcher-unit-contracts`.
- Mode-lattice properties — covered by `mode-lattice-properties`.
- Evaluator mode-dispatch complecting — covered by `evaluator-mode-complecting`.
- Settings schema validation, vault, watcher — separate subsystem.

## Amendment log

- (none yet)
