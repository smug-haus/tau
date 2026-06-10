---
template_version: 1
template_name: problem
node_kind: root
depth: 0
parent: —
status: decomposed
---

# Problem: session.ex retains inline FSM logic that belongs in sub-modules

## Statement

`lib/tau/session.ex` is a 1,438-LOC `:gen_statem` façade whose partial
decomposition extracted 10 sub-modules but left four clusters of logic inline:
(1) two `:cancel` clause bodies totalling ~240 LOC of cross-cluster teardown,
(2) `@doc false` helpers (`process_user_message`, `append_message`,
`broadcast`, `emit_user_message_telemetry`, `hook_payload`,
`transcript_path`, `current_run?`) that are used across multiple sub-modules
but live in the FSM itself, (3) three `handle_event` clauses for
`{:user_message, _, _}` routing that mix queue arithmetic with
slash-command dispatch, and (4) the FSM data struct remaining as an
anonymous map with ~45 fields rather than a `defstruct`. A developer
tracing any single concern must read the session façade alongside the
relevant sub-module, because the boundary between "FSM wiring" and
"concern logic" is inconsistent.

## Context

- `lib/tau/session.ex`: 1,438 LOC, 41 `handle_event/4` clauses, 81 function
  heads (including `@doc false` cross-module helpers).
- Sub-modules already extracted: `Journal`, `Queue`, `Compaction`,
  `ModelSwap`, `SkillActivation`, `SlashCommand`, `ProviderTurn`,
  `CodingAgentTurn`, `ToolDispatch`, `Data` — each cleanly delegates from a
  one-liner clause in `session.ex`.
- Cancel clauses: `handle_event(:cast, :cancel, :awaiting_permission, data)`
  (lines 842–961, ~120 LOC) and `handle_event(:cast, :cancel, _state, data)`
  (lines 963–1083, ~121 LOC) contain full teardown sequences — emitting
  `%ToolEnd{}` events, draining queues, demonitoring processes, resetting
  dozens of data fields — all inline.
- `@doc false` helpers used by sub-modules (e.g. `Tau.Session.broadcast/2`,
  `Tau.Session.append_message/2`, `Tau.Session.hook_payload/3`) are public
  functions on the FSM module instead of living in a shared internal module.
- `Tau.Session.Data` exists as a sub-module but the FSM data struct is still
  an anonymous map; `Data.new/1` returns `{:ok, map()}`.
- Prior audit: `.code_audit/archive/v1-flat/02-provider-session.md`
  identifies the `dispatch_tools/2` monolith (308 LOC, already extracted to
  `ToolDispatch`) and flags anonymous-map struct as a Dialyzer hole.
- `docs/refactor/inventory-session.md` documents the extraction plan that
  produced the current sub-modules; the cancel clusters were explicitly
  deferred.

## Complecting hypothesis

The `:cancel` teardown logic is complected with the FSM event-handler
dispatch because both the `awaiting_permission`-specific cancel and the
cross-cutting cancel inline their side effects (process kills, PubSub
broadcasts, data field resets) rather than delegating them to the sub-modules
that own each cluster.

The shared `@doc false` helpers (`broadcast`, `append_message`, `hook_payload`,
`current_run?`) are complected with the FSM module because they were
extracted from the large session.ex but not moved to a dedicated shared
internal module — making `Tau.Session` both the `:gen_statem` entry point and
the utility namespace for its own sub-modules.

The user-message routing clauses are complected with slash-command dispatch
because the `{:user_message, msg, _tier} in :awaiting_user` clause both
performs queue-gate logic (postpone, tier routing) and calls
`SlashCommand.classify_slash_command/4` inline rather than delegating the
full routing decision to `Tau.Session.Queue`.

## Decomposition strategy

The axis is **concern ownership**: each inline body belongs to an identifiable
concern (teardown, shared utilities, message routing, data shape). The four
sub-problems are mutually exclusive because each maps to a distinct cluster
of lines in `session.ex` with no overlap, and collectively exhaustive because
together they account for every remaining inline body that the partial
decomposition left behind. The concern-ownership axis yields MECE because the
sub-modules already define the concern boundaries — the residual complecting is
precisely where logic was not moved despite a clear owner existing.

## Sub-problems (filled by decomposer)

1. **cancellation-teardown** — both `:cancel` clause bodies (`:awaiting_permission`-specific and cross-cutting) contain inline multi-cluster teardown that should delegate to the sub-modules owning each cluster.
2. **fsm-facade-helpers** — `@doc false` helpers used across sub-modules live on the FSM module itself; they need a stable shared home that is not the `:gen_statem` entry point.
3. **user-message-routing** — the three `{:user_message}` clauses mix queue-gate logic with slash-command classification rather than delegating fully to `Tau.Session.Queue`.
4. **cross-cutting-data** — the FSM data struct is an anonymous map (`map()`) rather than a `defstruct` in `Tau.Session.Data`, leaving the field contract unenforced and defensive `Map.get(data, :field, default)` reads scattered across sub-modules.

## Acceptance criterion

`lib/tau/session.ex` contains no inline teardown logic, no `@doc false`
cross-module utility functions, no multi-branch message-routing bodies, and
no anonymous-map data initialisation; every `handle_event/4` clause body is
a one-line delegation or a three-line `:gen_statem` return, and `Tau.Session.Data`
exports a typed struct that all sub-modules pattern-match against.

## Out of scope

- Provider adapter normalisation (TextStart/TextEnd, usage maps) — separate
  audit node `tau-providers`.
- `try/rescue` removal — flagged in v1-flat audit but not a structural
  complecting problem; belongs in a bug-fix PR, not this decomposition.
- `dispatch_tools/2` (already extracted to `ToolDispatch`).
- Queue cap, drain ordering, or steering/followup queue semantics — those are
  behavioural; this audit targets structural complecting only.
- Any change to `test/` files — the audit is read-only on the codebase.

## Amendment log

- (none yet)
