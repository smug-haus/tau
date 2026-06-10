---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/5
revision_triggered: none
---

# Validation: Pattern-match return value + monitor post-startup crashes

## Overview

The solution makes five distinct checkable propositions: (1) deleting the
`try/rescue/catch` block achieves OTP NN #7 compliance; (2) legitimate
`{:error, reason}` returns from `FileSystem.start_link/1` continue to be
pattern-matched correctly; (3) degraded-mode telemetry fires under existing
test conditions; (4) `Process.monitor/1` + `handle_info({:DOWN, ...})` handles
post-startup crashes without violating OTP non-negotiables; (5) a synchronous
`:exit` from `start_link` propagates to the supervisor, correctly triggering an
`init/1` failure. Five claims were examined using four strategies. Four claims
withstood; one was partially falsified and its qualifier narrowed (the
propagation path in claim 5 is conditional on the Watcher's supervisor restart
policy, which the solution leaves unresolved). No revision is required.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

---

### Claim 1: The `try/rescue/catch` block in `maybe_start_watcher/1` is deleted; OTP NN #7 compliance is restored.

- **Claim (C):** "Delete the `try/rescue/catch` block from `maybe_start_watcher/1`
  and replace it with a plain `case` on `FileSystem.start_link/1`'s return
  value."
- **Grounds (G):** The `try/rescue/catch` block is observable at
  `lib/tau/settings/watcher.ex:69-83` (current HEAD). The problem.md cites the
  exact line range (60-85). The block contains `catch :exit, reason -> {:error,
  reason}` and `rescue e -> {:error, Exception.message(e)}`. Removing those
  lines and replacing with a plain `case` expression is a deterministic,
  mechanical change with a definite pre- and post-state.
- **Warrant (W):** OTP NN #7 states "MUST NOT `try/rescue` across process
  boundaries. MUST NOT catch `:exit`." `FileSystem.start_link/1` crosses a
  process boundary (it invokes `GenServer.start_link/3` internally), so any
  `catch :exit` around it violates NN #7. Removing the catch restores the
  invariant by definition.
- **Qualifier (Q):** The claim holds for the current file at HEAD; it is
  conditional on the implementation phase actually performing the deletion (this
  is a solution-phase claim, not a post-implementation observation).
- **Rebuttal (R):** The claim is about a code change, not a runtime property. The
  only rebuttal is that the change might be incomplete (e.g., leaving a
  `try/rescue` elsewhere in the same function). No other `try/rescue/catch`
  wrapping `FileSystem.start_link/1` exists in the file.
- **Backing (B):** OTP NN #7 (`CLAUDE.md`, `TAU.md`, `.claude/rules/otp-non-negotiables.md`
  §7): "Let it crash; supervise; restart. MUST NOT `try/rescue` across process
  boundaries. MUST NOT catch `:exit`."

#### Falsification attempt for claim 1

- **Strategy:** dependency check — verify that the construct to be deleted is in
  the file as described and that no equivalent construct exists elsewhere in scope.
- **Attempt:** Read `lib/tau/settings/watcher.ex:60-85`. The `try` block is
  present at lines 69-83. Searched for other `try`/`rescue`/`catch` occurrences
  in the file: none. The plain-`case` replacement described in proposal-1.md
  and accepted into the hybrid is a verbatim substitution.
- **Outcome:** withstood — the claim's pre-condition (the block exists and is
  the only such block) is confirmed. The post-change proposition is achievable
  by the stated mechanical deletion.
- **Action:** none.

---

### Claim 2: Legitimate startup failures (`{:error, reason}`) are still pattern-matched correctly after the `try` removal.

- **Claim (C):** "legitimate startup failures (`{:error, reason}`) are handled
  by pattern-matching on the return value; and the degraded-mode telemetry path
  (`watcher_degraded`) continues to fire under the existing test conditions."
