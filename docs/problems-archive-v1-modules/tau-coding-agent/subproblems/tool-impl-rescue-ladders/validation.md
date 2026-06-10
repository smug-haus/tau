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

# Validation: Asymmetric rescue removal — drop session_cwd/1 rescue, tag soft-fail sites distinctly

## Overview

The solution advances five checkable propositions: (1) removing `session_cwd/1`'s
rescue block makes crash propagation OTP-correct; (2) the `case` extension to
`{:error, _} → nil` preserves legitimate-absence behaviour; (3) adding
`"result_kind": "infrastructure_error"` makes soft-fail responses structurally
distinguishable; (4) emitting `[:tau, :tools, :infrastructure_error]` telemetry
makes absorbed errors observable; (5) the D-035 public contract is preserved
unchanged. Six claims are enumerated (claims 1–5 map 1:1; claim 6 covers the
cross-cutting "no callers outside tools.ex change" assertion). Falsification uses
edge-case enumeration (claims 1, 2, 5, 6), dependency check (claim 3),
integration check (claim 4), and counter-example construction (claim 2, supplementary).
Four claims withstand; claim 4 is partially falsified — the telemetry handler
placement is unresolved and the solution acknowledges this as an open question.
No revision is triggered because the qualifier is narrowed in place and the
open question is already documented in `solution.md §Open questions`.

---

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants found it
difficult to generate Toulmin structures, and their structures varied greatly even
though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to counter that
variance.

---

### Claim 1: Removing session_cwd/1's rescue block is OTP-correct because TauContext is supervised and `:temporary`

- **Claim (C):** "Remove the `rescue`/`catch` block from `session_cwd/1` entirely
  and let the crash propagate to the supervisor."
- **Grounds (G):**
  - `lib/tau/coding_agent/tau_context.ex:51` — `use GenServer, restart: :temporary`.
    TauContext is therefore a supervised process; crashes propagate to `Tau.CodingAgent.Supervisor`
    (a `DynamicSupervisor`, `lib/tau/coding_agent/supervisor.ex:20`) without
    triggering unwanted restart storms (`:temporary` means the DynamicSupervisor
    does not restart on any exit reason).
  - `lib/tau/coding_agent/tau_context.ex:212–214` — TauContext monitors its owner
    Dispatcher and stops itself (`:normal`) when the Dispatcher dies. This confirms
    the TauContext lifetime is bounded to the Dispatcher lifetime; a crash from
    `session_cwd/1` propagates up through the GenServer's handle_call/handle_cast
    stack to the TauContext process, which then exits and cleans up via `terminate/2`.
  - `lib/tau/coding_agent/tau_context/router.ex:271` — `Tools.call/3` is invoked
    from the Router, which runs inside the TauContext GenServer (or its HTTP handler);
    crashes in `Tools` therefore propagate to that process boundary.
- **Warrant (W):** OTP non-negotiable #7 ("let it crash; supervise; restart") holds
  that `rescue`/`catch` across process boundaries suppresses crash semantics the
  supervisor relies on. A `:temporary`-restart supervised process that absorbs its
  own crashes silently redirects control flow rather than terminating; the solution
  restores the OTP model for the `session_cwd/1` call site.
- **Qualifier (Q):** Holds when TauContext is started via a supervisor (normal
  production and test paths with `start_link`). Does not apply to the bare,
  unsupervised `start_link` test in `tau_context_test.exs:21` — but crashes in
  that context propagate to the test process, which is itself supervised by
  ExUnit.
- **Rebuttal (R):** If `session_cwd/1` is called from a process that is NOT
  supervised (e.g. a bare Task not under a supervisor), a crash would take down the
  unsupervised process without a restart. The code audit scope is the supervised
  TauContext path, so this rebuttal is noted but does not falsify the claim in scope.
- **Backing (B):** OTP non-negotiable #7 (`CLAUDE.md` / `TAU.md`). Also
  `lib/tau/coding_agent/dispatcher.ex:36` comment: "silent supervisor restart" is
  the documented intent for the TauContext lifecycle.

#### Falsification attempt for claim 1

- **Strategy:** edge-case enumeration
- **Attempt:** Enumerated cases where the supervision pre-condition fails: (a)
  TauContext started outside a supervisor — found to be only the test case at
  `tau_context_test.exs:21`, which propagates to ExUnit's own supervisor; (b)
  `session_cwd/1` called outside TauContext — not found; it is `defp` and all
  callers are within `tools.ex` which executes inside the TauContext HTTP handler
  (router.ex). (c) `:temporary` restart means no restart on crash — confirmed from
  `tau_context.ex:51`; the TauContext dies and the Dispatcher proceeds without a
  fresh TauContext. This is the intended behaviour per the module comment at line 22.
