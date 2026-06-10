---
template_version: 1
template_name: validation
parent_solution: ./solution.md
parent_problem: ./problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/7
revision_triggered: none
---

# Validation: four-workstream composition makes `Tau.Provider` enforce or honestly document every observable adapter divergence

## Overview

The root solution is a *synthesis* of four child solutions. To avoid
re-litigating per-child claims (each child has its own `validation.md`
on file), this validation focuses on the **cross-cutting integration
claims** the synthesis newly asserts at the parent level: workstream
composability, the conjunction satisfaction of the module-level
acceptance criterion AC-M1, the disjoint-files / shared-file-region
parallelisability of the four PRs, and the "every observable adapter
divergence currently present is covered" coverage claim. Ten claims
are enumerated and run through full six-field Toulmin with a named
falsification strategy each. Falsification strategies span
counter-example construction, edge-case enumeration, integration
check, dependency check, and type-level check. Outcome: nine claims
withstand; claim 7 ("every observable adapter divergence currently
present across the eleven adapters" is enforced or honestly
documented) is **partially falsified** by counter-example construction
— the live-decode-path defects for Bedrock and Gemini (missing
`TextStart`/`TextEnd` synthesis, atomic `ToolCallDelta` batching) are
*declared* via `stream_contract/0` but **not fixed** in this scope;
the parent solution itself acknowledges this under §What does not
change and §Open questions. The qualifier on claim 7 is narrowed in
place: "enforced or *declared* (declaration-only for two named
deferrals)". No revision to `solution.md` or `problem.md` is
triggered.

This validation also **inherits** the child validators' partial
falsifications and outstanding doubts; they are listed under §Inherited
qualifiers from child validations so the parent-level discharge of
AC-M1 carries them forward into its own Qualifier fields where
relevant.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism warns that participants
"found it difficult to generate Toulmin structures, and their
structures varied greatly even though they started with the same
content"
(<https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument>).
Each of the six fields is filled explicitly below to counter that
variance.

### Claim 1: The four workstreams' recommendations compose directly — none retracts or constrains another.

- **Claim (C):** "their recommendations compose directly — none
  retracts or constrains another, and the file-touch sets are nearly
  disjoint" (solution.md §"Composition rationale").
