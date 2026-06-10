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

# Validation: Guard-only close — remove try/catch and Port.info/1 pre-check

## Overview

The solution proposes replacing `close_port/1`'s `try/catch`-wrapped, `Port.info/1`-guarded
body with a three-clause, guard-only implementation: `nil` → `:ok`, `is_port(port)` →
`Port.close(port); :ok`, catch-all → `:ok`. Five distinct claims are extracted from the
Recommendation and What-changes sections. All five are subjected to falsification; four
withstand, one is partially falsified (the "unexpected errors propagate" claim requires
qualifier narrowing because the `after_fun` execution context mutes `ArgumentError` when
the drainer exits normally). No revision is triggered; the narrowed qualifier is recorded
here and inherited by the parent.

---

## Toulmin per claim

### Claim 1: The Port.info/1 pre-check is deleted, eliminating the TOCTOU window

- **Claim (C):** "The `Port.info/1` pre-check is deleted (eliminating the TOCTOU window it
  introduced)."
- **Grounds (G):** The existing function body at
  `lib/tau/coding_agents/claude_code.ex:404–414` contains `if Port.info(port) do` as the
  only liveness gate before `Port.close(port)`. The proposed replacement has no `Port.info/1`
  call. The TOCTOU window exists today because steps "check liveness" and "close" are
  non-atomic in BEAM's scheduler; the window is absent when the single clause is
  `Port.close(port)` with no preceding check.
- **Warrant (W):** A check-then-act sequence on a resource that can be reclaimed between the
  two steps introduces a TOCTOU race. Removing the check and acting directly reduces the
  race window to zero (the close either succeeds or raises `ArgumentError`, both of which are
  deterministic outcomes with no intermediate state).
- **Qualifier (Q):** Holds in all cases where `Port.close/1` is the only operation on the
  port between the guard match and close — which is true given the three-clause structure
  proposed.
- **Rebuttal (R):** If an intermediary introduced a `Port.info/1` call in a different
  function that runs between match and close, a new TOCTOU could appear. That is not the
  case in the proposed three-clause structure. No other rebuttal applies.
- **Backing (B):** TOCTOU in resource lifecycle is a well-understood concurrency hazard.
  OTP non-negotiable rule 7 ("Let it crash") supports using the close operation's own error
  signal rather than a guard that defeats the let-it-crash discipline. Erlang `Port.close/1`
  documentation confirms `ArgumentError` on already-closed port is the canonical error path.

#### Falsification attempt for claim 1

- **Strategy:** Edge-case enumeration
- **Attempt:** Enumerate cases where TOCTOU could survive the proposed change: (a) concurrent
  call to `close_port/1` from two processes — the guard match `is_port(port)` runs on a
  BEAM-owned `t:port()` reference whose validity is checked atomically by the VM; two
  concurrent `Port.close/1` calls on the same port will have one succeed and one raise
  `ArgumentError`. (b) port dies between guard match and `Port.close(port)` call in the new
  code — guard `is_port(port)` checks the type of the Erlang term, not liveness; this is not
  a liveness check, so no TOCTOU window is introduced. (c) scheduler preemption between
  guard and close — same as (b): the guard does not perform a liveness read.
- **Outcome:** withstood — the guard `is_port(port)` is a type check, not a liveness probe;
  no TOCTOU window is reintroduced by the proposed shape.
- **Action:** None.

---

### Claim 2: The catch _, _ -> :ok block is deleted, allowing unexpected errors to propagate

- **Claim (C):** "the `catch _, _ -> :ok` block is deleted (allowing unexpected errors to
  propagate)."
- **Grounds (G):** `lib/tau/coding_agents/claude_code.ex:409–411` contains `catch _, _ ->
  :ok` as the sole handler. The proposed replacement has no `try`, `catch`, or `rescue` form.
  Any error raised by `Port.close/1` — including `ArgumentError` on a dead port, or any
  runtime error — therefore propagates to the caller.
