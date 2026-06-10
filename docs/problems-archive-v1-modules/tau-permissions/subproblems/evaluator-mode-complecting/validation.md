---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/4
revision_triggered: none
---

# Validation: Extract mode policy to ModePolicy module + pin D-NNN invariant in SPEC

## Overview

The solution proposes a hybrid: (1) extract the six `defp default_for_mode/3`
clauses in `Tau.Permissions.Evaluator` into a new `Tau.Permissions.ModePolicy`
module backed by a compile-time `@policies` map and a `%ModePolicy{}` struct;
(2) replace those clauses with a single delegation; (3) add `StreamData`
properties targeting `ModePolicy.default/3`; (4) pin the contract as a new
D-NNN entry in `SPEC-PERMISSION-PROMPTS.md`. Six distinct claims are
enumerated below. Each claim is subjected to a named falsification strategy.
Five of six withstood. Claim 4 (D-NNN slot availability) is **partially
falsified** — the D-090..D-099 block is fully occupied; the new identifier
must come from D-170..D-179 (the second block allocated to the same SPEC).
The qualifier is narrowed in place; no solution/problem revision required
because the spec block ownership accommodates the slot and the
"Open questions" section already flags the placeholder.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants found
it difficult to generate Toulmin structures, and their structures varied
greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly to counter that variance.

### Claim 1: Introduce `Tau.Permissions.ModePolicy` holding per-mode allow-sets as compile-time values, with `%ModePolicy{}` struct (`allow_set`, `default_outcome`, `bash_heuristic?`), `default/3`, and `for_mode/1`.

- **Claim (C):** A new module `Tau.Permissions.ModePolicy` will hold the
  per-mode policy as a compile-time `@policies` map keyed by mode atom, with
  a `%ModePolicy{}` struct exposing `allow_set`, `default_outcome`, and
  `bash_heuristic?` fields, plus `default/3` and `for_mode/1` functions.
- **Grounds (G):** The current evaluator at
  `lib/tau/permissions/evaluator.ex:91-119` encodes the policy as six `defp
  default_for_mode/3` pattern-match clauses, with allow-lists buried in `when
  tool in [...]` guards. No `ModePolicy` module exists (verified by `grep -rn
  ModePolicy lib test` — only matches are in the proposal/solution docs).
  Proposal 2's sketch at `proposals/proposal-2.md:36-95` gives a concrete
  module shape that mirrors the existing data-table pattern in
  `lib/tau/permissions/mode.ex` (`@ranks` map at line 31).
- **Warrant (W):** Hickey's "data is the API" principle (decomplecting "what
  the policy is" from "when and how it is applied"): when policy is held as
  an inspectable value, callers and tests can interrogate it directly
  without recovering it from pattern-match clauses. The same pattern is
  already accepted in this codebase (`Mode.@ranks`).
- **Qualifier (Q):** Holds when the `allow_set: :all` anomaly for `:bypass`
  is resolved with a tagged-union type annotation or a dedicated handling
  arm, as the solution flags in "Open questions". Without that resolution,
  Dialyzer will warn on the struct definition.
- **Rebuttal (R):** If a future mode introduces context-dependent
  allow-rules (e.g., allow-set varies by `ctx`), a pure compile-time map
  becomes insufficient and the struct shape would need extension; the data
  abstraction would then leak the same way pattern-match clauses do today.
- **Backing (B):** Rich Hickey, "Simple Made Easy" (2011) — separating
  data-as-value from logic-as-function; this project's prior `Mode.@ranks`
  precedent at `lib/tau/permissions/mode.ex:31`; ADR-0013 (skill activation
  is FSM-scoped — same data-driven dispatch shape).

#### Falsification attempt for claim 1