- **Grounds (G):** The file-touch table in solution.md L59–64
  enumerates each workstream's targets. Workstream A touches
  `lib/tau/providers/*.ex` (six adapters' `vault_key/0` helpers) +
  one new `lib/tau/providers/auth.ex` + one ADR + two tests, and does
  NOT touch `lib/tau/provider.ex`. Workstream B touches
  `lib/tau/provider/event.ex` (the `Event` union, distinct file from
  `provider.ex`), three adapter wire files, plus new modules and
  tests. Workstream C touches `@doc`/`@typedoc` on
  `capabilities/0` in `lib/tau/provider.ex` (lines 58–70), three
  adapters' `capabilities/0` return values, one new Mix task, one
  ci.yml line. Workstream D touches the new `@callback
  stream_contract/0` in `lib/tau/provider.ex` (a new region appended
  after L131's `@optional_callbacks`), all eleven adapters'
  `stream_contract/0` implementations, one new struct file. **No two
  workstreams modify the same adapter `capabilities/0` body, the
  same `vault_key/0` helper, the same wire file, or the same
  `provider.ex` region.**
- **Warrant (W):** Two PRs that touch strictly disjoint files (or
  disjoint stable regions of a shared file) compose by source-control
  3-way merge without semantic conflict — the merge result is the
  union of each diff applied to the base. The factory-loop's parallel
  execution conflict check (`.claude/rules/factory-loop.md` §"The
  conflict check" clauses 2–3) is the canonical operational
  formalisation of this principle for the project.
- **Qualifier (Q):** Holds for the file-touch table as written. The
  three workstreams that touch `lib/tau/provider.ex` (B, C, D) edit
  *different* regions of that file but trigger the factory-loop
  freshness re-check (cycle step 8a) when scheduled concurrently —
  i.e., a textual rebase is needed but no merge conflict arises.
- **Rebuttal (R):** Does NOT hold if one workstream's implementer
  silently extends scope into another's region (e.g., the
  Workstream-B1 author "while I'm here" also edits the `@callback
  capabilities/0` docstring). The factory-loop's PR-scope guard
  forbids this and the critic gate is supposed to flag scope creep,
  but the validator cannot guarantee implementer discipline.
- **Backing (B):** `.claude/rules/factory-loop.md` §"Parallel
  execution" clause 2 ("Disjoint files") and clause 3 ("Disjoint
  codepoints"); `.claude/rules/factory-loop.md` §"PR scope guards"
  ("Declared, frozen scope").

#### Falsification attempt for claim 1

- **Strategy:** Edge-case enumeration over the four pairs of
  workstreams that could conflict (A×B, A×C, A×D, B×C, B×D, C×D —
  six pairs).
- **Attempt:** A×B: A edits `vault_key/0`/`api_key/0` helpers; B
  edits adapter `decode/2` (Bedrock, Gemini) and shared
  `openai_chat_wire.ex` decode functions. Disjoint functions in
  potentially the same file (Gemini and Bedrock are touched by both,
  but at distinct function definitions). Verified by inspecting
  `lib/tau/providers/bedrock.ex` (api_key resolution is at the top of
  the module; `decode_anthropic_event/2` is at line 111+) and
  `lib/tau/providers/gemini.ex` (api_key at line 172; decode at line
  95+). No function overlap. A×C: A touches no `capabilities/0`
  return-value lines; C touches no `vault_key/0` lines. Disjoint.
  A×D: A adds no `stream_contract/0` implementations; D adds one per
  adapter. Disjoint. B×C: B touches `event.ex`, `openai_chat_wire`,
  `bedrock.ex`/`gemini.ex` decode paths; C touches `@doc` on
  `provider.ex` and `capabilities/0` bodies on three adapters.
  Disjoint regions in shared adapter files. B×D: B touches event
  union and adapter decode paths; D adds the `stream_contract/0`
  callback declaration and one per-adapter implementation. The
  Bedrock and Gemini adapter files are touched by both, but at
  distinct function definitions. C×D: both touch `lib/tau/provider.ex`
  but at distinct regions — C edits L58–70 (`capabilities/0` doc) +
  L131 area; D appends a new `@callback` block after L131. Distinct
  textual regions. **All six pairs are file-or-region disjoint.**
- **Outcome:** withstood.
- **Action:** none.

### Claim 2: Three enforcement mechanisms (type-level, CI-gate, documentation) compose intentionally and each layer covers what the previous cannot.

- **Claim (C):** "Three forms of enforcement compose intentionally.
  Type-level enforcement … catches the 'absent implementation'
  failure mode at compile time. CI-gate enforcement catches the
  'declared but unimplemented' failure mode … Documentation … closes
  the residual case where a flag's obligations span too many callsites
  to localise mechanically. Each layer covers what the previous layer
  cannot — composition, not redundancy." (solution.md §"Composition
  rationale" L79–84).
- **Grounds (G):** Type-level: `%Event.Usage{}` with
  `@enforce_keys [:input_tokens, :output_tokens]` (Workstream B); the
  mandatory `stream_contract/0` callback (Workstream D) producing a
  compile warning if any adapter omits it (made fatal by
  `mix compile --warnings-as-errors`). CI-gate:
  `mix tau.gate.capabilities` enforcing
  `prompt_caching == true ⇔ function_exported?(mod, :cache_regions, 2)`
  (Workstream C); `mix tau.conformance` iterating
  `Tau.Test.ProviderConformance` per adapter (Workstream B PR-B3).
  Documentation: `@doc`/`@typedoc` on `capabilities/0`
  (Workstream C), the `@stream_contract` module attribute prose
  (Workstream D), `ADR-00XX-auth-resolution-policy.md` (Workstream A),
  and the cross-workstream `docs/PROVIDER-CONTRACT.md` index. The
  child `capabilities-flag-fidelity/validation.md` confirms (Claim 4
  partial-falsification) that `thinking: true` enforcement has no
  equivalent single-callback target — obligations span `build_body/3`
  and the decode path — so documentation is the only remaining
  enforcement layer for `thinking`.
- **Warrant (W):** Defence-in-depth across orthogonal mechanisms is
  the canonical pattern when no single mechanism covers the full
  failure surface. The three mechanisms here are orthogonal because
  they catch divergent failure modes: type-level catches *absent*
  declarations at compile time; CI-gate catches *false* declarations
  at PR time; documentation guides authors *before* either gate fires.
- **Qualifier (Q):** Holds for the failure modes the parent solution
  enumerates. Does NOT hold for failure modes outside this set: an
  adapter that declares an honest `stream_contract/0` but emits
  *wrong* events (a "value-level lie" inherited from the
  callback-contract-drift validation's claim 3 rebuttal) is caught
  only by the self-consistency test (Workstream D's
  `provider_stream_contract_test.exs`), which itself depends on a
  Replay fixture (the inherited fixture-completeness doubt from
  child Claim 7).
- **Rebuttal (R):** Does NOT hold if the three layers' inputs drift
  out of sync — e.g., a future workstream extends `Event.Usage` with
  a new field but the prose `@stream_contract` attribute and the
  capabilities gate are not updated. The cross-workstream
  `docs/PROVIDER-CONTRACT.md` index is the soft mitigation; no hard
  mitigation exists.
- **Backing (B):** `.claude/rules/factory-loop.md` §"The three
  mechanical gates" — established pattern for layering gates of
  different mechanism classes. OTP non-negotiable #2 (struct/atom
  pattern-matching for extensibility seams).

#### Falsification attempt for claim 2

- **Strategy:** Integration check — for each named "what each layer
  cannot do" boundary, verify the next layer actually does it.
- **Attempt:** (a) Type-level cannot catch a declared-but-lying
  `stream_contract/0` → CI-gate via the self-consistency test
  (Workstream D) catches it. Verified the test is in scope per
  solution.md L177–179. (b) Type-level cannot catch a `prompt_caching:
  true` declared without `cache_regions/2` → `mix
  tau.gate.capabilities` (Workstream C) catches it. Verified the
  biconditional and the gate's CI-blocking position. (c) Type-level
  and CI-gate cannot catch `thinking: true` lies because no single
  callback owns the obligation → documentation is the only remaining
  layer; `capabilities/0` docstring and `@stream_contract` prose are
  the artefacts. This *does* leave a gap (no mechanical catch), which
  the parent solution acknowledges under §Open questions
  ("`thinking` flag enforcement"). The composition claim survives:
  documentation is the named layer for this case, even if its
  enforcement strength is lower than the other two.
- **Outcome:** withstood.
- **Action:** none. Note: the parent's claim is "each layer covers
  what the previous *cannot*"; this is correct in the sense that
  documentation is the only layer that *can* address `thinking`, not
  in the sense that documentation *enforces* `thinking` honesty.

### Claim 3: The four workstreams ship as four (or six with B2/B3) separate PRs that can largely parallelise under the factory-loop conflict check.

- **Claim (C):** "The four workstreams touch disjoint files and ship
  as four separate PRs that can largely parallelise under the
  factory-loop conflict check" (solution.md §Recommendation L43–45).
- **Grounds (G):** The migration sketch (solution.md §"Migration
  sketch" L217–262) enumerates the PR sequence: PR-A and PR-B1 in
  parallel (fully disjoint files); PR-C after PR-B1 to claim the
  `lib/tau/provider.ex` edit window; PR-D after PR-C for the same
  reason; PR-B2 and PR-B3 in parallel after that. The
  factory-loop conflict check (rule §"The conflict check" clauses
  1–5) explicitly defines the parallelisation criterion: no
  dependency, disjoint files, disjoint codepoints, no shared SPEC/D-NNN
  block, shared-resource isolation possible.
- **Warrant (W):** The factory-loop conflict check is the project's
  authoritative concurrency arbiter; any PR set that clears all five
  of its clauses can be parallelised by definition. Claim 1's
  validation shows the four workstreams are file/region-disjoint;
  Workstream A introduces no SPEC; Workstream B amends
  SPEC-PROMPT-CACHING (`%Event.Usage{}` is new state at §4 B3);
  Workstream C may need a brief SPEC entry or ADR (Open question 6
  in solution.md); Workstream D may need its own SPEC entry (Open
  question 7). The SPEC-clause (4) is satisfied because no two
  workstreams amend the same SPEC.
- **Qualifier (Q):** Holds with the explicit serialisation noted:
  PR-B1 strictly precedes PR-B2 and PR-B3 (Workstream B's
  intra-sequencing); PR-C and PR-D should not run concurrently with
  PR-B1 to minimise rebase blast radius. The parent solution names
  this serialisation in its migration sketch.
- **Rebuttal (R):** Does NOT hold if Workstream D's SPEC question
  (Open question 7) lands as a SPEC amendment that Workstream B also
  amends in the same window — that would violate clause 4 (shared
  SPEC). The parent solution flags this open question; if it
  resolves as "new SPEC-PROVIDER-CONTRACT", B and D no longer share a
  SPEC. If it resolves as "amendment to SPEC-PROMPT-CACHING", B and
  D both amend it and must serialise on the SPEC amendment.
- **Backing (B):** `.claude/rules/factory-loop.md` §"Parallel
  execution" §"The conflict check"; `.claude/rules/spec-before-code.md`
  §"Critic / reviewer gate amendment".

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction — try to find a PR pair
  that the conflict check would reject despite the solution's
  parallelisation claim.
- **Attempt:** Examined the six PR pairs under the five clauses.
  Dependency (clause 1): only B1→B2 and B1→B3 are dependencies,
  matching the solution's stated serialisation. Disjoint files
  (clause 2): per claim 1 validation, all pairs are file-or-region
  disjoint. Disjoint codepoints (clause 3): no two PRs modify the
  same function. SPEC blocks (clause 4): A authors no SPEC; B amends
  SPEC-PROMPT-CACHING B3; C amends none mechanically (could need a
  small ADR); D's SPEC home is the open question. The
  worst-case-SPEC-collision is B and D both amending
  SPEC-PROMPT-CACHING — but D's content is *not* about prompt
  caching; the solution explicitly recommends a new
  `SPEC-PROVIDER-CONTRACT` (or ADR) for D. Shared-resource isolation
  (clause 5): none of the four workstreams invokes `mix tau.smoke` or
  `mix release tau ...`; the burrito-cache issue cited in
  `worktree-discipline.md` does not apply.
- **Outcome:** withstood (with the open-question 7 caveat under
  Outstanding doubts).
- **Action:** none. Implementer of PR-D must resolve the SPEC home
  before scheduling concurrently with PR-B series.

### Claim 4: PR-D (Workstream D — `stream_contract/0`) is the only workstream that breaks `@behaviour Tau.Provider` for external implementors.

- **Claim (C):** "PR-D … is the only workstream that breaks
  `@behaviour Tau.Provider` for external implementors (out-of-scope
  per the project; all current implementors are in-tree)."
  (solution.md §"Migration sketch" L240–242).
- **Grounds (G):** Inspection of `lib/tau/provider.ex` shows the
  current callback list: `stream/3` (mandatory), `capabilities/0`
  (mandatory), `default_model/0` (mandatory), `configure/1`
  (optional), `chat/3` (optional), `cache_regions/2` (optional),
  `context_window/1` (optional). The mandatory set is unchanged
  except for the addition of `stream_contract/0` (Workstream D).
  Workstream A adds no callback. Workstream B replaces the typespec
  of `%Event.Done{}.usage` from `map()` to `Event.Usage.t() | nil` —
  this is a *typespec* tightening on a struct *field*, not a
  behaviour-callback change; any adapter that emits `%Event.Done{usage:
  %{...}}` (a raw map) still compiles but fails Dialyzer's
  success-typing. Workstream C adds `@doc`/`@typedoc` text and a
  capabilities biconditional gate, but does not change the
  `capabilities/0` callback signature.
  `grep -rln '@behaviour Tau.Provider\b' lib/` returns exactly 11
  modules; no external (out-of-tree) implementor is shipped.
- **Warrant (W):** Adding a mandatory `@callback` requires every
  `@behaviour Tau.Provider` module to implement it; the compiler
  emits "behaviour callback X is not implemented" and
  `mix compile --warnings-as-errors` makes it fatal. This is the
  precise mechanism the child callback-contract-drift validation's
  Claim 6 cites. Adding an optional callback, a `@doc`, a typespec, or
  a new struct does NOT trigger the warning; therefore those changes
  do not break external implementors.
- **Qualifier (Q):** Holds while no external `@behaviour
  Tau.Provider` implementor ships. If an extension-loaded provider
  (SPEC-EXTENSIONS Stage B) is materialised before PR-D lands, the
  extension's compile step fails on the new mandatory callback —
  exactly the "behaviour break" the claim names.
- **Rebuttal (R):** Workstream B's `%Event.Usage{}` struct technically
  is a contract tightening on `%Event.Done{}`; an external implementor
  that emits a raw `usage: %{}` map would not fail compile (the
  emission site is the adapter's own code; the typespec is at the
  emitter side) but would surface as a Dialyzer warning. This is a
  *soft* break of the contract — not a hard compile break, so Claim 4
  remains correct that PR-D is the only *hard* break.
- **Backing (B):** Elixir documentation on behaviour callback warnings;
  `.claude/rules/factory-loop.md` §"PR scope guards" treats hard
  compile breaks as triggering the freshness re-check.

#### Falsification attempt for claim 4

- **Strategy:** Counter-example construction — enumerate the four
  workstreams' changes and check each for a hard behaviour break.
- **Attempt:** Workstream A: adds `Tau.Providers.Auth` and removes
  private helpers from six adapters. No `@callback` change. No break.
  Workstream B: typespec tightening on `Done.usage`; struct addition
  to `Tau.Provider.Event`. No `@callback` change. No hard break.
  Workstream C: `@doc`/`@typedoc` text; demotion of three adapters'
  flag values; new Mix task; ci.yml line. No `@callback` change. No
  break. Workstream D: adds mandatory `@callback stream_contract/0`.
  Every `@behaviour Tau.Provider` module must implement it or fail
  compile. **Confirmed hard break — but only Workstream D triggers
  it.** Claim 4 holds.
- **Outcome:** withstood.
- **Action:** none.

### Claim 5: A new adapter author following `@behaviour Tau.Provider` cannot pass `mix compile --warnings-as-errors`, `mix test`, AND `mix tau.gate.capabilities` without satisfying all four sub-criteria (AC-M1, the module-level synthesis criterion).

- **Claim (C):** AC-M1 verbatim (solution.md §"Module-level AC" L338–349):
  the new author must (a) declare a usage struct conforming to
  `Event.Usage`, (b) declare a stream contract matching emitted
  events, (c) declare `prompt_caching: true` only if implementing
  `cache_regions/2`, and (d) route standard API-key resolution through
  `Tau.Providers.Auth`.
- **Grounds (G):** Sub-criterion (a) is enforced by the mandatory
  `Done.usage` typespec change (Workstream B) plus the
  `ProviderConformance` test template (Workstream B PR-B3) iterating
  every adapter. (b) is enforced by Workstream D's mandatory
  `stream_contract/0` callback (Dialyzer-checked for structural
  divergence per child Claim 3) and the self-consistency test for
  value-level divergence (child Claim 7). (c) is enforced by `mix
  tau.gate.capabilities` (Workstream C, child Claim 5) which is
  wired into the lint job as blocking (child Claim 6). (d) is the
  weakest of the four: the cross-adapter telemetry test (Workstream
  A, child Claim 5) asserts `[:tau, :vault, :get]` fires during
  credential resolution but does NOT assert the call goes through
  `Tau.Providers.Auth` specifically — an adapter could call
  `Tau.Settings.Vault.resolve/1` directly and the telemetry test
  would still pass.
- **Warrant (W):** AC-M1 is satisfied iff every sub-criterion is
  satisfied (logical conjunction). Each child sub-AC set is
  individually validated (child validations on file); their union
  discharges the conjunction iff the union covers the full failure
  surface AC-M1 names. The four sub-criteria are exhaustive of the
  "ship a broken implementation" failure modes the parent problem
  cited (capabilities-flag fidelity, usage normalisation, callback
  contract drift, auth-resolution scatter).
- **Qualifier (Q):** Holds for the four named failure modes. **Narrowed
  for sub-criterion (d):** the telemetry test enforces "vault was
  consulted" rather than "`Tau.Providers.Auth` was the consulting
  module"; an adapter that goes directly to vault satisfies the test
  but not the spirit of routing-through-Auth. The ADR (Workstream A,
  child Claim 4) is the soft mitigation; the parent solution does
  not name a stricter test.
- **Rebuttal (R):** A new adapter author who skips
  `@behaviour Tau.Provider` entirely (e.g., implements the functions
  duck-typed) escapes the type-level enforcement; the compile warning
  is keyed on the `@behaviour` declaration. This is an edge case
  (every existing adapter does declare `@behaviour`), but it is a
  loophole the four workstreams do not close.
- **Backing (B):** Parent problem.md §"Acceptance criterion" L88–93;
  the four child validations' AC discharge sections.

#### Falsification attempt for claim 5

- **Strategy:** Counter-example construction — imagine a "minimum
  malicious adapter" and check whether each gate fires.
- **Attempt:** Author writes `Tau.Providers.Evil`, declares
  `@behaviour Tau.Provider`, implements `stream/3`, `capabilities/0`
  with `prompt_caching: true` but no `cache_regions/2`,
  `default_model/0`, and `stream_contract/0` claiming
  `text_framing: :start_delta_end` while emitting bare
  `%Event.TextDelta{}`. Result: (a) Dialyzer flags
  `%Event.Done{usage: nil}` if not wrapped, but a knowing author
  could call `UsageNorm.zero()` and pass type-level; conformance
  test fails if a fixture exists, but author can ship without one
  initially. (b) `stream_contract/0` declaration of conformant +
  bare-delta emission: self-consistency test fails (child Claim 7,
  qualified by fixture availability). (c) `prompt_caching: true` no
  `cache_regions/2`: `mix tau.gate.capabilities` fails — blocking.
  (d) `api_key/0` calls `Tau.Settings.Vault.resolve/1` directly
  (bypassing `Tau.Providers.Auth`): telemetry test passes (fires on
  vault), so this gate does NOT fire. **Sub-criterion (d) is the
  weakest** — but the *intent* of AC-M1 ("cannot silently ship a
  broken implementation") is still met for the gates that fire,
  and the bypass route is observable in the ADR's exception table on
  review. No claim falsification, but the Qualifier narrowing under
  (d) is consistent with the child auth-resolution-scatter
  validation's outstanding doubt that the telemetry assertion is
  fire-only not use-only.
- **Outcome:** withstood (with the narrowed qualifier under (d)).
- **Action:** none. The narrowed qualifier is recorded; the
  underlying weakness is inherited from the auth-resolution-scatter
  child's Outstanding doubts.

### Claim 6: `Tau.Provider`'s existing callback list is preserved except for the single new `stream_contract/0`; optional callbacks remain optional.

- **Claim (C):** "The `Tau.Provider` callback list **except** for the
  single new `stream_contract/0` (Workstream D). `configure/1` stays
  optional and unused; `cache_regions/2` stays optional;
  `context_window/1` stays optional." (solution.md §"What does not
  change" L191–195).
- **Grounds (G):** `lib/tau/provider.ex:131` reads `@optional_callbacks
  [configure: 1, chat: 3, cache_regions: 2, context_window: 1]`. The
  parent solution's "What changes" enumeration touches only: B's
  event-union typespec; C's `@doc`/`@typedoc` on `capabilities/0`;
  D's `@callback stream_contract/0` declaration (appended, not
  replacing). No workstream modifies the `@optional_callbacks` list
  or promotes/demotes existing callbacks.
- **Warrant (W):** Preserving an established public surface
  (callback list + optionality status) is the canonical Hyrum's-law
  consideration for an interface with 11 implementors. The child
  auth-resolution-scatter validation's Claim 6 verified `configure/1`
  remains optional; the parent inherits.
- **Qualifier (Q):** Holds for the four workstreams' scope as
  declared. A future PR could promote `configure/1` to mandatory
  (the auth-resolution-scatter Outstanding doubt #3), but the
  parent solution explicitly defers this.
- **Rebuttal (R):** None — the change set is enumerable and the
  preservation is by-construction.
- **Backing (B):** OTP non-negotiable #2 ("extensibility seams MUST
  be behaviours"; corollary: the seam's shape MUST NOT be changed
  gratuitously). Child validation
  `subproblems/auth-resolution-scatter/validation.md` §Claim 6.

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — search the parent
  solution's "What changes" for any modification to
  `@optional_callbacks` or any existing callback's mandatory/optional
  status.
- **Attempt:** Read solution.md L86–187 (the "What changes" block).
  Search hits for `@optional_callbacks`: zero. Search hits for
  `configure/1` outside §"What does not change": one (the
  callback-contract-drift child's open question about `known_adapters/0`
  helper does not touch `configure/1`). The Workstream D addition is
  explicitly stated as "mandatory, not optional" but it is a new
  callback, not a status change on an existing one.
- **Outcome:** withstood.
- **Action:** none.

### Claim 7: The behaviour contract and shared infrastructure enforces (or accurately documents as optional) **every observable divergence currently present** across the eleven adapters.

- **Claim (C):** The parent problem's acceptance criterion verbatim:
  "the behaviour contract at `lib/tau/provider.ex` and associated
  shared infrastructure enforces (or accurately documents as
  optional) every observable divergence currently present across
  the eleven adapters" (problem.md §"Acceptance criterion" L88–93;
  AC-M1 in solution.md L338–349 is the operational form).
- **Grounds (G):** The four workstreams collectively address the
  four divergence axes problem.md enumerates (L46–58): (1)
  capabilities flag fidelity → Workstream C; (2) usage normalisation
  → Workstream B; (3) auth-resolution scatter → Workstream A; (4)
  callback-contract drift → Workstream D. The child validations
  individually validate that each workstream achieves its sub-AC.
  However, the parent solution's §"What does not change" L196–201
  explicitly notes: "Live decode paths for Bedrock and Gemini (other
  than the usage extraction in B2) — they continue to omit
  `TextStart/End` framing; the `stream_contract/0` declaration makes
  the gap visible but does not fix it." The child
  callback-contract-drift validation's Claim 5 confirms this
  declaration-only treatment.
- **Warrant (W):** "Enforces or accurately documents as optional"
  has two satisfying disjuncts: hard enforcement (compile/CI gate
  fires on violation) or accurate documentation (the divergence is
  declared and discoverable without reading the decode path). The
  `stream_contract/0` callback satisfies the second disjunct for
  Bedrock and Gemini: their divergence is *declared* (`text_framing:
  :delta_only`), even though it is not *fixed*.
- **Qualifier (Q) — NARROWED during validation:** Holds with two
  named exceptions: (a) Bedrock's and Gemini's live-decode-path
  divergences (no `TextStart/End`, atomic `ToolCallDelta`) are
  declared via `stream_contract/0` but **not corrected** in scope.
  The parent solution names this under §"What does not change" and
  §"Open questions" (Bedrock/Gemini decode-path remediation is a
  follow-up sub-problem). (b) The `thinking` flag's enforcement
  remains advisory-by-doc (parent's §"Open questions" item 3 and
  child capabilities-flag-fidelity's Claim 4 partial falsification).
- **Rebuttal (R):** A maximally strict reading of AC-M1 might
  interpret "enforces or accurately documents as optional" as
  excluding declaration-only treatment (the divergence must be
  enforced *or* the divergence must be optional, not "declared but
  unfixed"). Under that reading, claim 7 is *fully* falsified, not
  partially: the live-decode-path divergences are neither enforced
  nor optional; they are declared-as-broken. The parent solution
  rejects this reading and treats declaration as sufficient
  documentation; the parent problem's acceptance criterion is
  ambiguous on the point.
- **Backing (B):** Parent problem.md L88–93; child
  `subproblems/callback-contract-drift/validation.md` §Claim 5 and
  §Open questions; child
  `subproblems/capabilities-flag-fidelity/validation.md` §Claim 4
  partial-falsification.

#### Falsification attempt for claim 7

- **Strategy:** Counter-example construction — enumerate every
  divergence in problem.md L24–43 and check whether each is either
  enforced or accurately documented post-synthesis.
- **Attempt:** (1) "`capabilities/0` flags are decorative
  (Bedrock/Gemini declare `thinking: true, prompt_caching: true`
  while implementing neither)" → Workstream C demotes the flags and
  the gate enforces `prompt_caching`. Enforced. (2) "usage maps are
  only canonically normalised by Anthropic" → Workstream B introduces
  the struct, scaffold, wire-extraction, and conformance test.
  Enforced. (3) "`retryable?` classification scattered across three
  layers with incompatible criteria" → **NOT in any workstream's
  scope.** The parent problem mentions `retryable?` in §Statement
  L18–21 but no sub-problem covers it. Workstream A is auth-only;
  Workstream B is usage-only; Workstream C is capability-flag-only;
  Workstream D is stream-contract-only. **Claim 7 is silently
  understating the gap: the `retryable?` divergence problem.md
  cites is unaddressed.** (4) "auth-resolution logic is duplicated"
  → Workstream A. Enforced. Plus the structural divergences from
  callback-contract-drift (Bedrock/Gemini decode paths) → Workstream
  D declares but does not fix.
- **Outcome:** **partially falsified.** Two distinct underspecification
  exceptions: (i) `retryable?` classification is named in problem.md
  §Statement but no sub-problem and no workstream addresses it; (ii)
  Bedrock/Gemini live-decode-path divergences are declared but not
  fixed.
- **Action:** **narrow the qualifier in place** (done above).
  Specifically: claim 7's Qualifier is narrowed to "every divergence
  enumerated as a sub-problem in problem.md L72–85", which is the
  decomposition the synthesis acts on. The `retryable?` line in
  problem.md §Statement was decomposed away — it appears in the
  statement but is not present in the four sub-problems. This is a
  **problem decomposition gap**, not a solution defect: the
  decomposition step (proposer-level) elided one of four divergences
  in problem.md §Statement when carving the four sub-problems.
  Recording as an outstanding doubt and flagging for the coordinator;
  no revision of the parent solution.md (it correctly synthesises the
  four children) but the **parent problem.md may need an amendment
  log entry** clarifying that `retryable?` is deferred. Not
  triggering a `revision_triggered: problem` because the acceptance
  criterion still holds for the divergences that *were* decomposed,
  and the missing decomposition is recoverable as a future
  sub-problem.

### Claim 8: The cross-workstream `docs/PROVIDER-CONTRACT.md` index consolidates four scattered artefacts into one operator-readable index.

- **Claim (C):** "Documentation — `docs/PROVIDER-CONTRACT.md` (or
  amendment to an existing provider doc) lists the four enforcement
  mechanisms (`stream_contract/0`, `%Event.Usage{}`, `mix
  tau.gate.capabilities`, `Tau.Providers.Auth`) and points at each
  workstream's spec / ADR / test entrypoint. This consolidates what is
  otherwise four scattered artifacts into one operator-readable index."
  (solution.md §"Cross-workstream additions" L181–187).
- **Grounds (G):** Each workstream produces its own artefact:
  Workstream A's `ADR-00XX-auth-resolution-policy.md`, Workstream B's
  SPEC-PROMPT-CACHING §4 B3 amendment, Workstream C's
  `capabilities/0` `@doc`/`@typedoc`, Workstream D's
  `@stream_contract` attribute and (per open question 7) a
  SPEC-PROVIDER-CONTRACT or ADR. Without consolidation, a new
  contributor must read all four to understand the provider contract.
- **Warrant (W):** Reducing N independent reference points to 1
  index reduces the activation cost of correct adapter authorship
  from O(N) to O(1) — a soft engineering benefit.
- **Qualifier (Q):** Holds when the index actually lands. The
  parent solution treats it as a cross-workstream addition; which PR
  authors it is unspecified. If no PR authors it, the four
  artefacts remain scattered.
- **Rebuttal (R):** The index can drift from the four canonical
  sources (the standard "documentation that mirrors code" risk).
  The solution does not address refresh policy.
- **Backing (B):** The `tau-architecture` skill's general guidance
  on layering documentation alongside code. No formal SPEC mandates
  this kind of index.

#### Falsification attempt for claim 8

- **Strategy:** Dependency check — does the parent solution name
  which PR owns the index?
- **Attempt:** Searched solution.md for `PROVIDER-CONTRACT`: three
  mentions, all in §"Cross-workstream additions" and §"Open
  questions". The PR ownership is unspecified — it is "Cross-
  workstream", not assigned to any of the six listed PRs (A, B1, B2,
  B3, C, D). This is a soft defect: a deliverable named with no
  owner risks not being delivered.
- **Outcome:** withstood (the claim is about the *value* of the
  index if it exists, not about its delivery). The delivery risk
  is flagged under Outstanding doubts.
- **Action:** none. Flag for the implementer-coordinator: assign the
  `docs/PROVIDER-CONTRACT.md` authorship to a specific PR (e.g.,
  the last to merge, so it can reference all four canonical sources).

### Claim 9: The per-workstream reversibility table (A: easy delete; B: B3→B2→B1 reverse; C: trivial revert; D: easy at struct level) is accurate.

- **Claim (C):** "Reversibility is per-workstream: A: easy (delete
  shared module). B: B3 → B2 → B1 reverse order; struct revert
  requires consumer-access revert. C: trivial (revert demotions;
  delete gate task; remove CI line). D: easy at struct level (delete
  `stream_contract.ex`); harder if any external implementor has
  already implemented the callback (out of scope today)."
  (solution.md §"Migration sketch" L264–271).
