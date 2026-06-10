---
template_version: 1
template_name: validation
parent_solution: ./solution.md
parent_problem: ./problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/3
revision_triggered: none
---

# Validation: Stream-from variant with pure classify_event/2 as fold kernel

## Overview

The solution proposes deleting `drain_run_loop/2` and `drain_session_end/2`
from `lib/tau/cli.ex` and replacing the consumption path with a new
`Tau.Session.stream_from/3` whose `Stream.resource/3` setup is a no-op
(the caller has already subscribed to satisfy D-004) plus two extracted
pure helpers (`classify_event/2`, `render_event/1`) folded over the
stream with `Enum.reduce_while`. The drain seeds the accumulator at
`{%{}, 1}` so that a missing `SessionEnd` within the drain window
surfaces as exit-code 1 rather than the present silent success.

Six checkable claims are extracted from the **Recommendation** and
**What changes** sections. Each receives full Toulmin treatment (six
fields) and an explicit, named falsification strategy. Five claims
withstood falsification; **claim 3** (the `Stream.resource/3` setup-as-
no-op design) was **partially falsified** by a resource-ownership
counter-example: the no-op setup cannot also unsubscribe on teardown
without breaking the caller's still-live subscription, so the
`stream_from/3` contract MUST explicitly state that subscription
ownership remains with the caller. The qualifier is narrowed in place
(no revision required); the implementer notes are sufficient to land
the change safely.

## Toulmin per claim

### Claim 1: "`drain_run_loop/2` and `drain_session_end/2` are deleted."

- **Claim (C):** The two raw-`receive` functions at `lib/tau/cli.ex:427-486`
  and `lib/tau/cli.ex:489-497` are removed entirely; the headless run
  path no longer contains a hand-rolled `receive` loop.
- **Grounds (G):** `lib/tau/cli.ex:427-486` defines `drain_run_loop/2`
  with a `receive do … _ -> drain_run_loop/2 end` body and a wildcard
  catch-all. `lib/tau/cli.ex:489-497` defines `drain_session_end/2`
  with `receive after 10_000 -> exit_code`. The solution's "What
  changes" §2 explicitly states "replace `drain_run_loop/2` and
  `drain_session_end/2` with [the new helpers and pipeline]" and the
  migration sketch step 3 says "delete `drain_run_loop/2` and
  `drain_session_end/2`".
- **Warrant (W):** OTP non-negotiable #4 — "Cross-process events MUST
  use `Phoenix.PubSub` or monitored refs"; the project reads this
  rule as forbidding hand-rolled `receive` in client code over
  PubSub-delivered events. Replacing the loop with a `Stream.resource/3`
  consumer concentrates the `receive` inside the established stream
  idiom (already in `Tau.Session.stream/2` at `lib/tau/session.ex:175-191`).
- **Qualifier (Q):** Holds for the headless `tau run` path. The TUI
  path is out of this sub-problem's scope; existing `Tau.Session.stream/2`
  callers are unaffected (solution §"What does not change").
- **Rebuttal (R):** If a hidden caller (test, neighbour module) calls
  `Tau.CLI.drain_run_loop/2` or `drain_session_end/2` directly,
  deletion breaks compilation. `Grep` over `lib/` and `test/` shows
  call sites in `test/tau/cli/headless_run_test.exs:84,92,107,140,166,
  190,211,252` and `test/tau/cli/headless_run_tool_exposure_test.exs:124,
  128` — all are tests; the comment at `lib/tau/tools/builtin/agent.ex:433`
  is a docstring-only reference. The solution's "What changes" §3
  explicitly notes the test rewrite obligation, so the rebuttal is
  pre-conceded.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §4; module
  docs at `lib/tau/cli.ex:36-46` already concede the present pattern
  is a workaround for D-004 (`SPEC-USER-TURN.md:497`).

#### Falsification attempt for claim 1

- **Strategy:** Dependency check + edge-case enumeration over the
  enumerated `Events.*` catalog.
