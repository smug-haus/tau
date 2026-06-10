---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: FSM data is an anonymous map rather than a typed defstruct

## Statement

The per-session FSM `data` value is an untyped `map()` with approximately
45 fields; `Tau.Session.Data.new/1` returns `{:ok, map()}` and the struct
shape is enforced only by runtime pattern matches in `handle_event/4`
guards. Sub-modules that access data fields do so with bare map-key access
(`data.field`) or defensive `Map.get(data, :field, default)` reads;
Dialyzer cannot verify field existence or type, and adding or renaming a
field requires a grep-and-replace across all ten sub-modules.

## Context

- `lib/tau/session/data.ex` (369 LOC): `Data.new/1` builds and returns a
  plain map; there is no `defstruct` or `@type t :: %Tau.Session.Data{}`.
- `session.ex` cancel clauses (lines 963–1083, 1145–1185): reset maps name
  all ~16 fields explicitly — `%{data | provider_task: nil, cancel_flag: nil,
  stream_ref: nil, ...}` — as the only runtime documentation of the data
  shape.
- `lib/tau/session/tool_dispatch.ex`, `provider_turn.ex`, `coding_agent_turn.ex`:
  all access data fields via bare `data.field`; some have defensive
  `Map.get(data, :tools_in_flight, %{})` reads against a shape that
  `Data.new/1` fully populates.
- `lib/tau/session/compaction.ex` and `queue.ex`: contain no defensive reads;
  those sub-modules were extracted after the data-shape was stabilised, but
  the struct was never formalised.
- The flat audit (`02-provider-session.md`) flags: "Pulling this into
  `defstruct` would (a) give Dialyzer something to check, (b) localise the
  field-initialisation table that init/1 currently sprawls over 270 lines,
  (c) eliminate defensive reads."
- `Tau.Session.Meta` (lines 54–113 of `session.ex`) is an existing `defstruct`
  for session metadata returned to callers; the internal FSM data has no
  equivalent.

## Complecting hypothesis

The data field contract is complected with the FSM module because the only
authoritative list of fields is the flat map literal in `Data.new/1` — there
is no type declaration that Dialyzer, documentation generators, or
pattern-match exhaustiveness checks can use; every sub-module must implicitly
know the shape via convention.

The defensive `Map.get(data, :field, default)` calls are complected with
sub-module logic because they exist to guard against a data-shape that is not
statically enforced — once the struct is typed, the defensive reads become
unnecessary noise that obscures real logic.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`Tau.Session.Data` exports a `defstruct` with `@enforce_keys` for every
required field and an `@type t :: %__MODULE__{}` spec; `Data.new/1` returns
`{:ok, %Tau.Session.Data{}}` (not `{:ok, map()}`); all sub-modules
pattern-match on `%Tau.Session.Data{}` in their function heads; and no
`Map.get(data, :field, default)` defensive reads remain in any sub-module for
fields the struct guarantees.

## Out of scope

- The semantic meaning or default values of any field — those are
  behavioural decisions already made.
- Adding, removing, or renaming fields — the struct should capture the
  current shape without change.
- `Tau.Session.Meta` (already a struct; no work needed).
- `@type` specs for individual field values — desirable but a separate effort.
- Sibling sub-problems: cancellation-teardown, fsm-facade-helpers,
  user-message-routing.

## Amendment log

- (none yet)