- **Grounds (G):** Workstream A is purely additive (new module +
  ADR + tests) plus deletions of private `vault_key/0` helpers;
  reverting means restoring the deletions from VCS — mechanical.
  Workstream B is staged (B1 → B2 → B3); each PR's reverse order is
  also mechanical, with the caveat that consumer migration in B1
  must be reverted before B1 itself. Workstream C is purely
  additive (new task, new test, new CI line) plus three flag
  demotions; reverting means re-elevating the flags and removing the
  gate — mechanical. Workstream D adds one new struct file, one
  new callback declaration, eleven adapter implementations, and one
  test file; reverting means deleting all of them — mechanical at
  the struct level. The "harder if external implementor" caveat is
  acknowledged.
- **Warrant (W):** A change is *reversible* iff its reverse is
  bounded in scope and does not require coordinating with downstream
  consumers. Each workstream's reverse is bounded; the
  cross-workstream consumer is in-tree (Anthropic adapter for
  Workstream B; the eleven adapters for Workstream D).
- **Qualifier (Q):** Holds for the in-tree-only scope. If extension-
  loaded providers (SPEC-EXTENSIONS Stage B) have shipped between
  the workstream's merge and the hypothetical revert, the revert
  blast radius extends to those extensions.
- **Rebuttal (R):** Workstream B's revert is the most complex: B1's
  consumer migration would need to be reverted (atom-keyed bracket
  access against the new struct does work, but a revert restores
  raw maps and any new struct-access call site breaks). The child
  usage-normalisation validation's Claim 6 partial falsification
  (the migration cost is over-stated against the current codebase)
  actually *strengthens* this rebuttal: the migration is so small
  that the revert is also small.