- **Attempt:** Grep'd `Events.*` struct names in
  `lib/tau/session/events.ex` (full list: `SessionStart`, `MessageStart`,
  `MessageUpdate`, `MessageEnd`, `ToolStart`, `ToolUpdate`, `ToolEnd`,
  `Cancelled`, `SkillActivated`, `SystemNotice`, `SessionEnd`,
  `CommandCatalog`, `PermissionRequest`). Confirmed each appears in
  the present `drain_run_loop/2` either by name or via the wildcard
  catch-all. The post-deletion replacement (`classify_event/2` with a
  fallback clause that emits `Logger.debug` for unknown structs)
  covers every enumerated event with named clauses or a single safe
  fallback. No event-shape is silently lost.
- **Outcome:** Withstood.
- **Action:** None.

### Claim 2: "Unknown `Events.*` structs log at `:debug` via the `classify_event` fallback clause and do not silently recurse."

- **Claim (C):** A struct delivered on the session topic that is not
  in the explicit `classify_event/2` head set produces a `Logger.debug`
  line and a `{:continue, names}` reduce-step, rather than the
  present silent wildcard `_ -> drain_run_loop(...)` recursion.
- **Grounds (G):** Present `lib/tau/cli.ex:483-484` is the literal
  silent-discard clause the problem statement names. The solution
  "What changes" §2 names a "fallback `Logger.debug` clause" in
  `classify_event/2`.
- **Warrant (W):** Hickey "Simple Made Easy": a single explicit
  fallback that names what it discards (via the log line) decomplects
  observability from control-flow; OTP NN §5 requires telemetry for
  user-visible/perf-sensitive behaviour, and a debug log is the
  minimum visibility bar for an unhandled-event class.
- **Qualifier (Q):** Holds for events delivered on the
  `"session:<id>"` topic. Cross-topic deliveries are out of scope —
  the subscriber only joins that one topic.
- **Rebuttal (R):** If a future event type carries information the
  drain MUST act on (e.g. a hypothetical `MidStreamFailure` that
  ought to short-circuit to exit 1), the fallback would silently
  continue. Solution does not pre-empt this; the implementer is
  obligated to update `classify_event/2` whenever a new event has
  drain-relevant semantics. This is acceptable because it converts
  a silent-discard bug into a "named extension point" risk surfaced
  by code review of any new `Events.*` struct.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §5
  (telemetry / observability); Hickey, "Simple Made Easy" (2011) —
  decomplecting "what to do" from "what to log".

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction.
- **Attempt:** Attempted to construct an event shape that would
  bypass `classify_event/2`'s fallback. Pattern-matching on
  `struct() x map() -> {:continue, map()} | {:halt, 0|1}` with a
  fallback clause `def classify_event(_, names), do: {:continue, names}`
  catches any term reachable through `receive` (all PubSub broadcasts
  are structs per the event catalog). The only non-struct deliverable
  would be a `{:permission_decision, …}` style cast — but those go to
  the FSM, not the subscriber.
- **Outcome:** Withstood.
- **Action:** None.

### Claim 3: "`stream_from/3` accepts an already-open subscription handle and satisfies D-004 without a hand-rolled handshake."

- **Claim (C):** A new `Tau.Session.stream_from/3` variant (or
  `stream/3` with an `:already_subscribed` sentinel) whose
  `Stream.resource/3` setup is a no-op preserves the D-004 invariant
  (subscribe-before-`start_session`) without requiring an inter-process
  `{:subscribed, ref}` / `{:start, ref}` handshake.
- **Grounds (G):** `lib/tau/cli.ex:314-327` shows the present
  manual `Phoenix.PubSub.subscribe/2` precedes `Tau.start_session/1`.
  `lib/tau/session.ex:175-191` shows the existing `stream/2` performs
  subscription inside its setup function — exactly the late-subscribe
  that violates D-004 (acknowledged in `lib/tau/cli.ex:296-299`).
  A setup-as-no-op preserves the caller's pre-existing subscription
  without re-subscribing or unsubscribing.
- **Warrant (W):** `Stream.resource/3` semantics: setup runs once at
  first pull, the reducer runs per element, teardown runs once on
  halt. If subscription is already held by the calling process (which
  also owns the `receive` mailbox the stream consumes), a no-op
  setup/teardown is sufficient — the receive body simply consumes
  messages already destined for the caller. D-004 is about *temporal
  ordering*; once subscription is established before `start_session`
  the invariant holds regardless of where in the pipeline the
  stream pulls.
- **Qualifier (Q):** Holds **only when the calling process is the
  subscription owner AND the same process consumes the stream.** If
  a `Task` or other process consumes the stream, the receive body
  reads the wrong mailbox.
