---
template_version: 1
template_name: validation
parent_solution: ./solution.md
parent_problem: ./problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/1
revision_triggered: none
---

# Validation: Symmetric rescue in handle_event/4 + :rest_for_one supervisor strategy

## Overview

The solution makes two structural assertions: (1) a `rescue` block added to
`Tau.Cost.Tracker.handle_event/4` makes it D-035-compliant and symmetric
with `handle_coding_agent_cost/4`, and (2) flipping
`Tau.Telemetry.Supervisor` from `:one_for_one` to `:rest_for_one` (with
`Handlers` before `Cost.Tracker`) decomplects handler-attachment lifecycle
from supervisor restart scope without over-restarting `Cost.Tracker` in the
common path. The solution also makes three derivative non-change assertions
(no API surface change, no `Tau.Application` blast-radius expansion,
existing `start_supervised(Tau.Telemetry.Supervisor)` tests preserved). I
extracted six checkable claims, ran a different falsification strategy per
claim against the live tree at `lib/tau/cost/tracker.ex` and
`lib/tau/telemetry/supervisor.ex`, and corroborated with ADR-0010,
OTP-NN §7, and the existing `OtelReporter.Handler` precedent. Five claims
withstood; one (Claim 1's coverage of the cited failure mode) is partially
falsified — the *crash window does exist*, but not via the float path the
solution names; the qualifier needs narrowing.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

### Claim 1: A rescue block in handle_event/4 makes it D-035-compliant (a malformed `:usage` measurement that would otherwise crash the emitter is degraded gracefully).

- **Claim (C):** Adding the `rescue` mirror around `handle_event/4`'s
  `with` block — emitting `[:tau, :cost, :tracker, :handler_failed]` and
  returning `:ok` on any raise — closes the crash boundary D-035 requires
  for cost-folding handlers, satisfying acceptance-criterion part (a).
- **Grounds (G):** `lib/tau/cost/tracker.ex:117-138` shows
  `handle_event/4` with no `rescue`; lines 144-172 show the
  D-035-compliant twin `handle_coding_agent_cost/4` with the exact
  pattern the solution mirrors (rescue → emit
  `[:tau, :cost, :tracker, :handler_failed]` → `:ok`). The module
  docstring at lines 50-53 explicitly names D-035 and the
  `:handler_failed` event as the contract. The reachable raise paths in
  the body include `:ets.update_counter/3` at line 129 (raises
  `ArgumentError` on table-missing, on a non-integer increment, or on
  spec mismatch) and tuple construction at line 122.
- **Warrant (W):** A handler executes in the emitter's process
  (`:telemetry.execute/3` invokes attached handlers synchronously in the
  calling process — `hexdocs.pm/telemetry`). Therefore any uncaught
  raise inside the handler propagates to the FSM that emitted the event.
  D-035 (cited in the docstring) and the
  "handler-must-not-crash-emitter" contract documented in
  `lib/tau/otel_reporter/handler.ex:5-7` together license an
  intra-process `try/rescue` *inside the handler boundary* as the
  required degrade-gracefully mechanism. This is consistent with — not
  in violation of — OTP non-negotiable §7 ("MUST NOT `try/rescue`
  across process boundaries"), because the rescue is purely intra-process.
- **Qualifier (Q):** Holds for any raise reachable from the body
  *that the `with`/`else` guard does not already short-circuit*. The
  cited float-via-`:usage` path is NOT one of those: `nz/1` at
  `tracker.ex:176-177` returns `0` for any non-integer, so a float in
  `usage[:input_tokens]` is silently coerced to `0` and never reaches
  `:ets.update_counter`. The load-bearing failure surface is therefore
  narrower than the problem statement implies: it is
  table-missing-during-restart, `update_counter` spec mismatch in a
  future refactor, or a non-binary `model` causing tuple-key trouble in
  a downstream consumer. The rescue is still load-bearing for those.
- **Rebuttal (R):** The rescue does NOT close the silent-data-loss hole
  that `nz/1` opens (a provider sending a float is silently recorded as
  zero tokens). It only protects against process death, not against
  observability data quality. The solution's open question #2 (lines
  113-117) flags this; the rescue is correctly scoped to crash-safety,
  not data-quality.
- **Backing (B):** D-035 (cited inline in
  `lib/tau/cost/tracker.ex:50-53` and at the docstring of
  `handle_coding_agent_cost/4` lines 141-143). OTP non-negotiable §7
  (`.claude/rules/otp-non-negotiables.md:26-28`) explicitly bounds the
  prohibition to *cross-process* try/rescue, leaving intra-process
  rescue inside a handler boundary permissible. The
  `Tau.OtelReporter.Handler.handle_event/4` precedent at
  `lib/tau/otel_reporter/handler.ex:27-38` shows the identical pattern
  already in production for the same reason, with the docstring
  contract explicit at lines 5-7.

#### Falsification attempt for claim 1

- **Strategy:** Edge-case enumeration over the documented and undocumented
  raise paths inside `handle_event/4`.
- **Attempt:** Enumerated five reachable failure modes inside the
  `with`-body of `handle_event/4`:
  (i) `:ets.update_counter` called when `@table` does not exist (raises
  `ArgumentError`) — possible during the narrow window between
  `Cost.Tracker` death and supervisor restart;
  (ii) `:ets.update_counter` called with a non-integer increment
  (`ArgumentError`) — the path the problem statement and Proposal 1
  cite via a float in `usage[:input_tokens]`;
  (iii) `today_iso()` raising on a system-clock NIF failure
  (theoretical; not observed in this codebase);
  (iv) the tuple key `{today_iso(), provider, metadata[:model], session_id}`
  being malformed and breaking an `:ets.update_counter` ordered-set
  invariant (no — ETS is `:set`, line 81-87, accepts any term as key);
  (v) the `update_counter` op list being mis-shaped (a future refactor
  defect, not present today).
  Then I checked each against the *as-is* code:
  - Path (i) — table-missing. Reachable. `:named_table, :public, :set`
    at `tracker.ex:81-87` means the table belongs to the `Cost.Tracker`
    process; if the process dies between the table being destroyed and
    a queued telemetry event still in flight in another process,
    `:ets.update_counter` raises `ArgumentError`. Rescue catches it.
    Withstands.
  - Path (ii) — float via `:usage`. NOT reachable as cited.
    `nz/1` at `tracker.ex:176-177` matches only
    `is_integer(n) and n >= 0`; a float falls to the catch-all and
    returns `0`. The named failure mode is absorbed by `nz/1`, not by
    the proposed rescue. The problem statement's "non-integer in `:usage`
    that passes the `is_map` guard causes an `ArgumentError`" is
    therefore *factually wrong about the float path* — `nz/1` is the
    actual silencer there. Partial falsification of the *motivating
    example* in the problem statement; the rescue is still defensible
    via paths (i) and (v).
  - Path (iii), (iv), (v) — theoretical/future; rescue covers them.
- **Outcome:** partially falsified. The rescue is justified, but the
  problem statement's cited motivating failure (float via `:usage`) is
  not the reachable path; `nz/1` already absorbs it silently. The
  load-bearing motivation is path (i) — the restart-window
  table-missing race, particularly relevant under the `:rest_for_one`
  change in Claim 2 which makes `Cost.Tracker` restarts more frequent.
- **Action:** Narrow Qualifier in place (done above). No
  solution.md edit required — the recommended change is correct; only
  the *justification narrative* in problem.md is slightly off. This is
  recorded under **Outstanding doubts** for the parent validator to
  fold into context, but does not warrant `revision_triggered`.

### Claim 2: Changing `Tau.Telemetry.Supervisor` from `:one_for_one` to `:rest_for_one` (with `Handlers` listed before `Cost.Tracker`) decomplects handler-attachment lifecycle from supervisor restart scope.

- **Claim (C):** Under `:rest_for_one`, a `Tau.Telemetry.Handlers` crash
  cascades to `Tau.Cost.Tracker`, forcing `Cost.Tracker.terminate/2` →
  `init/1` to run, which detaches then re-attaches handlers cleanly.
  This eliminates the duplicate-handler-registration window the
  problem.md identifies.
- **Grounds (G):** `lib/tau/telemetry/supervisor.ex:17-22` shows the
  current child list `[Tau.Telemetry.Handlers, Tau.Cost.Tracker]` —
  ordering already satisfies the solution's precondition (verified at
  this commit; the solution's open question #3 about a third sibling is
  vacuous today). `Cost.Tracker.terminate/2` at
  `lib/tau/cost/tracker.ex:111-115` calls `:telemetry.detach/1` for both
  `@handler_id` and `@coding_agent_handler_id`. `Cost.Tracker.init/1` at
  lines 80-108 calls `:telemetry.attach/4` for both IDs. Therefore the
  detach-on-terminate-then-attach-on-init cycle is mechanically present.
