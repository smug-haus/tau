---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: `on_message_end/2` in Events couples Markdown rendering, subagent lookup, StatusBar telemetry, and cost ETS access in one handler

## Statement

`Tau.TUI.App.Events.on_message_end/2` (~77 LOC) accumulates four distinct
concerns in a single private function: it invokes `Tau.TUI.Render.Markdown` to
convert assistant text to styled lines, calls `SubagentTree.tool_call_owned?/2`
to filter subagent-owned tool-call blocks, reads `Tau.Cost.for_session/1` from
an ETS table (inside a `try/rescue`), and computes a `StatusBar.warn_level`
transition and fires a telemetry event if the level changed. Each of these
concerns has its own failure mode and testability requirement; their co-location
means a test of warn-level telemetry must also supply a valid message with
markdown content and a live cost ETS table.

## Context

- `lib/tau/tui/app/events.ex:182–258` — `on_message_end/2` full body
- `lib/tau/tui/app/events.ex:183–219` — Markdown rendering block (calls `Tau.TUI.Render.Markdown.render/1`; D-028)
- `lib/tau/tui/app/events.ex:206–213` — subagent-owned tool-call filter (`SubagentTree.tool_call_owned?/2`; D-151)
- `lib/tau/tui/app/events.ex:224–227` — ETS cost read via `cost_for_session/1` with `try/rescue ArgumentError`
- `lib/tau/tui/app/events.ex:232–249` — warn-level computation and conditional telemetry emit (D-168, D-169)
- `lib/tau/tui/app/events.ex:262–269` — `cost_for_session/1` private helper wrapping `Tau.Cost.for_session/1`
- SPEC-TUI-HEADLESS §5d (D-168, D-169) owns the context-token and warn-level contract
- The `try/rescue` in `cost_for_session/1` is the only `try/rescue` site in the sub-module set

## Complecting hypothesis

1. Transcript-line construction (Markdown rendering + subagent filtering) is
   complected with session-counter aggregation (cost ETS read) in `on_message_end/2`
   because both are triggered by `%MessageEnd{}` arrival; the data they consume
   and produce are independent, but they are fused into one function body.

2. Warn-level telemetry emission is complected with model mutation in
   `on_message_end/2` because the telemetry-fire condition (`new_warn != prior_warn`)
   requires reading the prior model state — the telemetry decision is embedded
   inside the state-building pipeline rather than being a separate step.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`on_message_end/2` (or its replacement) is decomposed such that: (a) the
transcript-line construction pipeline is independently testable without a cost
ETS table, (b) the warn-level computation and telemetry emission are independently
testable without a Markdown content block, and (c) the `try/rescue` site for
ETS unavailability is isolated in a single helper rather than embedded in a
multi-concern function body.

## Out of scope

- Changing the telemetry event schema or the D-168/D-169 invariants.
- Changing `Tau.TUI.Render.Markdown` or `SubagentTree` internals.
- Changes to `duplicated-bounded-append` (sibling sub-problem).
- Changes to `model-as-bag-of-maps` (sibling).
- Changes to `session-side-effects-in-pure-modules` (sibling).

## Amendment log

- (none yet)