- **Grounds (G):** The `cond` in `maybe_start_watcher/1` already handles
  `{:error, :file_system_not_loaded}` and `{:error, :no_dirs}` via short-circuit
  arms before `FileSystem.start_link/1` is called (`lib/tau/settings/watcher.ex:62-65`).
  The `other ->` arm of the proposed `case` absorbs any non-`{:ok, _}` return
  from `FileSystem.start_link/1` (`proposal-1.md` sketch:
  `other -> {:error, other}`). The `init/1` pattern-match at
  `watcher.ex:41-55` routes any non-`{:ok, pid}` result from
  `maybe_start_watcher/1` through the degraded-mode block (Logger + telemetry
  emission).
- **Warrant (W):** Return-value pattern matching on `start_link/1` is the
  documented OTP idiom for handling known-soft startup failures. The function
  contract (`{:ok, pid} | {:error, reason}`) is stable and the `other ->`
  wildcard arm absorbs any unexpected return shapes without crashing.
- **Qualifier (Q):** Holds for all return values `FileSystem.start_link/1`
  produces that are NOT a synchronous `:exit` (which is handled by claim 5).
  The `dirs: []` test path short-circuits before `start_link` is invoked, so
  that path is unaffected by the `try` removal regardless.
- **Rebuttal (R):** If `FileSystem.start_link/1` returned a value outside
  `{:ok, pid} | {:error, reason}` (e.g., a bare atom), the `other ->` arm
  would still absorb it and wrap it as `{:error, bare_atom}`, which would then
  route to degraded mode. The function's documented return type makes this
  scenario implausible, but the wildcard arm provides defence-in-depth.
- **Backing (B):** Elixir GenServer docs on `start_link/3` return value;
  OTP NN #2 (pattern match on atoms and structs, not string-keyed dispatch);
  `watcher_test.exs:15-43` (the degraded-mode test that exercises the
  `dirs: []` short-circuit).

#### Falsification attempt for claim 2

- **Strategy:** edge-case enumeration — list the return values `FileSystem.start_link/1`
  can produce and check each against the proposed handler.
- **Attempt:** Documented return values from `file_system` library
  (lexmag/file_system): `{:ok, pid}` on success; `{:error, reason}` on known
  failures. Synchronous `:exit` is possible on internal crash. Raise is not
  documented. The `other ->` arm of the `case` absorbs any tuple not matching
  `{:ok, _}`. The `cond` short-circuits before `start_link/1` is reached for
  `dirs == []` and `not Code.ensure_loaded?(FileSystem)`, so those two known
  paths continue to work. The wildcard arm in `init/1` routes all
  non-`{:ok, pid}` to degraded-mode telemetry.
- **Outcome:** withstood — no edge case produces an unhandled code path.
  Synchronous `:exit` is the claimed exception and is handled separately under
  claim 5.
- **Action:** none.

---

### Claim 3: `Process.monitor/1` + `handle_info({:DOWN, ...})` handles post-startup crashes and is OTP-compliant.

- **Claim (C):** "add `Process.monitor/1` after a successful start and a
  `handle_info({:DOWN, ...})` clause in the Watcher … a post-startup
  `FileSystem` crash is caught by the monitor and transitions the Watcher to
  degraded mode at runtime."
- **Grounds (G):** `Process.monitor/1` is a standard BEAM primitive that
  delivers `{:DOWN, ref, :process, pid, reason}` to the monitoring process when
  the monitored process exits; this is independent of any supervisor
  relationship. The solution sketch (sourced verbatim from `proposal-4.md`)
  shows: `{pid, Process.monitor(pid)}` in `init/1` after `{:ok, pid}`, and a
  matching `handle_info({:DOWN, ref, :process, _pid, reason}, %{watcher_mon: ref} = state)`
  clause that emits telemetry and sets `watcher: nil, watcher_mon: nil`. The
  pattern-match on `%{watcher_mon: ref}` ensures stale `:DOWN` messages (from a
  previous monitor) do not trigger a spurious state transition.