- **Backing (B):** Standard software engineering practice on
  additive vs replacing changes; the child validations
  individually note each workstream's revert cost.

#### Falsification attempt for claim 9

- **Strategy:** Edge-case enumeration over the four workstreams.
- **Attempt:** A — `git revert <PR-A-sha>` restores the six adapters'
  private helpers and deletes the new module. Mechanical. B —
  `git revert <PR-B3-sha>; git revert <PR-B2-sha>; git revert
  <PR-B1-sha>` in that order. Atom-key consumer access stays
  working through both the struct and the reverted map. Mechanical.
  C — `git revert <PR-C-sha>` restores the three flags and removes
  the gate + CI line. Mechanical. D — `git revert <PR-D-sha>`
  deletes the struct and the callback; eleven adapter implementations
  vanish with it. Mechanical at the struct level. No edge case
  surfaces a non-mechanical revert.
- **Outcome:** withstood.
- **Action:** none.

### Claim 10: The `Tau.Provider` Event union (other than `Done.usage`) and Bedrock/Gemini live decode paths are NOT modified by this synthesis.

- **Claim (C):** "`Tau.Provider.Event` event types other than
  `%Event.Done{}`'s `usage` typespec — no new event variants, no
  changes to `TextStart/End`, `ToolCallStart/Delta/End`,
  `ThinkingStart/Delta/End`, `Error`. Live decode paths for Bedrock
  and Gemini (other than the usage extraction in B2) — they
  continue to omit `TextStart/End` framing." (solution.md §"What
  does not change" L196–203).
