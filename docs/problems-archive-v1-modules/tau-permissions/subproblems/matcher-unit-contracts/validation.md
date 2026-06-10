---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/6
revision_triggered: none
---

# Validation: StreamData property tests + purify PathPrefix (hybrid P2 + P3)

## Overview

The solution makes two coupled changes: (a) add a property suite
`test/tau/permissions/matchers_test.exs` covering all five matchers and
`Glob.glob_match?/2`, and (b) replace `PathPrefix.match?/4`'s
`File.cwd!/0` fallback with fail-closed `false` when `ctx[:cwd]` is
absent. Eight distinct propositions were extracted across the
Recommendation and What-changes / What-does-not-change sections.
Falsification strategies were chosen per claim from the catalog
(dependency check, integration check, edge-case enumeration,
counter-example construction, type-level check, prior-art
counter-case). Seven claims withstood; **claim 6** (no SPEC amendment
required) was **partially falsified** — narrowing its Qualifier (see
§Falsification summary). No solution or problem revision is required;
the Qualifier narrowing is recorded in place.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
The six fields below are filled explicitly per claim to counter that
variance.

### Claim 1: Property tests in a new `test/tau/permissions/matchers_test.exs` satisfy the acceptance criterion's "at least two direct property or unit tests per matcher" and "at least one property for `Glob.glob_match?/2`".

- **Claim (C):** Adding `test/tau/permissions/matchers_test.exs` with
  StreamData properties for `Always`, `Glob` (including
  `glob_match?/2`), `PathPrefix`, `Domain`, and `Regex` — two or more
  per matcher — satisfies the acceptance criterion in `problem.md`.
- **Grounds (G):**
  `docs/problems/.../matcher-unit-contracts/problem.md` lines 55-60
  state the criterion verbatim ("at least two direct property or unit
  tests pinning its `match?/4` contract"); `solution.md` line 43
  enumerates the new tests; `mix.exs` line 129 confirms
  `{:stream_data, "~> 1.1", only: [:test, :dev]}` is already a test
  dependency so no dep PR is needed.
- **Warrant (W):** A property test is strictly stronger than a unit
  test for the same input domain because it samples that domain
  randomly rather than at fixed points (StreamData generators emit
  ~100 inputs per property by default); therefore "at least one
  property" subsumes "at least one unit test". This is OTP
  non-negotiable #6 ("Properties before examples for invariant-bearing
  modules"; `.claude/rules/otp-non-negotiables.md`) applied in the
  direction the rule names.
- **Qualifier (Q):** Holds provided each per-matcher property has a
  non-degenerate generator (e.g. `string(:alphanumeric)` is acceptable
  for path/domain inputs at this layer; `constant("")` is degenerate
  and would not satisfy the spirit of the criterion). The solution's
  open question on Unicode/IDN/`..` widening is acknowledged but the
  acceptance criterion's threshold is met without it.
- **Rebuttal (R):** Would not hold if "direct test" is read narrowly
  to require examples *in addition to* properties; the acceptance
  criterion says "property or unit tests", so properties alone count.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §6
  ("Invariant-bearing modules MUST have properties before examples
  … `StreamData`"); StreamData defaults documented at
  https://hexdocs.pm/stream_data/StreamData.html (default 100 runs
  per property).

#### Falsification attempt for claim 1

- **Strategy:** dependency check.
- **Attempt:** Verified `stream_data ~> 1.1` is already in `mix.exs`
  deps (line 129) so the property suite compiles; verified
  `test/tau/permissions/` contains no file directly importing
  `Tau.Permissions.Matchers.*` today (`grep -rn
  "Tau.Permissions.Matchers\." test/` returned no matches) so the new
  file genuinely fills the gap rather than duplicating coverage.
- **Outcome:** withstood. No dependency or duplication blocker.
- **Action:** none.

### Claim 2: Replacing `PathPrefix.match?/4`'s `cwd = ctx[:cwd] || File.cwd!()` with a fail-closed `false` when `ctx[:cwd]` is `nil` is a 3-line production change.

- **Claim (C):** The production change to `PathPrefix.match?/4` fits
  within ~3 lines and is localised to one function in
  `lib/tau/permissions/matchers.ex`.
- **Grounds (G):** `lib/tau/permissions/matchers.ex:79-88` is the
  current body of `PathPrefix.match?/4`; the impure line is exactly
  line 82 (`cwd = ctx[:cwd] || File.cwd!()`). Replacing that single
  line with `case ctx[:cwd] do nil -> false; cwd -> …` reshapes lines
  82-84 only; the `tool == "*" or tool == tool_name` guard at line 80
  and the `String.starts_with?` test at line 84 stay verbatim.
- **Warrant (W):** A local pattern-match restructure that does not
  cross function or module boundaries is a closed-scope edit by
  construction; the diff size is bounded by the lines it touches.
- **Qualifier (Q):** "3-line" is the order of magnitude, not a hard
  cap; the precise diff size depends on formatting (the `case` may
  cost one extra line). Holds in all formatter outcomes within a small
  constant.
- **Rebuttal (R):** Would not hold if the change forced a cascading
  callback signature change — e.g. if `match?/4` became `match?/5`.
  It does not: the behaviour `Tau.Permissions.Matcher` (line 1 of
  `lib/tau/permissions/matcher.ex`) defines `match?/4` and the change
  preserves arity and return type (`boolean()`).
- **Backing (B):** OTP non-negotiable #2 (extensibility seams MUST be
  behaviours; pattern match on atoms and structs;
  `.claude/rules/otp-non-negotiables.md`) — preserving the behaviour
  signature is the rule licensing the bounded-edit claim.

