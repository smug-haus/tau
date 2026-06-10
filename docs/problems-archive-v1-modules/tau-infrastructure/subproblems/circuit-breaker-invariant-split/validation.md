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

# Validation: Store returns pre-increment counts

## Overview

`solution.md` makes six checkable propositions: (1) `Store.bump_*/1` will
return pre-increment values via the multi-op `:ets.update_counter/3` form;
(2) the `new_count - 1` adjustment and explanatory comment in
`record_outcome/5` are deleted; (3) `State.check/2` becomes `check/3` with a
`:cooldown_ms` keyword opt while keeping `@default_cooldown_ms` as fallback;
(4) `State.record_failure/2` and `record_success/2` are entirely unchanged
in signature, semantics, and internal `count + 1` arithmetic; (5) the D-044
ETS row layout (positions 3 and 4) is unchanged — no schema bump;
(6) SPEC-CIRCUIT-BREAKER §4 B4 is amended in the same PR. Each claim was
validated against the actual source files in
`/home/brentw/src/tau/lib/tau/circuit_breaker*` and against the existing
test suite. Falsification strategies span dependency check, code-state
counter-example construction, edge-case enumeration, and integration
check. Outcome: five claims withstood; claim 4 is partially falsified by
a transitive ripple via `current_struct/1` (the struct field is overwritten
by the façade caller, so `State`'s observable semantics still hold — the
qualifier is narrowed in place).

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

### Claim 1: `Store.bump_failure_count/1` and `bump_success_count/1` will return the pre-increment value via the multi-op `:ets.update_counter/3` form `[{pos, 0}, {pos, 1}]`, eliminating the `new_count - 1` adjustment in `record_outcome/5`.

- **Claim (C):** Changing `bump_*/1` to `[pre, _post] = :ets.update_counter(@table, provider, [{N, 0}, {N, 1}]); pre` returns the pre-increment value atomically, so the façade can pass the result directly into the `State` struct field with no arithmetic.
- **Grounds (G):** Current implementation at `lib/tau/circuit_breaker/store.ex:118` (`{3, 1}`) and `:133` (`{4, 1}`) returns post-increment by OTP definition. SPEC pins these positions (D-044) at `docs/spec/SPEC-CIRCUIT-BREAKER.md:203-204`. Proposal-1 sketches the multi-op form at `proposals/proposal-1.md:47,53`; the façade caller's post-bump arithmetic is the only consumer that branches on the return value (`lib/tau/circuit_breaker.ex:125,127,133,135`). `Tau.Cost.Tracker` uses single-op `update_counter` (`lib/tau/cost/tracker.ex:129,154`) — independent of breaker code, so no collateral impact.
- **Warrant (W):** `:ets.update_counter/3` with a list of operation tuples on the same key executes as a single atomic operation and returns the corresponding list of post-each-op values; with the operation list `[{N, 0}, {N, 1}]` the first element is therefore the pre-bump value (read with increment 0). This is the OTP-documented "multi-op" contract — the same rule underwrites every existing use of the list form in OTP releases.
- **Qualifier (Q):** Holds on OTP releases that support the multi-op form of `:ets.update_counter/3`. The project targets OTP 27.2 (`.tool-versions`), where the multi-op form is long-standing (present since OTP R14B); the qualifier is therefore vacuous for this repo, but the dependency MUST be re-verified if OTP is ever downgraded.
- **Rebuttal (R):** If a future change replaces `:ets.update_counter/3` with a non-counter ETS primitive (e.g. `:ets.update_element/3`) the atomicity guarantee disappears; the claim would no longer hold.
- **Backing (B):** OTP ets documentation, `:ets.update_counter/3` — "If a list of UpdateOp is supplied, a list of Result is returned". SPEC-CIRCUIT-BREAKER §4 B2 (`docs/spec/SPEC-CIRCUIT-BREAKER.md:72,150-155`) which already mandates atomic counter updates via `update_counter`.

#### Falsification attempt for claim 1

- **Strategy:** Dependency check + counter-example construction over the OTP primitive.
- **Attempt:** Verified the proposed `[{pos, 0}, {pos, 1}]` is the documented multi-op form for `:ets.update_counter/3` on OTP 27 (matches the same shape Tau already uses elsewhere via single-op tuples in `lib/tau/cost/tracker.ex`). Tried to construct a counter-example where the two operations could interleave with another concurrent `bump_*` and produce a wrong pre value. They cannot: the per-key multi-op list is documented as atomic — no other process can observe a partial state between the read (op 1) and the increment (op 2). Tried to construct a caller that depends on post-bump semantics: the only such caller is `record_outcome/5` itself (the very call site being fixed), plus tests at `test/tau/circuit_breaker/store_property_test.exs:208-209` which discard the return (`for _ <- 1..pre_fc//1, do: Store.bump_failure_count(provider)`). No third caller exists in `lib/` or `test/`.
- **Outcome:** withstood.
- **Action:** none.