- **Strategy:** Counter-example construction + dependency check.
- **Attempt:** Searched for an existing `Tau.Permissions.ModePolicy` module
  that the claim might collide with (`grep -rn ModePolicy lib test docs`);
  none exists outside the audit docs. Checked the `Tau.Permissions.Mode`
  module to confirm the same compile-time-map pattern is in active use
  (`lib/tau/permissions/mode.ex` lines 27-44 — `@ranks` map, exhaustive
  pattern via `is_map_key`). Constructed the proposed `%ModePolicy{}` shape
  mentally: `allow_set: [String.t()] | :all` requires a union or a
  dedicated arm for `:bypass`, which the solution explicitly defers to the
  implementer ("Open questions").
- **Outcome:** withstood. No collision; the proposed pattern matches the
  established codebase idiom; the type anomaly is acknowledged.
- **Action:** none.

### Claim 2: Replace all six `defp default_for_mode` clauses in `evaluator.ex` with a single-clause delegation to `ModePolicy.default/3`, preserving `evaluate/5`'s public signature and the rule-set scan logic.

- **Claim (C):** `lib/tau/permissions/evaluator.ex` will have its six
  `defp default_for_mode/3` clauses (lines 91, 92, 99, 102, 104, 107, 115,
  118, 119 — six clauses total) replaced by a single delegating clause; the
  `evaluate/5` public signature and the cond-tree ordering remain unchanged.