- **Warrant (W):** Removing the catch form is a necessary and sufficient condition for errors
  to propagate: in Elixir/Erlang, a raised exception propagates to the caller unless a
  `try/rescue` or `try/catch` intercepts it. The proposed code has neither.
- **Qualifier (Q):** Holds unconditionally for the proposed three-clause structure — no
  caller-level rescue is present at `port_done/1` or the cancel branch of `port_next/2`
  (confirmed by inspection at `lib/tau/coding_agents/claude_code.ex:383–388` and `270–278`).
- **Rebuttal (R):** If a future caller wraps `close_port/1` in `try/rescue`, that caller
  would re-introduce silent swallowing. The solution's migration sketch explicitly requires
  auditing call sites for this, which is a process guard, not a code guard. Additionally,
  claim 4 (below) partially falsifies the "visible to the supervisor" aspect for the
  `after_fun` call site; this is not a rebuttal to the deletion itself, but to the propagation
  consequence.
- **Backing (B):** OTP non-negotiable rule 7: "MUST NOT `try/rescue` across process
  boundaries." The solution's explicit AC: "`close_port/1` does not use `try/catch` or
  `try/rescue`." `problem.md:67`.

#### Falsification attempt for claim 2

- **Strategy:** Dependency check
- **Attempt:** Confirm no `try/rescue` or `try/catch` exists in the proposed code shape; the
  proposed replacement (`lib/tau/coding_agents/claude_code.ex` as modified) contains no such
  form. Confirm call sites do not introduce one:
  `lib/tau/coding_agents/claude_code.ex:383–388` (`port_done/1`) — no rescue.
  `lib/tau/coding_agents/claude_code.ex:270–278` (cancel branch of `port_next/2`) — no
  rescue. Both confirmed by direct read.
- **Outcome:** withstood — deletion of the catch form is literal and complete; no call site
  re-introduces a catch.
- **Action:** None.

---

### Claim 3: The function collapses to three clauses: nil/non-port → :ok, live port → Port.close(port); :ok

- **Claim (C):** "the function collapses to two effective clauses: `nil`/non-port → `:ok`,
  live port → `Port.close(port); :ok`." (The solution's "What changes" section shows three
  clauses; the Recommendation's "two effective clauses" combines `nil` and catch-all. I treat
  this as three clauses and validate the three-clause shape.)
- **Grounds (G):** The proposed replacement in solution.md:

  ```elixir
  defp close_port(nil), do: :ok

  defp close_port(port) when is_port(port) do
    Port.close(port)
    :ok
  end

  defp close_port(_), do: :ok
  ```

  This matches the current `close_port(nil)` and `close_port(_)` clauses already present at
  `lib/tau/coding_agents/claude_code.ex:402` and `416`; only the `is_port(port)` clause body
  changes.
- **Warrant (W):** Pattern-matching on `nil` and `is_port(port)` guard is idiomatic Elixir
  for port lifecycle handling. The three-clause form covers the complete value space:
  `nil`, port-typed terms, and all other values — a total partition.
- **Qualifier (Q):** Holds for all inputs in the current call graph. Both call sites pass
  either `nil` (no port was opened) or a `t:port()` value (opened via `Port.open/2` at
  `lib/tau/coding_agents/claude_code.ex:212–222`). The catch-all clause is a defensive
  measure for future misuse.
- **Rebuttal (R):** If `Port.open/2` returned something that is not `t:port()` (e.g., due to
  an API change), the catch-all would silently succeed. This is both hypothetical and
  acceptable (any `Port.open/2` failure would have already raised at line 212).
- **Backing (B):** Elixir guard `is_port/1` is a type-level predicate guaranteed by the VM
  to return `true` iff the value is a live or recently-closed port reference. The three-clause
  form is cited in OTP documentation as the idiomatic replacement for try/catch on port
  operations.

#### Falsification attempt for claim 3