- **Outcome:** withstood — no edge case falsifies the claim within documented scope.
- **Action:** none.

---

### Claim 2: Extending the case match to `{:error, :not_found} → nil` and `{:error, _} → nil` preserves legitimate-absence behaviour

- **Claim (C):** "The `case` match is extended to handle `{:error, :not_found}` → `nil`
  and `{:error, _}` → `nil` explicitly (Proposal 2's pattern). Unexpected returns
  (non-`:ok`/non-`:error` from `snapshot/1`) raise `CaseClauseError` — OTP
  propagates this to the supervisor."
- **Grounds (G):**
  - `lib/tau/coding_agent/tau_context/tools.ex:370–379` — current `session_cwd/1`
    body. The existing `case` arm is `{:ok, %{cwd: cwd}} when is_binary(cwd) -> cwd`
    and `_ -> nil`. The existing `_ -> nil` arm already handles
    `{:error, :not_found}` today (the wildcard absorbs it); the solution's Proposal 2
    pattern is therefore additive clarity, not a behavioural change for that path.
  - `lib/tau/coding_agent/tau_context/tools.ex:207` — `tau_session_status/1` already
    handles `{:error, :not_found}` explicitly; `snapshot/1`'s documented return shapes
    are `{:ok, snap}` and `{:error, :not_found}`.
- **Warrant (W):** Replacing the wildcard `_ -> nil` arm with the two explicit
  arms `{:error, :not_found} -> nil` and `{:error, _} -> nil` leaves the
  semantics unchanged for the documented return shapes while converting any
  undocumented shape (a new return from a future `snapshot/1` refactor) into a
  crash rather than silent swallowing. This is "make the envelope explicit; let
  unknowns crash" — the standard OTP idiom for case arms.
- **Qualifier (Q):** Holds given the current `snapshot/1` return contract
  (`{:ok, snap} | {:error, :not_found}`). If `snapshot/1` grows a third return
  shape (e.g. `{:error, :timeout}`), the `{:error, _}` arm absorbs it silently
  as `nil` rather than crashing — but the solution's intent is to crash on
  *undocumented* non-`:error`/non-`:ok` returns only (bare atoms, 3-tuples, etc.).
- **Rebuttal (R):** If `snapshot/1` legitimately returns `{:error, :timeout}` in a
  future version and callers expect `session_cwd/1` to return `nil` for that (rather
  than propagate), the `{:error, _}` arm quietly masks that. This is a future risk,
  not a current falsification, and is acceptable given the open question at
  `solution.md §Open questions ("Supervision topology")`.
- **Backing (B):** OTP non-negotiable #8 ("pure functions are the default"); the
  case-match style is consistent with `tau_session_status/1` at `tools.ex:207`.

#### Falsification attempt for claim 2

- **Strategy:** counter-example construction + dependency check
- **Attempt:**
  - Counter-example: constructed a scenario where `snapshot/1` returns
    `{:error, :timeout}`. Under the proposed `{:error, _} → nil` arm this returns
    `nil`, not a crash — same as today's wildcard. No regression; the claim is
    "preserves legitimate-absence behaviour", not "crashes on all errors".
  - Dependency check: verified `Tau.Session.snapshot/1`'s documented return contract
    by searching `lib/tau/session.ex` — not read in full, but `tools.ex:207` already
    handles `{:error, :not_found}` as the only error arm, and the `tau_session_status`
    test at `tools_test.exs:66` confirms "session id has no live process → `not_found`"
    is the expected error path.
- **Outcome:** withstood — the proposed case extension is a correct and non-regressive
  narrowing of the wildcard.
- **Action:** none.

---

### Claim 3: Adding `"result_kind": "infrastructure_error"` to rescue branches satisfies the acceptance criterion

- **Claim (C):** "For `tau_session_status/1` and `safe_memory_load/1`, retain the
  rescue but change the return shape: add `"result_kind": "infrastructure_error"`
  alongside the existing `"available": false` field … This hybrid satisfies the
  acceptance criterion (structurally distinguishable responses)."
- **Grounds (G):**
  - `problem.md §Acceptance criterion` — "infrastructure errors (unexpected
    exceptions, thrown terms) produce a response that is structurally
    distinguishable from legitimate absences, or are removed because the calling
    code can rely on the OTP process model instead."
  - `lib/tau/coding_agent/tau_context/tools.ex:207–228` — current `tau_session_status/1`:
    the `{:error, :not_found}` arm does NOT include `"result_kind"` today; adding it
    only to the rescue/catch arms makes the two envelopes structurally distinct.
  - `lib/tau/coding_agent/tau_context/tools.ex:264–265` — `tau_memory_query/2`'s
    `{:error, reason}` arm (from `safe_memory_load/1`) currently produces
    `%{"available" => false, "reason" => reason, "query" => query}` without
    `"result_kind"`. Adding `"result_kind" => "infrastructure_error"` at the
    `tau_memory_query/2` call site makes this distinguishable.