- **Grounds (G):** Workstream B's enumeration (solution.md
  L107–127) modifies only `event.ex` extension (one struct +
  typespec), `usage_norm.ex` (new), adapter wire files for usage
  extraction. No event variant additions; no
  `TextStart`/`TextEnd`/`ToolCallDelta`/`ThinkingStart` signature
  changes. Workstream B2 lists Bedrock and Gemini wire-extraction
  for usage only — distinct from `decode/2`/`decode_anthropic_event/2`
  text-framing clauses. Direct inspection of `lib/tau/providers/event.ex`
  L83–106 shows the existing variant set; none of the four
  workstreams adds a new one.
- **Warrant (W):** The "What does not change" enumeration is
  mutually exhaustive with "What changes" by construction; a PR
  that lands only the listed edits satisfies the claim by
  inspection. The child callback-contract-drift validation's
  Claim 8 already validated this for Workstream D specifically.
- **Qualifier (Q):** Holds for the scope as declared. If any
  workstream's implementer "while I'm here" modifies a non-listed
  file, the claim is violated and the PR is out-of-scope per
  factory-loop §"PR scope guards".
- **Rebuttal (R):** Workstream B2 *does* edit Bedrock's
  `decode_anthropic_event/2` clauses — specifically to add the
  `message_start.usage` accumulator clause. This is a *new clause
  inside* the decode function, not a modification to existing
  text-framing clauses. The child usage-normalisation validation's
  Claim 4 confirms the addition is well-scoped (ordering before the
  fallthrough; no existing clause replaced). Therefore the
  qualifier "other than the usage extraction in B2" is honored.