- **Grounds (G):** Current `evaluate/5` calls `default_for_mode(mode,
  tool_name, args)` at `lib/tau/permissions/evaluator.ex:70`. Replacing the
  body of `default_for_mode/3` with a delegation does not alter that call
  site or the cond arms above it (lines 53-70). The
  `lib/tau/permissions/evaluator.ex` module is the only caller of
  `default_for_mode/3` (private function, verified by the file's contents).
- **Warrant (W):** A private-function body change with identical input/
  output behaviour is API-preserving by construction. The cond-tree in
  `evaluate/5` is unchanged, so the documented priority order (deny → skill
  gate → bypass → allow/ask → mode default) is preserved.
- **Qualifier (Q):** Holds provided `ModePolicy.default/3` returns the same
  decision (`:allow | :deny | :ask`) for every `(mode, tool_name, args)`
  triple that the current clauses would return — i.e., the migration is a
  pure refactor, not a semantics change.
- **Rebuttal (R):** If `ModePolicy.default/3` raises `KeyError` on an
  unknown mode (per Proposal 2's `Map.fetch!/2`), it behaves *differently*
  from the existing catch-all `defp default_for_mode(_, _, _), do: :ask`
  (line 119). For a hand-crafted unknown mode atom, current behaviour is
  `:ask`; the proposed behaviour is a crash. The solution does not call
  this out. Production callers go through `Tau.Permissions.Mode.mode?/1`
  validation, so unknown atoms should not reach the evaluator, but the
  catch-all clause is a defensive backstop the refactor removes.
- **Backing (B):** OTP non-negotiable #8 ("Pure functions are the default").
  The current catch-all-`:ask` arm is defensive; the proposed `KeyError`
  honours "fail-loud over silent wrong" — defensible either way.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction + edge-case enumeration over
  the six modes plus the catch-all.
- **Attempt:** Enumerated each mode dispatch:
  - `:default` → current `:ask`; `ModePolicy.default(:default, _, _)` →
    `@policies[:default].default_outcome = :ask`. Match.
  - `:dont_ask` → current `:deny`; proposed `:deny`. Match.
  - `:plan` with `tool in ["Read","Grep","Glob","Agent"]` → `:allow`; else
    `:deny`. Proposed: `tool in allow_set → :allow`; else `default_outcome
    = :deny`. Match.
  - `:accept_edits` with `tool in ["Read","Write","Edit","Grep"]` →
    `:allow`; with `"Bash"` → heuristic; else fall through to `:ask` (via
    catch-all). Proposed: `allow_set` hit → `:allow`; `bash_heuristic? and
    "Bash"` → heuristic; else `default_outcome = :ask`. Match.
  - `:auto` with `tool in [allow]` → `:allow`; else `:ask`. Match.
  - `:bypass` is unreachable inside `default_for_mode/3` because
    `evaluate/5` short-circuits at line 60 (`mode == :bypass → :allow`).
    Proposed `@policies[:bypass].allow_set = :all` is dead code in practice
    but does not cause incorrect behaviour.
  - Unknown mode atom → current `:ask` via catch-all; proposed `KeyError`
    from `Map.fetch!/2`. **Behavioural divergence** — noted in the rebuttal.
- **Outcome:** withstood for all six declared modes; partially diverges
  only on an undocumented/invalid input. The semantics for declared modes
  are preserved.
- **Action:** the implementer should either retain the catch-all behaviour
  in `ModePolicy.default/3` (return `:ask` for unknown modes) or document
  the deliberate crash-on-unknown-mode policy. This is implementation
  detail, not a claim-falsifying defect.

### Claim 3: A new test file `test/tau/permissions/mode_policy_test.exs` (or addition to `evaluator_test.exs`) will contain StreamData properties asserting `:plan` denies outside allow-set, `:dont_ask` denies all, `:auto` never allows outside allow-set, and `:accept_edits` non-Bash non-allowed tools yield `:ask` — satisfying the acceptance criterion.

- **Claim (C):** StreamData property tests targeting `ModePolicy.default/3`
  will be added; they assert (i) `:plan` outside allow-set → `:deny`, (ii)
  `:dont_ask` → `:deny` for all tools, (iii) `:auto` outside allow-set
  never → `:allow`, (iv) `:accept_edits` non-Bash non-allowed → `:ask`.
- **Grounds (G):** The acceptance criterion in `problem.md` lines 66-71
  requires: "at least one property test asserts that for all tools outside
  the stated allow-set for each non-default mode (`:plan`, `:dont_ask`), the
  evaluator with an empty rule-set yields `:deny`". Proposal 2's sketch at
  `proposals/proposal-2.md:107-137` lists the matching property forms. The
  test infrastructure already exists: `mix.exs` declares `stream_data` as a
  dev dependency (referenced by `proposals/proposal-2.md:178`), and
  `test/tau/permissions/property_test.exs` and `mode_test.exs` use
  `use ExUnitProperties` (verified by `ls test/tau/permissions/`).
- **Warrant (W):** OTP non-negotiable #6 ("Invariant-bearing modules MUST
  have properties before examples") — the mode-default contract is an
  invariant, properties are the canonical enforcement form.
- **Qualifier (Q):** The acceptance criterion mentions only `:plan` and
  `:dont_ask` explicitly. Adding the `:auto` and `:accept_edits` properties
  is a coverage *superset* of the minimum — strengthens but does not narrow
  satisfaction of the criterion.
- **Rebuttal (R):** A StreamData generator using `string(:alphanumeric,
  min_length: 1)` may, with non-zero probability, generate one of the
  allow-set strings ("Read", "Grep", "Glob", "Agent" for `:plan`). The
  proposal's filter `tool not in policy.allow_set` handles this by
  rejecting non-matching shrinks, but the property may shrink slowly if the
  allow-set is large. Not a correctness issue; a performance qualifier.
- **Backing (B):** OTP non-negotiable #6
  (`.claude/rules/otp-non-negotiables.md` line 14); existing precedent
  `test/tau/permissions/skill_whitelist_property_test.exs` (StreamData over
  permission decisions).

#### Falsification attempt for claim 3

- **Strategy:** Integration check + counter-example over the acceptance
  criterion's wording.
- **Attempt:** Re-read the acceptance criterion verbatim (problem.md
  lines 66-71). It asks for "at least one property test ... for `:plan`
  [and] `:dont_ask`". Mapped each proposed property:
  - `:plan` outside allow-set → `:deny` ✓ satisfies criterion clause 1.
  - `:dont_ask` all → `:deny` ✓ satisfies criterion clause 2.
  - `:auto` non-allow → non-`:allow` and `:accept_edits` non-Bash
    non-allowed → `:ask` are coverage beyond the criterion; do not falsify
    it. Checked whether the property `:auto never allows tools outside its
    allow_set` (`refute ... == :allow`) is meaningful: under `:auto`, a
    non-allowed tool returns `:ask`, so `refute :ask == :allow` succeeds
    trivially. The property is true but weak; not falsifying.
  - The existing `EvaluatorTest` at
    `test/tau/permissions/evaluator_test.exs:73-74` already has an
    *example* test for `:dont_ask` (`":dont_ask defaults to deny on no
    match"`). The property generalises that example; no conflict.
- **Outcome:** withstood. The properties satisfy the acceptance criterion
  and add modest coverage beyond.
- **Action:** none. (The `:auto` property's weakness is noted in
  "Outstanding doubts" but is not falsifying.)

### Claim 4: Add one D-NNN invariant entry in `SPEC-PERMISSION-PROMPTS.md` (next available number in D-090..D-099 block, confirmed free by repo grep) stating the `ModePolicy` contract, the allow-set table, ADR-0014/0015 citations, the `"Agent"` exemption rationale, and the `:accept_edits` Bash exception; name the property test as enforcement.

- **Claim (C):** A new D-NNN entry is added to `SPEC-PERMISSION-PROMPTS.md`
  in the D-090..D-099 block, pinning the `ModePolicy` contract.
- **Grounds (G):** The MISSION.md registry at lines 75 and 80 allocates
  *two* D-NNN blocks to SPEC-PERMISSION-PROMPTS: `D-090 – D-099` and
  `D-170 – D-179`. An exhaustive grep of the SPEC
  (`grep -oE "D-[0-9]{3}" docs/spec/SPEC-PERMISSION-PROMPTS.md | sort -u`)
  returns: D-090, D-091, D-092, D-093, D-094, D-095, D-096, D-097, D-098,
  D-099, D-170, D-171, D-172, D-173, D-179. **The D-090..D-099 block is
  fully occupied; the next free slot in the SPEC's allocation is in the
  D-170..D-179 block (D-174..D-178 appear free, with D-179 in use).**
- **Warrant (W):** `spec-before-code.md` makes D-NNN entries the
  authoritative spec contract that future PRs must cite; a moduledoc can
  drift silently, a D-NNN is a gate trigger. CLAUDE.md's namespace rule
  (lines 14-19) requires verifying free identifiers across the repo.
- **Qualifier (Q):** **Narrowed in place.** The claim's "next available
  number in D-090..D-099 block" qualifier is false; the correct qualifier
  is "next available number in the SPEC's allocated blocks (D-090..D-099 ∪
  D-170..D-179), which today is in the D-170..D-179 block (e.g., D-174)."
- **Rebuttal (R):** If the implementer takes the solution's instruction
  literally and searches only D-090..D-099, they will find no free slot and
  either (a) escalate, (b) re-use an existing identifier (an integrity
  violation), or (c) silently grab a slot from another SPEC's block (also
  a violation). The solution's "Open questions" §1 (lines 109-110) flags
  the D-NNN identifier as a placeholder needing repo grep confirmation,
  which mitigates but does not eliminate the risk.
