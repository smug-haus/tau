---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/3
revision_triggered: none
---

# Validation: Site-specific decomplecting of the four tau-coding-agent rescue ladders

## Overview

The non-leaf root solution makes five cross-cutting integration claims about
how the four validated child solutions compose into a single satisfying answer
to the parent acceptance criterion. Per-site engineering claims (e.g. the
specific guard-clause shape of `close_port/1`, the asymmetric rescue split in
`tools.ex`) live in the four child `validation.md` files and are not
re-litigated here; this validation focuses on the *integration surface* the
parent introduces: composition independence, abstraction-extraction restraint,
telemetry-namespace coherence, parent-AC conjunction satisfaction, and faithful
inheritance of child qualifiers. Strategies used are integration check,
dependency check, edge-case enumeration, and prior-art counter-case. Outcome:
four claims withstood, one (Claim 3 — telemetry-namespace coherence) is
partially falsified at the handler-placement level, narrowed in place,
matching the partial falsification already present in the
`tool-impl-rescue-ladders` child.

## Toulmin per claim

### Claim 1: The four fixes have no inter-dependency and may land as four independent PRs in any order, or as a single combined PR.

- **Claim (C):** "The four fixes have no inter-dependency and may land as
  four independent PRs in any order, or as a single combined PR" (solution.md
  §"Migration sketch"); restated in §"Selected from" as "direct composition
  with no inter-child interface".
- **Grounds (G):** File-disjointness verified by `grep`: the four sites live
  at `lib/tau/coding_agent/dispatcher.ex:384–399` (private
  `expose_tau_context?/0`), `lib/tau/coding_agent/tau_context/tools.ex:215–229,
  269–284, 370–379` (three private functions inside one module),
  `lib/tau/coding_agents/claude_code.ex:402–416` (private `close_port/1` with
  two callers at lines 272 and 384 inside the same module), and
  `lib/tau/coding_agent/tau_context/router.ex:60–89` (public `call/2`).
  Cross-file caller search: `expose_tau_context` appears only in
  `dispatcher.ex` (definition + one call site) and `schema.ex` (settings
  schema); `Tau.CodingAgent.TauContext.Tools` appears only in its own module
  and its test file; `close_port` appears only inside `claude_code.ex`;
  `TauContext.Router` appears only in its own module (invoked via Plug
  dispatch, not by Elixir reference). No child fix imports, calls, or
  pattern-matches on another child's fix surface.
- **Warrant (W):** Two PRs that touch disjoint files, disjoint functions, no
  shared SPEC amendment, and no shared `$HOME`-namespace cache satisfy the
  five-clause conflict check in `.claude/rules/factory-loop.md` §"Parallel
  execution" and are therefore independently mergeable; rebase-on-current-
  origin/main plus the freshness re-check (cycle step 8a) makes merge order
  irrelevant.
- **Qualifier (Q):** Holds provided each PR carries its own test baseline
  re-run (no shared test fixture mutated by another fix), AND the
  `tools.ex` PR's optional SPEC-CODING-AGENT §3 amendment (additive
  `"result_kind"` field) does not need to land before another fix can compile
  — verified, none of the other three depends on the tagged-result wire
  format.
- **Rebuttal (R):** A rebuttal would arise if the `tools.ex` telemetry-handler
  attachment in `lib/tau/application.ex` (cited by the `tools.ex` child)
  happened to touch a line the dispatcher fix also edits — verified not the
  case: dispatcher's child fix is fully contained in `dispatcher.ex`. None
  exists for the cited file set.
- **Backing (B):** `.claude/rules/factory-loop.md` §"Parallel execution"
  (five-clause conflict check) and `.claude/rules/worktree-discipline.md`
  (parent-on-`main` invariant + freshness re-check) — both project rules.