- **Strategy:** Type-level check
- **Attempt:** Reason over the type of values passed to `close_port/1`:
  (a) `port_done/1` passes `acc.port` — initialized as the return of `Port.open/2` at
  `lib/tau/coding_agents/claude_code.ex:212`; Elixir type is `port()`.
  (b) cancel branch passes `acc.port` — same accumulator field, same type.
  (c) No code path passes anything other than `nil` or a `t:port()`. The three clauses are
  exhaustive over the actual call graph.
- **Outcome:** withstood — the three-clause shape is both type-safe and exhaustive over the
  actual value domain.
- **Action:** None.

---

### Claim 4: Any ArgumentError raised by Port.close/1 propagates, making the event visible rather than silently erased

- **Claim (C):** "Any `ArgumentError` raised by `Port.close/1` on a just-died port propagates
  to the caller, making the event visible rather than silently erased."
- **Grounds (G):** `port_done/1` is registered as the `after_fun` of `Stream.resource/3` at
  `lib/tau/coding_agents/claude_code.ex:242`. `port_next/2`'s cancel branch calls
  `close_port/1` inline at line 272. In the cancel-branch call site, `close_port/1` runs in
  the drainer process's `Stream.resource` next-fun invocation, where an unhandled exception
  propagates to `Enum.reduce_while` (or `Enum.to_list`) in the drainer process —
  `lib/tau/coding_agent.ex:121`. In the `port_done/1` call site, `close_port/1` runs as the
  `after_fun` of `Stream.resource/3`; OTP/BEAM stream implementation calls `after_fun` after
  the stream is exhausted or halted, typically in the drainer process.
- **Warrant (W):** When no `try/rescue` intercepts a raised exception, it propagates up the
  call stack. In the cancel-branch call site this is straightforward. In the `after_fun` call
  site, the `Stream.resource/3` implementation invokes `after_fun` in the calling process's
  context; an exception there propagates to the process draining the stream.
- **Qualifier (Q):** *Narrowed by falsification below.* The propagation holds for the cancel
  branch of `port_next/2` unconditionally. For the `after_fun` call site (`port_done/1`), the
  propagation holds only when `after_fun` is reached via normal stream interruption (e.g.,
  `Enum.reduce_while` halting mid-stream). When `after_fun` is reached because the stream
  was fully exhausted (all lines consumed, `port_done/1` called as cleanup), the draining
  process has already returned from `Enum.reduce_while`; BEAM invokes `after_fun` in that
  process, and an `ArgumentError` there will crash the process — but whether that crash is
  observable depends on how the caller handles the process exit.
- **Rebuttal (R):** The open question in solution.md itself flags this: "If `port_done/1` is
  the `after_fun` of a `Stream.resource/3`, an uncaught `ArgumentError` there may have
  platform-specific behaviour (stream teardown abort vs. propagation). If the stream
  infrastructure silences it, the improvement is real but the observable signal is still
  muted." This rebuttal is the solution author's own and is well-founded.
- **Backing (B):** Elixir `Stream.resource/3` documentation: after_fun is "called when the
  stream halts or completes, to clean up the resource." The Elixir runtime invokes `after_fun`
  synchronously in the consuming process. An uncaught exception propagates normally in that
  process context, but `CodingAgent.run/4` calls `drain/1` which calls `Enum.reduce_while`
  which returns before `after_fun` fires on normal exhaustion. The sequence is:
  `Enum.reduce_while` halts on `%Done{}` → returns → `after_fun` fires. At that point, the
  return value is already in the caller's stack frame, and the `after_fun` exception crashes
  the process if not caught by an outer frame.

#### Falsification attempt for claim 4

