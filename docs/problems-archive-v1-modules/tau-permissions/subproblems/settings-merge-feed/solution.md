---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-2.md]
selection_method: single
revision: 0
---

# Solution: Separate property test file loader_property_test.exs

## Recommendation

Add `test/tau/settings/loader_property_test.exs` — a dedicated StreamData property
test file for `Tau.Settings.Loader.merge/2` — containing three properties: the
prefix-then-suffix concatenation invariant for all three permissions keys
simultaneously (C1), the right-identity invariant `merge(x, %{}) == x` (C2), and
the absent-key-as-empty-list invariant (C3). Use `fixed_map/1`-based named
generator helpers local to the file. Leave `loader_test.exs` untouched.

## Selected from

- **Chosen:** `proposals/proposal-2.md` (single)
- **Why chosen:** Proposal 2 directly satisfies the acceptance criterion (both
  mandated properties) while also covering C3 (the third named invariant in the
  problem statement), all in one new file that does not touch the passing example
  tests. The `fixed_map/1`-based generators are more representative of real
  settings shapes than Proposal 1's inline `map_of(atom(:alphanumeric), ...)`
  approach, and the file-level separation makes OTP NN #6 compliance discoverable
  (`grep -r "use ExUnitProperties" test/tau/settings/` yields the file
  unambiguously). Proposal 1 is almost as good on fit but its generator for the
  identity property is weaker (arbitrary atom-keyed maps rather than
  settings-shaped maps), and co-location provides no depth advantage over a
  separate file. Proposal 3 adds a `test/support/SettingsGen` module whose value
  depends on sibling sub-problems reusing it — speculative at this node and out of
  scope. Proposal 4 introduces a production `lib/` module to fix a test-coverage
  gap, which the proposal's own confidence assessment rates low and its internal
  critique identifies as cost-exceeding-severity; that assessment is correct.

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Yes | Surface             | Low            | Low  | Easy          |
| 2 | Yes | Substantial         | Low            | Low  | Easy          |
| 3 | Yes | Substantial         | Medium         | Low  | Easy          |
| 4 | Partially | Surface       | High           | Medium | Hard        |

Proposal 2 wins on decomplecting depth (three invariants, all three permission
keys tested together, sparse-key case isolated) without any cost or risk penalty
over Proposal 1. Proposal 3 would tie with 2 on depth but introduces speculative
scope; Proposal 4 is defeated on cost and risk with no offsetting gain for this
problem's scope.

## What changes

- **New file:** `test/tau/settings/loader_property_test.exs` — three property
  tests as sketched in Proposal 2, with named local generator helpers
  (`permission_list/0`, `permissions_layer/0`, `settings_with_permissions/0`).
  Module: `Tau.Settings.LoaderPropertyTest`.

## What does not change

- `test/tau/settings/loader_test.exs` — untouched; all existing example tests
  continue to pass.
- `lib/tau/settings/loader.ex` — no production changes.
- `mix.exs` — `stream_data` already present; no dependency changes.
- `test/support/` — no new support modules added.

## Migration sketch

Single PR: create `test/tau/settings/loader_property_test.exs`. Run
`mix test test/tau/settings/loader_property_test.exs` to confirm all three
properties pass. Run `mix test test/tau/settings/` to confirm no regression in
`loader_test.exs`. The file is self-contained; no caller updates needed. If any
property fails, it is a signal that `Loader.merge/2` violates an invariant the
problem statement assumed was already correct — that failure is itself the value.

## Open questions

- Does `Loader.merge/2` currently satisfy C3 (absent key returns a list, not nil)?
  The problem statement asserts it "concatenates `allow`, `deny`, and `ask` arrays
  from each layer" but does not say what happens when a key is absent in one layer.
  If the property fails on the real implementation, the implementer must fix
  `Loader.merge/2` or narrow the property to match actual behaviour and file a
  follow-up. This is the intended outcome — the property test should surface the
  gap, not assume it is already closed.
- Proposal 2's `settings_with_permissions/0` generator always produces maps with
  all three keys present. The C3 property's layer-b is hand-constructed as
  `%{permissions: %{}}`. This is correct for C3 but means the concat property
  never sees partial-key layer inputs. If `Loader.merge/2` has a partial-key bug
  that only surfaces when one layer has two of three keys, C1 will not catch it.
  This is an acceptable residual given the acceptance criterion's scope; a future
  property extension is low-effort if needed.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — In-place extension of `loader_test.exs`; weaker
  generator shape for identity property; co-location with no depth gain.
- `proposals/proposal-2.md` — Separate property file with three invariants;
  `fixed_map`-based generators; OTP NN #6 compliance discoverable by grep.
  **Selected.**
- `proposals/proposal-3.md` — Shared `test/support/SettingsGen` module; depth
  equivalent to P2 but with speculative-reuse overhead.
- `proposals/proposal-4.md` — Production `lib/` contract module; self-assessed
  low confidence; cost-benefit unfavorable for a test-coverage gap.

## Revision history

- (revision 0 — initial)