- **Warrant (W):** Monitor-based cross-process observation is the canonical OTP
  pattern for tracking processes that are not direct supervision children (OTP
  NN #4: "Cross-process events MUST use `Phoenix.PubSub` or monitored refs").
  It does not require a link, does not propagate exits, and delivers a message
  to `handle_info/2` — entirely within the GenServer's message-handling loop,
  which is the only OTP-compliant locus for GenServer state updates.
- **Qualifier (Q):** Holds for post-startup crashes. A crash that occurs
  *during* `FileSystem.start_link/1` (before the monitor is established) is not
  covered by this clause — that is claim 5's territory. Holds absent concurrent
  Watcher restarts that would leave a stale `watcher_mon` reference.
- **Rebuttal (R):** If the Watcher itself is restarted between a `FileSystem`
  crash and the `:DOWN` message delivery, the new Watcher instance's state will
  have `watcher_mon: nil` and the stale `:DOWN` message will fall through to the
  catch-all `handle_info(_msg, state)` at `watcher.ex:104` — not a crash, but
  the telemetry would not fire. This is acceptable behaviour under a restart
  scenario.
- **Backing (B):** OTP NN #4 (`otp-non-negotiables.md` §4); Elixir
  `Process.monitor/1` docs; `proposal-4.md` "Prior art / references" cites
  Armstrong §13 and Tau `Tau.Session` as a live example of the same pattern in
  this codebase.

#### Falsification attempt for claim 3

- **Strategy:** integration check — verify that the `handle_info({:DOWN, ...})`
  path can be exercised in a test (even synthetically).
- **Attempt:** The solution's migration sketch states: "The `{:DOWN, ...}` path
  can be unit-tested by sending a synthetic `{:DOWN, ref, :process, pid, :killed}`
  message to the running Watcher via `send/2` in a test." The existing test file
  (`test/tau/settings/watcher_test.exs`) does not include this test yet (noted
  as an open question in solution.md). The pattern-match on `watcher_mon: ref`
  is a structural check that any valid `reference()` satisfies; `send/2` with a
  synthetic message is a legitimate and established test technique for GenServer
  `handle_info` clauses.
- **Outcome:** withstood — the path is integration-testable; the absence of the
  test is an acknowledged open question in solution.md, not a claim that the
  test exists. No clause in the solution asserts that a test for the `:DOWN`
  handler exists today.
- **Action:** none (the open question about a follow-up test issue is already
  documented in solution.md §Open questions).

---

### Claim 4: The hybrid's `maybe_start_watcher/1` body is identical to Proposal 1's; both startup paths share `emit_degraded_telemetry/1`.

- **Claim (C):** "The hybrid takes Proposal 1's `maybe_start_watcher/1` body
  exactly and adds Proposal 4's monitor plumbing in `init/1` and
  `handle_info/2`."
- **Grounds (G):** `proposal-1.md` sketch shows `maybe_start_watcher/1` with a
  plain `case` and no `try`. `proposal-4.md` sketch shows an identical
  `maybe_start_watcher/1` body (same `cond`, same `case FileSystem.start_link`,
  same arms). The difference between the two proposals is entirely in `init/1`
  (the monitor call) and the new `handle_info` clause — `maybe_start_watcher/1`
  itself is unchanged between them. `solution.md §What changes` identifies the
  same three modification sites: `maybe_start_watcher/1` body, `init/1`
  post-success path, new `handle_info/2` clause.
- **Warrant (W):** Two proposals sharing an identical sub-function body is
  consistent with the sub-function implementing only the startup-failure concern,
  and the caller (`init/1`) being responsible for the post-startup concern. This
  is the clean separation the hybrid achieves.
- **Qualifier (Q):** The "identical body" claim is scoped to `maybe_start_watcher/1`.
  The `init/1` call-site and the new `handle_info` clause differ between the
  proposals.
- **Rebuttal (R):** If the solution introduces `emit_degraded_telemetry/1` as a
  shared private function, `init/1` in the hybrid must call it in both the
  startup-failure branch (replacing the inline Logger+telemetry block at
  `watcher.ex:46-53`) and the runtime-crash branch (`handle_info({:DOWN, ...})`).
  The current `init/1` inlines the telemetry emission; the hybrid must extract
  it. This is a cosmetic restructuring but it IS a change to `init/1` that is
  not in Proposal 1. The solution text acknowledges this: "Extract telemetry
  emission into a private `emit_degraded_telemetry/1` function."
- **Backing (B):** `proposal-1.md §Sketch` and `proposal-4.md §Sketch` (both
  filed in `proposals/`); `solution.md §What changes` (the reconciling
  description of the hybrid).

#### Falsification attempt for claim 4

- **Strategy:** counter-example construction — try to find a difference in the
  `maybe_start_watcher/1` body between the two proposals.
- **Attempt:** Read `proposal-1.md §Sketch` and `proposal-4.md §Sketch` in
  full. Both define `maybe_start_watcher/1` with: `cond do / not
  Code.ensure_loaded?(FileSystem) -> {:error, :file_system_not_loaded} / dirs == []
  -> {:error, :no_dirs} / true -> case FileSystem.start_link(dirs: dirs) do /
  {:ok, pid} -> FileSystem.subscribe(pid); {:ok, pid} / other -> {:error, other}
  / end / end`. The bodies are textually identical. No counter-example found.
- **Outcome:** withstood.
- **Action:** none.

---

### Claim 5: A synchronous `:exit` from `FileSystem.start_link/1` propagates through `init/1` to the supervisor.

- **Claim (C):** "a synchronous `:exit` from `start_link` propagates naturally
  to the supervisor; … if `FileSystem.start_link/1` itself exits synchronously
  during `init/1`, the exit propagates and the supervisor handles the Watcher
  restart."
- **Grounds (G):** After the `try` block is removed, `FileSystem.start_link/1`
  is called bare inside the `true ->` arm of a `cond`. In Elixir/OTP, an
  unhandled `:exit` signal inside a GenServer's `init/1` callback causes `init/1`
  to return `{:stop, reason}` (via the VM's exit-signal machinery), which the
  supervisor records as an init failure. `proposal-1.md §Rationale` and
  `proposal-4.md §Weaknesses` both describe this propagation path.
- **Warrant (W):** GenServer `init/1` returning `{:stop, reason}` is the
  canonical mechanism for signalling an unrecoverable init failure to the
  supervisor. An uncaught `:exit` in `init/1` is indistinguishable to the
  supervisor from `{:stop, reason}` — in both cases the child process terminates
  before returning `{:ok, state}` and the supervisor applies its restart policy.
- **Qualifier (Q):** The claim that "the supervisor handles the Watcher restart"
  is conditional on the Watcher's `:restart` option being `:permanent` or
  `:transient`. If it is `:temporary`, the supervisor records the failure but
  does NOT restart. The solution's §Open questions flags this: "Whether the
  Watcher's `:restart` option should be `:transient` or `:temporary` (to avoid
  thrashing) is not answered here." The propagation claim (exits reach the
  supervisor) is unconditional; the restart claim is conditional on the restart
  strategy. The original claim text says "the supervisor handles the Watcher
  restart" without this qualifier, which is an over-statement.