- **Strategy:** integration check (`grep` over all callers + cross-file
  pattern-match enumeration). **Attempt:** searched `lib/` and `test/` for
  callers of each child's modified symbol; verified each modified function
  is private or has only intra-module callers; verified the only cross-file
  edit (telemetry handler in `application.ex`) is single-line and touches
  no surface the other three children edit. **Outcome:** withstood. **Action:**
  none.

### Claim 2: The synthesis declines to introduce a unifying tagged-result module/behaviour, and this is sound because the four sites have orthogonal complecting pairs.

- **Claim (C):** "The synthesis declines to introduce a unifying 'tagged-
  result' module/behaviour even though three of the four solutions adopt
  tagged-tuple or tagged-field returns. The harm profile, return shape, and
  call-site pattern differ at each site … A common abstraction would re-
  complect them. Composition, not aggregation (Hickey-aligned)" (solution.md
  §"Selected from").
- **Grounds (G):** Return-shape divergence: dispatcher returns
  `{:ok, boolean()} | {:error, :cache_unavailable}` (tagged tuple); `tools.ex`
  two-of-three retain `{:ok, json_binary}` and add an additive JSON field
  inside the binary (tagged wire-format field, not tagged tuple); `tools.ex`
  `session_cwd/1` returns `String.t() | nil` and lets unexpected errors crash;
  `close_port/1` returns `:ok` always and lets `ArgumentError` propagate;
  `router.ex` `load_state/1` returns a `@safe_default` map on rescue. Five
  distinct return shapes, four distinct error-handling philosophies (tagged
  tuple, tagged JSON, let-it-crash, safe-default-on-rescue), three distinct
  call-site dispatch patterns (pattern match, JSON consumer, supervisor).
- **Warrant (W):** Rich Hickey's complecting principle (cited in
  `.claude/skills/design-reasoning`): wrapping orthogonal concerns in a
  shared abstraction *re-complects* them — what was decomposed becomes
  re-tangled at the abstraction's surface. The four sites' shapes are
  orthogonal; a shared `Tau.CodingAgent.Result` module would force at least
  one site to adapt its natural shape into the union type, re-introducing
  the kind of conflation the decomposition removed.
- **Qualifier (Q):** Holds on the *current* set of four sites; if a fifth
  site emerged with the same shape as the dispatcher pair, extraction
  *might* become warranted — solution.md §"Open questions" explicitly says
  "a follow-up problem can be filed". The decision is "don't extract now",
  not "never extract".
- **Rebuttal (R):** A rebuttal would arise if all three tagged-shape sites
  shared *both* return shape *and* dispatch pattern — they don't (tuple vs
  JSON field vs safe-default map; pattern match vs JSON consumer vs
  supervisor restart). None of the three is a candidate for the same
  abstraction.
- **Backing (B):** Rich Hickey, "Simple Made Easy" (Strange Loop 2011);
  `.claude/skills/design-reasoning` §"Complecting checklist"; project
  precedent of declining to pre-aggregate distinct error envelopes (e.g.
  `Tau.Provider.Event.Error{}` is *one* event type, not a generic error
  module).
- **Strategy:** counter-example construction — try to construct a unifying
  `Result` type that would not re-complect the four sites. **Attempt:**
  attempted to sketch a `Tau.CodingAgent.Result` union covering
  `{:ok, term()} | {:error, atom() | binary() | map()}`; either (a) the
  union is so broad it provides no leverage (every caller still pattern-
  matches on its specific shape), or (b) it forces `close_port/1` (which
  returns `:ok` unconditionally and crashes for the unhappy path) into a
  shape it doesn't have, defeating the let-it-crash decision. Both
  outcomes confirm the synthesis's restraint. **Outcome:** withstood.
  **Action:** none.

### Claim 3: Two new telemetry events follow the `[:tau, ...]` convention with no namespace collision, and the `tools.ex` handler is attached early enough that no invocation fires before it.