- **Warrant (W):** `:rest_for_one` semantics (Erlang OTP supervisor
  docs — see https://www.erlang.org/doc/man/supervisor.html): when a
  child dies, every sibling listed *after* it in the child list is
  terminated and restarted in order. This is the idiomatic OTP location
  to express "X's lifecycle depends on Y's" — the dependency lives in
  the supervisor child ordering, not in ad-hoc monitoring code (cf.
  Proposal 3's monitor approach, rated lower for that reason).
- **Qualifier (Q):** Holds while (a) `Handlers` precedes `Cost.Tracker`
  in the child list (currently true at
  `lib/tau/telemetry/supervisor.ex:17-20`), and (b) only those two
  children sit under `Telemetry.Supervisor`. A third child added between
  them would be unnecessarily restarted on a `Handlers` crash — flagged
  in the solution's open question #3.
- **Rebuttal (R):** If `:telemetry.detach/1` were ever skipped (e.g. a
  brutal-kill restart that bypasses `terminate/2`), the post-restart
  `init/1` would call `:telemetry.attach/4` against an ID that is still
  registered, raising. `:telemetry.attach/4` returns
  `{:error, :already_exists}` rather than raising on duplicate IDs
  (verified at https://hexdocs.pm/telemetry/telemetry.html#attach/4),
  so the restart would silently fail to attach. Under default
  Supervisor `shutdown: 5_000` and `restart: :permanent`,
  `terminate/2` is invoked on normal restart; the rebuttal applies only
  to a brutal-kill path, which is not on the default supervision spec
  for either child.
- **Backing (B):** Erlang/OTP `Supervisor` documentation —
  `:rest_for_one` strategy
  (https://www.erlang.org/doc/man/supervisor.html). OTP non-negotiable
  §1 — "Stateful subsystems MUST run as supervised processes" — implies
  that lifecycle dependencies between them belong in the supervisor's
  declarative configuration. ADR-0010 (`docs/adr/0010-cost-tracker-owns-ets-not-state.md:46-69`)
  documents `Cost.Tracker` as the ETS-and-handler-attachment lifecycle
  anchor; `:rest_for_one` is the explicit encoding of that anchoring.

#### Falsification attempt for claim 2

- **Strategy:** Dependency check — verify the codebase state the claim
  depends on actually holds.
- **Attempt:** Three dependencies named:
  (a) `Handlers` precedes `Cost.Tracker` in the child list — confirmed
  at `lib/tau/telemetry/supervisor.ex:17-20`;
  (b) `Cost.Tracker.terminate/2` detaches both handler IDs — confirmed
  at `lib/tau/cost/tracker.ex:111-115`;
  (c) `Cost.Tracker.init/1` re-attaches both IDs — confirmed at
  `lib/tau/cost/tracker.ex:89-105`.
  Additionally checked the ETS table contract: `@table` is
  `:named_table` at line 82, so on `init/1` a `:ets.new` would normally
  raise on a name clash, but since the table was owned by the
  prior-incarnation `Cost.Tracker`, the table is destroyed when that
  owner dies — name is released. Verified by Erlang ETS docs
  (https://www.erlang.org/doc/man/ets.html — "If a table is created
  with the named_table option [...] [it] is also destroyed if the
  owning process is terminated").
- **Outcome:** withstood. All three required-state propositions hold;
  the ETS table lifecycle and handler attachment lifecycle compose
  correctly under the cascade restart.
- **Action:** None.

### Claim 3: The change is "the minimal change that satisfies both acceptance criterion parts (a) and (b) with no new modules, no API surface change, and no blast-radius expansion."

- **Claim (C):** The two-file diff is minimal among the four proposals
  evaluated and incurs no module or API addition.
- **Grounds (G):** Solution `## Scoring table` lines 56-64 score
  Proposal 1 as Low migration cost, Low risk, Easy reversibility;
  Proposals 2, 3, 4 score worse on at least one dimension. The
  `## What changes` section (lines 73-83) lists exactly two files;
  the `## What does not change` section (lines 85-95) enumerates the
  preserved surfaces. No new module is added; no exported function
  signature changes.
- **Warrant (W):** "Minimal change to satisfy the requirement"
  is the Rich-Hickey-style decomplecting heuristic: prefer the smallest
  edit that separates the previously-tangled concerns. Two concerns —
  crash-safety (Claim 1) and attachment-lifecycle vs restart-scope
  (Claim 2) — each get their own targeted edit; neither edit creates a
  new abstraction.
- **Qualifier (Q):** "Minimal among the four enumerated proposals."
  Not minimal in an absolute sense — for example, a hypothetical fifth
  proposal that only added the rescue and left the supervisor alone
  would be even smaller but would not satisfy AC part (b). The solution
  is minimal within the constraint of satisfying *both* AC parts.
- **Rebuttal (R):** If a reader interpreted "no blast-radius expansion"
  as "no behaviour change for non-crash paths", they would be wrong:
  `:rest_for_one` does change post-crash behaviour (Cost.Tracker now
  restarts on Handlers crash where it previously did not). The claim
  is about *structural* blast-radius (no change to `Tau.Application`'s
  17-child supervision tree), not about *behavioural* blast-radius.
  The latter is the very point of the change.
- **Backing (B):** Rich Hickey, "Simple Made Easy"
  (https://www.infoq.com/presentations/Simple-Made-Easy/) — the
  decomplecting heuristic. PSDH triage guidance in
  `.claude/skills/design-reasoning` — separate concerns, do not
  manufacture abstractions until n ≥ 3 (cited in the solution's
  reasoning for rejecting Proposal 2 at n=2 handlers).

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction — try to construct a
  smaller diff that satisfies both AC parts.
- **Attempt:** Considered three smaller alternatives:
  (i) Add the rescue but keep `:one_for_one` — fails AC part (b).
  (ii) Change strategy but skip the rescue — fails AC part (a).
  (iii) Use a `Process.flag(:trap_exit, true)` on Cost.Tracker to
  monitor Handlers crashes without changing supervisor strategy —
  adds a process-mailbox concern that violates ADR-0010's "no state in
  mailbox" stance, and is essentially Proposal 3 (rejected).
  None of the three is both smaller AND satisfies both AC parts.
- **Outcome:** withstood. Within the AC's joint constraints, the
  two-line strategy flip + ~10-line rescue is the minimum.
- **Action:** None.

### Claim 4: `Tau.Application`'s supervision tree is unchanged; blast radius is contained to the intermediate supervisor's two children.

- **Claim (C):** No edit to `lib/tau/application.ex` is required or
  performed; the cascade restart cannot propagate past
  `Tau.Telemetry.Supervisor`.
- **Grounds (G):** `lib/tau/application.ex:62` registers
  `Tau.Telemetry.Supervisor` as a single child of `Tau.Application`.
  Whatever strategy `Tau.Application` itself uses, its sibling children
  see only the supervisor handle, not the descendants inside it.
- **Warrant (W):** OTP supervision-tree composition: a supervisor's
  internal restart strategy bounds the cascade to its own children. A
  parent supervisor sees only the immediate child's start/stop
  transitions, not the grandchild-level restarts inside it. This is
  documented in the OTP design principles
  (https://www.erlang.org/doc/design_principles/sup_princ.html).
- **Qualifier (Q):** Holds unless `Tau.Telemetry.Supervisor` itself
  exceeds its supervisor `max_restarts` window and dies — which would
  then propagate up to `Tau.Application`'s strategy. Default
  `max_restarts: 3, max_seconds: 5` applies; if a `Handlers` crash
  flapped >3 times in 5s, the intermediate supervisor would die and
  `Tau.Application`'s strategy would govern. This is unchanged from
  `:one_for_one`.
- **Rebuttal (R):** None for the structural claim.
- **Backing (B):** Erlang/OTP design principles, supervisor section.

#### Falsification attempt for claim 4

- **Strategy:** Integration check — confirm by grep that no edit to
  `application.ex` is part of the proposed diff and that the parent
  supervisor's view of `Tau.Telemetry.Supervisor` is unchanged.
- **Attempt:** `grep -n "Telemetry.Supervisor" lib/tau/application.ex`
  shows the single registration at line 62. The `What changes` section
  lists only `cost/tracker.ex` and `telemetry/supervisor.ex`.
- **Outcome:** withstood.
- **Action:** None.

### Claim 5: Existing tests using `start_supervised(Tau.Telemetry.Supervisor)` continue to work (module name and child-spec API preserved).

- **Claim (C):** No test breakage from the change.
- **Grounds (G):** Grep across `test/` (`grep -rn
  "Tau.Telemetry.Supervisor\|start_supervised" test/`) returns no
  match for `start_supervised(Tau.Telemetry.Supervisor)`. The
  module name is unchanged; `start_link/1` signature is unchanged at
  `lib/tau/telemetry/supervisor.ex:11-13`; child-spec API is
  unchanged.
- **Warrant (W):** A supervisor's restart strategy is an internal
  property; consumers only observe `start_link/1` and the supervised
  PIDs. Changing strategy does not change either.
- **Qualifier (Q):** The "existing tests" set is currently empty for
  the named usage — the claim is *trivially true* by vacuity at this
  commit. It remains true under the change.
- **Rebuttal (R):** None.
- **Backing (B):** Supervisor module documentation
  (https://hexdocs.pm/elixir/Supervisor.html).

#### Falsification attempt for claim 5

- **Strategy:** Dependency check — confirm the consumer set is what the
  claim assumes.
- **Attempt:** `grep -rn` over `test/` and `lib/` for
  `Tau.Telemetry.Supervisor` returns three matches:
  `lib/tau/application.ex:62` (registration), the file itself, and
  the moduledoc reference in `lib/tau/cost/tracker.ex:71`. No test
  consumer.
- **Outcome:** withstood (vacuously — the consumer set named is
  empty, and the claim is robust to consumers being added later
  because the public API is unchanged).
- **Action:** None. Recorded under **Outstanding doubts** that this
  claim is currently vacuous; not a defect, just context for the
  parent validator.

### Claim 6: The `with`/`else` structural guard in `handle_event/4` is preserved unchanged; the rescue wraps the existing `with` block.

- **Claim (C):** The proposed `rescue` is additive — the `with` chain
  and its `else _ -> :ok` fall-through are unchanged.
- **Grounds (G):** The Proposal 1 sketch at
  `proposals/proposal-1.md:36-68` shows the `with` block verbatim from
  current `tracker.ex:118-138` with the `rescue` appended at the
  function body level.
- **Warrant (W):** Elixir function-body `rescue` clauses sit at the
  same level as the function's primary expression, catching raises
  from anywhere in that expression. The `with`/`else` shape is a
  distinct concern (structural shape mismatches → silent `:ok`); the
  rescue catches raise-level failures from the same expression. The
  two compose without interference.
- **Qualifier (Q):** Holds for the exact sketch in Proposal 1; a
  future refactor could entangle them, but is out of scope.
- **Rebuttal (R):** None for the present diff.
- **Backing (B):** Elixir `try/rescue/else/after` semantics
  (https://hexdocs.pm/elixir/try.html); the existing twin
  `handle_coding_agent_cost/4` at `tracker.ex:144-172` is the proof of
  composition (same shape: `with`/`else` body + `rescue`).

#### Falsification attempt for claim 6

- **Strategy:** Type-level / shape check — compare the proposed sketch
  to the existing twin's shape.
- **Attempt:** The twin's body uses the identical pattern:
  `with [matchers] do [body] else _ -> :ok end` followed by a
  function-body-level `rescue e -> [emit telemetry]; :ok end`. The
  proposed sketch (proposal-1.md:36-68) is structurally identical.
  No interference between the `else` clause and the `rescue` clause is
  possible because they handle disjoint outcomes (pattern-match miss
  vs raise).
- **Outcome:** withstood.
- **Action:** None.

## Cross-claim consistency

The six claims compose without tension:

- Claims 1 (rescue) and 2 (`:rest_for_one`) target independent
  failure modes — a handler raise versus a sibling crash — and are
  combined in a single PR for cohesion, not because they depend on
  each other.
- Claim 2's stronger justification under the partially-falsified
  Claim 1: with the float-path failure mode absorbed by `nz/1`, the
  remaining motivation for the rescue is largely the
  table-missing-during-restart race, which is *more* likely under
  Claim 2's `:rest_for_one` cascade than under `:one_for_one`.
  Claims 1 and 2 are therefore mutually reinforcing in motivation,
  not merely co-located in a PR.
- Claims 3, 4, 5, 6 are scoping / containment assertions about Claims
  1 and 2; each holds independently and none contradicts another.

No tension to escalate.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Rescue in `handle_event/4` makes it D-035-compliant | Edge-case enumeration (5 paths) | partially_falsified | Narrow qualifier — cited float path is absorbed by `nz/1`; rescue is load-bearing for table-missing-on-restart race, not for float-in-`:usage` |
| 2 | `:rest_for_one` cascade decomplects attachment lifecycle from restart scope | Dependency check (3 required states) | withstood | none |
| 3 | Two-file diff is minimal satisfying both AC parts | Counter-example construction (3 alternatives) | withstood | none |
| 4 | `Tau.Application` unchanged; blast radius contained | Integration check | withstood | none |
| 5 | Existing `start_supervised` tests preserved | Dependency check | withstood (vacuously) | none — flagged as vacuous |
| 6 | `with`/`else` guard preserved; rescue is additive | Type-level / shape check | withstood | none |

## Revision required

None. The solution's recommended change is correct; only one
sub-claim's *narrative justification* is narrowed (not falsified
outright). The narrowed Qualifier on Claim 1 reads: "the rescue is
load-bearing for the table-missing-during-restart race and for
future-refactor raise paths; it is NOT load-bearing for the
float-via-`:usage` motivating example from the problem statement,
which is already absorbed by `nz/1` at `tracker.ex:176-177`." This
narrowing strengthens the case for combining Claims 1 and 2 in one PR
(the table-missing race becomes more frequent under `:rest_for_one`)
rather than weakening either claim.

- **Target file:** none
- **Revision kind:** n/a — the validation is recorded in this
  document; parent validator should fold the narrower Qualifier into
  its synthesis if it surfaces Claim 1 at the parent level.
- **Rationale:** A narrowed qualifier is information for downstream
  reasoning; the implementer's diff is unchanged.

## Outstanding doubts

- The problem statement's motivating example (a non-integer in `:usage`
  that "passes the `is_map` guard causes an `ArgumentError`") is
  factually inaccurate at the current code: `nz/1` absorbs non-integers
  silently. The implementer should be aware that the rescue's
  load-bearing path is table-missing-during-restart, not float-input —
  this affects test design (a float-input test would not exercise the
  rescue; a contrived `:ets.delete` between handler invocations would).
  The solution's "open question #2" (lines 113-117) already notes this;
  flagging here so the parent validator and reviewer carry it forward.
- Claim 5 is vacuously true at this commit (no test consumer of
  `start_supervised(Tau.Telemetry.Supervisor)` exists). The claim is
  durable under the change because the public API is unchanged; flagged
  only so the parent validator does not over-weight it as evidence of
  test-coverage robustness.
- Open question #3 in solution.md (a third child between `Handlers` and
  `Cost.Tracker`) is a future-refactor risk, not a present defect; the
  current child list at `lib/tau/telemetry/supervisor.ex:17-20` has
  exactly two children in the required order. The reviewer should flag
  any future child insertion as requiring re-examination of the
  `:rest_for_one` ordering.
