---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-2.md, proposals/proposal-4.md]
selection_method: hybrid
revision: 0
---

# Solution: Extract mode policy to ModePolicy module + pin D-NNN invariant in SPEC

## Recommendation

Introduce `Tau.Permissions.ModePolicy` (Proposal 2's data-structure extraction)
to hold the per-mode allow-sets as inspectable, compile-time values, replacing
the six `defp default_for_mode/3` pattern-match clauses with a single delegation.
Simultaneously, add a D-NNN invariant entry to `SPEC-PERMISSION-PROMPTS.md`
(Proposal 4's spec-anchoring step) that formally names the contract, cites
ADR-0014/ADR-0015, and declares the property tests as its enforcement mechanism.
The property tests live in `mode_policy_test.exs` and target `ModePolicy.default/3`
directly; they satisfy the acceptance criterion and become the machine-checkable
proof the D-NNN entry requires. This hybrid gives the structural decomplecting
Proposal 2 provides (two-mechanism evaluator → one-mechanism evaluator) plus
the durable gate Proposal 4 provides (spec-gated D-NNN that future PRs must
cite under `spec-before-code.md`).

## Selected from

- **Chosen:** hybrid of `proposals/proposal-2.md` + `proposals/proposal-4.md`
- **Why chosen:** Proposal 1 and Proposal 4 both meet the acceptance criterion
  with minimal code change, but neither removes the structural complecting: the
  secondary allow-list remains as six `defp` clauses. The acceptance criterion
  is satisfiable at the lowest cost (Proposals 1/4) but the Hickey-aligned lean
  toward *decomplecting depth over cost* and *composition over aggregation*
  tips the balance: Proposal 2's `ModePolicy` data structure extracts *what the
  policy is* from *when and how it is applied*, making the allow-sets
  inspectable values rather than implicit pattern-match artefacts. Proposal 3
  goes deeper (eliminating `default_for_mode/3` entirely by folding mode
  defaults into the rule-set) but at disproportionate cost and risk: it requires
  extending `Matchers.Always` with a `{:only, tool}` form (semantic scope
  violation — `Always` should be unconditional), introduces a new
  `BashDestructive` matcher module, and changes the `evaluate/5` call signature
  in a way that is API-breaking for callers. Proposal 3 is the right structural
  direction for a future refactoring milestone but is too invasive relative to
  what the acceptance criterion demands. Proposal 2 decomplects sufficiently
  without those costs. Proposal 4's D-NNN pin is the correct durable anchor for
  this project's spec-gating discipline; a moduledoc (Proposal 1's primary
  artefact) can drift from the spec silently, whereas a D-NNN is a gate trigger.
  Combining Proposals 2 and 4 gives: structural extraction (2) + durable gate
  (4) at medium migration cost and low risk — the best composition on the
  relevant axes.

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Yes | Surface | Low | Low | Easy |
| 2 | Yes | Substantial | Medium | Low | Easy |
| 3 | Yes | Deep | High | Medium | Hard |
| 4 | Yes | Surface | Low | Low | Easy |

## What changes

- **New file** `lib/tau/permissions/mode_policy.ex`: `Tau.Permissions.ModePolicy`
  module with `@policies` compile-time map, `%ModePolicy{}` struct
  (`allow_set`, `default_outcome`, `bash_heuristic?`), `default/3`, and
  `for_mode/1`. Resolve the `allow_set: :all` type anomaly for `:bypass` by
  using `allow_set: :all` as a tagged union value with a dedicated `cond` arm
  rather than `[String.t()]`.
- **`lib/tau/permissions/evaluator.ex`**: replace all six `defp default_for_mode`
  clauses with a single-clause delegation to `ModePolicy.default/3`.
- **New file (or addition to `evaluator_test.exs`)** `test/tau/permissions/mode_policy_test.exs`:
  StreamData properties targeting `ModePolicy.default/3` directly: `:plan` denies
  outside allow-set; `:dont_ask` denies all; `:auto` never allows outside
  allow-set; `:accept_edits` non-Bash non-allowed tools yield `:ask`.
- **`docs/spec/SPEC-PERMISSION-PROMPTS.md`**: add one D-NNN invariant entry
  (next available number in D-090..D-099 block, confirmed free by repo grep)
  stating the `ModePolicy` contract, the allow-set table, ADR-0014/0015
  citations, `"Agent"` exemption rationale, and the `:accept_edits` Bash
  exception. Name `mode_policy_test.exs` as enforcement.

## What does not change

- `evaluate/5` public signature — unchanged; callers are unaffected.
- The evaluator's rule-set scan logic and priority order (deny → skill gate →
  bypass → allow/ask → mode default) — unchanged in semantics; `default_for_mode/3`
  still exists as a concept, now delegating to `ModePolicy`.
- `Tau.Permissions.Matchers.Always` — no `{:only, tool}` extension required
  (that was Proposal 3's dependency; not taken here).
- No new matcher modules required.
- Existing `EvaluatorTest` integration examples — unchanged; end-to-end paths
  are exercised as before.
- `Tau.Permissions.RuleSet` — no changes to `get/0` or rule compilation.

## Migration sketch

1. Introduce `lib/tau/permissions/mode_policy.ex` with `@policies` map and
   `ModePolicy.default/3`. All existing behaviour is preserved; no callers change.
2. In `evaluator.ex`, replace the six `defp default_for_mode` clauses with
   `defp default_for_mode(mode, tool, args), do: ModePolicy.default(mode, tool, args)`.
   Run `mix test` — all existing examples must pass unchanged.
3. Add `mode_policy_test.exs` with the StreamData properties. Run
   `mix test --only property` to confirm they pass.
4. Add the D-NNN entry to `SPEC-PERMISSION-PROMPTS.md` referencing the test file
   path. Confirm D-NNN is free (`grep -rn D-0XX lib test docs .claude`).
5. One PR; `Closes #<issue>`.

## Open questions

- **D-NNN identifier:** the next free slot in D-090..D-099 must be confirmed
  by repo grep before the PR is filed; the sketch uses a placeholder.
- **`allow_set: :all` type:** the tagged union for `:bypass` in `%ModePolicy{}`
  needs an explicit type annotation (`[String.t()] | :all`) or a separate
  `bypass_policy` field to satisfy Dialyzer; the implementer should choose one.
- **Test file location:** `mode_policy_test.exs` versus a `describe` block in
  `evaluator_test.exs`. Either satisfies the acceptance criterion; the D-NNN
  enforcement line should name whichever path is chosen.
- **Proposal 3 deferred:** the deeper structural fix (mode defaults compiled into
  rule-set triples) is the correct long-term direction. It should be filed as a
  follow-up issue against the same spec once the `:accept_edits` Bash matcher
  design is settled.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Document and property-test in-place (moduledoc + StreamData; no structural change)
- `proposals/proposal-2.md` — Extract to ModePolicy data structure (structural decomplecting; **selected as primary**)
- `proposals/proposal-3.md` — Compile mode defaults into rule-set (deep decomplecting; high cost/risk; deferred)
- `proposals/proposal-4.md` — Pin D-NNN invariant in SPEC + narrow property tests (**selected as spec-anchor component**)

## Revision history

- (revision 0 — initial)