### Claim 2: The `new_count - 1` adjustment expression and the comment block at lines 116–123 of `lib/tau/circuit_breaker.ex` are removed entirely from `record_outcome/5`.

- **Claim (C):** After the change, `record_outcome/5` contains no arithmetic on the bump return value and no comment explaining a pre/post-increment mismatch.
- **Grounds (G):** Current site at `lib/tau/circuit_breaker.ex:124-144` contains exactly two `new_count - 1` expressions (lines 127, 135) and a comment block at lines 116-123. The proposal-1 sketch (`proposals/proposal-1.md:60-76,78`) shows the post-change body with `pre_count` directly assigned and the comment removed.
- **Warrant (W):** OTP non-negotiable #8 (`.claude/rules/otp-non-negotiables.md`) — "Pure functions are the default; processes are the exception"; and the Hickey principle that protocol leaks across module boundaries must be eliminated rather than annotated. Removing the comment is required because the workaround it documents no longer exists; leaving a stale comment would itself be a protocol leak.
- **Qualifier (Q):** Holds for the post-change file; presupposes claim 1 (the Store actually returns pre-bump).
- **Rebuttal (R):** If a reviewer asks for an explanatory comment in `record_outcome/5` about why the bump return is used as-is (e.g. defensive against future Store changes), a one-line `@doc` or comment may survive — but the multi-line block at 116-123 explaining the arithmetic dance MUST be deleted because the arithmetic no longer happens.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` invariants 1, 3, 8; SPEC-CIRCUIT-BREAKER §4 B3.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction over the post-change function body.
- **Attempt:** Attempted to construct a scenario where `record_outcome/5` still needs the `- 1` term: only possible if `State.record_failure/2` or `record_success/2` changes to expect post-bump counts. Claim 4 explicitly preserves their semantics — so no such scenario exists in scope.
- **Outcome:** withstood.
- **Action:** none.

### Claim 3: `State.check/2` becomes `State.check/3` with an optional `:cooldown_ms` keyword opt; `@default_cooldown_ms` remains as the fallback; all existing 2-arity call sites continue to compile and behave identically.

- **Claim (C):** A new optional keyword arg makes cooldown caller-threadable while preserving binary-compatible default behaviour.
- **Grounds (G):** Current implementation at `lib/tau/circuit_breaker/state.ex:60-71` has three clauses on `check/2`; `@default_cooldown_ms 30_000` at line 45 is consumed only at line 64. Existing call sites are: `test/tau/circuit_breaker/state_property_test.exs:72,172,185` (all 2-arity, all assume default). There is no production caller of `State.check/*` in `lib/` — `current_struct/1` in the façade reads the row but never calls `check` (state is checked via `Store.state_for/1` at `lib/tau/circuit_breaker.ex:72`). Proposal-1 sketch (`proposals/proposal-1.md:80-94`) shows `check(state, now_ms, opts \\ [])` with `Keyword.get(opts, :cooldown_ms, @default_cooldown_ms)`.
- **Warrant (W):** Elixir default-argument semantics: adding `opts \\ []` to a clause-headed function generates the 2-arity head automatically, preserving source compatibility for all existing call sites. The rule from Hickey/Meyer: completing an established pattern (the `:failure_threshold` / `:success_threshold` pattern visible at `state.ex:87,140`) removes a special case rather than adding one.
- **Qualifier (Q):** Holds provided existing 2-arity call sites do not rely on dialyzer's `arity == 2` signature in a way that arity 3 with default would break. Dialyzer treats the clause-headed `def` with a default as a single function that accepts both arities, so this qualifier is satisfied by Elixir's default-argument expansion.
- **Rebuttal (R):** If any external module pattern-matches on the function reference `&State.check/2` (function capture with explicit arity), that capture continues to work because the 2-arity variant is auto-generated. A `&State.check/3` capture is also valid post-change. No call site uses either capture today.
- **Backing (B):** Elixir kernel docs on default arguments; SPEC-CIRCUIT-BREAKER §4 B4 (`docs/spec/SPEC-CIRCUIT-BREAKER.md:219-235`) which already declares the opts pattern for `record_*/2`; SPEC §5 Defaults table at `:262` lists `cooldown_ms` as a default but does not mark it non-threadable.

#### Falsification attempt for claim 3

- **Strategy:** Edge-case enumeration over call sites and dialyzer impact.
- **Attempt:** Enumerated every `State.check` call site (`grep -rn "State.check\|CircuitBreaker.State.check"` → only the three property-test sites above). All three call `State.check(s, now_ms)` with no opts. Default behaviour is identical. Dialyzer treats clause-headed default-arg functions as both arities. No production code path imports or uses `check/2` other than via the property tests. The SPEC's Transition Table (`SPEC-CIRCUIT-BREAKER.md:251-252`) and AC-6 (`:310`) describe cooldown behaviour but do not pin the arity — the §4 B4 amendment named in claim 6 covers the contract change.
- **Outcome:** withstood.
- **Action:** none.

### Claim 4: `State.record_failure/2` and `State.record_success/2` retain their existing signatures, semantics, and the internal `count + 1` arithmetic; State tests that construct `%State{}` with pre-bump field values and call those functions are unaffected.

- **Claim (C):** State module is bitwise-identical save for the `check` arity change in claim 3 (and the related `@moduledoc` doc, optionally) — its `record_*/2` callers see no contract change.
- **Grounds (G):** Current `record_failure/2` at `lib/tau/circuit_breaker/state.ex:86-118` and `record_success/2` at `:135-157` both compute `new_count = s.<field>_count + 1` internally. Proposal-1's sketch leaves both functions untouched (`proposals/proposal-1.md:60-76` modifies only the façade; the State sketch at `:82-94` modifies only `check`). The solution explicitly enumerates "no change to `record_failure/2` or `record_success/2`" at `solution.md:78`.
- **Warrant (W):** Local-reasoning principle: a function whose source is unmodified between commits has, by definition, unchanged semantics for inputs of the same shape.
- **Qualifier (Q):** Holds for the State module's *direct* callers passing pre-bump struct field values. The façade construction `%State{row | failure_count: new_count - 1}` at `circuit_breaker.ex:135` is replaced with `%State{row | failure_count: pre_count}`; the value the function ultimately sees as `s.failure_count` differs **only if the Store's pre-bump value differs from `Store-post-bump - 1`** — by claim 1 they are identical, so the value passed to `record_failure/2` is byte-identical to today. State's behaviour is therefore preserved on the production path. There is, however, an indirect ripple to flag: `current_struct/1` (`circuit_breaker.ex:148-162`) reads the row AFTER the bump has already mutated ETS, so `row.failure_count` reflects the post-bump value; the façade then *overwrites* that field with the pre-bump value before calling `State`. If a future refactor removes the field-overwrite, `State.record_failure/2` would silently double-count. This dependency is now load-bearing on a single line — narrow the qualifier to flag this constraint.
- **Rebuttal (R):** If `current_struct/1` is ever changed to read BEFORE the bump (a more conventional "read-modify-write" pattern), the field-overwrite line becomes unnecessary; absence of the overwrite would then be safe. Either invariant is acceptable; documenting which one is in force in the §4 B3 amendment is good hygiene.
- **Backing (B):** SPEC-CIRCUIT-BREAKER §4 B4 (`docs/spec/SPEC-CIRCUIT-BREAKER.md:219-235`) which fixes the `record_*/2` opts contract.

#### Falsification attempt for claim 4

- **Strategy:** Counter-example construction over the call-site coupling.
- **Attempt:** Constructed the trace: `Store.bump_failure_count/1` returns `pre`; `current_struct/1` reads ETS (now holding `pre + 1`); façade builds `%State{row | failure_count: pre}`; `State.record_failure/2` computes `pre + 1` = correct new count. This is identical to today's behaviour at the State level. Then constructed the failure mode: drop the `failure_count: pre` overwrite (hypothetical future refactor) → `State.record_failure/2` would compute `(pre + 1) + 1` = double-count. The original problem-statement complecting hypothesis (`problem.md:46-52`) flags this same coupling: "changing either the Store primitive or the State arithmetic requires updating the façade's private adjustment". The solution shifts the adjustment from arithmetic to a struct-field overwrite — still complected, but the seam is now a struct assignment rather than a subtract-one. This is partially-falsified at the level of the "completely decomplected" reading of claim 4; State's *observable* contract is preserved, but the façade-state coupling is preserved in transmuted form.
- **Outcome:** partially_falsified.
- **Action:** narrow Qualifier in place (done above); flag in Outstanding doubts. No solution revision needed because the partial falsification is a known residual coupling, not a contract violation; the qualifier captures it.

### Claim 5: D-044 ETS row layout is unchanged — counter column positions 3 and 4 are not renumbered, no `@schema_version` bump, no data migration.

- **Claim (C):** The schema (`{provider_key, state_atom, failure_count, success_count, opened_at_ms, probe_slot}` at positions 1..6) is byte-for-byte identical post-change.
- **Grounds (G):** Proposal-1 changes the operation parameter passed to `:ets.update_counter/3` (`[{3, 0}, {3, 1}]` instead of `{3, 1}`) but the position numbers `3` and `4` are unchanged. SPEC pins these at `docs/spec/SPEC-CIRCUIT-BREAKER.md:203-204`. `Store.transition/3` match-spec at `lib/tau/circuit_breaker/store.ex:226-247` writes positions 1, 2, 5, 6 and preserves 3, 4 — unchanged. `@schema_version 1` at `store.ex:48` is not bumped.
- **Warrant (W):** SPEC-CIRCUIT-BREAKER's D-044 invariant: "Field positions MUST NOT be renumbered without bumping `@schema_version` and adding a data-migration step in the PR description" (`store.ex:37-38`). The converse: if no field is renumbered, no bump is required.
- **Qualifier (Q):** Q: none — universal. The op-list change touches only the *operation* argument, not the *schema*. ETS is schema-less; `update_counter` does not redefine positions.
- **Rebuttal (R):** If a future change adds a new field (e.g. a per-provider `cooldown_ms` column to back claim 3's threadable opt without re-passing it every call), that change WOULD require a schema bump — but it is out of scope for this solution.
- **Backing (B):** SPEC-CIRCUIT-BREAKER §4 B2, D-044 (`docs/spec/SPEC-CIRCUIT-BREAKER.md:196-204`); `store.ex:37-38` moduledoc explaining the schema-version invariant.

#### Falsification attempt for claim 5

- **Strategy:** Dependency check — what would actually require a schema bump?
- **Attempt:** Enumerated triggers for `@schema_version` bump from `store.ex:37-43`: position renumbering, field-type change, new field. Proposal-1 does none of these; it changes only the *call signature* into `update_counter`, not the table schema. Test `test/tau/circuit_breaker/store_property_test.exs:196-234` ("D-044 — transition writes state columns; counter columns preserved from ETS") would still pass — it reads positions 3 and 4 unchanged.
- **Outcome:** withstood.
- **Action:** none.

### Claim 6: SPEC-CIRCUIT-BREAKER §4 B4 is amended in the same PR to document (a) the new pre-increment Store return convention and (b) the new `:cooldown_ms` opt on `State.check/3`.

- **Claim (C):** The SPEC update lands in the same PR as the code change.
- **Grounds (G):** `solution.md` enumerates this at `:80-81` ("§4 B4 amended"). The `spec-before-code.md` rule applies because this PR touches `lib/tau/circuit_breaker.ex`, `lib/tau/circuit_breaker/store.ex`, `lib/tau/circuit_breaker/state.ex`, and `lib/tau/application.ex`'s supervision-tree entry remains stable but the SPEC §4 B4 contract (`SPEC-CIRCUIT-BREAKER.md:219-235`) is the boundary being changed. The SPEC catalog entry in `.claude/rules/spec-before-code.md` lists exactly these files as mandatory scope.
- **Warrant (W):** `.claude/rules/spec-before-code.md` — "MUST NOT merge a PR that adds new state to a SPEC'd boundary without a corresponding §3 entry and §4 contract update in the same PR". The rule is enforced by both the critic and reviewer gates.
- **Qualifier (Q):** Holds provided the PR is gated through the `critic` + `reviewer` pair before merge — which is mandatory under `.claude/rules/factory-loop.md` ("The gate").
- **Rebuttal (R):** If the SPEC's §4 B4 entry were unaffected by the change (e.g. only B3 is touched), the §4 B4 amendment claim would be over-specified. Inspection shows §4 B4 is the home of the `State` function contracts including arity, so arity change *does* require B4 amendment. A separate §4 B2 amendment for the Store return convention is also implied by the solution's wording ("Store side") but the solution only names §4 B4; this is a minor under-specification.
- **Backing (B):** `.claude/rules/spec-before-code.md`; `.claude/rules/factory-loop.md` gate sections; SPEC-CIRCUIT-BREAKER §4 B2 (`SPEC-CIRCUIT-BREAKER.md:72-95,143-155`) and §4 B4 (`:219-235`).

#### Falsification attempt for claim 6

- **Strategy:** Integration check — does the existing SPEC text actually pin the contracts being changed?
- **Attempt:** Read SPEC §4 B2 (`SPEC-CIRCUIT-BREAKER.md:143-155`) — explicitly names `bump_failure_count/1` and `bump_success_count/1` as the counter-update primitives but does NOT pin pre- vs post-increment return semantics. Read SPEC §4 B4 (`:219-235`) — pins `check/2` arity and signature in the table at `:224`. Both sections require text changes: §4 B2 to add the pre-increment return convention; §4 B4 to widen `check/2` to `check/2 | check/3` (or rewrite as a default-opt form). The solution's `solution.md:80-81` names only §4 B4 — strictly true but incomplete; §4 B2 also requires an amendment.
- **Outcome:** partially_falsified at the granularity of "which §4 subsection" (the solution names only §4 B4; §4 B2 also needs amending). Not solution-falsifying — the *behaviour* the solution proposes is correct and the SPEC-amendment intent is sound; the wording is imprecise about the scope of the SPEC edit.
- **Action:** narrow Qualifier in place — the SPEC amendment MUST cover §4 B2 (Store return semantics) AND §4 B4 (`State.check` arity). Flag in Outstanding doubts; no full solution revision needed (the implementer brief should reference both subsections).

## Cross-claim consistency

Claims 1, 2, 4, and 5 form a coherent invariant: Store returns pre-bump
(C1) → façade uses it directly with no arithmetic (C2) → State's contract
is unchanged (C4) → ETS schema is unchanged (C5). The transitive
dependency in C4's qualifier (the façade's field-overwrite line on
`current_struct/1` output is now load-bearing) is the only soft seam in
the design; it is a known residual coupling, not an inconsistency.

Claims 3 and 6 are also coherent: the `check/2 → check/3` arity change
requires a §4 B4 amendment; both are scoped to the same PR.

No two claims are in tension. The package is internally consistent.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Store returns pre-increment via multi-op `update_counter` | Dependency + counter-example | withstood | none |
| 2 | `new_count - 1` and explanatory comment are removed from `record_outcome/5` | Counter-example construction | withstood | none |
| 3 | `State.check/2` → `check/3` with `:cooldown_ms` opt; 2-arity callers unaffected | Edge-case enumeration | withstood | none |
| 4 | `State.record_*/2` signatures, semantics, internal `+ 1` arithmetic unchanged | Counter-example over call-site coupling | partially_falsified | narrow Qualifier — façade field-overwrite line is now load-bearing |
| 5 | D-044 row layout unchanged; no schema bump | Dependency check | withstood | none |
| 6 | SPEC §4 B4 amended in same PR for both Store return and check arity | Integration check | partially_falsified | narrow Qualifier — §4 B2 also requires amendment, not only §4 B4 |

## Revision required

No revision triggered. Two partial falsifications narrow qualifiers in
place; neither falsifies the core proposition.

- **Target file:** none.
- **Revision kind:** n/a.
- **Rationale:** Claim 4's partial falsification is a residual coupling
  (transmuted, not eliminated) that the solution implicitly accepts — the
  qualifier now names the load-bearing seam. Claim 6's partial
  falsification is an under-specification of the SPEC-edit scope (the
  edit MUST cover §4 B2 in addition to §4 B4); this is an implementer-brief
  precision issue, not a wrong design choice.

## Outstanding doubts

- **Façade-State coupling moves but does not vanish.** After the change,
  `record_outcome/5` builds the struct passed to State via
  `%State{row | <field>: pre_count}`, where `row` was read AFTER the
  Store bump. The overwrite of the post-bump field with the pre-bump
  value is now a single load-bearing line; if a future refactor inlines
  `current_struct/1` or reorders the bump-then-read sequence, the
  double-count bug returns silently. A property test asserting
  "`new_state.failure_count` equals the value passed in `s.failure_count`
  plus 1, in `:closed`" would pin this; the existing
  `state_property_test.exs` does not yet enforce it.
- **SPEC-edit scope under-specified.** The solution names §4 B4 only; §4
  B2 also requires text changes (pre-increment return convention for
  `bump_*/1`). The implementer brief MUST reference both subsections to
  satisfy `spec-before-code.md`.
- **Reader-comment in `record_outcome/5`.** Claim 2 removes the
  multi-line explanatory block. The reviewer may legitimately ask for a
  one-line `# pre-bump count from Store; see State.record_failure docstring`
  comment to compensate for the loss of context. This is at the reviewer's
  discretion; not solution-falsifying.
- **OTP version pin.** The multi-op `update_counter` form is supported on
  OTP 27.2 (project target). A downgrade to a pre-multi-op OTP would
  falsify claim 1; the `.tool-versions` pin makes this acceptably low-risk.
