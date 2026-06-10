---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: matcher modules have no direct unit or property tests

## Statement

The five concrete matcher modules in `lib/tau/permissions/matchers.ex`
(`Always`, `Glob`, `PathPrefix`, `Domain`, `Regex`) have zero direct unit or
property tests; they are exercised only indirectly through `EvaluatorTest`.
This means boundary conditions — empty args, wildcard tool name `"*"`,
`PathPrefix` when `ctx[:cwd]` is absent, `Glob.glob_match?/2` edge cases,
`Domain` subdomain matching — are not contractually pinned, and a silent
regression in any matcher changes permission decisions without a failing test.

## Context

- `lib/tau/permissions/matchers.ex` — all five matchers, one file.
- `Tau.Permissions.Matcher` behaviour: `match?/4` — the only public callback.
- `PathPrefix.match?/4` line 82: `cwd = ctx[:cwd] || File.cwd!()` — impure
  fallback when `ctx[:cwd]` is absent; this is the only place in the subsystem
  where a nominally-pure function makes an OS call.
- `Glob.glob_match?/2` is a public function (used by the module's `match?/4`
  and potentially by other callers) but has no direct tests.
- `test/tau/permissions/evaluator_test.exs` exercises matchers indirectly via
  `Parser.compile/1 + Evaluator.evaluate/5`; no file under
  `test/tau/permissions/` directly imports a `Matchers.*` module.
- `Domain` matcher relies on `URI.parse/1`; subdomain matching (`host == domain
  or String.ends_with?(host, "." <> domain)`) has no property covering arbitrary
  hostnames.

## Complecting hypothesis

`PathPrefix.match?/4` is complected with process environment because it
calls `File.cwd!/0` when `ctx[:cwd]` is absent, making its contract
non-deterministic under different OS working directories — a pure function
should not read ambient state.

`Glob.glob_match?/2` is complected with its caller's responsibility because the
function is public but untested at the unit level, so callers cannot reason
about its contract (e.g. does `*` match the empty string? does `?` match `/`?)
without reading its implementation.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

Each matcher module has at least two direct property or unit tests pinning its
`match?/4` contract for valid and boundary inputs; `Glob.glob_match?/2` has at
least one property; the `PathPrefix` `File.cwd!` fallback is either replaced
with a ctx-driven default (pure) or its non-determinism is documented in a
`@note` in the moduledoc.

## Out of scope

- `Tau.Permissions.Parser` — the string-to-matcher compilation logic is tested
  indirectly and is not a matcher-unit concern.
- `Evaluator.evaluate/5` — covered by the `evaluator-mode-complecting`
  sub-problem.
- Mode lattice properties — covered by `mode-lattice-properties`.
- `Settings.Loader.merge/2` — covered by `settings-merge-feed`.

## Amendment log

- (none yet)