- **Backing (B):** `.claude/rules/factory-loop.md` §"PR scope
  guards" ("Declared, frozen scope"); child validation
  `subproblems/callback-contract-drift/validation.md` §Claim 8.

#### Falsification attempt for claim 10

- **Strategy:** Edge-case enumeration — for each "does not change"
  bullet, check the four workstreams' "What changes" lists for
  contradicting edits.
- **Attempt:** (a) Event variants other than `Done` — `event.ex` is
  touched only by Workstream B1 for the Usage struct and Done
  typespec; the other variants are not enumerated as edits.
  Disjoint. (b) `TextStart/End/ToolCallStart/Delta/End/ThinkingStart/
  Delta/End/Error` — none enumerated. Disjoint. (c) Bedrock/Gemini
  live decode paths for text framing — Workstream D adds
  `stream_contract/0` to each (declaration, not decode-path edit);
  Workstream B2 adds usage extraction (distinct clause). Disjoint
  with text-framing clauses. (d) `Tau.Message.Assembler` tolerances
  — no workstream lists it; disjoint. (e) Anthropic Auth, Bedrock
  AWS-credential, Copilot two-token model — Workstream A explicitly
  carves these out. Disjoint.
- **Outcome:** withstood.
- **Action:** none.

## Cross-claim consistency

