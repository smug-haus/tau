---
template_version: 1
template_name: problem
node_kind: internal
depth: 0
parent: —
status: decomposed
---

# Problem: tau-permissions invariant coverage gaps and matcher/mode complecting

## Statement

The `tau-permissions` subsystem is named by CLAUDE.md OTP non-negotiable #6 as
invariant-bearing, yet four distinct coverage holes exist today: the five
concrete matcher modules have zero property tests; `Mode.clamp/2` has example
tests but its lattice properties were only recently added (present) while its
peer-rank edge cases are untested as properties; `default_for_mode/3` in the
evaluator hard-codes mode-specific tool lists that overlap with, but diverge
from, the rule-set precedence logic; and `Settings.Loader.merge/2`, the
upstream feed for the rule-set, has no property tests asserting that the
permission arrays it concatenates remain order-stable and idempotent under
repeated merge. The problem is true today because a targeted property sweep
catches none of these holes, and a one-off breakage in any of them silently
alters user-visible permission decisions.

## Context

- `lib/tau/permissions/mode.ex` — lattice with `@ranks` map; `clamp/2`,
  `at_or_below?/2`, `rank/1`. Property tests present in
  `test/tau/permissions/mode_test.exs` covering the key invariants.
- `lib/tau/permissions/evaluator.ex` — `evaluate/5` with `default_for_mode/3`
  hard-coding per-mode tool allow-lists (`:plan`, `:auto`, `:accept_edits`).
  Tool lists (e.g. `"Agent"`) encode sub-agent delegation policy inline.
- `lib/tau/permissions/matchers.ex` — five matcher modules (`Always`, `Glob`,
  `PathPrefix`, `Domain`, `Regex`). Zero direct unit or property tests; exercised
  only indirectly through `EvaluatorTest`.
- `lib/tau/permissions/parser.ex` — compiles settings strings into
  `{decision, matcher, compiled_rule}` triples.
- `lib/tau/permissions/rule_set.ex` — GenServer; stores compiled rules in
  `:persistent_term`; subscribes to PubSub `"settings"` topic.
- `lib/tau/settings/loader.ex` — `merge/2` deep-merges layered settings; no
  property tests (`test/tau/settings/loader_test.exs` is example-only).
- ADR-0013 (skill whitelist gate), ADR-0014/0015 (mode ceiling / sub-agent
  clamp). `SPEC-PERMISSION-PROMPTS.md` §D-090..D-099.

## Complecting hypothesis

`default_for_mode/3` in `Evaluator` is complected with rule-set precedence
because it encodes a secondary tool-allowlist (e.g. `["Read","Grep","Glob","Agent"]`)
inline in the evaluator rather than deferring to the rule-set; a change to one
concern (which tools are safe in `:plan` mode) silently requires a change to the
other (the rule-set ordering contract).

`Matchers.PathPrefix.match?/4` is complected with process environment because it
calls `File.cwd!/0` as a fallback when `ctx[:cwd]` is absent, making the
pure-function contract undiscoverable: the same `(rule, tool_name, args, ctx)`
inputs produce different results under different working directories.

`Settings.Loader.merge/2`'s permissions-array concatenation is complected with
the order-dependence of `Evaluator`'s first-match logic: the merge contract
(layer B's deny entries append after layer A's) is not tested as a property,
so a merge-order regression silently changes which deny rules win.

## Decomposition strategy

Split by **concern layer**: each sub-problem maps to a distinct layer of the
pipeline — matcher unit contracts, mode-lattice properties, evaluator
mode-dispatch, and settings-merge feed — where the coupling or test gap lives
exclusively. The four concerns are disjoint in source ownership
(`matchers.ex`, `mode.ex`, `evaluator.ex`, `settings/loader.ex`) and in the
failure mode each gap exposes; none is a sub-concern of another.

## Sub-problems (filled by decomposer)

1. **matcher-unit-contracts** — The five matcher modules (`Always`, `Glob`,
   `PathPrefix`, `Domain`, `Regex`) have zero direct tests; their contracts
   (including `PathPrefix`'s impure `File.cwd!` fallback) are untested.
2. **mode-lattice-properties** — `Mode.clamp/2` has example tests; the lattice
   properties that already exist in `mode_test.exs` are good but the peer-rank
   contract (all three rank-3 modes interchangeable under clamp) is only
   spot-checked, not property-swept.
3. **evaluator-mode-complecting** — `default_for_mode/3` encodes per-mode
   tool allow-lists inline in the evaluator, complecting mode policy with
   rule-set precedence; this creates an undocumented second allow-list that
   can diverge silently.
4. **settings-merge-feed** — `Settings.Loader.merge/2` concatenates
   permissions arrays with no property tests; a merge-order regression silently
   changes which deny/allow rules win in the evaluator.

## Acceptance criterion

Every invariant-bearing function in `tau-permissions` and its upstream feed
(`Settings.Loader.merge/2`) has at least one property test asserting its
named invariant; the `PathPrefix` impure-fallback concern is documented as a
known deviation from the pure-function contract; and the evaluator's
`default_for_mode/3` tool allow-lists are structurally separated from the
rule-set precedence logic so that a change to one does not silently affect the
other.

## Out of scope

- `Tau.Permissions.RuleSet` GenServer lifecycle (PubSub subscription,
  `:persistent_term` write path) — these are infrastructure concerns, not
  invariant-bearing logic.
- `SPEC-PERMISSION-PROMPTS.md` `:awaiting_permission` FSM state and TUI dialog
  — owned by `Tau.Session` and `Tau.TUI.App`, not this subsystem.
- Parser regex syntax (the `~r/^([A-Za-z]...)\((.*)\)$/` rule-parsing regex)
  — correctness is covered by `EvaluatorTest`'s example suite; not the focus
  here.
- Settings schema validation, vault backends, watcher — separate subsystem.

## Amendment log

- (none yet)