#### Falsification attempt for claim 2

- **Strategy:** counter-example construction.
- **Attempt:** Drafted the post-change shape:
  ```
  def match?({tool, prefix}, tool_name, args, ctx) do
    if tool == "*" or tool == tool_name do
      case ctx[:cwd] do
        nil -> false
        cwd ->
          path = args["path"] || ""
          full = Path.expand(path, cwd)
          String.starts_with?(full, Path.expand(prefix, cwd))
      end
    else
      false
    end
  end
  ```
  Diff vs. current: net +3 lines (the `case` head, the `nil -> false`
  arm, and the closing `end`); body line preserved. No counter-example
  to "3-line order of magnitude" found.
- **Outcome:** withstood.
- **Action:** none.

### Claim 3: After the change, `PathPrefix.match?/4` is pure (no OS call) and fails closed.

- **Claim (C):** Post-change, `PathPrefix.match?/4` performs no OS
  call and returns `false` when `ctx[:cwd]` is absent — a
  fail-closed, deterministic contract.
- **Grounds (G):** Pre-change, `lib/tau/permissions/matchers.ex:82`
  invokes `File.cwd!/0` — the *only* OS call in
  `lib/tau/permissions/matchers.ex` (grepped the file: no other
  `File.*`, `System.*`, `:os.*`, or `Process.*` calls). Post-change,
  the `case` branch on `nil` returns `false` directly without any
  side-effecting call.
- **Warrant (W):** A function whose only side-effecting line is
  removed and whose remaining body is pure data transformation
  (`Path.expand/2`, `String.starts_with?/2`) is pure. This matches
  Hickey's "decomplecting" — removing the ambient-state dependency
  separates the matcher's policy decision from process state.
- **Qualifier (Q):** Pure modulo `Path.expand/2`'s implementation;
  `Path.expand/2` itself is documented as a pure path manipulation
  (https://hexdocs.pm/elixir/Path.html#expand/2) and makes no OS call
  when given an explicit second `cwd` argument.
- **Rebuttal (R):** Would not hold if a future change reintroduces an
  OS-state read (e.g. a `Path.absname/1` call without the explicit
  cwd argument). The property suite assertion that `match?/4` returns
  `false` on `ctx[:cwd] == nil` guards against silent regressions.
- **Backing (B):** OTP non-negotiable #8 ("Pure functions are the
  default; processes are the exception";
  `.claude/rules/otp-non-negotiables.md`); `Path.expand/2` docs at
  https://hexdocs.pm/elixir/Path.html#expand/2.