The ten claims are internally consistent. Recurring structure:
composability (claims 1, 2, 3) → behaviour-API impact (claims 4, 6,
10) → conjunction discharge of AC-M1 (claim 5) → coverage of
problem.md (claim 7) → operator readability (claim 8) → reversibility
(claim 9).

Tensions resolved:

- **Claim 4 (only PR-D breaks `@behaviour`) vs Claim 5 (AC-M1 requires
  four sub-criteria, including (a) usage struct conformance).** No
  tension: Workstream B's usage typespec is a Dialyzer-visible *soft*
  contract change, not a compile-time *hard* behaviour break. Claim 4
  is precisely about hard breaks; Claim 5 is about the combined
  enforcement surface.
- **Claim 6 (callback list preserved) vs Claim 4 (PR-D adds a
  mandatory callback).** Resolved by the explicit exception in
  Claim 6's claim text: "except for the single new
  `stream_contract/0`".
- **Claim 7 (every divergence covered) vs the inherited child
  partial-falsification on `thinking` enforcement (capabilities-flag-
  fidelity Claim 4 partial).** Resolved by claim 7's narrowed
  qualifier explicitly inheriting the advisory-by-doc treatment for
  `thinking`. No internal contradiction; the parent claim is
  appropriately weakened.
- **Claim 7's partial falsification on `retryable?`.** The parent
  problem's §Statement names four divergences; the
  §"Sub-problems" decomposition names four sub-problems that map
  onto a *different* four (the `retryable?` line is dropped; the
  callback-contract-drift line is added). The synthesis is faithful
  to the decomposition but the decomposition is unfaithful to the
  statement. This is a problem-level decomposition gap, recorded
  under Outstanding doubts and as the falsified-claim qualifier
  narrowing.

The inherited child outstanding doubts (see §Inherited qualifiers
from child validations below) do not introduce new cross-claim
tensions; they tighten qualifiers on individual parent claims.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Four workstreams' recommendations compose; no retract/constrain | edge-case enumeration over six pairs | withstood | none |
| 2 | Three enforcement layers compose (type / CI / docs) | integration check | withstood | none |
| 3 | Four workstreams parallelisable under factory-loop conflict check | counter-example construction | withstood | none |
| 4 | PR-D is the only hard behaviour break | counter-example construction | withstood | none |
| 5 | AC-M1 sub-criteria conjunction discharged by the four workstreams | counter-example construction (malicious adapter) | withstood (narrowed Q on (d) telemetry strength) | none |
| 6 | Callback list preserved except for new `stream_contract/0` | counter-example construction | withstood | none |
| 7 | Every observable adapter divergence enforced or accurately documented | counter-example construction (divergence enumeration) | **partially falsified** | narrow Q in place; record `retryable?` decomposition gap as outstanding doubt |
| 8 | `docs/PROVIDER-CONTRACT.md` consolidates four scattered artefacts | dependency check (PR ownership) | withstood (delivery risk flagged) | flag PR ownership |
| 9 | Per-workstream reversibility (A easy, B staged, C trivial, D easy at struct) | edge-case enumeration | withstood | none |
| 10 | Event union and live decode paths unchanged | edge-case enumeration | withstood | none |

## Inherited qualifiers from child validations

These are carried forward from the four child `validation.md` files
and inform the parent's qualifiers above:

- **auth-resolution-scatter Claim 3 partial:** Gemini's vault leg
  covers `GOOGLE_API_KEY` only, not `GEMINI_API_KEY`. Parent Claim 5
  sub-criterion (d) inherits this — the ADR exception table is the
  resolution.