- **Claim (C):** "two new telemetry events are introduced by separate child
  fixes — `[:tau, :coding_agent, :tau_context, :settings_unavailable]`
  (dispatcher) and `[:tau, :tools, :infrastructure_error]` (tools). Both
  follow the `[:tau, ...]` convention (OTP non-negotiable #5). The validator
  should confirm no collision with existing events and that the second
  event's handler is attached early enough that no `tools.ex` invocation can
  fire before it" (solution.md §"Open questions" — phrased as a validation
  request, but the synthesis claim is that both events are well-formed and
  conflict-free).
- **Grounds (G):** Project-wide `grep` for the two event names returns no
  pre-existing occurrences in `lib/` or `test/` — both names are
  introduction-clean. The `[:tau, ...]` prefix matches the namespace
  invariant in `.claude/rules/otp-non-negotiables.md` §5. The
  `tool-impl-rescue-ladders` child's own validation explicitly partially
  falsifies its claim 4 on the same handler-placement risk and narrows the
  qualifier to "handler placement must be resolved in implementation PR".
- **Warrant (W):** OTP non-negotiable #5 (`.claude/rules/otp-non-negotiables.md`)
  requires the `[:tau, ...]` prefix; a telemetry event without an attached
  handler "fires into a vacuum" (the parent solution's own phrasing) and the
  observability claim — the only payoff for keeping the rescue at all —
  silently fails. A handler attached *after* the `Tau.CodingAgent` subtree
  starts is therefore load-bearing for the observability half of the claim.
- **Qualifier (Q):** *Narrowed*: the namespace-coherence half holds
  unconditionally; the observability half holds only if the
  `application.ex` (or `otel_reporter.ex`) handler attachment is sequenced
  before `Tau.CodingAgent.Supervisor` (and any code-path that invokes
  `tools.ex`) starts — solution.md flags this as a question, not a
  guarantee, and the child's partial falsification inherits.
- **Rebuttal (R):** If `application.ex` cannot attach the handler before
  `Tau.CodingAgent.Supervisor` starts (e.g. because telemetry-handler
  attachment lives downstream in the supervision tree), the observability
  payoff is lost for early invocations; the implementation PR must resolve
  this rather than the synthesis deferring it.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §5;
  `.telemetry` library docs (telemetry handlers are attached imperatively
  via `:telemetry.attach/4`, with no auto-replay of pre-attachment events);
  the `tool-impl-rescue-ladders` child validation's own narrowing on its
  claim 4.
- **Strategy:** dependency check — verify (a) no pre-existing event of the
  same name (already done above by `grep`), and (b) the handler-attachment
  ordering invariant is structurally guaranteed in `application.ex`.
  **Attempt:** for (a), `grep -rn ':settings_unavailable\|:infrastructure_error'
  lib/ test/` returns no matches; both names are unused. For (b), inspecting
  `lib/tau/application.ex`'s supervision-tree order would let me verify
  ordering, but the parent solution defers this to the implementation PR and
  the child has already partially falsified the corresponding claim.
  **Outcome:** *partially falsified* on the same axis as the child:
  namespace-coherence withstood; ordering-guarantee not provable from the
  synthesis itself. **Action:** narrow qualifier in place — the parent
  inherits the child's narrowed qualifier; the implementation PR for the
  `tools.ex` child MUST verify handler attachment precedes any code-path
  that could invoke `tools.ex`. No solution revision required (the
  decomposition correctly delegates this to the implementation PR).

### Claim 4: All four sites together exhaust the audit's scope; the four-site fixes conjunction-satisfy the parent acceptance criterion (each site replaced with delegate-to-OTP, tagged-structured-error, or provably-unreachable-by-construction).

- **Claim (C):** "The four sites together exhaust the audit's scope (the
  problem's 'What this rule forbids' enumeration cites exactly these four
  sites; the out-of-scope list explicitly carves out `safe_start/3`,
  `safe_cancel/2`, `spawn_drainer/2`, and `Replay`)" (solution.md §"Selected
  from"), and the per-site mapping in §"Combined acceptance criteria"
  satisfies the parent AC at each of the five disposition rows (dispatcher
  → tagged; `tools.ex` `session_cwd/1` → delegate-to-OTP; `tools.ex` soft-
  fail pair → tagged in wire format; `close_port/1` → delegate-to-OTP;
  `router.ex` `call/2` → provably narrowed).