- **Warrant (W):** Adding an additive field to the rescue/catch return maps — and
  only to those branches — is the minimal change that satisfies structural
  distinguishability: a consumer can branch on `result_kind == "infrastructure_error"`
  vs. absent/other. This follows Hickey's "data over code" principle and minimises
  diff surface.
- **Qualifier (Q):** Satisfies the acceptance criterion as stated. Does not
  satisfy a stronger criterion (e.g. typed constructors, never-absorb policy);
  the problem.md acceptance criterion is the target.
- **Rebuttal (R):** A consumer that ignores `"result_kind"` still sees
  `"available": false`; for such consumers, the distinction is invisible.
  The criterion requires the response to *be* distinguishable, not that all
  consumers *act* on the distinction — so this is a note, not a falsification.
- **Backing (B):** `problem.md §Acceptance criterion` (the governing contract).
  `solution.md §What does not change` — "The MCP wire format's existing fields.
  `"result_kind"` is additive."

#### Falsification attempt for claim 3

- **Strategy:** dependency check — verify no legitimate-absence branch in the
  current code already emits `"result_kind"`, which would break distinguishability.
- **Attempt:** Searched `tools.ex` for `"result_kind"` — no occurrences in the
  current file. Verified that `"available" => false` appears at lines 188, 210,
  219, 226, 265, 317, 343, 356 — none of the non-rescue arms include
  `"result_kind"`. Adding it exclusively to rescue/catch arms will therefore create
  a genuine structural distinction.
- **Outcome:** withstood.
- **Action:** none.

---

### Claim 4: Emitting `[:tau, :tools, :infrastructure_error]` telemetry makes absorbed errors observable in production

