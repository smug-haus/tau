---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Loader.merge/2 invariants are untested by properties

## Statement

`Tau.Settings.Loader.merge/2` and its helper `merge_value/3` encode
several cascade-merge invariants (list-key concatenation, scalar
override, recursive map merge), but the only tests are four example
cases in `loader_test.exs`. No property test exercises the algebraic
properties of the merge — commutativity is NOT expected (later-layer
wins), but associativity, idempotency of identical layers, and the
list-key concatenation contract all hold as invariants. A regression in
any of these would pass the current suite.

## Context

- `lib/tau/settings/loader.ex:36-51` — `merge/2`, `merge_value/3`, and
  `list_keys/0` implement the merge contract.
- `test/tau/settings/loader_test.exs` — four example tests: scalar
  override, deep-map merge, list concatenation, deny-rule concat. All
  pass with concrete fixtures; none exercises shrinkable generators.
- OTP NN #6 (CLAUDE.md): "Invariant-bearing modules MUST have properties
  before examples (`Permissions.Evaluator`, `Settings.Loader` merge,
  `Message.Assembler`, permission matchers — `StreamData`)."
  `Settings.Loader` is named explicitly.
- `test/tau/settings/vault/env_test.exs` — shows the project already
  uses `StreamData` and `ExUnitProperties` in the settings test tree;
  the tooling is available.
- List keys: `[:hooks, :extensions, :mcp, :allow, :deny, :ask,
  :permissions]` (loader.ex:88-96).

## Complecting hypothesis

The merge-invariant specification is complected with its test coverage
because the module embeds the invariants in implementation code but
documents them only via coincidental examples, making it impossible to
tell which properties are contractual vs incidental.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`test/tau/settings/loader_test.exs` (or a sibling `loader_property_test.exs`)
contains at least one `property/2` block using `StreamData` generators that
exercises the associativity of three-layer merge, the list-key
concatenation contract under arbitrary list inputs, and the scalar
override invariant — and `mix test --only property` passes for these
tests.

## Out of scope

- `Loader.load/1` file I/O and source-tracking (watcher/cache concern).
- `Loader.paths/1` path computation.
- Any change to which keys are in `list_keys/0`.
- `Settings.Watcher` or `Settings.Cache` behaviour (sibling problems).
- Schema validation or `to_known_module/1` logic (sibling problem).

## Amendment log

- (none yet)
