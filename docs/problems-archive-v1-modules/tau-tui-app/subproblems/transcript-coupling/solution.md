---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-4.md]
selection_method: single
revision: 0
---

# Solution: Split `on_message_end/2` into two named private handlers via dispatcher

## Recommendation

Replace `on_message_end/2` with a thin dispatcher that calls two independent
private functions — `on_message_end_transcript/2` and
`on_message_end_counters/2` — each owning a disjoint field set on the model.
The dispatcher makes call-order explicit; neither sub-handler reads from the
other's output. The existing `cost_for_session/1` private helper (the sole
`try/rescue` site) remains unchanged and is called only from
`on_message_end_counters/2`. All three acceptance criterion clauses are met at
the function-boundary level rather than by naming convention, with no new
modules, no public API changes, and no SPEC amendments required.

## Selected from

- **Chosen:** `proposals/proposal-4.md`
- **Why chosen:** Proposal 4 satisfies criteria (a), (b), and (c) and provides
  the strongest structural enforcement of independence among the single-file
  options without the costs of the module-boundary proposals. Compared to
  Proposal 1, which achieves the same three criteria via naming convention only,
  Proposal 4 enforces the transcript/counters separation at the function
  signature level: `on_message_end_transcript/2` receives no `session_id` and
  has no path to ETS; `on_message_end_counters/2` receives no content blocks and
  has no path to Markdown. The enforcement is structural, not conventional.
  Proposal 2 matches on decomplecting depth but introduces a side-effecting
  addition to `StatusBar` and silently regresses the `session_id` field in
  telemetry metadata — both are avoidable costs. Proposal 3 adds type
  enforcement via an intermediate struct but the `__MODULE__.MessageEndResult`
  nested module pattern is uncommon, `with_warn_level/3` still threads the full
  model (partially re-coupling), and the struct exists solely to service one
  private function — over-engineered relative to the problem. Proposal 4 is
  the reversible, low-cost, structurally-enforced option that dominates on all
  relevant axes.

## What changes

- `lib/tau/tui/app/events.ex` — `on_message_end/2` (~77 LOC) is replaced by:
  - A thin `on_message_end/2` dispatcher (~4 LOC) that pipes through the two
    sub-handlers in sequence.
  - `on_message_end_transcript/2` (~20 LOC): reads `model.subagents` and
    `msg.content`; writes `model.transcript` and `model.last_assistant`; no
    ETS, no telemetry dependency.
  - `on_message_end_counters/2` (~20 LOC): reads `model.session_id`,
    `model.context_window`, `model.warn_level`, and `message.usage`; writes
    `model.usage`, `model.context_tokens`, `model.warn_level`, `model.status`;
    calls `cost_for_session/1` (the sole `try/rescue` site); emits telemetry
    conditionally.
  - `@spec` annotations on both sub-handlers document field ownership; the
    existing `cost_for_session/1` private helper is unchanged.

## What does not change

- `Tau.TUI.Render.Markdown` — no changes.
- `Tau.TUI.SubagentTree` — no changes.
- `Tau.Cost.for_session/1` and the `cost_for_session/1` private helper in
  `Events` — unchanged; the `try/rescue` stays where it is.
- `Tau.TUI.StatusBar` — no new functions; `context_pct/2` and `warn_level/1`
  are called as before.
- The telemetry event schema `[:tau, :tui, :status, :update]` and its metadata
  (including `session_id`) — D-168/D-169 invariants unchanged.
- All public APIs of `Tau.TUI.App.Events` — no public function signatures move.
- SPEC-TUI-HEADLESS Appendix B source map — no new files to register.
- Sibling sub-problems: `duplicated-bounded-append`, `model-as-bag-of-maps`,
  `session-side-effects-in-pure-modules` — unaffected.

## Migration sketch

The refactor is purely mechanical and stays within `lib/tau/tui/app/events.ex`.
First, introduce the two named sub-handlers as private functions that reproduce
the current logic; then replace the body of `on_message_end/2` with the
dispatcher pipe. Run `mix compile --warnings-as-errors` to confirm no
cross-reads were introduced. Add two unit tests: one driving
`on_message_end_transcript/2` with a plain list of content blocks and a stub
`SubagentTree` (no ETS); one driving `on_message_end_counters/2` with a mock
session counter and a `:telemetry.attach` handler (no Markdown content). The
existing integration tests require no changes as all public behaviour is
preserved.

## Open questions

- Does `on_message_end_counters/2` reading model fields set by
  `on_message_end_transcript/2` remain impossible across future changes?
  The current implementation confirms it does not, but the independence is
  a fragile invariant — a future author adding a field read could re-couple
  silently. A review checklist note is the only guard; this is not enforced
  by the type system.
- Is the dispatcher ordering (`transcript` before `counters`) load-bearing?
  Currently no, since neither reads the other's output. If that ever changes,
  the ordering becomes a hidden coupling.
- `on_message_end_counters/2` still combines ETS read, warn computation, and
  telemetry emit in one function. The acceptance criterion does not require
  separating these, but if a future problem statement targets them, a further
  split (possibly matching Proposal 2's `StatusBar.maybe_emit/3` approach)
  would be the natural next step — at which point the `session_id` metadata
  question in Proposal 2's weakness must be resolved.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Extract three named private functions inside
  `Events`; satisfies criterion but at convention level only; dominated by P4.
- `proposals/proposal-2.md` — New `Transcript` module + `StatusBar.maybe_emit/3`;
  stronger module-level enforcement but adds side effect to `StatusBar` and
  regresses `session_id` in telemetry metadata.
- `proposals/proposal-3.md` — `MessageEndResult` intermediate struct;
  type-level enforcement but over-engineered for a single private function,
  and `with_warn_level/3` still partially threads `model`.
- `proposals/proposal-4.md` — Two named private handlers via dispatcher;
  **selected**; structural independence at function-signature level, no new
  modules, no API changes, all three criteria met.

## Revision history

- (revision 0 — initial)