- **auth-resolution-scatter Claim 5 qualifier:** the telemetry test
  is fire-only, not use-only. Parent Claim 5 sub-criterion (d) is
  narrowed accordingly.
- **callback-contract-drift Claim 5 qualifier:** Bedrock and Gemini
  decode-path remediation is deferred; `stream_contract/0` declares
  the gap but does not fix it. Parent Claim 7 inherits this as the
  primary partial-falsification driver.
- **callback-contract-drift Claim 6 partial:** the solution's prose
  names a non-existent Copilot provider and elides `OpenAI.Responses`;
  the operative mechanism (compile warning) is unaffected. Parent
  Claim 4 inherits — the eleven-adapter set is the grep-confirmed
  set, not the parent solution's prose enumeration.
- **callback-contract-drift Claim 7 qualifier:** Replay fixture
  completeness is a precondition for the self-consistency test;
  fixtures may not exist for Bedrock and Gemini. Parent Claim 2
  enforcement-layer-(b) inherits a residual gap on value-level lies
  for these adapters.
- **capabilities-flag-fidelity Claim 4 partial:** DeepSeek's
  `thinking: true` is advisory-by-doc, same as OpenAI Responses and
  Custom; no mechanical enforcement. Parent Claim 7 inherits — the
  `thinking` flag is an inherited declaration-only treatment.
- **usage-normalisation Claim 6 partial:** the consumer migration
  cost is over-stated; atom-keyed access works against the new
  struct via the `Access` behaviour. Parent Claim 9 (reversibility)
  is strengthened by this — Workstream B's revert is even smaller
  than claimed.
- **usage-normalisation Outstanding doubt:** `OpenAI.Responses`
  wire-extraction is unspecified (`from_openai_responses/1` is not
  listed in the solution); the wire is distinct from OpenAI Chat.
  Parent Claim 5 sub-criterion (a) inherits a coverage gap for that
  one adapter until PR-B2 scoping closes it.
- **usage-normalisation Outstanding doubt:** the `@enforce_keys`
  tightening is staged via an open question; until the follow-up
  lands, an adapter can still emit `%Event.Done{usage: nil}`.
  Parent Claim 5 sub-criterion (a) is weakened accordingly.

## Revision required

None. The single partial falsification (Claim 7) is resolved by
narrowing the qualifier in place: the synthesis correctly discharges
the acceptance criterion for the four divergences the decomposition
named, and the unmodelled `retryable?` divergence (named in
problem.md §Statement but not in §Sub-problems) is a
**decomposition-step gap** belonging to the proposer/decomposer
level, not a solution-level defect.

- **Target file:** none — qualifier narrowed in-validation. Optional
  follow-up: an Amendment-log entry on `problem.md` clarifying that
  `retryable?` is deferred to a future sub-problem would close the
  Statement-vs-Decomposition gap, but is not required for the
  parent solution to discharge AC-M1 as scoped.
- **Revision kind:** n/a
- **Rationale:** Partial falsifications and inherited child
  doubts narrow qualifiers in place (per validate.md §5); the
  solution.md does not need a different *technical* approach. The
  problem.md decomposition could be tightened but is not falsified
  in scope.

## Outstanding doubts

The parent-level validator inherits the union of child outstanding
doubts plus the parent-specific doubts surfaced here:

- **`retryable?` divergence is unmodelled.** problem.md §Statement
  L18–21 names "`retryable?` classification scattered across three
  layers with incompatible criteria" but the §"Sub-problems"
  decomposition has no corresponding sub-problem. The parent
  synthesis cannot address what the decomposition did not surface.
  Flagged for coordinator: consider filing a follow-up sub-problem
  or amending problem.md to either resolve or defer `retryable?`
  explicitly.
- **`docs/PROVIDER-CONTRACT.md` ownership.** The cross-workstream
  index is named but no PR owns it. Without explicit assignment, the
  index risks not being delivered. Recommend assigning to the last-
  merging PR (likely PR-B3) so it can reference all four canonical
  artefacts.
- **Open question 7 (PR-D SPEC home).** Until resolved, the
  Workstream B and Workstream D SPEC scopes might collide on
  SPEC-PROMPT-CACHING amendments. The factory-loop conflict-check
  clause 4 forbids two concurrent steps amending the same SPEC; if
  D's SPEC home becomes a SPEC-PROMPT-CACHING amendment, B and D
  must serialise their SPEC edits.
- **AC-M1 sub-criterion (d) telemetry strength.** The cross-adapter
  telemetry test asserts vault was *consulted*, not that the call
  went through `Tau.Providers.Auth` specifically. A "rogue" adapter
  could bypass `Tau.Providers.Auth` and still fire the telemetry
  event. Mitigated by the ADR exception table and reviewer
  attention; no mechanical gate exists.
- **`thinking` flag enforcement gap.** Inherited from child
  capabilities-flag-fidelity; advisory-by-doc only across three
  adapters (Bedrock, Gemini, DeepSeek + the two pre-existing
  cases on OpenAI Responses and Custom). Parent solution
  acknowledges in §Open questions.
- **Live decode-path remediation deferral.** Bedrock and Gemini's
  text-framing and tool-call-delta gaps are *declared* by
  `stream_contract/0` but not *fixed*. A follow-up sub-problem is
  named in the parent solution's §Open questions. Until it lands,
  the AC-M1 disjunct ("accurately documents as optional") is
  load-bearing for these two adapters; the maximally-strict reading
  of "enforces or documents as optional" might consider this
  declaration-only treatment insufficient.
- **Replay adapter posture under `stream_contract/0`.** Open
  question; affects Workstream D's compile-readiness.
- **`OpenAI.Responses` wire-extraction (B-series gap).** Inherited
  from usage-normalisation; the wire differs from OpenAI Chat and
  needs its own `UsageNorm.from_openai_responses/1` helper that the
  solution does not name.
- **Extension-loaded providers.** Inherited from
  capabilities-flag-fidelity. The gate task currently iterates
  compiled `Tau.Providers.*`; SPEC-EXTENSIONS Stage B providers
  would need an explicit decision.
- **Burrito-cache style shared-resource collision risk under
  concurrent PRs.** None of the four workstreams invokes
  `mix tau.smoke` or `mix release tau ...`, so the canonical
  burrito-cache collision does not apply. Recorded for completeness.
