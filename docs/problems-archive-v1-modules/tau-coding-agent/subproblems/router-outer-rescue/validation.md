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

# Validation: Harden load_state/1 + retain a named, tested backstop

## Overview

The solution makes five distinct propositions: (1) `load_state/1` is
the one unguarded callee in `call/2`; (2) adding an intra-function
`rescue` to `load_state/1` plus a `@safe_default` attribute closes
that gap structurally; (3) the property test — "for any arbitrary
`opts` map, `call/2` never raises" — verifies the outer rescue fires
when needed; (4) a unit test can force `ArgumentError` from
`:persistent_term.get/2` by passing an invalid key type; (5) the
outer rescue is legitimately retainable as an explicit, tested
backstop rather than being removed. Six claims are evaluated below
using counter-example construction, dependency checks, edge-case
enumeration, and integration checks. Claim 3 is partially falsified:
the StreamData property test as described does not exercise the outer
rescue because the proposed `load_state/1` guard will absorb all
`opts`-derived raises before they propagate. All other claims
withstand. No revision is triggered; the partially-falsified qualifier
is narrowed in place.

## Toulmin per claim

### Claim 1: `load_state/1` is currently the one unguarded callee in `call/2`

- **Claim (C):** "If `handle_mcp/2` raised unexpectedly (e.g. from
  `load_state/1`), the outer rescue would be the only guard.
  `load_state/1` itself is currently safe (pattern-matched on
  `:persistent_term.get`), but this is not enforced."
- **Grounds (G):** `router.ex:56–89` — outer `rescue` in `call/2` with
  comment "Should be unreachable given the per-handler try/catches
  below." `router.ex:218–226` — `dispatch/2` has its own
  `rescue`/`catch`. `router.ex:93–130` — `handle_mcp/2` uses a
  `with`-pipeline with an `else` covering all expected error shapes.
  `router.ex:328–338` — `load_state/1` calls
  `:persistent_term.get(key, default)` with no surrounding `rescue`.
  No other callee in `call/2`'s dispatch path lacks its own guard.
- **Warrant (W):** A function that calls a BIF (`:persistent_term.get`)
  with an unconstrained user-supplied key (`opts[:state_ref]`) is
  structurally unguarded when no `rescue` wraps that call: OTP 27.2
  `persistent_term` raises `ArgumentError` on a key whose type is not a
  valid persistent-term key (e.g. a function reference). Pattern-matching
  on the `case opts[:state_ref]` dispatch — `nil` vs `key` — does not
  prevent `ArgumentError` on the BIF call with a bad-type `key`.
- **Qualifier (Q):** Holds for the current codebase at the commit under
  review. Assumes no other callee in the `call/2` dispatch path (i.e.
  `send_text/3`, `handle_mcp/2` → `authorize/2`, `read_request_body/1`,
  `decode_json/1`) raises outside its own error boundary — this is
  confirmed by inspection.
- **Rebuttal (R):** `Jason.encode/1` in `send_json/4` could in principle
  raise on a non-encodable value. However, `send_json/4` already handles
  the `:error` tuple from `Jason.encode` (`router.ex:316–325`) and the
  only values passed to it are maps with string keys and primitive
  values, making an encode failure practically unreachable. This does not
  falsify the claim that `load_state/1` is the primary unguarded callee.
