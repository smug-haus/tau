---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Collapse Tau.Telemetry.Supervisor — merge Cost.Tracker into Tau.Application's supervision tree directly, eliminate the intermediate supervisor

## Approach

Delete `Tau.Telemetry.Supervisor` entirely. Move `Tau.Telemetry.Handlers` and
`Tau.Cost.Tracker` as direct children of `Tau.Application`'s `:rest_for_one`
supervision tree (which already exists and already uses `:rest_for_one`).
Insert them at the correct position in `Tau.Application`'s child list so the
existing `:rest_for_one` cascade covers both. Add the `rescue` to
`handle_event/4` as in Proposal 1. The intermediate supervisor's strategy
ambiguity is eliminated by removing the layer.

## Rationale

`Tau.Telemetry.Supervisor` exists as a grouping convenience, but its
`:one_for_one` strategy actively contradicts the intended restart dependency
between its two children. `Tau.Application` already uses `:rest_for_one` and
already correctly orders its 17 children. Rather than patching the intermediate
supervisor's strategy (Proposals 1 and 2), this proposal removes the layer that
introduced the mismatch, placing both telemetry children directly under the
already-correct outer supervisor. The handler-attachment lifecycle is then
expressed by the outer supervisor's child ordering — visible, correct by
construction, and not duplicating a supervisor level with no independent value.

## Sketch

**Delete `lib/tau/telemetry/supervisor.ex`.**

**`lib/tau/application.ex` — replace the `Tau.Telemetry.Supervisor` child
entry with the two individual children at the same position:**

```elixir
# Before (approximate, from application.ex context):
children = [
  # ... earlier children ...
  Tau.Telemetry.Supervisor,
  # ... later children (PubSub, Finch, Sessions, etc.) ...
]

# After:
children = [
  # ... earlier children (same as before) ...
  Tau.Telemetry.Handlers,  # was first child of Telemetry.Supervisor
  Tau.Cost.Tracker,        # was second child — :rest_for_one now covers both
  # ... later children (same as before) ...
]

Supervisor.init(children, strategy: :rest_for_one)
# strategy unchanged — Application already uses :rest_for_one
```

**`lib/tau/cost/tracker.ex`** — add `rescue` to `handle_event/4` (identical
to Proposal 1 sketch).

**File move summary:**
- `lib/tau/telemetry/supervisor.ex` → deleted
- `lib/tau/application.ex` — child list updated (~3 lines net)
- `lib/tau/cost/tracker.ex` — rescue added (~8 lines net)

Any module that starts `Tau.Telemetry.Supervisor` by name (e.g. tests calling
`start_supervised(Tau.Telemetry.Supervisor)`) must be updated to start
`Tau.Telemetry.Handlers` and `Tau.Cost.Tracker` individually.

## Tradeoffs

### Strengths

- Eliminates the root cause of the mismatch: the intermediate supervisor with
  the wrong strategy. No strategy patch needed; the outer supervisor is already
  correct.
- Reduces the supervision tree depth by one level; failure modes are simpler
  to reason about.
- `Tau.Application`'s `:rest_for_one` cascade already exists and is already
  relied on by the 17-child tree; extending it is idiomatic, not novel.
- The intermediate supervisor was adding no independent value (no dynamic child
  management, no separate restart policy, no separate name registration).

### Weaknesses

- Deleting a module is an API-breaking change: any test or external code that
  `start_supervised(Tau.Telemetry.Supervisor)` breaks immediately.
- Increases the width of `Tau.Application`'s child list, which is already 17
  children — adding 2 more (net change: +2 children, -1 Supervisor child)
  makes the application-level tree harder to read.
- If `Tau.Application` is ever split into sub-supervisors for other reasons,
  these two children would need to be re-extracted, making the deletion a
  premature simplification.
- `:rest_for_one` at the application level means a crash in `Handlers` or
  `Cost.Tracker` restarts everything that comes after them in
  `Tau.Application`'s child list — the blast radius is larger than with an
  intermediate supervisor that contains the crash to just those two children.
- Behavioural change: whether this blast-radius expansion is acceptable depends
  on what children follow `Handlers`/`Cost.Tracker` in `Tau.Application`'s
  list — if PubSub, Finch, or session supervisors follow, their restarts on
  a telemetry handler crash may be unacceptable.

### Costs

- 1 file deleted, 2 files modified, ~15 lines net.
- Test surface: tests using `start_supervised(Tau.Telemetry.Supervisor)` must
  be updated; estimate 2-4 test files.
- Search required: `grep -rn "Telemetry.Supervisor"` to find all references.
- No dependency changes; no library migration.

## Dependencies

- Must verify the position of `Tau.Telemetry.Handlers` / `Tau.Cost.Tracker`
  in `Tau.Application`'s child list — specifically, what children follow them.
  If the blast-radius analysis is unacceptable, wrap both in a new
  `Tau.Telemetry.Supervisor` using `:rest_for_one` (effectively Proposal 1).
- `Tau.Application` must be read before implementing to confirm the child
  ordering.

## Confidence

low — the approach is sound in principle, but the blast-radius weakness means
it may be rejected on review once the full `Tau.Application` child list is
examined. The outcome depends on information not yet in scope (what follows
telemetry children in `application.ex`). Confidence rises to medium after
confirming the child ordering and that the blast radius is acceptable.

## Prior art / references

- `Tau.Application` — already uses `:rest_for_one`; extending it is
  idiomatically consistent.
- OTP design principle: intermediate supervisors are warranted when they
  provide independent restart policy, dynamic child management, or separate
  naming. When none of these apply, flattening is simpler.
- Erlang/OTP docs: "The trade-off between a flat and a deep supervision tree
  is between containment of failures and the complexity of the tree."