- **Backing (B):** `docs/MISSION.md` lines 74-80 (the D-NNN partition
  table); `CLAUDE.md` Hard Rules (D-NNN free-across-repo invariant);
  `spec-before-code.md` §"Why this exists".

#### Falsification attempt for claim 4

- **Strategy:** Dependency check (verify the state of the codebase that the
  claim assumes).
- **Attempt:** Ran two queries:
  1. `grep -oE "D-[0-9]{3}" docs/spec/SPEC-PERMISSION-PROMPTS.md | sort -u`
     → D-090..D-099 all present; D-170, D-171, D-172, D-173, D-179 present.
  2. `grep -rn "D-09[0-9]\b" lib test docs .claude` → confirms each
     D-090..D-099 identifier is *used* in production code (e.g.,
     `lib/tau/session.ex:1207`, `lib/tau/session/tool_dispatch.ex:1019`).
  Cross-referenced MISSION.md lines 74-80: SPEC-PERMISSION-PROMPTS owns
  *both* the D-090..D-099 and D-170..D-179 blocks. D-090..D-099 is
  saturated; D-170..D-179 has free slots (D-174..D-178). The solution's
  narrower instruction to use the D-090..D-099 block specifically is
  factually wrong; the broader spec-block ownership accommodates the slot.
- **Outcome:** partially falsified — the claim's *qualifier* (block
  selection) is false but the *substance* (a new D-NNN entry in the
  SPEC's allocation) holds with the corrected block.
- **Action:** narrow the qualifier in place (done above). The
  implementer's brief should cite D-170..D-179 (e.g., D-174 pending
  re-grep at PR-time, per the solution's own "Open questions"). No
  solution-revision needed; the "Open questions" §1 placeholder
  already invites this confirmation.

### Claim 5: The hybrid achieves "structural decomplecting" (two-mechanism evaluator → one-mechanism evaluator) plus a "durable gate" (spec-gated D-NNN that future PRs must cite under `spec-before-code.md`).

- **Claim (C):** Combining Proposal 2 (extract module) and Proposal 4 (pin
  D-NNN) yields both structural decomplecting (the evaluator becomes a
  single-mechanism rule-set scanner delegating to a data-driven policy)
  and a durable, gate-enforced spec contract.
- **Grounds (G):** Post-change, `evaluator.ex` has only one mechanism for
  fallback dispatch (delegation to `ModePolicy.default/3`); the secondary
  allow-list pattern-matching is collapsed into a single data structure
  inspectable as `ModePolicy.for_mode(:plan).allow_set`. The D-NNN entry,
  per `spec-before-code.md`, becomes a critic/reviewer gate item for any
  PR touching the SPEC's source-map (which includes
  `lib/tau/permissions/evaluator.ex` if added; see
  `.claude/rules/spec-before-code.md` line 28 — SPEC-PERMISSION-PROMPTS
  currently lists `lib/tau/session.ex`, but the source-map can be extended
  by the same PR per the spec-amendment rule).