- **Rebuttal (R):** If `Stream.resource/3`'s teardown were to
  `Phoenix.PubSub.unsubscribe/2`, it would break the caller's
  subscription that the caller still owns. The solution's setup-as-
  no-op implies teardown-as-no-op; the caller (`run_cmd/1`) retains
  ownership and the subscription dies with the calling process at
  exit. This is correct but **MUST be made explicit in the new
  function's docstring** — a future maintainer adding "polite
  teardown" would silently break the contract.
- **Backing (B):** SPEC-USER-TURN §4 B6, D-004 row at
  `docs/spec/SPEC-USER-TURN.md:497`; `Stream.resource/3` HexDocs
  (https://hexdocs.pm/elixir/Stream.html#resource/3) on
  setup/reducer/teardown semantics.

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction over resource-ownership.
- **Attempt:** Constructed the hypothetical "polite teardown" case:
  if `stream_from/3` adds `Phoenix.PubSub.unsubscribe/2` on teardown,
  the caller's subscription is severed mid-`run_cmd/1` lifetime,
  silently breaking any further consumption (e.g. a future
  post-drain step that re-uses the subscription). The solution does
  not state this constraint in the function contract; only the
  migration sketch implies it. This is **not** a falsification of the
  claim that D-004 is satisfied — but it falsifies the broader
  reading that the new API is contract-complete without a docstring
  warning. **Partial falsification.**
- **Outcome:** Partially falsified.
- **Action:** Narrow the qualifier in place: the claim holds only
  under "caller-owned subscription, no-op teardown, contract
  documented". The implementer must encode this in the new function's
  `@doc` and `@spec`. No solution revision required; this is a
  drafting tightening that fits inside the implementation PR.

### Claim 4: "A missing `SessionEnd` yields exit code `1` because the initial reduce accumulator is `{%{}, 1}`."

- **Claim (C):** When the drain stream halts (timeout) without ever
  delivering `%SessionEnd{}`, `Enum.reduce_while/3` returns the
  initial accumulator `{%{}, 1}`, and the `elem(1)` projection
  yields exit code `1`.
- **Grounds (G):** Solution "What changes" §2: pipeline is
  `… |> Enum.reduce_while({%{}, 1}, fn e, {names, _} -> render_event(e);
  classify_event(e, names) end) |> elem(1)`. The present
  `drain_session_end/2` at `lib/tau/cli.ex:489-497` returns the
  caller-seeded `exit_code` on timeout — which the problem statement
  identifies as the silent-success bug.
- **Warrant (W):** `Enum.reduce_while/3` semantics: when the
  enumerable is exhausted without a `{:halt, _}` reducer step, the
  current accumulator is returned. The seed `{%{}, 1}` thus survives
  timeout untouched; any successful `MessageEnd`-without-tool_calls
  path explicitly returns `{:halt, {names, 0}}` via `classify_event/2`,
  overwriting the seed's `1`.
- **Qualifier (Q):** Holds **only if** `classify_event/2` for the
  non-failure `MessageEnd` clause produces `{:halt, {names, 0}}` —
  not `{:cont, {names, 0}}` — and the `SessionEnd` clause produces
  the same. The solution describes `{:halt, 0|1}` but the actual
  shape passed to `reduce_while` must be `{:halt, {names, 0|1}}`
  because the accumulator is the pair. The solution's wording is
  shorthand; the implementer must lift the integer into the pair.
- **Rebuttal (R):** If `render_event/1` raises before `classify_event/2`
  is reached (e.g. on a malformed event), the reducer crashes and
  the caller never receives `1` — it receives the exception. This is
  acceptable under OTP NN #7 ("let it crash") but slightly
  changes the failure mode versus today's silent-success-on-timeout.
  The escript halt path will surface an error exit; this is strictly
  better than silent success.
- **Backing (B):** `Enum.reduce_while/3` HexDocs
  (https://hexdocs.pm/elixir/Enum.html#reduce_while/3) on accumulator
  return semantics; `.claude/rules/otp-non-negotiables.md` §7
  (let-it-crash).

#### Falsification attempt for claim 4

- **Strategy:** Edge-case enumeration over reduce_while termination
  modes.
- **Attempt:** Three termination modes: (i) reducer returns
  `{:halt, acc}` — `acc` is returned; (ii) enumerable exhausted —
  current acc is returned; (iii) reducer raises — exception
  propagates. For mode (i), explicit halt clauses in
  `classify_event/2` set the exit-code value. For mode (ii) — the
  timeout path — seed survives; `elem(1)` is `1`. For mode (iii) —
  unexpected — the escript exits non-zero via OTP crash. No mode
  produces a silent success after the seed initialisation.
- **Outcome:** Withstood.
- **Action:** None — but ensure implementer encodes the pair-lifting
  (Qualifier note above) and writes a property test that timeout →
  exit 1.

### Claim 5: "Rendering is decomplected into a separate `render_event/1` pure function called before the classify step."

- **Claim (C):** `render_event/1` is a separate, pure side-effecting
  function (`struct() → :ok`) called before `classify_event/2` in
  the `reduce_while` body; rendering and control-flow are not
  interleaved.
- **Grounds (G):** Present `lib/tau/cli.ex:467-468,477-478` shows
  rendering (`IO.puts(:stderr, …)`) interleaved with control-flow
  (`drain_run_loop(session_id, Map.put(…))`). Solution "What
  changes" §2 names `render_event/1` and the inline pipeline
  `… fn e, {names, _} -> render_event(e); classify_event(e, names) end`.
- **Warrant (W):** Hickey's "Simple Made Easy" complecting test: a
  function that both renders and decides exit-code complects two
  concerns; separating them per call ordering decomplects render-
  before-classify and lets each be tested independently.
- **Qualifier (Q):** Holds for events whose render output does not
  depend on classify state. `ToolEnd` needs `tool_names` to print
  the tool name — solution Open Questions explicitly flags this and
  requires either event-enrichment or a `(event, tool_names)`
  signature for `render_event/1`.
- **Rebuttal (R):** The Open-Question concession means `render_event/1`
  is **not** strictly `struct() → :ok` for `ToolEnd`; it needs
  `(struct(), map()) → :ok` at least there. The solution
  acknowledges this; the implementer must commit to one of the two
  paths. Either path preserves the decomplecting intent.
- **Backing (B):** Hickey, "Simple Made Easy" (2011) — complecting
  vs orthogonal composition; `.claude/skills/design-reasoning`
  (PSDH) on decomplecting as a triage outcome.

#### Falsification attempt for claim 5

- **Strategy:** Counter-example construction over the `ToolEnd` path.
- **Attempt:** Tried to construct a `render_event/1` that handles
  `ToolEnd` without access to `tool_names`. Result: it would print
  `"[tau] ← ? ✓"` for every `ToolEnd`, losing the name lookup the
  present implementation performs at `lib/tau/cli.ex:474-478`. The
  decomplecting is preserved if `render_event/1` takes `tool_names`
  as a second argument (the Open Question's recommended fix) — but
  the strict-arity-1 reading of the claim is falsifiable for `ToolEnd`.
- **Outcome:** Withstood under the qualifier "with the Open Question
  resolved by the recommended `(event, tool_names)` shape". The
  claim's *intent* (decomplect render from control-flow) is
  preserved; only the literal arity-1 wording yields if pressed.
- **Action:** None — solution itself flags this as an implementer
  decision.

### Claim 6: "Existing `Tau.Session.stream/2` callers are unaffected; no new supervised processes; no new dependencies."

- **Claim (C):** The change adds `stream_from/3` as a new sibling of
  `stream/2` without modifying `stream/2`; no new GenServer, no new
  application-tree entry, no new Mix dep.
- **Grounds (G):** Solution "What does not change" §2-5 enumerates
  these non-changes. `lib/tau/session.ex:175-191` shows `stream/2` is
  a standalone function — adding `stream_from/3` does not touch it.
- **Warrant (W):** Additive API extension preserves caller contracts
  by construction; OTP NN #3 ("MUST NOT wrap stateless logic in a
  GenServer") cuts against the GenServer proposal-2 alternative,
  which is why the hybrid wins on this axis.
- **Qualifier (Q):** Holds for the production tree. Test code may
  add helper processes for the new function's properties; that is
  expected and non-objectionable.
- **Rebuttal (R):** If the implementer chooses the `stream/3`-with-
  sentinel form (vs a separate `stream_from/3`), they are modifying
  `stream/2`'s arity. The solution explicitly accepts either shape
  ("`stream_from/3` (or `stream/3` with an `:already_subscribed`
  sentinel)"); the sentinel form is a non-breaking arity-2-to-3
  default-arg extension and remains contract-preserving.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §3 (no
  GenServer for stateless logic); SPEC-USER-TURN §4 B6 on the
  stream contract.

#### Falsification attempt for claim 6

- **Strategy:** Dependency check + integration check.
- **Attempt:** Grep'd `lib/tau/application.ex` for current supervised
  children and `mix.exs` for current deps; neither requires
  modification for an additive function. Existing callers of
  `Tau.stream/2` are unaffected because `stream/2` is unchanged
  (additive extension only). No counter-example surfaced.
- **Outcome:** Withstood.
- **Action:** None.

## Cross-claim consistency

Claims 1, 2, and 3 form a chain: deletion of the raw-receive loop
(C1) presupposes a working stream-based replacement (C3), which in
turn requires the unknown-event fallback (C2) to absorb everything
the wildcard previously absorbed. The chain is consistent: C3's
no-op-setup design holds the caller's subscription, C2's
`Logger.debug` fallback absorbs unenumerated structs, and C1's
deletion becomes safe.

Claims 4 and 5 share the `reduce_while` body. C5's `render_event/1`
runs before C4's `classify_event/2`; if `render_event/1` raises,
C4's seed-survives-timeout property does not apply (the reduce never
completes). The let-it-crash rebuttal under C4 resolves this: an
exception is acceptable, and is strictly better than the present
silent-success bug.

Claim 6 is orthogonal to 1-5 and consistent with all of them.

The only friction is between Claim 3's "no-op teardown" implication
and any future maintainer who reads the new `stream_from/3` and
adds an `unsubscribe/2` for symmetry. This is the partial
falsification under Claim 3 and is mitigated by docstring
clarification at implementation time.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Delete drain_run_loop/2 + drain_session_end/2 | Dependency + edge-case enum | withstood | none |
| 2 | Unknown events log at :debug, not silently discarded | Counter-example | withstood | none |
| 3 | stream_from/3 with no-op setup preserves D-004 | Counter-example (resource ownership) | partially falsified | narrow Q in place — docstring must state caller-owned subscription, no-op teardown |
| 4 | Missing SessionEnd → exit 1 via {%{}, 1} seed | Edge-case enum over reduce_while modes | withstood | none |
| 5 | render_event/1 separated from classify_event/2 | Counter-example (ToolEnd) | withstood (under Open-Q resolution) | none |
| 6 | Additive API; no new procs, no new deps | Dependency + integration | withstood | none |

## Revision required

None at the solution-revision or problem-revision level. Claim 3's
partial falsification is resolved by narrowing the qualifier in
place: the implementer MUST document, in `stream_from/3`'s `@doc`,
that subscription ownership remains with the caller and that
teardown is intentionally a no-op. This is a drafting tightening
that lands inside the implementation PR, not a solution rewrite.

- **Target file:** none (qualifier narrowed in place)
- **Revision kind:** n/a
- **Rationale:** The solution's intent is correct and achievable;
  only the contract documentation needs to be explicit. Treating
  this as a solution revision would be Toulmin theater — the design
  decision is sound; the docstring is an implementation detail the
  reviewer will catch.

## Outstanding doubts

- The `tool_names` accumulator in the `reduce_while` second slot
  is correct for `ToolStart`/`ToolEnd` correlation but does not
  appear in the solution's Recommendation prose — only in the
  pipeline snippet. The parent-level validator should ensure the
  `(map, integer)` accumulator shape is explicit in any parent
  synthesis.
- The solution's "10 s vs 60 s" timeout Open Question is unresolved.
  The recommendation (10 s for headless, 60 s for `stream/2`) is
  sound but means `stream_from/3` MUST accept `:timeout` as an
  option — the snippet shows `timeout: 10_000` but the function
  signature `stream_from/3` does not enumerate options in the
  Recommendation. Implementer obligation, surfaced for the parent.
- The pure-vs-side-effect framing of `render_event/1` ("pure side-
  effecting function") is contradictory at the surface; the intent
  is "isolated side-effect; no control-flow return" but the wording
  invites a reviewer challenge. Parent validator should rewrite to
  "isolated I/O function returning `:ok`" or similar.