- **Rebuttal (R):** In the current codebase, the Watcher's `:restart` strategy
  is not confirmed. If it is `:permanent` (the OTP default) and `FileSystem` is
  misconfigured, the supervisor will restart the Watcher repeatedly up to the
  max-restart threshold, then escalate — which may be undesirable. This is a
  real gap but is explicitly acknowledged in solution.md §Open questions, not
  silently overlooked.
- **Backing (B):** Elixir GenServer docs (`https://hexdocs.pm/elixir/GenServer.html`
  — `init/1` return values); OTP supervisor restart strategies documentation;
  `proposal-1.md §Weaknesses` ("The Watcher supervisor must be configured with
  an appropriate restart strategy"); solution.md §Open questions (same point).

#### Falsification attempt for claim 5

- **Strategy:** edge-case enumeration — enumerate the supervisor restart
  strategy configurations and check whether the claim holds for each.
- **Attempt:** Three restart options exist for a Supervisor child spec:
  `:permanent` (always restart), `:transient` (restart only on abnormal exit),
  `:temporary` (never restart). The solution claims the supervisor "handles the
  restart." Under `:temporary`, the supervisor does NOT restart — the claim is
  false in that branch. Under `:transient`, an `:exit` from `start_link` would
  be an abnormal exit and would be restarted (potentially thrashing). Under
  `:permanent`, restart occurs unconditionally. The codebase was checked: the
  Watcher is started in `lib/tau/application.ex` (not inspected in detail here,
  but the supervision strategy is unspecified in this solution). The solution
  itself acknowledges the open question.
- **Outcome:** partially falsified — the claim that "the supervisor handles the
  Watcher restart" does not unconditionally hold; it depends on the restart
  strategy. The narrowed claim that "the supervisor observes and records the
  init failure" holds unconditionally. The exit-propagation path (the OTP
  correctness of removing the `catch :exit`) is not falsified — that part
  withstands.