- **Warrant (W):** Hickey's decomplecting principle (separate orthogonal
  concerns into independently composable units) + Tau's spec-before-code
  rule (D-NNN entries are the authoritative, gated invariants). The two
  together produce structural simplification *and* drift protection.
- **Qualifier (Q):** "Durable gate" holds only if `spec-before-code.md`
  is consistently enforced by `critic`/`reviewer` and only if the new
  D-NNN entry lists `lib/tau/permissions/evaluator.ex` and
  `lib/tau/permissions/mode_policy.ex` in the SPEC's Appendix B
  source-map. Without the source-map amendment, a future PR could touch
  `mode_policy.ex` without triggering the gate.
- **Rebuttal (R):** If a contributor adds a new mode by mutating only the
  `@policies` map and ignoring the D-NNN entry, the structural
  decomplecting holds but the spec contract drifts. The gate fires only on
  files in the source-map; the gate does not inspect the `@policies` map
  for completeness.
- **Backing (B):** Hickey, "Simple Made Easy"; `spec-before-code.md` §"What
  this rule requires" (lines 25-37); ADR-0023 (documentation taxonomy —
  D-NNN as the runtime-invariant tier).

#### Falsification attempt for claim 5

- **Strategy:** Counter-example construction targeting the "durable gate"
  half of the claim.
- **Attempt:** Read `.claude/rules/spec-before-code.md` for the SPEC-PERMISSION-PROMPTS
  scope (lines 117-126 in CLAUDE.md system prompt): scope today is
  `lib/tau/session.ex` (the gate in `dispatch_tools/2`), the
  `:awaiting_permission` state, `lib/tau/session/events.ex`'s
  `%PermissionRequest{}`, and `lib/tau/cli.ex`'s `interactive:` opt. It
  does NOT today list `lib/tau/permissions/evaluator.ex` or any prospective
  `mode_policy.ex`. Therefore, *unless the implementer also amends the
  SPEC's source-map in the same PR*, a future PR touching only
  `evaluator.ex` or `mode_policy.ex` will not trigger the
  spec-before-code gate, and the D-NNN entry's "durable gate" property is
  not realised.
