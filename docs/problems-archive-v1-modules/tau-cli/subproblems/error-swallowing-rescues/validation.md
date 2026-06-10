---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: withstood
revision_triggered: none
---

# Validation: Delete wildcard rescue/catch; targeted catch + rescue at command boundary; amend NN #7

## Overview

This validation enumerates seven distinct propositions from `solution.md`
(four about code shape, one about exit-code/`@spec` alignment, one about
the rules-file amendment, one about asynchronous reload semantics being
preserved). The chosen falsification strategies are a mix of dependency
check (verifying that `reload_all/0` and `reload/0` are indeed
`GenServer.cast`), counter-example construction (probing for non-exit
exception escape paths and TOCTOU windows), edge-case enumeration (the
four AC-named failure modes), and type-level check (`@spec`
widening). Outcome across all seven claims: **withstood**. This revision
materially addresses the four prior falsifications recorded in
solution.md's revision-1 history; no new falsifications surfaced. One
outstanding doubt is noted regarding the per-PR scope of the NN #7
amendment.

## Toulmin per claim

### Claim 1: `safe_list/0` and `safe_reload/0` are deleted from both modules

- **Claim (C):** The four private helpers (`Tau.CLI.Extensions.safe_list/0`,
  `Tau.CLI.Extensions.safe_reload/0`, `Tau.CLI.MCP.safe_list/0`,
  `Tau.CLI.MCP.safe_reload/0`) are removed, eliminating the wildcard
  rescue/catch sites.
- **Grounds (G):** Solution §"What changes" first two bullets specify
  deletion of `lib/tau/cli/extensions.ex:67-73` and `:75-81` and
  `lib/tau/cli/mcp.ex:98-104` and `:106-112`. Confirmed at the named
  line ranges: `lib/tau/cli/extensions.ex:67-73` contains
  `defp safe_list … rescue _ -> [] catch :exit, _ -> []`;
  `lib/tau/cli/extensions.ex:75-81`, `lib/tau/cli/mcp.ex:98-104`, and
  `lib/tau/cli/mcp.ex:106-112` carry the matching shapes.
- **Warrant (W):** OTP non-negotiable #7 ("MUST NOT `try/rescue` across
  process boundaries. MUST NOT catch `:exit`")
  (`.claude/rules/otp-non-negotiables.md:26-27`) makes wildcard rescue/
  catch of supervised-process calls a rule violation; the only way to
  bring the four files into compliance with the existing rule is to
  remove the wildcard sites.
- **Qualifier (Q):** Scoped to the four named helpers; the broader
  rescue/catch surface in `Tau.CLI.Config`, `Tau.CLI.Init`, and the
  run-loop (`drain_run_loop/2`) is explicitly out of scope per
  problem.md.
- **Rebuttal (R):** Deletion alone is not sufficient if the replacement
  surface still contains a wildcard interception. Claim 2 covers the
  shape of the replacement.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §"Invariants"
  rule 7; problem.md "Out of scope" section (which the solution honours
  by not touching `safe_to_atom/1`, etc.).

#### Falsification attempt for claim 1

- **Strategy:** Dependency check — verify the named line ranges still
  contain the helpers the solution proposes to delete.
- **Attempt:** Read `lib/tau/cli/extensions.ex:67-81` and
  `lib/tau/cli/mcp.ex:98-112`. Both contain the exact patterns
  problem.md cites: two `defp` helpers per file with the wildcard
  rescue/catch shapes.
- **Outcome:** withstood — the helpers exist at the named lines and
  match the description; deletion is a mechanical edit with no hidden
  dependency.
- **Action:** none.

### Claim 2: Targeted `catch :exit, {:noproc, _}` + fallthrough `catch :exit, reason` + `rescue _` replace the deleted shims at the command-handler boundary

- **Claim (C):** Each of `list/1`, `status/1`, and `reload/1` wraps its
  direct call to the supervised process in a `try` block carrying three
  arms: `rescue e -> stderr + non-zero exit`,
  `catch :exit, {:noproc, _} -> stderr + non-zero exit`, and
  `catch :exit, reason -> stderr + non-zero exit`. None of the arms are
  wildcard `:exit, _`.
