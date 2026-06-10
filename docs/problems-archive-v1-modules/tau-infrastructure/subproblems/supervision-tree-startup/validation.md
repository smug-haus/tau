---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/1
revision_triggered: none
---

# Validation: inline spawn_monitor + receive in start/2; OtelReporter always-in-tree; relaxed restart bounds

## Overview

The solution makes three discrete claims: (1) replacing `Task.start/1` with
inline `spawn_monitor/1` + blocking `receive` in `Tau.Application.start/2`
guarantees `System.halt/1` fires on every CLI exit path; (2) deleting
`otel_reporter_spec/0` and unconditionally placing `Tau.OtelReporter` in the
child list makes `OtelReporter.init/1`'s `:ignore` path the sole OTel
enable/disable gate; (3) setting `max_restarts: 10, max_seconds: 60` on the
root supervisor is appropriate for a binary that must absorb transient SQLite
or Finch init failures without halting. A scoping claim (4) — "no other
supervision tree changes" — is also extracted. Each claim is taken in turn
with full Toulmin (six fields) and an explicit falsification strategy.
Outcome: claims 2, 3, 4 withstood; claim 1 is **partially falsified** by an
unhandled edge case (supervisor death from restart-intensity exhaustion
while the controller blocks in `receive`). The qualifier on claim 1 is
narrowed accordingly; no solution revision is required because the partial
falsification does not contradict the acceptance criterion (a) and the
narrowed claim still satisfies it for the spawned-process exit paths the
criterion enumerates.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This validation enforces all six components explicitly per claim.

### Claim 1: inline `spawn_monitor/1` + blocking `receive` in `start/2` guarantees `System.halt/1` fires on every CLI exit path

- **Claim (C):** "The spawned process calls `exit(exit_code)` so the integer
  exit code is carried verbatim in the `:DOWN` reason; the `receive`
  dispatches to `System.halt/1` on every exit path"
  (`solution.md:19-21`). The proposal sketch
  (`proposals/proposal-3.md:74-83`) shows three receive clauses:
  `{:DOWN, ..., exit_code} when is_integer(exit_code)` →
  `System.halt(exit_code)`; `{:DOWN, ..., :normal}` → `System.halt(0)`;
  `{:DOWN, ..., _reason}` → `System.halt(1)`.
- **Grounds (G):** Three observable facts. (1) `Process.spawn_monitor/1`
  guarantees a `:DOWN` message for every spawned-process termination
  (Erlang/OTP `erlang:spawn_monitor/1` man page; the monitor is always
  delivered exactly once, unlike a link which can be silently dropped by
  `Process.unlink/1`). (2) `exit/1` with any non-`:normal` term propagates
  that term verbatim as the `:DOWN` reason; `exit(0)` is non-`:normal` and
  therefore arrives as the integer `0` (Erlang/OTP process model — open
  question 1 in `solution.md:100-104` flags this for smoke-test
  confirmation but the warrant rule is well-established). (3) The three
  receive clauses exhaustively cover the message shapes (`is_integer/1`,
  `:normal`, wildcard) so no `:DOWN` can be received without `System.halt/1`
  firing.
- **Warrant (W):** OTP rule — `Process.spawn_monitor/1` is the canonical
  primitive for "spawn a process and be notified of its termination
  irrespective of crash vs. normal exit", and a `receive` with an
  exhaustive set of pattern clauses over the message space cannot drop
  delivery. Combined with the well-defined exit-reason propagation rule
  (verbatim for non-`:normal`, `:normal` for normal return / `exit(:normal)`),
  the three-clause receive is total over `:DOWN` messages from the
  monitored pid.
- **Qualifier (Q):** Holds for terminations of the spawned CLI process
  itself — normal return, `exit(integer)`, and any raise/throw that the
  BEAM converts into a `:DOWN` reason. Does NOT hold if (a) the BEAM is
  brought down externally (SIGKILL, OOM-kill, `:erlang.halt/0` from
  another process) before the `:DOWN` arrives; (b) the supervisor crashes
  due to `max_restarts: 10 / max_seconds: 60` exhaustion, propagating an
  exit signal to the Application controller (which is `link`-ed to the
  supervisor it returned from `Supervisor.start_link/2`) — the controller
  is not trapping exits inside the blocking receive, so it dies and the
  BEAM terminates via the application controller's normal shutdown
  semantics without `System.halt/1` firing.