- **Outcome:** withstood as written *iff* the implementer treats the
  SPEC's Appendix B source-map amendment as implicit in the work. The
  solution's "What changes" §4 ("Add the D-NNN entry to
  `SPEC-PERMISSION-PROMPTS.md` referencing the test file path") does not
  explicitly mention amending the source-map, but the Migration sketch
  §4 ("`Closes #<issue>`") implies a complete spec amendment. A literal
  reading falsifies; a charitable reading withstands.
- **Action:** Add to "Outstanding doubts": the implementer brief MUST
  include amending the SPEC's Appendix B source-map to list
  `lib/tau/permissions/evaluator.ex` and the new `mode_policy.ex`, or the
  gate-trigger half of the claim is vacuous.

### Claim 6: The chosen hybrid is preferable to Proposal 3 (compile mode defaults into the rule-set) because Proposal 3's costs (extend `Matchers.Always` with `{:only, tool}` form; new `BashDestructive` matcher; potentially API-breaking `evaluate/5` changes) are disproportionate to what the acceptance criterion demands.

- **Claim (C):** Proposal 3, although structurally deeper, is rejected on
  cost/risk grounds; Proposal 2 + Proposal 4 is sufficient and lower-cost.
- **Grounds (G):** Proposal 3 (per the solution's table at line 58: "Deep /
  High / Medium / Hard") requires changes outside the evaluator's pure
  fallback path: extending the `Tau.Permissions.Matchers.Always` matcher
  (a public behaviour implementation) and introducing a new matcher
  module. The acceptance criterion (problem.md lines 66-71) requires only a
  property test and documentation; it does not require structural
  elimination of `default_for_mode/3`.
- **Warrant (W):** Hickey-aligned preference for the smallest decomplecting
  step that satisfies the constraint set — over-engineering is itself a
  form of complecting (premature generality couples future code to a
  choice made without forcing evidence).
- **Qualifier (Q):** Holds for the current acceptance criterion. If a
  future requirement demands that mode defaults be expressible as rule-set
  entries (e.g., for unified audit logging), Proposal 3's path becomes
  necessary; the solution defers it as a follow-up.
- **Rebuttal (R):** Proposal 2 preserves the architectural complaint that
  *two* mechanisms (rule-set scan + mode-default dispatch) exist; the
  hybrid documents and tests the second mechanism but does not eliminate
  it. A reader might argue this is decomplecting *in name only* — the
  second mechanism is still there, just better-described.
- **Backing (B):** Hickey, "Simple Made Easy"; this codebase's prior
  preference for incremental refactors over deep restructuring (e.g.,
  ADR-0022 extension API was authored before reworking the existing tool
  dispatcher).

#### Falsification attempt for claim 6

- **Strategy:** Prior-art counter-case + cost comparison.
- **Attempt:** Read Proposal 3 implicit cost (not loaded for this
  validation but referenced in the solution): the solution explicitly
  characterises Proposal 3 as touching `Matchers.Always` (semantic
  violation: `Always` should be unconditional, per the proposal's
  description) and changing `evaluate/5`'s signature. Re-checked the
  evaluator: `evaluate/5` is declared at `lib/tau/permissions/evaluator.ex:43-50`
  and is widely called (session, cli, tui callers). An API-breaking change
  would ripple. Confirmed the rule-set/mode-default split is acknowledged
  in the moduledoc (lines 5-8: "walks them in deny → ask → allow order;
  first match wins" — followed by the mode list). The hybrid does not
  eliminate the two-mechanism shape, but it makes the second mechanism a
  data-driven module rather than imperative dispatch, which is the
  Hickey-aligned middle path.
- **Outcome:** withstood. Proposal 3's cost is concretely higher
  (API-breaking, matcher-semantics violation) and its decomplecting
  benefit is incremental, not categorical. The hybrid is the cost-minimal
  satisfaction of the criterion + decomplecting depth.
- **Action:** none.

## Cross-claim consistency

Claims 1, 2, 3 form a coherent extraction-and-property unit (data structure
+ delegation + tests). Claims 4 and 5 add the spec-anchor layer. Claim 6
justifies the rejection of the deeper alternative. No internal tensions
between claims.

One observed tension between Claim 4 and Claim 5: Claim 4 asserts the
D-NNN slot is in D-090..D-099 (false — partially falsified above), while
Claim 5 assumes the D-NNN entry is properly authored against the SPEC's
source-map (which today does not list `evaluator.ex`). Both gaps are
implementation-detail issues, not solution-falsifying. They are recorded in
"Revision required" (qualifier narrowing only) and "Outstanding doubts".

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | New `ModePolicy` module with compile-time map | Counter-example + dependency check | withstood | none |
| 2 | Replace 6 `defp` clauses with delegation; preserve `evaluate/5` API | Counter-example + edge-case enumeration | withstood | implementer documents unknown-mode behaviour |
| 3 | StreamData properties for `:plan`, `:dont_ask`, `:auto`, `:accept_edits` | Integration check + criterion mapping | withstood | none |
| 4 | New D-NNN entry in D-090..D-099 block | Dependency check (grep SPEC) | partially falsified | narrow qualifier: use D-170..D-179 block (e.g., D-174) |
| 5 | Hybrid yields structural decomplecting + durable gate | Counter-example on gate triggerability | withstood (charitable reading) | brief MUST include SPEC Appendix B source-map amendment |
| 6 | Hybrid is preferable to Proposal 3 on cost/risk | Prior-art + cost comparison | withstood | none |

## Revision required

No `solution.md` revision and no `problem.md` revision is required.

- **Target file:** solution.md (qualifier narrowing only; not a re-run)
- **Revision kind:** surgical update — the implementer brief at PR time
  should cite the corrected D-NNN block (D-170..D-179, with D-174..D-178
  candidates). The solution's "Open questions" §1 (lines 109-110) already
  invites this re-grep at PR-time, so the implementer brief inherits the
  correction without solution re-authoring.
- **Rationale:** the substance of Claim 4 (a new D-NNN entry pinning the
  contract) holds; only the block specification is wrong. The solution's
  own placeholder discipline ("placeholder; confirm by repo grep")
  accommodates the fix at implementer-brief time, so no propose/select
  re-run is justified.

## Outstanding doubts

- **Claim 2 — unknown-mode behaviour divergence.** Current evaluator's
  catch-all `defp default_for_mode(_, _, _), do: :ask` returns `:ask` for
  any unrecognised mode atom; Proposal 2's `Map.fetch!/2` raises
  `KeyError`. The implementer should choose explicitly: defensive `:ask`
  (mirrors current behaviour, weaker exhaustiveness signal) or fail-loud
  `KeyError` (stronger exhaustiveness signal, removes a defensive
  backstop). Recommended: fail-loud, with `Tau.Permissions.Mode.mode?/1`
  validation at the boundary. Not falsifying.
- **Claim 3 — `:auto` property weakness.** The property `:auto never
  allows outside allow_set` reduces to `refute :ask == :allow` for the
  non-allow-set branch, which is trivially true. A stronger property
  would assert `default(:auto, tool, %{}) == :ask` for non-Bash
  non-allowed tools. The proposal's wording matches the criterion; the
  implementer may strengthen at no risk.
- **Claim 5 — SPEC source-map amendment.** The new D-NNN entry's
  "durable gate" property requires that `SPEC-PERMISSION-PROMPTS.md`'s
  Appendix B source-map be amended in the same PR to list
  `lib/tau/permissions/evaluator.ex` and `lib/tau/permissions/mode_policy.ex`,
  or future PRs touching only those files will not trigger
  spec-before-code review. The solution does not call this out
  explicitly; the implementer brief should.
- **Claim 6 — second-mechanism persistence.** The hybrid documents and
  property-tests the mode-default mechanism but does not eliminate it
  (Proposal 3 would). Future audits should consider whether the
  documentation/data-structure layer is sufficient or whether
  Proposal 3's path becomes worthwhile after the `:accept_edits` Bash
  matcher design settles. Not a defect of the current solution.