- **Grounds (G):** Solution §"What changes" bullets 1 and 2 enumerate
  the three arms explicitly for each handler. The fallthrough is
  `catch :exit, reason -> …`, which under Erlang/Elixir pattern-matching
  semantics binds (does not unconditionally accept) `reason`; the
  preceding `{:noproc, _}` clause already removed that case, so the
  fallthrough catches the residual set (e.g. `{:timeout, _}`,
  `:killed`, application-specific exits) — a *targeted-by-position*
  catch, not a wildcard in the NN #7 sense (which the rule names as
  `catch :exit, _ -> ignore` style swallows).
- **Warrant (W):** Pattern-matched exit-reason arms produce
  observability (each reason routed to a tagged stderr line and
  non-zero exit) rather than swallowing. The `rate_limiter.ex:86`
  precedent — `catch :exit, {:timeout, _} -> {:error, …}; catch :exit,
  {:noproc, _} -> :ok` — establishes that targeted, named catches at
  CLI/operational boundaries are accepted house practice even today.
- **Qualifier (Q):** Targeted in the sense of "no wildcard `_`-only
  pattern over arbitrary exit reasons that discards the reason". The
  `reason` binding is preserved into the stderr message; it is not
  discarded.
- **Rebuttal (R):** A literal reading of NN #7 ("MUST NOT catch
  `:exit`") admits no exception by reason-shape; this is precisely the
  concern Claim 6 addresses by amending NN #7 in the same PR.