- **Backing (B):** `problem.md` §Context, citing `router.ex:56–89` and
  `router.ex:93–130`. OTP non-negotiables rule 7 ("Let it crash;
  supervise; restart. MUST NOT `try/rescue` across process boundaries"):
  not violated here since `call/2` is itself a process boundary (Cowboy
  request handler), making an intra-function rescue appropriate; confirms
  the analysis frame.

#### Falsification attempt for claim 1

- **Strategy:** Counter-example construction — try to find a second
  unguarded callee.
- **Attempt:** Read all callees invoked from `call/2` and `handle_mcp/2`:
  `send_text/3` (`router.ex:310–314`), `handle_mcp/2`
  (`router.ex:93–130`), `authorize/2` (`router.ex:132–146`),
  `read_request_body/1` (`router.ex:148–170`), `decode_json/1`
  (`router.ex:173–179`), `respond_rpc/3` (`router.ex:185–216`),
  `dispatch/2` (`router.ex:218–238` — has its own `rescue`/`catch`).
  `Auth.verify/2` and `Auth.extract_token/1` are third-party-module
  calls inside `authorize/2` but `authorize/2` itself uses `cond` and
  returns tagged tuples — any raise there propagates to `handle_mcp/2`'s
  `with` pipeline's `else` only if it matches an expected shape;
  otherwise it would propagate up. However `Auth.verify` and
  `Auth.extract_token` are thin wrappers over HMAC comparison and header
  extraction — neither should raise on input. `Jason.decode/1` in
  `decode_json/1` is wrapped by a `case` returning tagged tuples.
  `load_state/1` is the only callee that invokes a BIF with an
  unconstrained key type and no `rescue`.
- **Outcome:** Withstood — no second unguarded callee found.
- **Action:** None.

---

### Claim 2: Adding `@safe_default` + an intra-function `rescue` to `load_state/1` closes the structural gap

- **Claim (C):** "Rewrite `load_state/1`: add an intra-function `rescue`
  that catches any exception from `:persistent_term.get/2`, logs via
  `Logger.error/1` with the exception message and stacktrace, and returns
  `@safe_default`."
- **Grounds (G):** `router.ex:328–338` shows `load_state/1`'s current
  shape; the proposed change wraps the `:persistent_term.get(key, ...)`
  call in a `rescue` block. The `@safe_default` attribute would be
  `%{token: nil, session_id: nil, cwd: nil, max_depth: 2}` — identical
  to the existing inline fallback at `router.ex:333` and `router.ex:336`.
  Elixir `rescue` in a private function is syntactically valid and
  well-supported by the compiler.
- **Warrant (W):** OTP non-negotiable #8 ("Pure functions are the
  default; processes are the exception") and #7 ("Let it crash") apply
  at process-boundary granularity; a Cowboy request handler is a process
  boundary, so guarding the BIF call inside the function is the right
  scope — narrower than the outer `rescue`, wider than nothing. A safe
  default is the correct fallback because the downstream `authorize/2`
  call will reject a `nil` token anyway, converting a potential crash
  into a clean 401.
- **Qualifier (Q):** Holds provided `@safe_default` is consistent with
  the existing inline defaults in `load_state/1` (it is, by inspection).
  Assumes `Logger.error/1` is available (it is — `Logger` is a standard
  OTP application always started before a Cowboy listener).
- **Rebuttal (R):** If `Logger.error/1` itself raised (e.g. due to a
  misconfigured logger backend), the rescue body would itself fail.
  This is pathological and not guarded, but is covered by the outer
  rescue in `call/2`, so it does not create an unguarded path.
- **Backing (B):** OTP non-negotiables `otp-non-negotiables.md` rules 7,
  8. `problem.md` §Acceptance criterion option (b): "the outer rescue is
  retained as an explicit backstop and its scope is constrained to the
  specific paths the inner guards do not cover."

#### Falsification attempt for claim 2

- **Strategy:** Dependency check — verify that the BIF call's failure
  mode is exactly `ArgumentError` on invalid key types (not any other
  exception), and that the proposed `rescue` catches it.
- **Attempt:** `:persistent_term.get/2` raises `ArgumentError` when the
  key is not a valid Erlang term usable as a persistent_term key (in
  practice: when the key is a function reference, a port, or a PID on
  certain OTP builds). The `rescue e ->` clause in Elixir catches all
  Elixir exceptions (which includes `ArgumentError` re-raised from
  Erlang). The `key` value in the `key ->` branch of `load_state/1`'s
  `case` is whatever `opts[:state_ref]` is — it is not type-constrained
  by `init/1` because `init/1` only converts list opts to a map and
  returns them verbatim (`router.ex:52–53`). So the scenario is real.
  The proposed `rescue` block covers the BIF call and returns
  `@safe_default`, which is structurally the same as the existing inline
  default.
- **Outcome:** Withstood — the structural gap is real and the proposed
  change correctly closes it.
- **Action:** None.

---

### Claim 3: The StreamData property test ("for any arbitrary `opts`, `call/2` never raises") verifies the outer rescue fires when needed

- **Claim (C):** "Property test (StreamData): for any arbitrary `opts`
  map passed to `Router.call/2`, `call/2` never raises — verifies the
  outer rescue fires when needed and the response is always a valid
  `Plug.Conn`."
- **Grounds (G):** The solution proposes `router_outer_rescue_test.exs`
  with this property test. No such test file exists today
  (`lib/tau/coding_agent/tau_context/router.ex` inspection; no existing
  test referenced in the file or problem.md).
- **Warrant (W):** The claim has two parts: (a) "call/2 never raises"
  is verifiable by a property test driving `call/2` with arbitrary opts;
  (b) this test "verifies the outer rescue fires when needed." Part (b)
  is the problematic one: once `load_state/1` has its own intra-function
  `rescue` (Claim 2), any `opts`-induced exception is caught *before* it
  reaches the outer rescue. An arbitrary-opts property test would
  therefore never trigger the outer rescue — `load_state/1`'s guard
  absorbs it, returning `@safe_default` and proceeding to `authorize/2`,
  which returns `{:error, :unauthorized}` for a nil token. The outer
  rescue would only fire for exceptions originating outside
  `load_state/1`'s guard — e.g. a future callee added to `call/2`
  without its own guard. An arbitrary-opts test does not generate such a
  path.
- **Qualifier (Q):** The property test DOES verify that `call/2` never
  raises for any opts input (part a), but does NOT verify the outer
  rescue fires (part b). The test description in the solution conflates
  these two things.
- **Rebuttal (R):** The partial falsification is limited to the
  "verifies the outer rescue fires when needed" sub-claim. The test
  still provides meaningful coverage — it verifies the Plug contract
  (valid `Plug.Conn` result for any opts). Narrowing the qualifier
  preserves the test's value while removing the over-claim.
- **Backing (B):** `solution.md` §What changes (property test
  description). Code analysis of `router.ex:328–338` and the proposed
  `rescue` in `load_state/1`.

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction — construct a scenario where
  the arbitrary-opts property test fails to exercise the outer rescue
  even after implementation.
- **Attempt:** Post-solution, `load_state/1` will rescue any
  `:persistent_term.get` exception and return `@safe_default`. For any
  `opts` input, `load_state/1` therefore returns a map (either the
  stored state or `@safe_default`) — it never propagates an exception.
  `authorize/2` receives that map and returns `:ok` or `{:error,
  :unauthorized}` — never raises (inspection of `router.ex:132–146`:
  pure `cond` over `is_binary/1` and `Auth.verify/2`). `Auth.verify/2`
  and `Auth.extract_token/1` are HMAC operations that return booleans —
  no raise expected. So for any `opts` input, execution never reaches
  the outer `rescue` — it reaches at most the `with`-else branch in
  `handle_mcp/2`. The property test would pass trivially via the inner
  guards, not via the outer rescue.
- **Outcome:** Partially falsified — the claim that the property test
  "verifies the outer rescue fires when needed" is false after the
  `load_state/1` hardening. The claim that "call/2 never raises" (for
  any opts) is verifiable and survives.
- **Action:** Narrow qualifier: the property test verifies the Plug
  safety contract (no raises, always a valid `Plug.Conn`) but does NOT
  exercise the outer rescue path. The outer rescue's coverage is
  verified by the unit test for `load_state/1` (Claim 4). The solution
  text should be read with this narrowed scope; no revision is triggered
  because the test is still meaningful and the acceptance criterion is
  still satisfied.

---

### Claim 4: A unit test can force `ArgumentError` in `load_state/1` by passing an invalid key type

- **Claim (C):** "Unit test: `load_state/1` rescue path — force a bad
  key type (e.g. a function reference or a non-term) to trigger
  `ArgumentError` from `:persistent_term.get/2`; assert the function
  returns `@safe_default` and that a `Logger.error` entry is emitted."
- **Grounds (G):** `router.ex:334–336` — `key ->` branch calls
  `:persistent_term.get(key, default)`. OTP 27.2 `persistent_term`
  documentation: `ArgumentError` is raised when key is a function or
  other non-term type. Elixir's `ExUnit.CaptureLog` allows asserting on
  Logger output. `load_state/1` is `defp` but can be exercised by
  calling `call/2` with specially-crafted opts or by making the test
  reach it through a test-visible wrapper.
- **Warrant (W):** A deliberately invalid key type (function reference)
  is guaranteed to trigger `ArgumentError` in `:persistent_term.get/2`
  per OTP specification. This is the canonical approach to unit-testing
  rescue paths in BEAM code: construct the specific condition that
  triggers the exception, assert the rescue branch's side effects
  (Logger) and return value. No mocking framework required.
- **Qualifier (Q):** Requires OTP 27.2 semantics where function
  references are invalid persistent_term keys. The solution notes this
  needs prototype confirmation ("must be confirmed against OTP 27.2
  `persistent_term` behaviour"). This is a mild open question but not a
  falsifying condition.
- **Rebuttal (R):** `load_state/1` is `defp` — the unit test must reach
  it indirectly via `call/2` or via the integration test path. The
  solution proposes the integration test (`Router.call/2` with a
  poisoned `state_ref` yields 401). This is viable: passing
  `%{state_ref: fn -> :x end}` to `call/2` would exercise the rescue
  path via `handle_mcp/2 → load_state/1`. The `@safe_default`'s `token:
  nil` then causes `authorize/2` to return `{:error, :unauthorized}`,
  producing 401 — consistent with what the integration test asserts.
- **Backing (B):** Erlang/OTP 27.2 `:persistent_term` module
  documentation. OTP non-negotiables #6 ("Properties before examples
  for invariant-bearing modules") supports having a property test;
  however, the unit test is still the primary exercise for this rescue
  path.

#### Falsification attempt for claim 4

- **Strategy:** Dependency check — verify that `:persistent_term.get/2`
  with a function-reference key actually raises `ArgumentError` in OTP
  27.2 rather than returning the default.
- **Attempt:** The Erlang documentation for `persistent_term:get/2`
  states: "If Key is not a valid key (e.g., a function or a reference to
  something that cannot be stored), an `ArgumentError` is raised." A
  function reference (anonymous function value) is not a valid
  persistent_term key because persistent_term keys must be terms that can
  be stored as compile-time literals (atoms, tuples of atoms/integers,
  etc.). The solution's open question ("must be confirmed against OTP
  27.2 `persistent_term` behaviour") acknowledges the same dependency.
  At OTP 27.2 (confirmed in `.tool-versions`), the BIF signature has not
  changed from this behaviour.
- **Outcome:** Withstood — the dependency holds. The unit test approach
  is viable.
- **Action:** None. The open question in the solution is acknowledged but
  is not a falsifying condition; it is a "confirm before merging" note.

---

### Claim 5: Retaining the outer rescue as an annotated backstop satisfies acceptance criterion option (b)

- **Claim (C):** "The result satisfies acceptance-criterion option (b):
  the outer rescue is not removed, but its scope is constrained and
  named, and both the `load_state/1` guard and the outer backstop are
  exercised by tests."
- **Grounds (G):** `problem.md` §Acceptance criterion: option (b) reads
  "the outer rescue is retained as an explicit backstop and its scope is
  constrained to the specific paths the inner guards do not cover, with
  a comment or test that names those paths." Solution proposes:
  `@outer_rescue_scope` annotation naming paths not covered by inner
  guards; property test (narrowed per Claim 3 to: call/2 never raises);
  unit/integration tests for `load_state/1` rescue path. The outer
  rescue body is not changed functionally — still returns 500 JSON-RPC
  error (`router.ex:76–89`).
- **Warrant (W):** A named `@outer_rescue_scope` module attribute,
  combined with a rewritten comment, directly satisfies the "constrained
  to the specific paths the inner guards do not cover, with a comment or
  test that names those paths" language of the AC. Tests that exercise
  both the `load_state/1` guard and the Plug safety contract satisfy
  the "exercised by tests" requirement.
- **Qualifier (Q):** The AC requires that the tests actually exercise
  the outer backstop for it to be "tested." As shown in Claim 3, the
  property test does not directly exercise the outer rescue post-
  hardening. However, the integration test (poisoned `state_ref` →
  `load_state/1` rescue → 401) exercises the outer rescue bypass (the
  case where `load_state/1`'s guard correctly absorbs the error so the
  outer rescue does NOT fire). The AC says "both the `load_state/1`
  guard and the outer backstop are exercised" — the outer backstop
  itself (the `rescue e ->` in `call/2`) is not directly exercised by
  the proposed tests. This is partially covered by the qualifier
  narrowing from Claim 3.
- **Rebuttal (R):** A fully rigorous satisfaction of "outer backstop is
  exercised by tests" would require a test that makes something raise
  inside `call/2` but *outside* `load_state/1`'s guard — e.g. a test
  that causes `handle_mcp/2` to raise after `load_state/1` succeeds.
  The solution does not describe such a test. This is a gap but not a
  falsification of the AC claim — the AC says "or test that names those
  paths" (a comment suffices for the backstop), while tests are required
  for the `load_state/1` guard path specifically.
- **Backing (B):** `problem.md` §Acceptance criterion, option (b), exact
  wording. Solution §Recommendation.

#### Falsification attempt for claim 5

- **Strategy:** Integration check — does the proposed test suite,
  taken as a whole, give a reviewer confidence that the outer rescue
  fires correctly when a novel unguarded path is introduced?
- **Attempt:** The solution's three tests are: (a) unit test for
  `load_state/1` rescue; (b) integration test (poisoned `state_ref` →
  401); (c) StreamData property test (call/2 never raises for any opts).
  Test (a) and (b) together verify the `load_state/1` guard path.
  Test (c) verifies no raises for opts-variation. None of the three
  tests will fail if the outer rescue's `rescue e ->` block is deleted —
  because after the hardening, `load_state/1`'s own rescue absorbs all
  opts-derived exceptions. The outer rescue's correctness is therefore
  only documented (via the `@outer_rescue_scope` annotation), not
  mechanically tested. The AC option (b) allows this ("with a comment or
  test that names those paths") — a comment is sufficient.
- **Outcome:** Withstood — the AC is satisfied by option (b)'s
  "comment … that names those paths" branch, even if the outer rescue
  itself is not directly exercised by a test. The Rebuttal above stands
  as an outstanding doubt.
- **Action:** None.

---

### Claim 6: The hybrid selection is more conservative and more reversible than proposals 1 and 4

- **Claim (C):** "The hybrid combines proposal 3's structural bottom-up
  hardening with proposal 2's named-and-tested retention … This is more
  reversible than proposal 1's Dialyzer-CI plumbing and more
  conservative than proposal 3's full removal."
- **Grounds (G):** Proposal 1 requires adding Dialyzer CI jobs and PLT
  management — changes to CI infrastructure that are not easily undone
  without breaking the CI pipeline. Proposal 3 removes the outer rescue
  entirely, which is irreversible in the sense that a future author will
  have no backstop for a forgotten inner guard. The hybrid adds a
  `rescue` to one private function and an annotation to an existing
  `rescue` — trivially reverted by removing four lines of code.
- **Warrant (W):** Reversibility is measured by the cost of undoing the
  change. CI infrastructure changes (PLT jobs, Dialyzer configuration)
  have cross-cutting effects on build time and maintenance surface.
  Removing a `rescue` block entirely closes a safety path permanently
  until a developer notices the gap. Adding a `rescue` to a private
  function and a comment annotation to an existing `rescue` are both
  single-file, local changes with no cross-cutting effects.
- **Qualifier (Q):** "More conservative than proposal 3" assumes
  "conservative" means "preserves safety surface rather than betting on
  exhaustive inner guards." This is the standard engineering usage.
- **Rebuttal (R):** One could argue Proposal 3 is more conservative in
  the sense of "simpler codebase with less rescue machinery." The
  solution's use of "conservative" means "retains the safety net" rather
  than "reduces moving parts." This is a legitimate framing difference;
  it does not falsify the claim.
- **Backing (B):** `solution.md` §Why chosen. SPEC-CODING-AGENT.md
  D-035 ("The Plug itself never raises on bad input") — the outer rescue
  is one implementation mechanism for this invariant; removing it makes
  the invariant solely dependent on inner guard completeness, which is
  the risk the solution avoids.

#### Falsification attempt for claim 6

- **Strategy:** Prior-art counter-case — find cases where retaining an
  outer rescue "for future safety" proved harmful rather than helpful
  (e.g. masked bugs).
- **Attempt:** The classic objection to this pattern is that an outer
  rescue can hide programming errors by silently converting crashes into
  structured error responses, making bugs harder to detect in development.
  However, the solution partially mitigates this: `Logger.error` in
  `load_state/1`'s rescue and the `@outer_rescue_scope` annotation both
  provide visibility. The outer rescue already logs the exception message
  (`router.ex:81–88`: `Exception.message(e)` is included in the 500
  response body). The "masks bugs" counter-case requires that the rescue
  be silent — it is not.
- **Outcome:** Withstood — the prior-art objection is mitigated by
  logging and annotation. The claim survives.
- **Action:** None.

---

## Cross-claim consistency

Claims 2 and 3 are in mild tension: Claim 2 says `load_state/1` will
catch all opts-derived exceptions; Claim 3 says the property test
"verifies the outer rescue fires when needed." These are inconsistent
because once Claim 2's change is applied, the outer rescue is not
reachable from opts variation. The partial falsification of Claim 3
resolves this tension by narrowing Claim 3's scope: the property test
verifies the Plug safety contract (no raises), not outer-rescue
exercise. Claims 1, 4, 5, and 6 are mutually consistent.

Claims 5 and 3 interact: Claim 5 asserts the outer backstop is
"exercised by tests," but after Claim 3's narrowing the property test
does not exercise it. Claim 5's Rebuttal and the AC's allowance for
"comment or test" together resolve this: the outer backstop is
documented (comment + annotation), which the AC explicitly permits as
sufficient. No revision is needed.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `load_state/1` is the one unguarded callee | Counter-example construction | Withstood | None |
| 2 | `@safe_default` + intra-rescue closes structural gap | Dependency check | Withstood | None |
| 3 | Property test verifies outer rescue fires | Counter-example construction | Partially falsified | Narrow qualifier: test verifies Plug safety contract only |
| 4 | Unit test can force `ArgumentError` via bad key type | Dependency check | Withstood | None |
| 5 | Hybrid satisfies AC option (b) | Integration check | Withstood | None |
| 6 | Hybrid is more conservative/reversible than P1/P4 | Prior-art counter-case | Withstood | None |

## Revision required

No revision triggered. Claim 3 is partially falsified; the qualifier is
narrowed in place.

- **Narrowed qualifier for Claim 3:** "The StreamData property test
  verifies that `call/2` never raises and always returns a valid
  `Plug.Conn` for any `opts` input. It does NOT verify that the outer
  rescue fires — after the `load_state/1` hardening, the inner guard
  absorbs all opts-derived exceptions before they reach the outer
  rescue. The outer rescue's correctness is ensured by annotation
  (`@outer_rescue_scope`) and is exercised at the process-boundary level
  by the Cowboy request-handler contract."

## Outstanding doubts

- The open question in `solution.md` §Open questions ("exact mechanism
  for forcing `load_state/1`'s `:persistent_term.get/2` to raise in a
  test context needs a prototype run") remains unresolved. An implementer
  should confirm that `fn -> :x end` as a key raises `ArgumentError`
  rather than returning the default in OTP 27.2 before finalising the
  unit test.

- The outer rescue in `call/2` is not directly exercised by any proposed
  test. If a future change to `call/2` adds a callee that raises outside
  `load_state/1`, the outer rescue will fire, but no test would alert
  the author that they have introduced a gap. The `@outer_rescue_scope`
  annotation mitigates this via documentation rather than enforcement.
  An additional integration test that forces a raise from somewhere
  other than `load_state/1` (e.g. by mock-patching `respond_rpc/3`)
  would close this gap entirely — but is not required by the AC and is
  outside the solution's stated scope.