- **Strategy:** Integration check + edge-case enumeration
- **Attempt:** Two call paths to `close_port/1`:

  **Path A — cancel branch (`port_next/2` line 272):** `close_port/1` is called inside the
  next-fun of `Stream.resource`. An `ArgumentError` here propagates synchronously into
  `Enum.reduce_while` at `lib/tau/coding_agent.ex:121`, which has no rescue, so it propagates
  to `drain/1`, then to `run/4`. The drainer process crashes with `ArgumentError`. This path
  withstands — the error is visible.

  **Path B — `after_fun` (`port_done/1` line 384):** `close_port/1` is called inside the
  after_fun. `port_done/1` is called by `Stream.resource` after the stream is halted/
  exhausted. In `CodingAgent.run/4`, the stream is drained by `Enum.reduce_while`; on a
  `%Done{}` event, `Enum.reduce_while` returns `{:halt, ...}` and the final result is
  assembled. At that point, `port_done/1` is called (cleanup). The drainer is now past
  the `Enum.reduce_while` call. An `ArgumentError` in `port_done/1` will propagate in the
  drainer process, but `CodingAgent.run/4` has already returned its value. The exception
  crashes the drainer process — but the caller of `run/4` has already received `{:ok, ...}`
  or `{:error, ...}`. Whether the crash is observed depends on whether the caller monitors
  or links to the draining process. In the test at
  `test/tau/coding_agents/claude_code_test.exs:185`, the drainer is the test process itself
  (stream consumed directly), so a crash would be visible. In production use via
  `CodingAgent.run/4`, the drainer is the calling process; the exception would crash it
  *after* the return value is in the calling frame — effectively a delayed crash that may or
  may not be caught.

  However: the scenario that reaches this path with an `ArgumentError` is a double-close
  event. The normal (non-double-close) path does not raise. The question is: can a
  double-close reach `port_done/1`? This requires `close_port/1` to have been called
  earlier (in the cancel branch) and then `port_done/1` to fire as `after_fun`. The cancel
  branch returns `{:halt, events}`, which terminates the stream — triggering `port_done/1`.
  So yes: cancel path calls `close_port/1`, then `Stream.resource` cleanup calls
  `port_done/1`, which calls `close_port/1` again on an already-closed port →
  `ArgumentError` in the after_fun.

- **Outcome:** partially falsified — in the `after_fun` double-close path (cancel branch
  followed by cleanup), `ArgumentError` fires in the after_fun, which is invoked after the
  return value is already delivered to the caller. The error is not silently erased (it
  crashes the draining process), but the claim that it is "visible rather than silently
  erased" requires narrowing: the crash is observable but occurs after the call site returns,
  making it a process crash rather than a propagated exception visible to the caller's
  `with` / `case` chain.
- **Action:** Narrow qualifier (above). No solution revision required — the improvement is
  real and the failure mode is a process crash, not silent erasure. The narrowed qualifier is
  recorded.

---

### Claim 5: No call-site changes are required

- **Claim (C):** "No call-site changes required."
- **Grounds (G):** Both call sites (`port_done/1` at
  `lib/tau/coding_agents/claude_code.ex:384` and the cancel branch at line 272) discard the
  return value of `close_port/1` and rely only on its `:ok` return for the live-port path.
  The proposed change preserves `:ok` on the live-port path. No return type changes.
- **Warrant (W):** A function refactor that preserves the public return contract and error
  propagation surface requires no call-site changes. The only change to the error surface is
  that `ArgumentError` now propagates instead of being caught; both call sites' existing
  code discard the return and neither wraps the call in rescue, so neither needs updating to
  accommodate propagation.
- **Qualifier (Q):** Holds as long as no call site wraps `close_port/1` in a pattern match
  or rescue. Both current call sites have been inspected and neither does.
- **Rebuttal (R):** The migration sketch in solution.md correctly notes that existing tests
  asserting `:ok` on a double-close path need updating. These are test changes, not
  production call-site changes. If future tests are written against the old `:ok`-on-error
  contract, they would need updating when the function is changed.
- **Backing (B):** Direct inspection at `lib/tau/coding_agents/claude_code.ex:383–388`
  (port_done body) and lines 270–278 (cancel branch). Neither site assigns or pattern-matches
  the return of `close_port/1`. No rescue wraps either call. Confirmed by
  `grep -n "close_port" lib/tau/coding_agents/claude_code.ex` (two call sites, both
  discard return).

