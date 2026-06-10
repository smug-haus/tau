---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md]
selection_method: single
revision: 0
---

# Solution: Extract `bounded_append` into `Tau.TUI.App.Model`

## Recommendation

Move `bounded_append/2`, `bounded_append_many/2`, and `@transcript_cap 500`
into `Tau.TUI.App.Model` as public functions. Delete both private copies from
`Events` and `Input`. Update all call-sites in those modules to call
`Model.bounded_append/2` and `Model.bounded_append_many/2`. The cap constant
and the ring-buffer body then exist in exactly one place — the module that
already declares the `transcript` field type and is the canonical owner of
`Model.t()` invariants.

## Selected from

- **Chosen:** `proposals/proposal-1.md`
- **Why chosen:** Proposal 1 satisfies the acceptance criterion fully — one
  canonical implementation, one `@transcript_cap`, duplication absent from
  both `Events` and `Input` — while adding no new module and no new dependency
  edge. It places the invariant in `Model`, which already owns the `transcript`
  field type and already hosts `transcript_pane_width/1` as a non-pure-struct
  helper, so there is clear existing precedent. Migration cost is the lowest of
  the three viable proposals (2 files modified to remove, 1 to add functions).

  Proposal 2 (`Transcript` sub-module) offers deeper decomplection and better
  opaque encapsulation but at materially higher cost and risk: an `@opaque`
  audit across all consumers, a new module, and a merge-conflict surface with
  the `model-as-bag-of-maps` sibling. These costs are not justified by the
  problem statement, which asks only for a single canonical home — not for a
  new abstraction boundary.

  Proposal 3 (model-update helpers) has the cleanest call-sites ("tell, don't
  ask") but carries a call-site cascade risk: any `Events` or `Input` function
  that receives only `model.transcript` as a parameter must be widened to
  accept the full `Model.t()`, which may propagate to their callers. The
  problem statement does not require hiding the field name or the type — only
  eliminating the duplication. Proposal 3 solves a broader problem than stated
  at higher cost.

  Proposal 4 (`Input` delegates to `Events`) is the smallest diff but creates
  a new sibling-module coupling (`Input → Events`) that does not currently
  exist, leaves the function architecturally misplaced in an event-dispatcher,
  and is self-rated low confidence due to the unverified circular-dependency
  risk. Even after confirming no `Events → Input` cycle exists, the coupling
  anti-pattern and wrong-home diagnosis make this the weakest choice.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Yes | Substantial | Low | Low | Easy |
| 2 | Yes | Deep | Medium | Medium | Easy |
| 3 | Yes | Substantial | Medium | Low-Medium | Easy |
| 4 | Partially | Surface | Low | Medium | Easy |

Proposal 1 is the only proposal that scores Yes on fit, Substantial on
decomplecting depth, and Low on both migration cost and risk simultaneously.

## What changes

- `lib/tau/tui/app/model.ex` — add `@transcript_cap 500`, `def bounded_append/2`
  (with `@doc` and `@spec`), and `def bounded_append_many/2` (with `@doc` and
  `@spec`).
- `lib/tau/tui/app/events.ex` — remove `@transcript_cap 500`, remove
  `defp bounded_append/2`, remove `def bounded_append/2`, remove
  `def bounded_append_many/2`; add `alias Tau.TUI.App.Model` if not already
  present; update all call-sites to `Model.bounded_append/2` and
  `Model.bounded_append_many/2`.
- `lib/tau/tui/app/input.ex` — remove `@transcript_cap 500`, remove
  `defp bounded_append/2`; add `alias Tau.TUI.App.Model`; update all
  call-sites to `Model.bounded_append/2`.

## What does not change

- The function bodies: `list ++ [item]` → `Enum.drop` semantics are preserved
  exactly.
- The cap value (500).
- The public API of `Events` for any caller using `Events.bounded_append/2`
  directly — this function is removed from `Events` (it was the source of the
  duplication), so callers must be audited; however, given the function is
  specific to internal transcript mutation, external callers are expected to be
  absent.
- `Model.t()` struct shape and field names — no field is added, renamed, or
  typed differently.
- `Tau.TUI.App.Transcript` does not exist and is not introduced.
- All sibling sub-problems (`model-as-bag-of-maps`, `session-side-effects-in-pure-modules`,
  `transcript-coupling`) are unaffected.

## Migration sketch

1. Add `@transcript_cap`, `bounded_append/2`, and `bounded_append_many/2` to
   `model.ex` with `@doc`/`@spec`. Run `mix compile`; confirm clean.
2. Update `events.ex`: add alias, replace all `bounded_append` calls with
   `Model.bounded_append`, remove the now-dead private/public definitions and
   `@transcript_cap`. Run `mix compile --warnings-as-errors`; confirm no unused
   variable or function warnings.
3. Update `input.ex` identically: add alias, replace call, remove dead code.
   Run `mix compile --warnings-as-errors`.
4. Run `mix test` — no test changes are expected because the function bodies
   are identical and the rename only changes call qualification.
5. Grep for `Events.bounded_append` across the repo to confirm no external
   caller is silently broken. One-time check; expected result: zero hits.

## Open questions

- The `if Code.ensure_loaded?(Ratatouille.Runtime)` compilation guard in
  `model.ex` wraps the module. The proposal notes this is fine for TUI use, but
  should be confirmed with `mix test` run without Ratatouille loaded (e.g. in a
  stripped CI environment) to verify the functions are reachable in all test
  contexts.
- `Events` currently exposes `bounded_append/2` as a public function with
  `@doc`/`@spec`. Removing it is a breaking API change for any external caller.
  The grep in step 5 of the migration sketch settles this; if an external caller
  exists, it should be redirected to `Model.bounded_append/2` in the same PR.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Extract into `Model` as public functions (chosen)
- `proposals/proposal-2.md` — New `Tau.TUI.App.Transcript` sub-module with
  opaque type (deeper decomplection, higher cost; not chosen)
- `proposals/proposal-3.md` — Model-update helpers (`append_transcript/2`);
  "tell, don't ask" style; call-site cascade risk (not chosen)
- `proposals/proposal-4.md` — Keep in `Events`, delegate from `Input`; sibling
  coupling anti-pattern, wrong architectural home (not chosen)

## Revision history

- (revision 0 — initial)