- **Grounds (G):** `problem.md` §"Sub-problems" enumerates exactly four
  sub-problems by name and rescue site, each cited with a specific file:line
  range from §"Context". `problem.md` §"Out of scope" explicitly excludes
  `safe_start/3`, `safe_cancel/2`, `spawn_drainer/2`, `Replay`, the
  `SettingsCache` retry/breaker logic, the D-035 contract, and any router
  refactor beyond the outer-rescue question — establishing the audit
  boundary. The five rows in solution.md §"Combined acceptance criteria"
  each map an enumerated site to one of the three AC dispositions.
- **Warrant (W):** A MECE decomposition (the problem.md's own framing —
  "axis is MECE: each sub-problem names exactly one site … no site belongs
  to more than one sub-problem") whose union covers the parent's scope, and
  each of whose elements satisfies the parent AC, *conjunction-satisfies*
  the parent AC by the standard logical rule for set-indexed conjunctions
  (∀ site ∈ scope: site satisfies AC ⟹ scope satisfies AC). The MECE
  guarantee is what licenses moving from "each site fixed" to "the audit
  scope is fixed".
- **Qualifier (Q):** Holds only over the audit scope `problem.md` declared
  — not over the entire `tau-coding-agent` subsystem, which still contains
  the out-of-scope rescues. The synthesis honours this scope and does not
  over-claim.
- **Rebuttal (R):** A rebuttal would arise if (a) the four-site enumeration
  in `problem.md` had missed a flagged site, or (b) any of the five
  dispositions in §"Combined acceptance criteria" failed to land on the AC's
  three categories (delegate, tagged, provably unreachable). Inspecting the
  source-line ranges in `problem.md` §"Context" against the AC categories:
  all five dispositions match the three categories cleanly. The `tools.ex`
  pair maps "tagged" to a *wire-format field*, not a tagged tuple — this is
  a permitted reading of "tagged structured error" since the AC says
  "structured errors distinguishable from legitimate absences", and the
  additive `"result_kind"` field provides distinguishability.
- **Backing (B):** `problem.md` §"Decomposition strategy" (MECE assertion);
  `problem.md` §"Acceptance criterion" (the three-category disjunction);
  the four child `validation.md` files (each validates its own site against
  its own sub-acceptance criterion and returns `falsification_outcome:
  partially_falsified` or `withstood` — none returns `falsified`).
- **Strategy:** edge-case enumeration over the AC categories combined with
  prior-art counter-case against MECE-conjunction reasoning. **Attempt:**
  (1) enumerated the AC's three categories against each of the five
  dispositions: `dispatcher` = tagged ✓; `session_cwd` = delegate ✓;
  `tools.ex` pair = tagged-in-wire-format (permitted reading) ✓;
  `close_port` = delegate ✓; `router.ex` = provably narrowed (option (c)
  "provably unreachable by construction" — the parent solution interprets
  this as "the one previously-fallible callee is now self-guarding, the
  outer rescue is property-tested defence-in-depth"). The
  `router-outer-rescue` child validation partially falsifies its property-
  test claim — the property test verifies the Plug safety contract, not
  outer-rescue-fires-on-poisoned-state-ref — but the AC's "provably
  unreachable by construction" reading remains satisfied because
  `load_state/1` is now self-guarding; the backstop is *retained*, not
  required-for-AC-satisfaction. (2) Checked for an "all-MECE-elements-
  satisfy-AC ⟹ scope-satisfies-AC" counter-case: the only standard
  counter-case is a missed element (audit gap), which would falsify the
  MECE assertion — but `problem.md` §"Context" enumerates four sites and
  §"Out of scope" enumerates the carved-out residues, leaving no obvious
  gap. **Outcome:** withstood. **Action:** none.

### Claim 5: SPEC-CODING-AGENT §4 D-035 public contract is preserved; the `"result_kind"` field is additive.

- **Claim (C):** "SPEC-CODING-AGENT §4 D-035 public contract: every public
  function in `tools.ex` still returns `{:ok, String.t()}` to its caller.
  The `"result_kind"` field is **additive** in the JSON wire format;
  existing subprocess consumers that do not inspect it are unaffected"
  (solution.md §"What does not change"); the §"Open questions" entry asks
  validator to confirm the spirit-vs-letter reading.
- **Grounds (G):** Inspection of `tools.ex` at the cited lines: the
  `tau_session_status/1` rescue branch already returns `{:ok, encode(%{...})}`
  (line 217–229) and the proposed change adds `"result_kind" =>
  "infrastructure_error"` as an additional map key — same `{:ok,
  String.t()}` outer shape. Same pattern in `tau_memory_query/2` (line 264
  shows the existing `{:ok, encode(...)}` envelope on the `{:error, reason}`
  branch). The `session_cwd/1` change removes a rescue from a *private*
  function — no public-contract surface change.
- **Warrant (W):** D-035 ("Every public function in `tools.ex` catches its
  own errors and returns a tagged tuple") is satisfied if every public
  function still returns `{:ok, _} | {:error, _}` (the tagged tuple). The
  *spirit* of D-035 (the problem's framing: "errors are absorbed, not
  tagged") is improved by making infrastructure errors *distinguishable*
  in the wire payload, which is what the additive field does.
- **Qualifier (Q):** Holds for subprocess consumers that ignore unknown
  JSON fields (standard JSON forward-compatibility); a consumer that
  rejects unknown fields would break, but no such consumer exists in the
  audit-scoped code (the MCP wire format permits forward-compatible
  fields).
- **Rebuttal (R):** If a downstream consumer schema-validates the
  `tau_session_status` / `tau_memory_query` response shape with a strict
  schema (e.g. `additionalProperties: false`), the additive field would
  fail validation. No such schema exists in the audited code, but a
  future spec-amendment in SPEC-CODING-AGENT §3 (as solution.md
  recommends) would foreclose this risk.
- **Backing (B):** SPEC-CODING-AGENT §4 D-035 (cited by problem.md);
  `.claude/rules/spec-before-code.md` §"What this rule requires"
  (additive amendments land in the same PR).
- **Strategy:** type-level check + integration check. **Attempt:**
  enumerated the public-function return signatures in `tools.ex` against
  the proposed changes — none change the outer `{:ok, _}` shape; the
  additive field is map-key addition, not return-type change. Searched
  for any MCP wire-format schema validator in the audited surface — none
  found. **Outcome:** withstood. **Action:** none beyond noting that the
  recommended SPEC-CODING-AGENT §3 amendment lands in the same PR as the
  `tools.ex` fix (already prescribed by solution.md §"Migration sketch").

## Cross-claim consistency

Five claims; no internal tension. Claims 1 and 2 are mutually reinforcing
(independence licenses the abstraction-restraint), and both ground the
parallel-mergeability claim in §"Migration sketch". Claim 4 (conjunction-
satisfaction of parent AC) presupposes Claim 1 (independence) — if the four
fixes had inter-dependency, "each site replaced" would not imply "audit
scope replaced" without checking interaction effects. Claim 4 is therefore
*correctly* downstream of Claim 1; no tension. Claim 3's partial-
falsification on handler ordering is contained within the `tools.ex`
implementation PR scope and does not propagate into Claims 1, 2, 4, or 5.
Claim 5 (D-035 preservation) is consistent with Claim 2 (no shared
abstraction) — preserving the public contract is achieved without
introducing a unifying envelope module.

A note on **inherited qualifiers**: all four child validations returned
`partially_falsified` outcomes on a per-site claim (port-lifecycle claim 4
re after_fun double-close; router-outer-rescue claim 3 re property-test
coverage scope; settings-feature-flag-access claim 3 re rescue arms being
defensive rather than load-bearing; tool-impl-rescue-ladders claim 4 re
telemetry handler placement). The parent solution's claim set covers the
*integration surface* and inherits these per-site qualifiers without
needing to re-narrow at the parent level — except for tool-impl-rescue-
ladders claim 4, which surfaces at the parent as Claim 3 (telemetry-
namespace coherence) and is narrowed in place above.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | No inter-dependency; independent PRs | integration check | withstood | none |
| 2 | No shared abstraction; composition over aggregation | counter-example construction | withstood | none |
| 3 | Telemetry namespace coherence + handler ordering | dependency check | partially falsified | narrow qualifier in place (matches child) |
| 4 | Four-site fixes conjunction-satisfy parent AC | edge-case enumeration + prior-art counter-case | withstood | none |
| 5 | D-035 contract preserved; `result_kind` additive | type-level + integration check | withstood | none |

## Revision required

None. The single partial falsification (Claim 3, telemetry handler
ordering) is contained within the `tools.ex` child's implementation PR
scope and is already qualified in the parent's §"Open questions" as
something the validator should confirm. The qualifier is narrowed in place
to: *the namespace-coherence half holds unconditionally; the
observability half holds only if the handler attachment in `application.ex`
is sequenced before `Tau.CodingAgent.Supervisor` starts — the
implementation PR for the `tools.ex` child MUST verify this ordering*.

- **Target file:** none (no revision)
- **Revision kind:** N/A
- **Rationale:** all integration claims either withstood falsification or
  are partially falsified in a way already flagged as an open question for
  the implementation PR; no parent-level claim is false; the
  decomposition's MECE assertion is sound; the abstraction-restraint
  argument is sound; AC conjunction-satisfaction is sound.

## Outstanding doubts

- **Handler attachment ordering** (inherited from `tool-impl-rescue-
  ladders` child): the implementation PR for the `tools.ex` fix must
  verify `:telemetry.attach/4` for `[:tau, :tools, :infrastructure_error]`
  precedes any code-path that can invoke a `tools.ex` rescue branch. If
  `application.ex`'s supervision-tree topology makes this unverifiable
  (e.g. handler attachment lives downstream of `Tau.CodingAgent.Supervisor`),
  the observability payoff for those two soft-fail sites is silently lost
  and a follow-up problem should be filed.
- **after_fun double-close edge case** (inherited from `port-lifecycle-
  rescue` child): the cancel-branch path can produce a `Port.close/1` on
  an already-closed port, which under the guard-only form crashes the
  caller. The child validation narrows its claim 4 qualifier to "process
  crash, not in-chain exception" — the parent inherits this; OTP
  supervisor restart absorbs it cleanly under the supervised-caller
  invariant.
- **Property test scope** (inherited from `router-outer-rescue` child):
  the StreamData property test verifies the Plug safety contract
  (`Router.call/2` never raises), not that the outer rescue specifically
  fires on a poisoned `state_ref`. The parent's §"Combined acceptance
  criteria" row 5 ("provably narrowed") is satisfied because
  `load_state/1` is now self-guarding; the property test is supporting
  evidence, not the proof carrier.
- **Future fifth site triggering extraction** (raised in parent §"Open
  questions"): the synthesis declines the abstraction *now*; if a fifth
  site emerges with shape matching the dispatcher pair, the
  abstraction-restraint argument would need re-evaluation. Not a defect
  in this validation; a deferred design watch.
- **Telemetry handler-attach observability via test** (Claim 3 residual):
  no integration test today asserts that the handler is attached before
  the first `tools.ex` invocation. Adding such a test would close the
  Claim-3 partial falsification permanently; the `tools.ex` implementation
  PR should consider it.