#### Falsification attempt for claim 3

- **Strategy:** edge-case enumeration over side-effect surfaces.
- **Attempt:** Enumerated possible OS interactions of the post-change
  body: (i) `Path.expand(path, cwd)` with `cwd :: String.t()` — pure
  by docs; (ii) `String.starts_with?/2` — pure; (iii) `case ctx[:cwd]`
  — pure map access. No remaining OS-state read.
- **Outcome:** withstood.
- **Action:** none.

### Claim 4: All current call sites of `Evaluator.evaluate/5` already populate `:cwd` in the ctx, so the fail-closed `nil` branch is reachable only by test or future bug, not by today's production path.

- **Claim (C):** The pre-PR audit will find every production call
  site of `Evaluator.evaluate/5` already passes `:cwd` in its ctx;
  the new fail-closed branch does not regress today's behaviour.
- **Grounds (G):** `grep -rn "Evaluator.evaluate"
  /home/brentw/src/tau/lib/` returns exactly one production call
  site: `lib/tau/session/tool_dispatch.ex:88`. Its `eval_ctx` is
  built on line 81 as `%{cwd: data.cwd, active_skill:
  data.active_skill}` — `:cwd` is always present (the
  `Tau.Session.Data` struct enforces `:cwd` as a required key:
  `lib/tau/session.ex:100` `@enforce_keys [:id, :cwd, :created_at]`).
- **Warrant (W):** A struct field declared in `@enforce_keys` cannot
  be `nil` at struct-construction time; therefore `data.cwd` is
  guaranteed non-nil for any `Tau.Session.Data` that exists, and the
  map literal `%{cwd: data.cwd, …}` always includes a non-nil
  `:cwd` key.
- **Qualifier (Q):** Holds for the current codebase as of this
  validation's audit (single production call site, struct enforces
  the key). A future call site that omits `:cwd` would silently
  trigger the fail-closed branch; the property suite catches that
  category by asserting the behaviour.
- **Rebuttal (R):** `@enforce_keys` does not prevent later
  assignment to `nil` via `%{data | cwd: nil}`. Grepping `lib/`
  found no such assignment; the rebuttal is hypothetical.
- **Backing (B):** Elixir `@enforce_keys` docs at
  https://hexdocs.pm/elixir/Module.html#module-enforce_keys; struct
  definition at `lib/tau/session.ex:100-101`.

#### Falsification attempt for claim 4

- **Strategy:** integration check (boundary enumeration).
- **Attempt:** Enumerated every `Evaluator.evaluate` call in `lib/`
  (one hit, `tool_dispatch.ex:88`); traced the `eval_ctx` construction
  to line 81; verified `:cwd` key is unconditionally present; verified
  `@enforce_keys` guarantees `data.cwd != nil` at struct creation.
- **Outcome:** withstood.
- **Action:** none. The solution's "Open question — call-site audit
  scope" is resolved in favour of no widening.

### Claim 5: The hybrid of P2 + P3 is strictly stronger than either alone and subsumes P1; P4 is over-engineered.

- **Claim (C):** The hybrid is the best fit across the four
  proposals because P1 is example-only (weaker than properties), P2
  alone leaves the impurity, P3 alone meets only the minimum bar,
  and P4 introduces a module extraction with zero current external
  callers.
- **Grounds (G):** `solution.md` scoring table (lines 25-39) records
  P1 as "Partially / Surface", P2 as "Yes / Substantial", P3 as
  "Yes / Deep", P4 as "Partially / Substantial". The hybrid covers
  P2's column (property suite) AND P3's column (purification) — by
  inspection, no column is worse than either parent. `grep -rn
  "glob_match?\|Matchers.Glob" /home/brentw/src/tau/lib` confirms
  exactly one caller of `Glob.glob_match?/2`
  (`lib/tau/permissions/matchers.ex` itself) and one caller of the
  `Glob` module (`lib/tau/permissions/parser.ex:67`), making P4's
  extraction premature.
