---
template_version: 1
template_name: problem
node_kind: internal
depth: 0
parent: —
status: decomposed
---

# Problem: tau-settings correctness gaps across three orthogonal concerns

## Statement

`Tau.Settings` contains three distinct correctness deficits that are
currently obscured by each other: (1) the loader's cascade merge
semantics are invariant-bearing but untested by properties; (2)
`Settings.Watcher` catches `:exit` from `FileSystem.start_link/1` in
violation of OTP NN #7; (3) `Settings.Schema.to_known_module/1` uses
`rescue ArgumentError` as its primary control-flow path, coupling
exception handling to expected-case logic. None of these failures is
visible in the existing example-based test suite, which passes.

## Context

- `lib/tau/settings/loader.ex` — pure cascade merge; `merge/2` and
  `merge_value/3` carry invariants about list-key concatenation and
  map deep-merge; only 4 example tests in `test/tau/settings/loader_test.exs`.
- `lib/tau/settings/watcher.ex:69-83` — `maybe_start_watcher/1` wraps
  `FileSystem.start_link/1` in `try/rescue/catch :exit`; OTP NN #7
  forbids `catch :exit` across process boundaries.
- `lib/tau/settings/schema.ex:291-296` — `to_known_module/1` calls
  `String.to_existing_atom/1` inside a `rescue ArgumentError` block to
  detect unknown provider strings; this conflates the "not an existing
  atom" exceptional path with the normal "unknown provider" path.
- No property tests exist anywhere in `test/tau/settings/` except
  `vault/env_test.exs` (vault round-trip, unrelated to merge invariants).
- OTP NN #6 (CLAUDE.md): invariant-bearing modules MUST have properties
  before examples; Loader is explicitly named as such.
- OTP NN #7 (CLAUDE.md): MUST NOT `catch :exit`; no exception.

## Complecting hypothesis

The loader's merge logic is complected with its lack of property test
coverage because both live in the same module and the tests treat merge
as a set of coincidental examples rather than a contractual specification.

The Watcher's availability-degradation logic is complected with `:exit`
propagation from `FileSystem` — a cross-process OTP signal — by routing
both normal startup failure and abnormal exit through the same `catch`
arm.

Schema's module-resolution logic is complected with Elixir's atom-intern
exception mechanism because `ArgumentError` from
`String.to_existing_atom/1` is used as a sentinel for a domain-level
"unknown provider" result rather than being a true exceptional condition.

## Decomposition strategy

The three problems are orthogonal along the **concern** axis (Hickey):
merge-invariant coverage, OTP signal handling, exception-as-control-flow.
They share no code paths and can be analysed and remediated independently.
Each is a leaf: none requires further decomposition because the scope and
proposed fix are narrow enough for a single proposer pass.

## Sub-problems (filled by decomposer)

1. **merge-invariant-properties** — Loader cascade merge is invariant-bearing but tested only by examples; property tests are absent in violation of OTP NN #6.
2. **watcher-exit-catch** — `Settings.Watcher.maybe_start_watcher/1` catches `:exit` from `FileSystem.start_link/1`, violating OTP NN #7 (MUST NOT catch :exit across process boundaries).
3. **schema-exception-as-flow** — `Schema.to_known_module/1` uses `rescue ArgumentError` as primary control flow for the "unknown provider" domain result, conflating exceptional and normal paths.

## Acceptance criterion

All three sub-problems reach `proposed` status with candidate solutions
that, collectively, (a) eliminate the `catch :exit` site, (b) add
property tests for `Loader.merge/2`, and (c) replace the rescue-based
control flow in `to_known_module/1` with explicit conditional logic —
without breaking any currently-passing test.

## Out of scope

- `Settings.Cache` GenServer behaviour (publish/reload lifecycle — separate concern).
- `Settings.Vault` backends (credential resolution — separate concern).
- Schema JSON validation logic beyond the `to_known_module/1` control-flow issue.
- `Settings.Watcher` debounce timer logic or `relevant?/1` path filter.
- Any change to the cascade layer ordering or file path resolution in `Loader.paths/1`.

## Amendment log

- (none yet)