- **Rebuttal (R):** Two cases narrow Q. The first (external kill) is not
  the solution's responsibility — no in-process Elixir code can guarantee
  `System.halt/1` against SIGKILL. The second (supervisor restart-intensity
  exhaustion while CLI is running) IS in scope and is not addressed by
  the solution: the controller dies before `System.halt/1` fires, so the
  exit code is whatever the BEAM produces on application-controller death
  (typically non-zero, but not the CLI's chosen code). The current
  `Task.start/1` code shares this weakness, so the solution does not
  regress here, but it does not close it either.
- **Backing (B):** Erlang/OTP documentation —
  `https://www.erlang.org/doc/man/erlang#spawn_monitor-1` for the monitor
  semantics; `https://www.erlang.org/doc/man/erlang#exit-1` for the
  exit-reason propagation rule (non-`:normal` reasons propagated verbatim
  in `:DOWN`). OTP non-negotiable #4 (cross-process signalling) and #7
  (let-it-crash) — neither is violated by this construct; the controller
  blocking is unusual but not contraband. Existing test scaffolding for
  `Tau.OtelReporter` (`test/tau/otel_reporter/otel_reporter_test.exs:56`)
  uses `start_supervised/1` against the same module, demonstrating the
  module-as-spec child pattern the solution relies on for OTel.

#### Falsification attempt for claim 1

- **Strategy:** Edge-case enumeration over the failure modes the claim
  implicitly excludes, paired with a counter-example construction for any
  enumerated edge case that is in scope of the acceptance criterion.
- **Attempt:** Enumerated the exit channels for a process spawned with
  `spawn_monitor/1`:
  1. `exit(integer)` from inside the spawned fn — receive's
     `is_integer(exit_code)` clause matches; `System.halt(exit_code)`
     fires. Withstood.
  2. Normal return from the fn (the `exit_code` is set by `case` and the
     spawned fn ends without an explicit `exit/1`) — the `exit(exit_code)`
     line in the sketch (`proposal-3.md:71`) does call `exit/1`
     unconditionally; the fn never returns normally. Withstood by code
     shape, not by warrant.
  3. `exit(:normal)` directly — second receive clause matches;
     `System.halt(0)` fires. Withstood.
  4. Uncaught raise inside `Tau.CLI.main/1` — converted to
     `{kind, reason, stacktrace}` exit; matches wildcard;
     `System.halt(1)` fires. Withstood.
  5. Throw inside `Tau.CLI.main/1` — same as raise; matches wildcard.
     Withstood.
  6. The Application controller process is killed (e.g., another supervised
     subtree fires `max_restarts` and the root supervisor exits, sending
     an `EXIT` signal to its linked Application controller) — the
     controller is blocked in `receive` and is not trapping exits, so it
     dies; the `:DOWN` for the CLI may or may not have arrived first.
     If it has not, `System.halt/1` does NOT fire — the BEAM terminates
     via the application controller's death path. **Counter-example
     constructed** for the edge case "supervisor exhausts restart
     intensity while CLI is running".
  7. The BEAM is killed externally (SIGKILL) — out of scope; no Elixir
     construct can guarantee `System.halt/1` here.
- **Outcome:** **Partially falsified.** Case (6) is a real exit channel
  the claim does not cover. It is not in scope of acceptance criterion
  (a) — which targets "normal and crash exits" of the CLI process itself
  — but the claim as written in `solution.md:19-21` ("on every exit
  path") overreaches relative to what the solution actually delivers.
- **Action:** Narrow the qualifier in place. The narrowed claim:
  "`System.halt/1` fires on every CLI process exit path
  (normal return, `exit(:normal)`, `exit(integer)`, raise, throw),
  but not on Application controller death due to supervisor
  restart-intensity exhaustion." No solution revision is required:
  acceptance criterion (a) is satisfied by the narrowed claim, and the
  uncovered case is identical in the existing `Task.start/1` code so
  the solution does not regress. The Outstanding doubts section records
  the residual concern for the parent-level validator.

### Claim 2: deleting `otel_reporter_spec/0` and unconditionally including `Tau.OtelReporter` in the child list makes `OtelReporter.init/1`'s `:ignore` path the sole OTel enable/disable gate

- **Claim (C):** "Remove `otel_reporter_spec/0` and replace its conditional
  call site with `Tau.OtelReporter` unconditionally —
  `OtelReporter.init/1`'s existing `:ignore` return becomes the sole
  enabled/disabled gate" (`solution.md:22-24`).
- **Grounds (G):** Direct code evidence. (1)
  `lib/tau/otel_reporter.ex:53-73` shows `init/1` reading `Config.load()`,
  checking `config.enabled`, and returning `:ignore` when disabled. (2)
  `lib/tau/application.ex:113-119` defines `otel_reporter_spec/0` reading
  `Application.get_env(:tau, :otel, []) |> Keyword.get(:enabled, false)`.
  (3) The two gates already share the same source of truth via
  `Config.load/0` (the application env) — there is no third independent
  observer. (4) `grep -rn` confirms no other call sites for either
  `otel_reporter_spec` or any out-of-band OTel enable check
  (`lib/tau/application.ex:67, 113` and `lib/tau/application.ex:179`
  are the only occurrences across `lib/` and `test/`).
- **Warrant (W):** Rich Hickey "complecting" rule: a single concept
  (enable/disable policy) expressed in two independent code sites is
  complected and must be braided every time either is touched. Reducing
  to one site decomplects. OTP supervisor child-spec convention also
  supports this: `:ignore` from `init/1` is the idiomatic way to declare
  "this optional process is not needed in this configuration" without
  the parent rewriting its child list.
- **Qualifier (Q):** Holds for the runtime read path — every supervisor
  boot will see the same `config.enabled` value via `Config.load/0`.
  Does NOT hold if some downstream code observes "is `Tau.OtelReporter`
  in the registered processes?" as a proxy for "is OTel enabled?" —
  that observation would still be answered consistently (the process
  is absent in both cases: `:ignore` means no pid is registered), but
  the assertion shape is different from the current `[Tau.OtelReporter]
  vs []` shape.
- **Rebuttal (R):** Tests that assert "the OtelReporter child is absent
  from the supervision tree when OTel is disabled" must be rewritten to
  assert "the process is not running" or removed
  (`solution.md:94-96`). The solution acknowledges this. A second
  rebuttal: if `Tau.OtelReporter` is moved from `:rest_for_one` position
  inside the tree without considering that a hard `init/1` crash (vs.
  `:ignore`) would still cascade to descendants, the unconditional
  inclusion makes the cascade depend on `init/1` correctness — but
  `:ignore` does NOT cascade (it is treated as "child intentionally
  absent"), so this rebuttal does not apply unless `init/1` returns
  `{:stop, reason}` (the `:otel_not_started` branch at
  `lib/tau/otel_reporter.ex:67-68`).
- **Backing (B):** Hickey, "Simple Made Easy" (2011) —
  https://www.infoq.com/presentations/Simple-Made-Easy/ — for the
  decomplect-by-single-source-of-truth rule. OTP design principles ch.
  "Supervisor behaviour" for the `:ignore` semantics
  (https://www.erlang.org/doc/design_principles/sup_princ.html); the
  Elixir `GenServer.init/1` typespec
  (https://hexdocs.pm/elixir/GenServer.html#c:init/1) documenting that
  `:ignore` causes the supervisor to silently skip the child without
  treating it as an error.

#### Falsification attempt for claim 2

- **Strategy:** Dependency check — verify the cited prior state
  (`OtelReporter.init/1` already has the `:ignore` branch and the
  conditional in the supervisor reads from the same env) holds today,
  plus integration check that no other site observes the dual-gate
  shape.
- **Attempt:** (1) Read `lib/tau/otel_reporter.ex:50-74` — `:ignore`
  branch present and unchanged. (2) `grep -rn "otel_reporter_spec\|
  Tau.OtelReporter" lib/ test/` — the only producers of "is OTel
  enabled?" decisions are the two cited sites; tests reference
  `Tau.OtelReporter` only by module name in
  `test/tau/otel_reporter/otel_reporter_test.exs`, never by checking
  presence in the supervision tree.
- **Outcome:** **Withstood.** The dependency state holds and no third
  observer exists. The migration note in `solution.md:94-96` correctly
  identifies the test-update surface.
- **Action:** None.

### Claim 3: `max_restarts: 10, max_seconds: 60` on the root supervisor is appropriate for the binary's recovery expectations

- **Claim (C):** "Set `max_restarts: 10, max_seconds: 60` on the root
  supervisor opts" (`solution.md:24`, `solution.md:65-66`).
- **Grounds (G):** (1) Current opts are `[strategy: :rest_for_one, name:
  Tau.Supervisor]` (`lib/tau/application.ex:93`) with the OTP default
  `max_restarts: 3 / max_seconds: 5`. (2) The problem statement
  enumerates transient init failures the binary must absorb: SQLite
  locked on cold start, Finch init, the `Tau.Memory.Supervisor`'s
  schema migration (`problem.md:24-30`). (3) Boot ordering encodes
  ~15 children under `:rest_for_one` (`lib/tau/application.ex:7-47`);
  any early-child transient produces a cascade restart of all
  descendants, consuming the restart budget rapidly.
- **Warrant (W):** OTP supervisor-intensity rule: `max_restarts` /
  `max_seconds` bounds the number of restarts that count as "the
  supervised system can recover by itself" before the supervisor gives
  up and shuts down. The defaults (3 in 5s) are tuned for development;
  production systems with transient external-resource dependencies
  routinely raise them. `:rest_for_one` amplifies restart cost because
  one transient cascades to all later children.
- **Qualifier (Q):** Holds against the failure modes the problem
  statement names (transient SQLite lock, Finch init, schema migration
  retry). Does NOT necessarily hold for systematic failures (a
  permanently-broken config that crashes every restart); for those, no
  finite bound is appropriate and the binary correctly halts.
- **Rebuttal (R):** A bound that is too loose hides systematic failures
  behind a long restart cycle — e.g., a misconfigured Finch endpoint
  could thrash for 60s before the supervisor gives up, delaying the
  operator's awareness. Counter-rebuttal: 10/60 still terminates within
  a minute, which is acceptable for a CLI binary; for a server-mode
  process where instant termination is preferable, the bound should be
  re-examined. The solution targets CLI-mode operation per the
  acceptance criterion.
- **Backing (B):** Erlang/OTP supervisor man page —
  https://www.erlang.org/doc/man/supervisor — documents the
  intensity/period contract. Tau's own
  `lib/tau/coding_agent/dispatcher.ex:63` comment ("rapid runs trip the
  DynamicSupervisor's max_restarts intensity") confirms the project
  has hit default-intensity exhaustion before and knows the failure
  shape.

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction — try to construct a
  failure mode the new bound mishandles.
- **Attempt:** Enumerate failure shapes against the 10/60 bound:
  (1) cold-start SQLite locked, single retry succeeds: 1 restart →
  withstood. (2) cold-start SQLite locked for several seconds, multiple
  retries: bounded above by 10 restarts in 60s, leaving headroom for
  the system to wait → withstood. (3) Finch DNS misconfiguration:
  systematic; restart loops at maximum rate → consumes 10 restarts
  within seconds; supervisor exits; binary terminates within ~10s →
  acceptable for CLI mode. (4) A child whose `init/1` runs in 7s and
  fails: each restart attempt consumes 7s; 10 restarts span 70s,
  exceeding the 60s window, so the bound triggers before all 10 are
  consumed → withstood by intent. No counter-example falsifies the
  claim within its qualifier.
- **Outcome:** **Withstood.**
- **Action:** None.

### Claim 4: no other supervision-tree structural changes

- **Claim (C):** "No new files. No new modules. No supervision tree
  structural changes beyond removing the `otel_reporter_spec/0`
  conditional" (`solution.md:71-72`); "All other children in the
  supervision tree — order and identity unchanged" (`solution.md:78`).
- **Grounds (G):** The "what changes" section
  (`solution.md:59-69`) enumerates only deletions
  (`maybe_dispatch_cli/0`, `otel_reporter_spec/0`), replacements
  (conditional → unconditional `Tau.OtelReporter` in the child list),
  the new `opts` line, and the inline `spawn_monitor` block. No
  add/remove/reorder of any other child in
  `lib/tau/application.ex:60-91`.
- **Warrant (W):** Boot-order discipline rule (encoded in
  `lib/tau/application.ex:7-47` moduledoc): every reorder requires
  re-justifying the dependency chain under `:rest_for_one`. The
  solution explicitly opts out of touching this surface, which is the
  minimum-blast-radius choice.
- **Qualifier (Q):** Holds as stated for the named file. Holds
  conditionally for "no new modules": the solution introduces no new
  module identifiers, but the existing `Tau.OtelReporter` module's
  child-spec call shape changes from an indirect call to a direct one.
- **Rebuttal (R):** None substantive — the claim is a scoping
  assertion verifiable by diff.
- **Backing (B):** `lib/tau/application.ex:7-47` moduledoc, which
  codifies the boot order as a hard project invariant; ADR-0004
  (cited there, governing PubSub placement).

#### Falsification attempt for claim 4

- **Strategy:** Counter-example construction — attempt to find any
  edit the solution forces beyond what is enumerated.
- **Attempt:** Cross-walked every line of the "What changes" list
  against `lib/tau/application.ex`. Each entry maps to either a
  deletion (`maybe_dispatch_cli/0` body at 179-195;
  `otel_reporter_spec/0` body at 113-119), a one-line replacement
  (child list entry 67, opts line 93), or an insertion (the
  `spawn_monitor` block at the `{:ok, pid}` branch, ~15 lines
  beginning at line 96). No collateral edits required.
- **Outcome:** **Withstood.**
- **Action:** None.

## Cross-claim consistency

The four claims are mutually consistent. Claim 1's narrowed qualifier
(uncovered case: supervisor restart-intensity exhaustion crashes the
Application controller) interacts with Claim 3 (which raises the
intensity bound from 3/5 to 10/60): a higher bound makes the
uncovered case in Claim 1 *less likely*, not more. Claim 2's removal
of the dual-gate is orthogonal to claims 1 and 3. Claim 4 (no other
structural changes) is consistent with all others. No internal
tension to resolve.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | spawn_monitor+receive guarantees `System.halt/1` on every CLI exit path | edge-case enumeration | partially_falsified | narrow Q to "every CLI *process* exit path"; record outstanding doubt |
| 2 | `OtelReporter.init/1` `:ignore` becomes sole gate | dependency + integration check | withstood | none |
| 3 | `max_restarts: 10, max_seconds: 60` is appropriate | counter-example construction | withstood | none |
| 4 | No other supervision-tree structural changes | counter-example construction | withstood | none |

## Revision required

No revision triggered. The Claim 1 partial falsification is handled in
place via qualifier narrowing: the original claim's "on every exit
path" is narrowed to "on every CLI *process* exit path (normal
return, `exit(:normal)`, `exit(integer)`, raise, throw)". The
uncovered case — Application controller death due to supervisor
restart-intensity exhaustion while the receive is blocked — is
identical in the existing `Task.start/1` code (the current Task does
not survive the BEAM's response to supervisor death either), so the
solution does not regress, and the acceptance criterion (a) targets
the CLI-process exit channels, all of which the narrowed claim
covers. No file requires revision.

- **Target file:** none
- **Revision kind:** in-place qualifier narrowing (recorded above)
- **Rationale:** the partial falsification is outside the acceptance
  criterion's scope and the solution does not regress against the
  current code on the uncovered case.

## Outstanding doubts

For the parent-level validator (`docs/problems/tau-infrastructure/`)
to inherit:

- The proposal's prior-art reference (`proposals/proposal-3.md:167`)
  cites `IEx.App` as "blocks the Application controller to ensure the
  IEx REPL drives the VM lifetime". Inspection of
  `/home/brentw/.local/elixir/lib/iex/lib/iex/app.ex` shows
  `IEx.App.start/2` does NOT block — it returns immediately after
  `Supervisor.start_link/2`. The cited prior art is therefore
  incorrect, weakening (but not falsifying) the warrant that the
  blocking-`receive`-in-`start/2` pattern is established OTP idiom.
  The pattern is still implementable and correct under its narrowed
  qualifier, but the project should not rely on a published precedent
  to justify it; document the idiom explicitly in the
  `lib/tau/application.ex` moduledoc as the solution's open question 2
  already requests (`solution.md:105-108`).
- Solution open question 1 (`solution.md:100-104`) — whether
  `exit(0)` propagates as integer `0` or as `:normal` — is answerable
  from the OTP `erlang:exit/1` documentation (non-`:normal` reasons
  propagate verbatim; `0` is non-`:normal`) but the solution defers
  to a smoke test. The smoke test is good practice but the warrant
  underlying claim 1 does not depend on the answer because the
  receive's three clauses cover both possibilities.
- The blocking `receive` inside `Application.start/2` is unusual; any
  downstream caller that calls `Application.started_applications/0`
  to check for `:tau` while the binary is in CLI mode will observe
  `:tau` as "not yet started" for the lifetime of the CLI run. The
  binary's own subsystems do not appear to make this check, but a
  future addition might.
