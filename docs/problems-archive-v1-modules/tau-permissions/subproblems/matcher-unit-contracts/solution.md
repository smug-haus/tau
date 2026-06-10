---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from:
  - proposals/proposal-2.md
  - proposals/proposal-3.md
selection_method: hybrid
revision: 0
---

# Solution: StreamData property tests + purify PathPrefix (hybrid P2 + P3)

## Recommendation

Add `test/tau/permissions/matchers_test.exs` with StreamData property tests for all five matchers and `Glob.glob_match?/2` (from Proposal 2), and simultaneously replace `PathPrefix.match?/4`'s `File.cwd!/0` fallback with fail-closed `false` when `ctx[:cwd]` is absent (from Proposal 3). The property suite is the primary deliverable; the `PathPrefix` purification is a 3-line production change that makes the suite's assertions about purity true rather than aspirational. Both changes ship in the same PR. The `@note` documentation path (Proposals 1 and 3's fallback) is abandoned: a known deviation should be fixed, not documented.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-2.md` + `proposals/proposal-3.md`
- **Why chosen:** Proposal 2 satisfies the acceptance criterion's "at least one property" requirement with properties that explore orders of magnitude more input space than Proposal 1's examples, and honours OTP non-negotiable #6 at the spirit level. Proposal 3 takes the decomplecting step that Proposal 2 defers: it removes the `File.cwd!` side-effect rather than merely documenting it. The two are strictly complementary — Proposal 2 provides the test suite; Proposal 3 provides the production fix that the property suite can then assert. Neither alone is as strong: Proposal 2 without the fix means the "absent `ctx[:cwd]`" property cannot make a deterministic claim; Proposal 3 without the full property suite meets only the minimum bar. Proposal 1 is subsumed by this hybrid (example tests are weaker than properties; documentation-only for the fallback is weaker than elimination). Proposal 4's extraction of `GlobMatcher` is over-engineered for zero current external callers and adds a production file to satisfy what a property test in-place already satisfies.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|---|---|---|---|---|
| 1 | Partially | Surface | Low | Low | Easy |
| 2 | Yes | Substantial | Low | Low | Easy |
| 3 | Yes | Deep | Low–Medium | Medium | Easy |
| 4 | Partially | Substantial | Medium | Low | Easy |

Notes:
- P1: "Partially" because the acceptance criterion says "at least one property" for `Glob.glob_match?/2`; P1 uses examples only. "Surface" decomplecting because the `File.cwd!` impurity remains.
- P2: "Yes" fit; "Substantial" because properties cover the input space, but impurity stays.
- P3: "Yes" fit; "Deep" because it eliminates the only impure function in the subsystem, but "Medium" risk due to the call-site audit requirement.
- P4: "Partially" because the extraction is not required by the acceptance criterion; the split adds structural change that is premature given zero external callers.

The hybrid of P2 + P3 scores "Yes / Deep / Low–Medium / Low–Medium / Easy" — the best overall profile.

## What changes

- **New file** `test/tau/permissions/matchers_test.exs`: StreamData property tests for `Always`, `Glob` (including `glob_match?/2`), `PathPrefix`, `Domain`, `Regex` — two or more properties per matcher plus boundary examples where properties are insufficient (e.g. `?`/`/` semantics documentation test).
- **`lib/tau/permissions/matchers.ex`**, `PathPrefix.match?/4`: replace `cwd = ctx[:cwd] || File.cwd!()` with a `case ctx[:cwd]` that returns `false` when `nil` (fail-closed).
- **`lib/tau/permissions/matchers.ex`**, `PathPrefix` moduledoc: update to state the now-pure contract ("when `ctx[:cwd]` is absent, returns `false`; no OS call").
- **Pre-PR audit** (not a file change, but a required step): grep all `Evaluator.evaluate/5` call sites (`lib/tau/session.ex`, `lib/tau/tui/app.ex`, any tests using `PathPrefix`-containing rule sets) to confirm `:cwd` is present in the ctx map. If any call site is missing `:cwd`, that fix lands in the same PR.

## What does not change

- `Tau.Permissions.Matcher` behaviour interface (`match?/4` signature unchanged).
- `lib/tau/permissions/matchers.ex` — all five matchers except the 3-line `PathPrefix` change.
- `test/tau/permissions/evaluator_test.exs` — existing indirect coverage is not removed.
- `Tau.Permissions.Matchers.Glob.glob_match?/2` remains a public function on its current module (no extraction, no rename); the property tests call it directly.
- `mix.exs` dependencies — `stream_data` is already present.
- No SPEC amendments required: the acceptance criterion is under `SPEC-PERMISSION-PROMPTS` but the change is test-only plus a 3-line production fix with no new public API surface.

## Migration sketch

1. Run the call-site audit for `Evaluator.evaluate/5` to confirm `:cwd` propagation. Fix any gap in the same PR before changing production code.
2. Apply the `PathPrefix.match?/4` 3-line change and update the moduledoc.
3. Add `test/tau/permissions/matchers_test.exs` with the full property suite.
4. Run `mix test test/tau/permissions/matchers_test.exs` — all green (the audit from step 1 ensures no regressions from the `PathPrefix` change).
5. Run `mix test` — full suite green.
6. The gate picks up the new tests as gating-test paths; mutation check (gate 5.3) verifies at least one property fails against the pre-fix production code.

## Open questions

- **Call-site audit scope**: does `Tau.Session` always populate `:cwd` in the ctx it passes to `Evaluator.evaluate/5`? This is the only gate-risk for the P3 component. If the answer is no, the PR must include the ctx-population fix, and the scope slightly widens.
- **Generator widening**: Proposal 2 noted that `:alphanumeric` generators miss Unicode hostnames, IDNs, and paths with `..` components. The hybrid inherits this weakness. Widening to `:utf8` or custom generators for `Domain` properties is left as a follow-up; the minimum bar of the acceptance criterion is met without it.
- **`Glob.glob_match?/2` `?`/`/` behaviour**: current implementation treats `?` as matching any single character including `/`. The property suite documents this but does not change it. If the intended contract is `?` does not match `/`, that is a separate issue.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Example-based tests + `@note` doc for `PathPrefix`. Subsumed; weaker on both property coverage and the impurity fix.
- `proposals/proposal-2.md` — StreamData property tests, no production change. Selected as the test-suite component of this hybrid.
- `proposals/proposal-3.md` — Purify `PathPrefix` + property tests. Selected as the production-fix component of this hybrid.
- `proposals/proposal-4.md` — Extract `GlobMatcher` module + properties. Rejected as premature architecture with no current second caller.

## Revision history

- (revision 0 — initial)
