---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: `bounded_append/2` duplicated across Events and Input with no canonical home

## Statement

`bounded_append/2` — the function that appends a `{text, attrs}` tuple to the
transcript list and enforces a 500-entry cap — is defined as a private function
in both `Tau.TUI.App.Events` and `Tau.TUI.App.Input`, with identical bodies and
the same `@transcript_cap 500` module attribute. Any future change to the cap
constant or drop semantics must be made in two places, and the absence of a
canonical home means a third consumer (e.g. a new sub-module) will copy it
again rather than call it from one source.

## Context

- `lib/tau/tui/app/events.ex:428–437` — `defp bounded_append/2` + `bounded_append_many/2`; also has public `@doc` specs
- `lib/tau/tui/app/events.ex:18` — `@transcript_cap 500`
- `lib/tau/tui/app/input.ex:193–201` — `defp bounded_append/2`; private, no spec
- `lib/tau/tui/app/input.ex:191` — `@transcript_cap 500`
- Both copies are identical: `list ++ [item]`, then `Enum.drop` if over cap.
- `bounded_append_many/2` is defined only in `Events`; `Input` has no equivalent.
- `Model.t()` owns the `transcript` field; `Model` does not own the append helper.

## Complecting hypothesis

`bounded_append/2` is complected with both `Events` and `Input` because the
decomposition created two modules that both mutate `model.transcript` and
each privately claimed the helper rather than extracting it to its natural
home (`Model`, which owns the `transcript` field's definition and invariants).

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

A single canonical implementation of `bounded_append/2` (and `bounded_append_many/2`)
exists in exactly one location; every consumer calls that single implementation;
the `@transcript_cap` constant is defined once; and the duplication is absent
from both `Events` and `Input`.

## Out of scope

- Changing the cap value or the ring-buffer semantics.
- Moving transcript rendering or any other transcript concern.
- Changes to `model-as-bag-of-maps` (sibling sub-problem).
- Changes to `session-side-effects-in-pure-modules` (sibling).
- Changes to `transcript-coupling` (sibling).

## Amendment log

- (none yet)
