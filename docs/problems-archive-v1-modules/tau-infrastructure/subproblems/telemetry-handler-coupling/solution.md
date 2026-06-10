---
template_version: 1
template_name: solution
parent_problem: ../../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md]
selection_method: single
revision: 0
---

# Solution: Symmetric rescue in handle_event/4 + :rest_for_one supervisor strategy

## Recommendation

Add a `rescue` block to `Tau.Cost.Tracker.handle_event/4` that is structurally
symmetric with the existing guard in `handle_coding_agent_cost/4`, emitting
`[:tau, :cost, :tracker, :handler_failed]` on error and returning `:ok`. Change
`Tau.Telemetry.Supervisor.init/1` from `strategy: :one_for_one` to
`strategy: :rest_for_one`, with `Tau.Telemetry.Handlers` listed before
`Tau.Cost.Tracker` in the child list so a `Handlers` crash cascades to
`Cost.Tracker`, forcing a clean re-`init/1` that detaches then re-attaches
handlers. This is the minimal change that satisfies both acceptance criterion
parts (a) and (b) with no new modules, no API surface change, and no blast-radius
expansion.

## Selected from

- **Chosen:** `proposals/proposal-1.md`
- **Why chosen:** Proposal 1 directly satisfies both halves of the acceptance
  criterion with the smallest diff, the lowest migration cost, and the lowest risk.
  The rescue pattern it introduces is not novel — it is literal symmetry with the
  already-merged `handle_coding_agent_cost/4` pattern, which itself documents the
  D-035 requirement. The `:rest_for_one` change encodes the attachment-lifecycle
  dependency in the idiomatic OTP location (supervisor child ordering) rather than
  in ad-hoc process-monitoring code, and it is contained to the intermediate
  supervisor — no blast-radius expansion to `Tau.Application`'s 17-child tree.

  Proposal 2 adds a `HandlerGuard` module that would be the correct choice if a
  third cost-telemetry handler were imminent, but with exactly two handlers today
  the abstraction pays no structural benefit and adds review surface for a
  ~5-line pattern. The DRY argument is weak at n=2.

  Proposal 3 (self-managed monitor) trades the clean OTP idiom for a retry loop
  with timing-dependent test behaviour, a TOCTOU startup race, and implicit
  startup-order coupling that `:rest_for_one` already solves explicitly. The
  proposer rated it low confidence; the comparison confirms that.

  Proposal 4 (delete intermediate supervisor) introduces a blast-radius risk that
  depends on what follows the telemetry children in `Tau.Application`'s list — a
  dependency it cannot resolve without inspecting `application.ex`. It also breaks
  any test using `start_supervised(Tau.Telemetry.Supervisor)`. The proposer
  rated it low confidence pending that audit; the risk is asymmetric and the
  benefit (removing one supervisor level) is cosmetic given that the intermediate
  supervisor's strategy patch in Proposal 1 is two lines.

## Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Yes | Substantial | Low | Low | Easy |
| 2 | Yes | Substantial | Medium | Low | Easy |
| 3 | Partially | Substantial | Medium | Medium | Medium |
| 4 | Yes | Deep | Medium | Medium | Hard |

Proposal 3 scores Partially on fit because the monitor-in-`init/1` idiom
creates an implicit startup-order dependency, leaving a residual complect between
attachment lifecycle and child start sequence (now implicit in `Process.whereis`
timing rather than supervisor ordering). Proposal 4 scores Hard on reversibility
because deleting a module and updating test scaffolding is meaningfully harder to
undo than changing a two-word strategy atom.

## What changes

- `lib/tau/cost/tracker.ex` — add `rescue` block to `handle_event/4` mirroring
  the existing rescue in `handle_coding_agent_cost/4`; emit
  `[:tau, :cost, :tracker, :handler_failed]` with `%{system_time:
  System.system_time()}` measurements and `%{reason: Exception.message(e)}`
  metadata; return `:ok`.
- `lib/tau/telemetry/supervisor.ex` — change `strategy:` from `:one_for_one` to
  `:rest_for_one`; confirm `Tau.Telemetry.Handlers` is listed before
  `Tau.Cost.Tracker` in the child list (current ordering must be verified before
  implementation).

## What does not change

- `Tau.Cost.Tracker.handle_coding_agent_cost/4` — already D-035-compliant; no
  touch.
- `Tau.Telemetry.Handlers` — module unchanged; no new module added.
- `Tau.Application` — supervision tree unchanged; blast radius is contained to
  the intermediate supervisor's two children.
- Any existing tests using `start_supervised(Tau.Telemetry.Supervisor)` —
  module name and child-spec API are preserved.
- The `with`/`else` structural guard in `handle_event/4` — the rescue wraps the
  existing `with` block; the guard itself is not changed.

## Migration sketch

Open a single PR against the `lib/tau/cost/tracker.ex` and
`lib/tau/telemetry/supervisor.ex` files. Verify the child ordering in
`supervisor.ex` before committing (confirm `Handlers` precedes `Cost.Tracker`).
Add one test: inject a float into `:usage` to reach the `:ets.update_counter`
raise path; assert `handle_event/4` returns `:ok` and the
`[:tau, :cost, :tracker, :handler_failed]` event is emitted. Use the
`handle_coding_agent_cost/4` test as the pattern. No migration steps, no
dependency changes, no binary schema changes.

## Open questions

- Is `Tau.Cost.Tracker.terminate/2` confirmed to call `:telemetry.detach/1`
  for both handler IDs? Proposal 1 asserts yes (lines 112-114); this must be
  verified before the `:rest_for_one` change lands — if `terminate/2` does not
  detach, the cascade restart will produce duplicate handler registration rather
  than curing it.
- Does `nz/1` return `0` for a float input, or does it allow a float through to
  the `:ets.update_counter/3` call? If `nz/1` coerces floats to integers, the
  rescue is a no-op defensive belt-and-suspenders; if it passes floats through,
  the rescue is load-bearing. Clarifying this determines whether the rescue is
  strictly necessary or conservative.
- Are there any children of `Tau.Telemetry.Supervisor` beyond `Handlers` and
  `Cost.Tracker`? If a third child is ever added between them, the `:rest_for_one`
  cascade would restart it unnecessarily on a `Handlers` crash.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Symmetric rescue + `:rest_for_one` (chosen: minimal, symmetric, idiomatic)
- `proposals/proposal-2.md` — Extract `Tau.Cost.HandlerGuard` shared wrapper (not chosen: over-engineering at n=2 handlers)
- `proposals/proposal-3.md` — Self-managed monitor in `Cost.Tracker`, no supervisor change (not chosen: retry complexity, timing races, low proposer confidence)
- `proposals/proposal-4.md` — Delete intermediate supervisor, merge into `Tau.Application` (not chosen: unresolved blast-radius risk, hard reversibility, module deletion)

## Revision history

- (revision 0 — initial)