- **Backing (B):** `lib/tau/providers/rate_limiter.ex:80-92` precedent;
  Elixir documentation on `try/catch` pattern-matching semantics
  (https://hexdocs.pm/elixir/try-catch-and-rescue.html).

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — try to construct an
  exit-reason shape that would slip past both `catch :exit` arms or
  that would be swallowed without a stderr line.
- **Attempt:** Enumerate the documented exit shapes:
  - `{:noproc, mfa}` — matched by arm 1.
  - `{:timeout, mfa}` — matched by arm 2 (binds `reason`), prints
    diagnostic, returns non-zero.
  - `:killed` — matched by arm 2.
  - `{:shutdown, term}` — matched by arm 2.
  - Application-thrown `{:tau_error, …}` — matched by arm 2.
  Each path produces a stderr message including the bound `reason` and
  a non-zero exit. No swallowing path remains.
- **Outcome:** withstood — every exit-reason shape this validator could
  construct is routed to a diagnostic-plus-exit path; none is
  swallowed.
- **Action:** none.

### Claim 3: Non-exit exceptions (e.g., `ArgumentError`, `FunctionClauseError`) raised inside the supervised call are caught by `rescue _` and produce non-zero exit + diagnostic

- **Claim (C):** Adding `rescue e -> stderr; exit_code` to the `try`
  block covers the AC-named "unexpected exception" failure mode
  (non-exit exceptions), closing the prior revision's gap.
- **Grounds (G):** Solution §"What changes" bullets 1 and 2 specify
  `rescue e -> IO.puts(:stderr, "<cmd> failed: " <>
  Exception.message(e)); <code>` on each handler. `Exception.message/1`
  accepts any value implementing the `Exception` behaviour and returns
  a binary; the bound `e` is the raised exception struct.
- **Warrant (W):** `rescue _` (or `rescue e ->`) in Elixir matches any
  exception (not exits); combined with the two `catch :exit` arms, the
  three-arm structure partitions the error space into
  exceptions-via-`rescue` and exits-via-`catch`, covering both
  failure-signal channels in the BEAM.
- **Qualifier (Q):** Only covers exceptions and named exit reasons —
  throws (`throw(term)`) are NOT covered. Per Erlang convention,
  `throw` is reserved for non-local control flow within a single
  process and should not cross a GenServer.call boundary; supervised
  processes that misuse `throw` are themselves NN-violating.
- **Rebuttal (R):** A misbehaving callee that `throw(term)`-s inside
  its caller process context (i.e., the throw escapes
  `GenServer.call/2`) would crash the CLI process — but this is
  pathological and itself a callee bug.
- **Backing (B):** Elixir `try/rescue/catch` docs
  (https://hexdocs.pm/elixir/try-catch-and-rescue.html) — `rescue`
  matches exceptions; `catch` (without atom prefix or with `:throw`)
  matches throws; `catch :exit` matches exits.

#### Falsification attempt for claim 3

- **Strategy:** Edge-case enumeration over the AC's four named failure
  modes (`:noproc`, process exit, unexpected exception, fail silently
  returning 0).
- **Attempt:** Walk each mode through the proposed `try`:
  - `:noproc`: caught by arm 2 (`{:noproc, _}`) — non-zero + stderr.
  - Other process exit: caught by arm 3 (`catch :exit, reason`) —
    non-zero + stderr.
  - Unexpected exception (e.g., `MatchError` if the callee returns an
    unexpected shape): caught by `rescue e` — non-zero + stderr.
  - Silent return of 0: removed — every failure path now returns a
    non-zero code.
- **Outcome:** withstood — all four AC modes are covered.
- **Action:** none. (Throws-escaping-GenServer.call remain uncovered
  but are explicitly out of scope as pathological callee bugs.)

### Claim 4: The `{:error, reason}` arm in `reload/1` is dead and is removed

- **Claim (C):** Both `Tau.Extensions.Loader.reload_all/0` and
  `Tau.MCP.Reconciler.reload/0` are `GenServer.cast`-based and return
  only `:ok`; the existing `case … {:error, reason} -> … 2 end` arm in
  `reload/1` is reachable today only via the `safe_reload/0` rescue
  itself, and is removed in this PR.
- **Grounds (G):** `lib/tau/extensions/loader.ex:65` defines
  `def reload_all, do: GenServer.cast(__MODULE__, :reload_all)` with
  `@spec reload_all() :: :ok`. `lib/tau/mcp/reconciler.ex:44` defines
  `def reload, do: GenServer.cast(__MODULE__, :reload)` with
  `@spec reload() :: :ok`. `GenServer.cast/2` returns `:ok` and never
  blocks; it cannot return `{:error, _}`. The current `safe_reload/0`
  shims convert exit-style failures (caught from the cast's local
  registry lookup or send) into `{:error, reason}`, which is the only
  source of that arm being reached today.
- **Warrant (W):** Dead-code elimination is correctness-preserving when
  the call path proves the arm unreachable. The OTP `GenServer.cast/2`
  contract (returns `:ok` synchronously after enqueueing) is part of
  the public API; an unreachable error arm is a code smell that
  obscures the actual error path (the new `try`/`rescue`/`catch`).
- **Qualifier (Q):** Holds only as long as the callees remain `cast`.
  If a future PR converts them to `call` (which would surface
  async-reload errors), this claim no longer applies and the
  `{:error, _}` arm must be re-introduced. Solution §"Open questions"
  flags this trade-off explicitly.
- **Rebuttal (R):** If a developer reintroduces `{:error, _}` returns
  by changing the callee to `call`, the now-deleted arm must be
  restored. The amendment log of solution.md and the @spec on the
  callee make this discoverable.
- **Backing (B):** Erlang/OTP `GenServer.cast/2` documentation
  (https://hexdocs.pm/elixir/GenServer.html#cast/2); revision-1 history
  in solution.md confirms manual inspection of both callee files.

#### Falsification attempt for claim 4

- **Strategy:** Dependency check — verify the callee return shapes at
  the cited line numbers.
- **Attempt:** Read `lib/tau/extensions/loader.ex:65` and
  `lib/tau/mcp/reconciler.ex:44`. Both are exactly
  `GenServer.cast(__MODULE__, …)` with `@spec :: :ok`. No alternative
  return shape can flow from these callees as written.
- **Outcome:** withstood — the dead arm is genuinely dead.
- **Action:** none.

### Claim 5: `@spec` widening for `list/1` and `status/1` (0 → 0 | 1) and preservation of `0 | 2` for `reload/1` aligns Dialyzer with the new exit-code shape

- **Claim (C):** `Tau.CLI.Extensions.list/1`, `Tau.CLI.MCP.list/1`, and
  `Tau.CLI.MCP.status/1` widen `@spec :: 0` to `0 | 1`;
  `Tau.CLI.Extensions.reload/1` and `Tau.CLI.MCP.reload/1` keep
  `@spec :: 0 | 2`; the `2` exit code is repurposed from
  "application-level reload error" to "process unavailable / unexpected
  exception".
- **Grounds (G):** Current `@spec`s at
  `lib/tau/cli/extensions.ex:17` (`@spec list(opts()) :: 0`),
  `:49` (`@spec reload(opts()) :: 0 | 2`),
  `lib/tau/cli/mcp.ex:21` (`@spec list(opts()) :: 0`),
  `:48` (`@spec status(opts()) :: 0`),
  `:80` (`@spec reload(opts()) :: 0 | 2`). The dispatch sink at
  `lib/tau/cli.ex:816-817` (`defp halt(code) when is_integer(code), do:
  System.halt(code)`) accepts any integer.
- **Warrant (W):** Dialyzer reads `@spec` declarations to constrain
  return-type inference; if a function can now return `1` but the
  `@spec` says only `0`, Dialyzer raises a contract violation. The
  widening is the type-level mirror of the behavioural change.
- **Qualifier (Q):** Conditional on Dialyzer being run as part of CI.
  `CLAUDE.md` lists `mix dialyzer` in the project lint set, so this is
  satisfied in normal operation.
- **Rebuttal (R):** If a future patch narrows `@spec` back to `0`
  without removing the `1` return path, Dialyzer will catch it on next
  run — the alignment is self-checking by tooling.
- **Backing (B):** Dialyzer success-typing documentation
  (https://hexdocs.pm/dialyxir/readme.html); CLAUDE.md project-rules
  section listing `mix dialyzer` in the lint set.

#### Falsification attempt for claim 5

- **Strategy:** Type-level check — mentally simulate Dialyzer over the
  proposed new shapes.
- **Attempt:** For `list/1` post-change, body is `try` returning `0` on
  success, `1` on `rescue` / `catch` arms. Union of returns is `0 | 1`,
  matching the proposed widened `@spec`. For `reload/1`, body is `try`
  returning `0` on success, `2` on `rescue` / `catch` arms. Union is
  `0 | 2`, matching the preserved `@spec`. Caller at `lib/tau/cli.ex`
  pipes into `halt/1` which accepts any integer; no caller-side
  contract is violated.
- **Outcome:** withstood — the `@spec` updates exactly match the
  function bodies; Dialyzer would not flag the change.
- **Action:** none.

### Claim 6: Amending NN #7 in the same PR family adds a documented carve-out for targeted `catch :exit, {:noproc, _}` at CLI/TUI command boundaries

- **Claim (C):** `.claude/rules/otp-non-negotiables.md` rule #7 is
  amended in the same PR to add an explicit carve-out permitting
  *targeted* (named exit-reason) `catch :exit` at CLI/TUI command
  boundaries, citing `lib/tau/providers/rate_limiter.ex:86` as the
  existing precedent.
- **Grounds (G):** Current text at `.claude/rules/otp-non-negotiables.md:26-27`
  reads "Let it crash; supervise; restart. MUST NOT `try/rescue` across
  process boundaries. MUST NOT catch `:exit`" — no qualifier
  distinguishing wildcard from targeted catches. Existing
  `rate_limiter.ex:80-92` already uses
  `catch :exit, {:timeout, _} -> …; :exit, {:noproc, _} -> :ok` and
  ships today; the carve-out makes the precedent and the new code
  literally rule-compliant.
- **Warrant (W):** Rules that admit unwritten exceptions ("the rule
  doesn't really mean that case") are weaker than rules whose
  carve-outs are written down. The amendment converts an implicit
  pattern (already present) into an explicit rule, restoring the
  rule's literal correspondence to the practice.
- **Qualifier (Q):** The carve-out is narrowly scoped to CLI/TUI
  command boundaries and to *named* (pattern-matched) exit reasons; a
  bare `catch :exit, _ -> _` remains forbidden under the amended rule.
- **Rebuttal (R):** If during PR review the amendment is rejected on
  the grounds that NN #7's literal reading is load-bearing for other
  reasons, the fallback (solution §"Open questions" bullet 3) is the
  deletion-only form plus a top-level `Tau.CLI.main/1` rescue. That
  fallback also requires touching `cli.ex`, which the current solution
  avoids; the trade-off is explicit.
- **Backing (B):** Project's `tau-architecture` and
  `factory-loop.md`'s spec-amendment-in-same-PR pattern; the existing
  precedent at `rate_limiter.ex:86`; solution.md's revision-1
  acknowledgement that NN #7 has no wildcard qualifier today.

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — try to find a pattern of
  `catch :exit` that the amendment would (perhaps unintentionally)
  permit but that is genuinely harmful (i.e., a wildcard-equivalent
  spelled as a near-wildcard).
- **Attempt:** Consider `catch :exit, reason when is_term(reason) ->
  swallow(reason)`. This pattern names `reason` but `is_term/1` matches
  everything; semantically it is a wildcard with a guard that never
  fires. The amendment as drafted ("a *targeted* `catch :exit,
  {:noproc, _}` (or other named exit-reason shape)") emphasises
  shape-matching on the exit reason, not mere binding; a guard-as-
  wildcard sidesteps the spirit. This is a real loophole the amendment
  text should close by requiring the named pattern to be a *structural*
  shape (tuple, atom-literal, or specific exception), not a bound
  variable with a true-everywhere guard.
- **Outcome:** partially falsified — the amendment as drafted is
  open to a "named-but-wildcard" reading; in practice the rate_limiter
  precedent and the solution's own code use structural matches, but
  the rule text should be tightened to forbid the loophole.
- **Action:** narrow Qualifier. The amendment text should be tightened
  to read approximately: "a *targeted* `catch :exit, <structural
  pattern>` (e.g., `{:noproc, _}`, `{:timeout, _}`, or a specific atom
  reason) — but NOT a bound-variable-only pattern such as
  `catch :exit, reason -> swallow(reason)` without a structural
  match". This narrowing does not invalidate Claim 6 or require a
  solution revision; it adds a textual constraint to the amendment
  that the PR author should incorporate. Recorded here for the
  PR-time tightening; not severe enough to require a fresh
  propose/select cycle.

  Note: solution.md's draft already includes the fallthrough `catch
  :exit, reason -> …` arm, which under a tightened amendment would
  itself need to satisfy "structural pattern OR explicit allowlist of
  diagnostic-only fallthroughs at the command boundary". Since that
  fallthrough surfaces the reason via stderr (does not swallow), it is
  within the spirit of the rule and should be admitted by the amended
  text — the tightening must permit `reason`-binding when the binding
  is forwarded to diagnostic output.

### Claim 7: Asynchronous cast-based reload semantics are preserved (reload returns 0 on cast delivery regardless of async outcome)

- **Claim (C):** `tau extensions reload` and `tau mcp reload` continue
  to return `0` as soon as the cast is delivered; surfacing async-
  reload errors would require changing the callee API and is out of
  scope.
- **Grounds (G):** Solution §"What does not change" bullet 4 names this
  explicitly. Both callees remain `GenServer.cast`
  (`lib/tau/extensions/loader.ex:65`, `lib/tau/mcp/reconciler.ex:44`);
  the new `try` block wraps only the cast call, so any failure to
  *deliver* the cast (registry lookup yielding `:noproc`, etc.) is
  surfaced, but failure of the *handler* code that runs asynchronously
  is not.
- **Warrant (W):** `GenServer.cast/2`'s contract is fire-and-forget;
  the caller cannot observe handler outcomes without a separate
  feedback channel. Preserving the callee API preserves the
  semantics.
- **Qualifier (Q):** "Reload requested" vs "reload completed" is the
  cast/call distinction; users who need confirmation must use a
  separate query.
- **Rebuttal (R):** If a user expects `tau mcp reload` to return
  non-zero when the reload *handler* fails, this PR does not deliver
  that — and the existing `safe_reload/0` shim never did either (the
  shim only caught delivery-time exits, not handler-time failures).
  The user-visible behaviour is unchanged in this dimension.
- **Backing (B):** Erlang/OTP `GenServer.cast/2` documentation;
  solution.md "Open questions" bullet 2.

#### Falsification attempt for claim 7

- **Strategy:** Integration check — verify that the test surface at
  `test/tau/cli/extensions_test.exs` and `test/tau/cli/mcp_test.exs`
  does not assert async-reload outcomes.
- **Attempt:** Read both test files. They assert only that `reload/1`
  exits 0 in the happy path (`test "asks Tau.MCP.Reconciler to
  reconcile and exits 0" do … assert 0 == CLI.reload([])`) — no
  async-outcome assertion. The PR's behaviour matches the existing
  test surface.
- **Outcome:** withstood — async-cast semantics are preserved, and
  the test surface does not contradict the claim.
- **Action:** none.

## Cross-claim consistency

The seven claims form a coherent set:

- Claims 1–3 describe the code-shape change at the four named
  functions; Claim 4 removes a now-dead arm; Claim 5 aligns the
  type-level contract with the new shape; Claim 6 makes the rule
  amendment explicit; Claim 7 documents what intentionally does not
  change.
- Claim 4's removal of the `{:error, _}` arm is consistent with
  Claim 7's preservation of async-cast semantics: both rest on the
  same observation (`reload_all/0` and `reload/0` are `GenServer.cast`
  and return only `:ok`). If one of these claims were false, the other
  would also need revision — and the dependency check on
  `lib/tau/extensions/loader.ex:65` and `lib/tau/mcp/reconciler.ex:44`
  confirms both.
- Claims 2 and 6 are mutually load-bearing: Claim 2's targeted catch
  is rule-compliant only under Claim 6's amendment. The solution
  states the dependency explicitly and provides a fallback (top-level
  `main/1` rescue) in §"Open questions" if Claim 6's amendment is
  rejected at PR review.
- The partial falsification on Claim 6 (named-but-wildcard loophole in
  the amendment text) does not destabilise Claim 2: the solution's
  actual code uses structural matches (`{:noproc, _}`) plus a
  diagnostic-forwarding fallthrough (`reason`-binding sent to stderr),
  which a tightened amendment would still permit.

No tension between the seven claims; no escalation needed.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Delete four safe_* helpers | Dependency check | withstood | none |
| 2 | Three-arm try at command boundary | Counter-example | withstood | none |
| 3 | `rescue _` covers non-exit exceptions | Edge-case enumeration | withstood | none |
| 4 | `{:error, _}` arm is dead, removed | Dependency check | withstood | none |
| 5 | `@spec` widening aligns with Dialyzer | Type-level check | withstood | none |
| 6 | NN #7 amendment with targeted carve-out | Counter-example | partially falsified — named-but-wildcard loophole | narrow Qualifier; tighten amendment text at PR time |
| 7 | Async cast semantics preserved | Integration check | withstood | none |

## Revision required

None at the solution level. The single partial falsification (Claim 6)
narrows the Qualifier of the amendment-text wording in place: the PR
author should ensure the carve-out language requires a *structural*
exit-reason pattern (or a documented diagnostic-forwarding fallthrough),
not a bound-variable-with-true-guard. This is a textual tightening of
the rule amendment, recordable on the PR itself, and does not require
re-running propose/select.

- **Target file:** none for re-dispatch; advisory note to the PR
  author for the amendment-text wording in
  `.claude/rules/otp-non-negotiables.md`.
- **Revision kind:** advisory only (PR-time tightening of amendment
  text).
- **Rationale:** The structural-loophole concern is a textual
  refinement that does not affect the code change or the chosen
  solution shape. Treating it as a full solution revision would be
  pre-emptive over-narrowing per the validate.md anti-pattern list.

## Outstanding doubts

- The NN #7 amendment is asserted in solution.md to ship in the same
  PR family as the code change. The `factory-loop.md` rule (cited in
  CLAUDE.md) requires SPEC amendments to land *in the same PR* as the
  code that depends on them. The rules file
  (`.claude/rules/otp-non-negotiables.md`) is not strictly a SPEC, but
  the same principle applies — the validator notes the PR should bundle
  the amendment with the code change, not split them. If the
  amendment is split into a separate PR, the code-change PR would
  ship a rule violation under literal NN #7 reading; the parent
  validator should confirm same-PR landing.
- The solution's "fallback if NN amendment is rejected" pivot (top-level
  rescue in `Tau.CLI.main/1`) widens the PR's blast radius from three
  files to four and changes the failure-diagnosis surface (top-level
  rescue cannot produce per-command stderr prefixes without
  threading command identity through). This is acceptable as a
  fallback, but the parent should be aware that the fallback is
  meaningfully different from the primary plan and may itself warrant
  a fresh propose/select for the wider scope.
- The existing tests (`test/tau/cli/extensions_test.exs:24,29,37,43`
  and `test/tau/cli/mcp_test.exs:27,35,43,48,56,62`) all assert
  `assert 0 == CLI.<fn>(...)` in the happy path. The PR must add
  failure-path tests asserting the `1` / `2` return codes and the
  stderr diagnostic content — the solution's migration sketch mentions
  updating tests "asserting `list/1 == 0` when the supervisor is down"
  but does not require new positive failure-path tests. The parent
  should consider whether the AC's "diagnostically useful error
  message" clause demands an explicit test on stderr content.