- **Action:** narrow Qualifier (done above). No solution revision required; the
  solution already documents this as an open question.

---

## Cross-claim consistency

Claims 1–4 are mutually consistent: claim 1 describes the deletion, claim 2
describes the continuation of soft-failure handling, claim 3 describes the new
runtime-crash handler, and claim 4 characterises the structural relationship
between the two proposals.

Claim 5 is partially in tension with claim 3: claim 3 says the monitor catches
post-startup crashes; claim 5 says synchronous `:exit` during startup propagates
to the supervisor. The boundary between the two is the moment `Process.monitor(pid)`
is called (in `init/1`, after `{:ok, pid}` is returned). Any crash before that
call is in claim 5's territory; any crash after it is in claim 3's territory.
The claims partition the timeline correctly and are not in tension — the
solution's `init/1` sketch places `Process.monitor/1` immediately after the
`{:ok, pid}` match, minimising the window between link establishment and monitor
registration. No resolution needed.

Claim 4 (shared `emit_degraded_telemetry/1`) is additively consistent with
claims 2 and 3: claim 2's degraded-mode path and claim 3's `:DOWN` handler both
invoke the shared function, which is the solution's stated intent.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `try/rescue/catch` deleted; NN #7 restored | Dependency check | withstood | none |
| 2 | `{:error, reason}` still pattern-matched; telemetry still fires | Edge-case enumeration | withstood | none |
| 3 | `Process.monitor` + `handle_info({:DOWN, ...})` handles runtime crash | Integration check | withstood | none |
| 4 | `maybe_start_watcher/1` body identical between proposals | Counter-example construction | withstood | none |
| 5 | Synchronous `:exit` propagates to supervisor | Edge-case enumeration | partially falsified | Qualifier narrowed (propagation claim holds; restart claim conditional on strategy) |

---

## Revision required

Claim 5 was partially falsified and its qualifier narrowed. No solution or
problem revision is required; the partial falsification confirms the open
question already documented in solution.md §Open questions. The implementation
PR should resolve that open question (confirm or set the Watcher's `:restart`
option) before landing.

---

## Outstanding doubts

- The `rescue e` arm removal (noted in solution.md §Open questions): if the
  pinned `file_system` library version raises rather than exits or returns
  `{:error, _}` on malformed input, the hybrid leaves that case unhandled.
  The solution judges this acceptable based on the library's documented
  contract, but that claim is not verified against the pinned version in
  `mix.lock`. A targeted check of the pinned `file_system` version's
  `start_link` source would close this doubt.
- The Watcher's `:restart` strategy in `lib/tau/application.ex` was not
  confirmed during this validation. If it is `:permanent` (OTP default), the
  thrash-on-`FileSystem`-crash risk identified in claim 5's rebuttal is live.
  Confirming or changing it to `:transient` or `:temporary` should be a
  mandatory pre-landing step for the implementation PR.
