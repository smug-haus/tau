---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-3.md]
selection_method: single
revision: 0
---

# Solution: inline spawn_monitor + receive in start/2; OtelReporter always-in-tree; relaxed restart bounds

## Recommendation

Replace `maybe_dispatch_cli/0` and its `Task.start/1` call with an inline
`spawn_monitor/1` + `receive` block inside `Tau.Application.start/2`, placed
immediately after the `{:ok, pid}` match on `Supervisor.start_link/2`. The
spawned process calls `exit(exit_code)` so the integer exit code is carried
verbatim in the `:DOWN` reason; the `receive` dispatches to `System.halt/1` on
every exit path. Remove `otel_reporter_spec/0` and replace its conditional call
site with `Tau.OtelReporter` unconditionally — `OtelReporter.init/1`'s existing
`:ignore` return becomes the sole enabled/disabled gate. Set `max_restarts: 10,
max_seconds: 60` on the root supervisor opts.

## Selected from

- **Chosen:** `proposals/proposal-3.md`
- **Why chosen:** All four proposals satisfy the three acceptance criteria; the
  differentiators are dependency surface, OTP-rule compliance, and migration
  cost. Proposal 3 uses `spawn_monitor/1`, whose monitor handle is a private
  `ref` scoped entirely to `start/2` — no dependency on a named supervisor
  being started in a specific position (the silent ordering risk in Proposal 1).
  Proposal 2 wraps a one-shot task in a `GenServer` carrying only `%{cli_pid:
  pid}` — stateless logic in a GenServer, which violates OTP non-negotiable #3
  and is disqualified on that ground alone. Proposal 4 introduces a second
  supervision tree / OTP application for a problem the problem statement
  classifies as a major/minor defect pair; its confidence is low-medium and
  migration cost is high. Proposal 3 and Proposal 1 are close; Proposal 3 wins
  because removing the `Tau.Tools.TaskSupervisor` dependency reduces the number
  of invariants the implementation must maintain and makes `start/2` fully
  self-contained.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Yes | Substantial | Low | Low | Easy |
| 2 | Yes | Substantial | Medium | Medium | Medium |
| 3 | Yes | Substantial | Low | Low | Easy |
| 4 | Yes | Deep | High | Medium | Hard |

Proposal 2 is disqualified by OTP non-negotiable #3 regardless of its score.
Proposal 4 is deprioritised by cost+risk disproportionate to defect severity.
Between 1 and 3: equivalent fit, cost, reversibility; Proposal 3 wins on the
named-supervisor dependency axis.

## What changes

- `lib/tau/application.ex`:
  - Delete `defp maybe_dispatch_cli/0`.
  - Delete `defp otel_reporter_spec/0`.
  - Remove the `maybe_dispatch_cli()` call site in `start/2`.
  - Replace `otel_reporter_spec()` in the child list with `Tau.OtelReporter`
    (unconditional).
  - Set `opts = [strategy: :rest_for_one, name: Tau.Supervisor, max_restarts:
    10, max_seconds: 60]`.
  - Add inline `spawn_monitor/1` + `receive` block to the `{:ok, pid}` branch
    of `start/2`, gated on `cli_argv()`, with a comment explaining the blocking
    idiom and `exit(exit_code)` convention.

No new files. No new modules. No supervision tree structural changes beyond
removing the `otel_reporter_spec/0` conditional.

## What does not change

- `Tau.OtelReporter` module and its `init/1` `:ignore` logic — unchanged; it
  becomes the sole gate.
- `Tau.Application.cli_argv/0` — unchanged; called in the same place.
- All other children in the supervision tree — order and identity unchanged.
- `lib/tau/cli.ex` internals — explicitly out of scope.
- `lib/tau/factory/gate.ex` — explicitly out of scope.
- All other sub-problems' scopes (global-name-collision, telemetry-handler-
  coupling, circuit-breaker-invariant-split) — not touched.

## Migration sketch

Single-file change in `lib/tau/application.ex`. Sequence: (1) delete
`otel_reporter_spec/0` and update the child list; (2) set the new `opts`; (3)
delete `maybe_dispatch_cli/0` and its call site; (4) insert the `spawn_monitor`
block with inline comment into `start/2`. The existing binary smoke test
(`mix test --only smoke`) validates normal-exit and crash-exit paths against
the patched binary.

Tests that assert `Tau.OtelReporter` is absent from the supervision tree when
OTel is disabled must be updated to assert it is present-but-ignored (or
removed if they were testing the now-deleted `otel_reporter_spec/0` function).

## Open questions

1. Does `exit(0)` (integer 0) arrive as `{:DOWN, ref, :process, pid, 0}` or as
   `{:DOWN, ref, :process, pid, :normal}`? OTP propagates non-`:normal` exit
   reasons verbatim, but `exit(0)` with integer `0` is technically non-`:normal`
   — should be confirmed by a smoke test before landing, since the receive guard
   `when is_integer(exit_code)` relies on it.
2. The blocking `receive` in `start/2` means the Application controller process
   blocks until the CLI finishes. In non-CLI (server) mode this is a non-issue;
   in CLI mode the Burrito binary is designed to block exactly here. Confirm this
   expectation is documented in `lib/tau/application.ex`'s moduledoc or a comment.
3. Are there existing unit tests for `maybe_dispatch_cli/0` that will break and
   need explicit deletion rather than update?

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Task.Supervisor child + OTel passthrough + relaxed bounds (loses on named-supervisor dependency)
- `proposals/proposal-2.md` — Tau.CLIRunner supervised GenServer with trap_exit (disqualified: OTP non-negotiable #3)
- `proposals/proposal-3.md` — **selected** — inline spawn_monitor + receive in start/2
- `proposals/proposal-4.md` — dedicated tau_cli OTP application (disproportionate cost for defect severity)

## Revision history

- (revision 0 — initial)
