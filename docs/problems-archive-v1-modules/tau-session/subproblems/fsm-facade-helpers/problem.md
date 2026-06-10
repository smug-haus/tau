---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: shared @doc false helpers are public functions on the FSM module

## Statement

`lib/tau/session.ex` exports eight `@doc false` functions
(`broadcast/2`, `append_message/2`, `generate_event_id/0`,
`transition/3`, `emit_user_message_telemetry/3`, `hook_payload/3`,
`process_user_message/2`, `current_run?/2`) that sub-modules call as
`Tau.Session.broadcast(id, event)`, `Tau.Session.append_message(data, msg)`,
etc. These functions have no relationship to the `:gen_statem` contract; they
are utilities used across sub-modules that have been left on the FSM module
because there was no other home for them during the extraction. Any sub-module
that calls them is coupled to the top-level FSM module purely for utility
access.

## Context

- `session.ex` lines 1293–1438: eight `@doc false` function heads — `current_run?/2`
  (token validity), `process_user_message/2` (hook + route), `append_message/2`
  (O(n) list append), `generate_event_id/0` (UUID/fallback), `transition/3`
  (telemetry emit), `broadcast/2` (PubSub), `emit_user_message_telemetry/3`
  (telemetry), `hook_payload/3` + `transcript_path/1` (hook payload builder).
- Sub-modules that call these via `Tau.Session.<fn>`:
  `SlashCommand`, `ProviderTurn`, `CodingAgentTurn`, `ToolDispatch`,
  `Compaction`, `ModelSwap` — six of the ten sub-modules reference the FSM
  module for utility functions.
- `Tau.Session.Data` (`lib/tau/session/data.ex`, 369 LOC) already owns struct
  initialisation; it is the natural home for pure data-manipulation utilities
  (`append_message`, `generate_event_id`, `current_run?`).
- `Tau.Session.Events` (`lib/tau/session/events.ex`, 263 LOC) or a new
  `Tau.Session.Broadcast` module could own `broadcast/2` and
  `emit_user_message_telemetry/3`.
- `process_user_message/2` is not a utility — it is a routing function that
  calls hook dispatch and then re-enters `handle_event/4`; it belongs in
  `Tau.Session.Queue` or `Tau.Session.SlashCommand`, not as a `@doc false`
  on the FSM.
- `hook_payload/3` and `transcript_path/1` are pure builders; they could live
  in `Tau.Session.Data` or a new `Tau.Session.Hooks` helper module.

## Complecting hypothesis

The utility functions are complected with the `:gen_statem` entry point
because the extraction of sub-modules did not simultaneously introduce a
shared internal utility module; the path of least resistance was to leave
helpers in the original file and mark them `@doc false`.

`process_user_message/2` is complected with the FSM module because it
calls `handle_event/4` internally (routing back into the FSM), making it
appear to be FSM logic when it is actually a coordination function between
`SlashCommand` classification and turn initiation.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`lib/tau/session.ex` contains no `@doc false` functions; every utility
used by sub-modules lives in a clearly-named sub-module
(e.g. `Tau.Session.Data`, `Tau.Session.Queue`, or a new
`Tau.Session.Broadcast`), and sub-modules call those modules directly rather
than calling `Tau.Session.<fn>`.

## Out of scope

- The behaviour of any of these utilities — this problem is about location,
  not correctness.
- `append_message/2` O(n) performance — a separate bug, not a structural
  complecting problem.
- `generate_id/0` (public API, line 487) — that is a documented public
  function, not a `@doc false` helper.
- Sibling sub-problems: cancellation-teardown, user-message-routing,
  cross-cutting-data.

## Amendment log

- (none yet)