- **Warrant (W):** When two proposals modify orthogonal axes (P2
  modifies tests only; P3 modifies production only) and neither
  regresses the other's axis, their union dominates each alone. The
  YAGNI rule (Hickey: "Decomplect; don't add structure to satisfy
  imagined needs") rejects P4's extraction.
- **Qualifier (Q):** "Strictly stronger" holds against the
  acceptance criterion as written; a stricter criterion that
  demanded example coverage in addition to properties (P1 + P2)
  would change the calculus, but the criterion does not so demand.
- **Rebuttal (R):** Would not hold if P2's properties exercised the
  pre-fix `File.cwd!/0` path in a way that broke when P3 lands — but
  the properties as specified pass `ctx[:cwd]` explicitly, so they
  exercise the post-fix path.
- **Backing (B):** Hickey, "Simple Made Easy" (2011) — decomplecting
  via removal of state, not via additional structure
  (https://www.youtube.com/watch?v=SxdOUGdseq4); YAGNI in
  XP/Beck (https://martinfowler.com/bliki/Yagni.html).

#### Falsification attempt for claim 5

- **Strategy:** prior-art counter-case.
- **Attempt:** Searched for known cases where a "test-only + tiny
  production fix" hybrid produced worse outcomes than either alone.
  The risk pattern in the literature is "hidden coupling" — the test
  encodes the impurity and locks it in. The hybrid does the opposite:
  it removes the impurity in the same PR as the test, so the test
  encodes the *post-fix* contract. No counter-case applies.
- **Outcome:** withstood.
- **Action:** none.

### Claim 6: No SPEC amendment is required because the change is "test-only plus a 3-line production fix with no new public API surface".

- **Claim (C):** `solution.md` line 55 asserts that no SPEC
  amendment is required for this PR.
- **Grounds (G):** `solution.md` line 55; `lib/tau/permissions/`
  contains no `SPEC-MATCHERS.md` reference in
  `.claude/rules/spec-before-code.md`'s catalog;
  `.claude/rules/spec-before-code.md` lists
  `SPEC-PERMISSION-PROMPTS.md` as the relevant spec but its
  mandatory scope is limited to `lib/tau/session.ex` (the permission
  gate), `lib/tau/session/events.ex` (the `%PermissionRequest{}`
  struct), and `lib/tau/cli.ex` (the `interactive:` opt). The PR
  touches neither.
- **Warrant (W):** `spec-before-code.md` says a PR is in scope of a
  SPEC if it "touches any file the SPEC's source-map (Appendix B)
  names, OR it changes a boundary contract (§4), OR it introduces
  new state at any boundary the spec lists." The PR touches none of
  `SPEC-PERMISSION-PROMPTS`'s listed files.
- **Qualifier (Q):** Holds provided the contract change in
  `PathPrefix.match?/4` (the behaviour change from "fallback to
  `File.cwd!`" to "fail closed") is NOT considered a boundary
  contract under SPEC-PERMISSION-PROMPTS §4. The validator is
  partially uncertain on this point (see falsification).
- **Rebuttal (R):** If the behaviour change shifts an `:allow` verdict
  to `:deny` (or vice versa) for any historical input, that is
  observably a permission-decision change. The pre-fix branch was
  reached only when `ctx[:cwd] == nil`; this validator confirmed
  (claim 4) that production never passes `nil`, so production
  permission verdicts are unchanged. Tests that previously relied on
  the implicit `File.cwd!/0` fallback would change; the new property
  suite makes the post-fix contract explicit.
- **Backing (B):** `.claude/rules/spec-before-code.md` §"What this
  rule requires"; `docs/spec/SPEC-PERMISSION-PROMPTS.md` §"Source
  map".

#### Falsification attempt for claim 6

- **Strategy:** edge-case enumeration over `spec-before-code.md`'s
  three trigger conditions.
- **Attempt:** Iterated the three triggers: (i) source-map files
  touched — `lib/tau/permissions/matchers.ex` is NOT in
  SPEC-PERMISSION-PROMPTS's source map; (ii) boundary contract
  change — the matcher's `match?/4` callback IS part of a behaviour
  contract (`Tau.Permissions.Matcher`), and altering the implicit
  semantics for `nil` `:cwd` IS a contract change at the matcher
  boundary (even if no callable signature changes); (iii) new state
  at a boundary — no new state. Trigger (ii) raises a non-trivial
  question: does
  `Tau.Permissions.Matcher` have a SPEC? It does not appear in the
  catalog at all, so no SPEC owns it. The "no SPEC amendment"
  conclusion holds for the existing catalog, but a more precise
  framing is needed.
- **Outcome:** **partially falsified**. The original claim is too
  strong as written ("no new public API surface" elides the fact
  that the implicit-vs-explicit semantics of `nil` `:cwd` IS a
  contract refinement at the `Tau.Permissions.Matcher` behaviour
  level — there just happens to be no SPEC that codifies it today).
- **Action:** narrow the Qualifier in place. Narrowed claim: "No
  amendment to any existing `docs/spec/SPEC-*.md` is required
  because no SPEC currently owns `Tau.Permissions.Matcher`. The
  PR's moduledoc update to `PathPrefix` documents the contract
  refinement; that documentation suffices in the absence of a
  matcher SPEC." Solution revision is NOT needed — the narrowed
  conclusion is the same operational decision (no SPEC PR), and
  the moduledoc update is already in `solution.md`'s What-changes
  list (line 45).

### Claim 7: The existing `test/tau/permissions/evaluator_test.exs` indirect coverage is preserved.

- **Claim (C):** Adding the new matchers test file does not remove
  the existing indirect coverage in `evaluator_test.exs`.
- **Grounds (G):** `solution.md` line 52 ("`test/tau/permissions/
  evaluator_test.exs` — existing indirect coverage is not removed");
  `What does not change` list explicitly preserves it. New file
  addition does not modify existing files.
- **Warrant (W):** Creating a new test file is an additive operation
  in Mix's test runner; it cannot delete or skip an existing file
  unless `mix.exs`'s `test_paths`/`test_pattern` is changed (the
  solution does not change `mix.exs`).
- **Qualifier (Q):** Universal for `mix test`'s default file
  discovery semantics.
- **Rebuttal (R):** Would not hold if the new file shadowed
  `evaluator_test.exs`'s module name; ExUnit would warn on duplicate
  module names. The proposed file name (`MatchersTest`) does not
  collide with `EvaluatorTest`.
- **Backing (B):** Mix test discovery docs
  (https://hexdocs.pm/mix/Mix.Tasks.Test.html); ExUnit module
  naming conventions.

#### Falsification attempt for claim 7

- **Strategy:** counter-example construction (module-name collision).
- **Attempt:** Verified `EvaluatorTest` module names current
  `Tau.Permissions.EvaluatorTest`; the new file is
  `Tau.Permissions.MatchersTest`. No collision.
- **Outcome:** withstood.
- **Action:** none.

### Claim 8: `Tau.Permissions.Matchers.Glob.glob_match?/2` remains a public function on its current module (no extraction, no rename); the property tests call it directly.

- **Claim (C):** The property suite invokes `glob_match?/2` directly
  on `Tau.Permissions.Matchers.Glob`; no module extraction or rename
  is proposed.
- **Grounds (G):** `solution.md` line 53; `lib/tau/permissions/
  matchers.ex:42` declares `@spec glob_match?(String.t(), String.t())
  :: boolean()` and line 43 defines it as `def`. The function is
  already public — no API change is needed to test it directly.
- **Warrant (W):** A `def`-declared function in Elixir is callable
  by any external module by definition
  (https://hexdocs.pm/elixir/Kernel.html#def/2); therefore a test
  in another module can call it without any production change.
- **Qualifier (Q):** Universal — `def` is public.
- **Rebuttal (R):** None. The function would have to be `defp` to
  block this approach; it is `def`.
- **Backing (B):** Elixir Kernel docs
  (https://hexdocs.pm/elixir/Kernel.html#def/2).

#### Falsification attempt for claim 8

- **Strategy:** type-level check (visibility).
- **Attempt:** Inspected `lib/tau/permissions/matchers.ex:43`; the
  declaration is `def glob_match?` not `defp glob_match?`. Direct
  external call is permitted.
- **Outcome:** withstood.
- **Action:** none.

## Cross-claim consistency

Claims are mutually consistent:

- Claims 1 (property suite satisfies criterion), 2 (3-line fix), 3
  (post-fix purity), and 8 (`glob_match?/2` is callable directly)
  jointly describe the deliverable: tests + small production fix +
  no API change.
- Claim 4 (call sites already pass `:cwd`) and claim 3 (post-fix
  purity) together guarantee no production behaviour change today.
- Claim 5 (hybrid dominance) ratifies the selection rationale and is
  internally consistent with the proposal scoring table.
- Claim 6 (narrowed: no SPEC amendment because no SPEC currently
  owns `Tau.Permissions.Matcher`) is consistent with claim 2's
  bounded edit — both depend on the matcher behaviour being a tacit
  contract rather than a codified SPEC §4 surface.
- Claim 7 (existing coverage preserved) is consistent with the
  additive nature of all other claims.

No tension requires resolution.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Property suite meets the acceptance criterion | dependency check | withstood | none |
| 2 | `PathPrefix` fix is a 3-line change | counter-example construction | withstood | none |
| 3 | Post-fix `PathPrefix.match?/4` is pure and fail-closed | edge-case enumeration | withstood | none |
| 4 | All current `Evaluator.evaluate/5` callers pass `:cwd` | integration check | withstood | none |
| 5 | Hybrid P2+P3 dominates P1, P2, P3, P4 individually | prior-art counter-case | withstood | none |
| 6 | No SPEC amendment required | edge-case enumeration | partially falsified | narrow Qualifier in place |
| 7 | Existing `evaluator_test.exs` coverage preserved | counter-example construction | withstood | none |
| 8 | `glob_match?/2` is testable as-is (public function) | type-level check | withstood | none |

## Revision required

No solution or problem revision is required. The single partial
falsification (claim 6) is handled by a Qualifier narrowing recorded
in place; the operational decision (no SPEC PR; ship the moduledoc
update) is unchanged.

- **Target file:** none
- **Revision kind:** in-place Qualifier narrowing on claim 6
- **Rationale:** The narrowed claim ("no SPEC amendment because no
  SPEC currently owns `Tau.Permissions.Matcher`; the PR's moduledoc
  update documents the contract refinement") produces the same
  observable PR scope as the original. Triggering a full solution
  revision over a precision-of-framing issue would be
  pre-emptive-over-narrowing in reverse — it would block on a
  semantic-only correction.

## Outstanding doubts

- Whether `Tau.Permissions.Matcher` *should* have a SPEC of its own
  is outside this node's scope but is a candidate for a future spec
  catalog entry. Recording here so the parent node's validator can
  surface it.
- The solution's open question on Unicode/IDN generator widening
  remains a real follow-up but does not block the acceptance
  criterion. The parent validator inherits this doubt.
- A future change that introduces a second production call site of
  `Evaluator.evaluate/5` MUST populate `:cwd` or it will silently
  fail closed under the post-fix `PathPrefix`. The property suite
  documents this contract; consider whether a behaviour-level
  assertion (e.g. `@callback match?/4` with a `@spec` comment
  requiring `:cwd`) is warranted (also outside this node's scope).