- **Claim (C):** "Add a single telemetry call per rescue branch — `[:tau, :tools,
  :infrastructure_error]` — to make absorbed errors visible in production (Proposal
  4's observability, scoped only to the retained soft-fail sites)." And: "attach a
  telemetry handler for `[:tau, :tools, :infrastructure_error]` that emits a
  `Logger.warning`."
- **Grounds (G):**
  - `:telemetry.execute/3` with event name `[:tau, :tools, :infrastructure_error]`
    is the proposed emission. At present, no handler for this event is registered
    anywhere in `lib/tau/otel_reporter.ex:237–266` (the full event list was verified
    by reading that file — `[:tau, :tools, ...]` does not appear).
  - `lib/tau/otel_reporter.ex:210–272` — `attach_handlers/1` subscribes a fixed
    event list; `[:tau, :tools, :infrastructure_error]` is absent from both the
    mandatory and optional event lists.
  - `lib/tau/application.ex` — no `telemetry` attach for this event was found in the
    search at startup time.
  - `solution.md §Open questions ("Telemetry handler placement")` — the solution
    itself flags this as unresolved: "application.ex vs otel_reporter.ex is a
    codebase-convention question not resolved here."
- **Warrant (W):** A `:telemetry.execute/3` call without a registered handler fires
  into a vacuum — the event is dispatched and silently discarded. Therefore the
  "observable in production" claim requires a handler to be attached at startup.
  The solution identifies this requirement but leaves handler placement undecided.
- **Qualifier (Q):** The claim holds **if and only if** a telemetry handler for
  `[:tau, :tools, :infrastructure_error]` is attached before the TauContext server
  starts. In the current codebase no such handler exists; the claim as stated is
  prospective, not yet realisable.
- **Rebuttal (R):** The absence of a handler at the time of writing does not falsify
  the intent — the PR that implements the solution must add the handler. However, the
  solution does not declare *where* to add it, which creates a risk of omission
  during implementation. This is partially falsified: the observability claim holds
  only after handler wiring, which is not yet decided.
- **Backing (B):** OTP non-negotiable #5: "Telemetry events MUST cover everything
  user-visible or perf-sensitive … `:telemetry.execute/3` in `[:tau, ...]`". The
  telemetry contract implies the emission and handler are co-deployed.

#### Falsification attempt for claim 4

- **Strategy:** integration check — does a handler exist or is the telemetry event
  testable end-to-end?
- **Attempt:** Read `lib/tau/otel_reporter.ex:237–266` — confirmed `[:tau, :tools,
  :infrastructure_error]` is NOT in the attached event list. Searched
  `lib/tau/application.ex` for "infrastructure_error" — no result. No handler exists.
  The proposed emission would fire unobserved in the current codebase.
- **Outcome:** partially falsified — the claim that absorbed errors will be
  "observable in production" after the PR is contingent on the handler being added.
  The qualifier is narrowed: "holds after a handler is attached at startup per the
  OTP non-negotiables; the solution's open question on placement must be resolved in
  the implementation PR."
- **Action:** narrow qualifier (done above). No revision to solution.md required —
  the open question is already documented there. The implementation PR MUST resolve
  the placement and the gate should verify handler attachment.

---

### Claim 5: The D-035 public contract (`{:ok, String.t()}`) is preserved unchanged

- **Claim (C):** "The D-035 public contract: every public function still returns
  `{:ok, String.t()}`." And: "No callers outside `tools.ex` change."
- **Grounds (G):**
  - `lib/tau/coding_agent/tau_context/tools.ex:155–156` — `@spec call(...) ::
    {:ok, String.t()} | {:error, %{code: integer(), message: String.t()}}` — the
    public `call/3` spec is unchanged by the proposed diff.
  - `lib/tau/coding_agent/tau_context/tools.ex:184` — `@spec tau_session_status(state())
    :: {:ok, String.t()}` — the tau-visible spec of the public-ish function
    (annotated `@doc false` but spec-visible).
  - All proposed changes in `solution.md §What changes` are confined to the rescue
    branches of `tau_session_status/1`, `safe_memory_load/1`, and the
    `tau_memory_query/2` call site — all within `tools.ex`. The return type for the
    rescue arms is still `{:ok, encode(...)}`.
  - The only other file touched is `application.ex` or `otel_reporter.ex` for
    handler wiring — those changes add a telemetry subscription, not a function
    signature change.
- **Warrant (W):** Additive changes to the *content* of a returned JSON map do not
  alter the structural type `{:ok, String.t()}`. `Jason.encode!/1` (or `encode/1`
  as called in the module) still returns a binary; wrapping it in `{:ok, ...}`
  is type-stable.
- **Qualifier (Q):** Holds for all three public and semi-public functions in scope
  (`call/3`, `tau_session_status/1`, `tau_memory_query/2`). Does not apply to the
  `{:error, %{code: ...}}` error path already in `call/3` — that path is not
  changed.
- **Rebuttal (R):** If `Jason.encode!` raises on the new `"result_kind"` field
  value (a string literal), D-035 would be violated. This is not a realistic risk
  for a string constant but is noted.
- **Backing (B):** `lib/tau/coding_agent/tau_context/tools.ex:31–35` — `@moduledoc`
  D-035 annotation: "Every public function in this module catches its own errors
  and returns a tagged tuple."

#### Falsification attempt for claim 5

- **Strategy:** edge-case enumeration
- **Attempt:** Enumerated all return sites in the proposed changes: `tau_session_status/1`
  rescue arm → `{:ok, encode(%{..., "result_kind" => "infrastructure_error"})}`;
  `safe_memory_load/1` rescue arm → `{:error, "memory loader failed: ..."}` (unchanged
  return type; caller wraps in `{:ok, encode(...)}`); `tau_memory_query/2` call site
  for `{:error, reason}` → `{:ok, encode(%{"available" => false, "result_kind" =>
  "infrastructure_error", "reason" => reason})}`. All return `{:ok, String.t()}`.
  Checked `Jason.encode!` risk: all added fields are string keys and string values —
  no encoding risk.
- **Outcome:** withstood.
- **Action:** none.

---

### Claim 6: No callers outside tools.ex require changes

- **Claim (C):** "No callers outside `tools.ex` change."
- **Grounds (G):**
  - `session_cwd/1` is `defp` (`tools.ex:370`); no external callers possible.
  - `safe_memory_load/1` is `defp` (`tools.ex:269`); no external callers possible.
  - `tau_session_status/1` is `@doc false` and exported; its only call site found
    is `call/3` at `tools.ex:157`.
  - `tau_memory_query/2` is `@doc false`; its only call site is `call/3` at
    `tools.ex:159`.
  - `router.ex:271` calls `Tools.call(name, args, state)` — the public `call/3`
    interface — whose signature and return type are unchanged.
- **Warrant (W):** Elixir's `defp` visibility guarantee ensures no module outside
  `tools.ex` can call `session_cwd/1` or `safe_memory_load/1`. The `@doc false`
  annotation is convention (not enforcement), but the grep search for external call
  sites confirms no other caller.
- **Qualifier (Q):** Holds in the current codebase. Would not hold if a future
  module calls `tau_session_status/1` or `tau_memory_query/2` directly (the `@doc
  false` convention discourages this but does not enforce it).
- **Rebuttal (R):** `tau_session_status/1` and `tau_memory_query/2` are `def`, so
  they are technically callable from outside the module. If any test (other than via
  `call/3`) directly calls `tau_session_status/1` and asserts on the absence of
  `"result_kind"`, that test would require updating. The test file `tools_test.exs`
  was read in full — all tests go through `Tools.call/3`, not direct function calls.
- **Backing (B):** Elixir language spec: `defp` functions are module-private.
  `tools_test.exs` as read confirms test access is via `call/3` only.

#### Falsification attempt for claim 6

- **Strategy:** dependency check — verify `tools_test.exs` and `router_test.exs`
  call patterns.
- **Attempt:** Read `tools_test.exs` in full — all assertions use `Tools.call/3`.
  No test calls `Tools.tau_session_status/1` directly. `router_test.exs:84` calls
  `tau_session_status` via the MCP route, not the internal function directly.
  Searched for `Tools.tau_session_status` and `Tools.tau_memory_query` across the
  test tree — no direct calls found.
- **Outcome:** withstood.
- **Action:** none.

---

## Cross-claim consistency

Claims 1 and 3 are the core asymmetry of the solution: crash for `session_cwd/1`,
soft-fail with tagging for the other two. These are consistent because the harm
profiles differ: `session_cwd/1` silently redirects downstream cwd to `File.cwd!/0`
on crash (a correctness error), while `tau_session_status/1` and `safe_memory_load/1`
return bounded-degraded responses the subprocess can handle. The asymmetry is load-
bearing, not arbitrary.

Claim 4 (telemetry) is additive to claim 3; they are consistent — claim 3 tags the
envelope, claim 4 makes the event observable to operators. Claim 4's partial
falsification (handler not yet wired) does not affect claim 3.

Claim 5 (D-035 preserved) is consistent with claims 1 and 3: removing a rescue from
a `defp` helper does not affect the public contract, and adding a field to a returned
map does not alter the `{:ok, String.t()}` return type.

No internal tension found.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Remove session_cwd/1 rescue — OTP-correct under supervision | edge-case enumeration | withstood | none |
| 2 | Extend case match to {error, _} → nil — preserves legitimate absence | counter-example + dependency check | withstood | none |
| 3 | Add "result_kind" field — structurally distinguishable | dependency check | withstood | none |
| 4 | Emit telemetry — absorbed errors observable in production | integration check | partially falsified | narrow qualifier; handler placement must be resolved in implementation PR |
| 5 | D-035 public contract preserved | edge-case enumeration | withstood | none |
| 6 | No callers outside tools.ex change | dependency check | withstood | none |

---

## Revision required

No revision triggered. Claim 4 is partially falsified and the qualifier is
narrowed in place:

> "Absorbed errors are observable in production **after** a telemetry handler for
> `[:tau, :tools, :infrastructure_error]` is attached at application startup (in
> `application.ex` or `otel_reporter.ex`). The implementation PR must resolve the
> placement question raised in `solution.md §Open questions`."

- **Target file:** n/a (qualifier narrowed in this validation.md)
- **Revision kind:** none — solution.md already documents the open question;
  the narrowed qualifier is recorded here for the implementer brief.
- **Rationale:** partial falsification with an acknowledged open question does
  not require a new solution proposal; it requires the implementer to close the
  open question before merging.

---

## Outstanding doubts

- **`MemoryLoader.load/1` exit semantics (solution §Open questions):** if
  `MemoryLoader.load/1` can throw bare `:exit` terms (e.g. from a linked process
  dying inside `load/1`), the retained `catch kind, reason` in `safe_memory_load/1`
  absorbs them into `{:error, "memory loader threw: ..."}`. Whether this is the
  desired behaviour — or whether those `:exit` terms should propagate — was not
  assessed here (explicitly out of scope per `solution.md §Open questions`). The
  parent-level validator should carry this doubt forward.
- **SPEC-CODING-AGENT §3 amendment:** `"result_kind"` is a new wire-format field
  that subprocess callers can rely on. The solution recommends but does not block
  on a §3 amendment. If a future PR adds a subprocess consumer that keys on
  `"result_kind"`, the absence of a SPEC entry creates an undocumented contract.
  Low urgency; noted for the parent-level validator.