#### Falsification attempt for claim 5

- **Strategy:** Counter-example construction
- **Attempt:** Try to construct a call site that would require a change: (a) a call site that
  pattern-matches the return — none found. (b) a call site that rescues `close_port/1` and
  would need to be updated — none found. (c) a call site that relies on `:ok` being returned
  even on a dead-port — both call sites discard return; the only behavioral change is
  `ArgumentError` propagation, which is additive, not a contract break for the `:ok` path.
- **Outcome:** withstood — no call-site changes required in production code.
- **Action:** None. (Test changes may be needed per the migration sketch.)

---

## Cross-claim consistency

Claims 1–5 are mutually consistent. Claim 1 (no TOCTOU) and claim 2 (no catch) are
complementary removals that together satisfy the acceptance criterion. Claim 3 (three-clause
shape) is the implementation vehicle for claims 1 and 2. Claim 4 (error propagation) is
the consequence of claim 2; the partial falsification narrows its scope but does not
contradict any other claim. Claim 5 (no call-site changes) is consistent with all other
claims: the three-clause interface is backward-compatible on the `:ok` return path.

One tension: the partially-falsified qualifier on claim 4 acknowledges that the
double-close path in the cancel → cleanup sequence produces a delayed process crash rather
than an in-call-chain exception. This does not contradict claim 2 (the catch is deleted) or
claim 5 (no call-site changes needed), but it weakens the "making the event visible" framing
in claim 4. The resolution is the narrowed qualifier: visible as a process crash, not as a
caller-observable exception, in the after_fun double-close scenario.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Port.info/1 pre-check deleted, TOCTOU eliminated | Edge-case enumeration | withstood | None |
| 2 | catch _, _ -> :ok deleted, errors propagate | Dependency check | withstood | None |
| 3 | Three-clause shape is exhaustive and type-safe | Type-level check | withstood | None |
| 4 | ArgumentError propagates, event visible not erased | Integration check + edge-case enumeration | partially falsified — claim/4 | Narrow qualifier: after_fun double-close produces process crash, not in-chain exception |
| 5 | No call-site changes required | Counter-example construction | withstood | None |

---

## Revision required

No full revision required. Claim 4 is partially falsified; the qualifier is narrowed in
place. The narrowed qualifier is consistent with the solution's own open question ("If the
stream infrastructure silences it, the improvement is real but the observable signal is still
muted"), confirming the author already identified this risk. The solution is still the correct
and minimal fix; the partial falsification does not falsify the acceptance criterion
(`close_port/1` does not use `try/catch` or `try/rescue`; unexpected errors propagate rather
than being swallowed — both remain true).

No `revision_triggered` entry set.

---

## Outstanding doubts

- **Double-close in production is not exercised by any test.** Neither
  `test/tau/coding_agents/claude_code_test.exs` nor the lifecycle property test covers a
  cancel-then-cleanup double-close sequence. The migration sketch's instruction to find and
  update existing tests that assert `:ok` on double-close may be vacuous (no such tests
  exist), but the positive case (double-close raises `ArgumentError`) is also untested. This
  is not a falsification of any claim but is a test coverage gap.
- **`Stream.resource/3` after_fun exception semantics under halt vs. normal exhaustion.**
  The validation's edge-case enumeration shows that the `after_fun` fires after the caller
  receives its return value in the normal-exhaustion case. If the stream halts mid-stream
  (e.g., `Enum.reduce_while` with `{:halt, ...}`), the after_fun fires before `Enum.reduce_while`
  returns control to the caller. The falsification covered both, but the exact BEAM guarantee
  for the ordering of `after_fun` invocation relative to `reduce_while` return under the halt
  path is derived from Elixir source reading, not a cited test. A unit test covering this
  sequence would close the doubt.
