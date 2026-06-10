---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Delete `Events`' public copy; keep one private copy in `Events`, expose via delegation from `Input`

## Approach

Keep a single private `bounded_append/2` in `Events` and promote it to a
module-private-but-accessible function via a thin public delegating wrapper
only in `Events`; `Input` delegates its call through `Events`. Delete `Input`'s
own private copy and `@transcript_cap` entirely. The cap constant and the body
live in exactly one place (`Events`). `bounded_append_many/2` remains in
`Events`. No new module; `Model` is not modified.

## Rationale

`Events` already holds the canonical copy — it has the `@doc`, the `@spec`, and
the public visibility marker that `Input` does not. The minimum-disturbance fix
is to make `Events` the single source without changing `Model` or introducing
new modules: `Input` calls `Events.bounded_append/2` instead of its private
duplicate. This is a behaviour-preserving, API-preserving, incremental
change: the public surface of `Events` stays identical (the function was already
public there); only `Input`'s internal structure changes. The acceptance
criterion is satisfied with the smallest diff possible.

## Sketch

```elixir
# lib/tau/tui/app/events.ex  (minimal change: no modification needed)
# bounded_append/2 and bounded_append_many/2 are already public with @doc/@spec.
# @transcript_cap 500 stays here.
# No change required in events.ex.
```

```elixir
# lib/tau/tui/app/input.ex  (after change)

# Remove these two lines entirely:
#   @transcript_cap 500
#   defp bounded_append(list, item) do ... end

# Add alias at top of inner module:
alias Tau.TUI.App.Events

# All call-sites in input.ex that previously called bounded_append/2 become:
Events.bounded_append(model.transcript, item)

# Example — before:
#   %{model | transcript: bounded_append(model.transcript, {text, attrs})}
# After:
#   %{model | transcript: Events.bounded_append(model.transcript, {text, attrs})}
```

File moves: none. Only `input.ex` is changed.
```

## Tradeoffs

### Strengths

- Smallest possible diff: only `input.ex` changes, `events.ex` requires zero
  modification.
- Zero new modules, zero changes to `Model`.
- Acceptance criterion is fully satisfied: `@transcript_cap` defined once;
  duplication absent from both `Events` and `Input`.
- Strictly behaviour-preserving: function bodies are identical; call-sites only
  change in qualification.
- Lowest merge-conflict risk with sibling sub-problems; `model.ex` is untouched.

### Weaknesses

- Creates a dependency from `Input` to `Events` — a sibling-sub-module coupling
  that does not currently exist. Sibling modules in the same decomposed layer
  should typically not depend on each other; this coupling makes `Input` harder
  to test or evolve independently of `Events`.
- `bounded_append/2` remaining in `Events` (not in `Model`) is still
  architecturally surprising: the function operates on `model.transcript` but
  lives in the event dispatcher. Any future third consumer that doesn't naturally
  depend on `Events` will face the same friction again.
- Does not fix the "natural home" concern from the problem statement — the
  complecting hypothesis says `Model` is the natural home; this proposal leaves
  the function in `Events`, which is an event dispatcher, not a data-invariant
  module.
- `bounded_append_many/2` is not accessible to `Input` without adding another
  delegation call — if `Input` ever needs it, this proposal requires a second
  change.

### Costs

- 1 file modified (`input.ex`), 0 new files, 0 changes to `model.ex` or
  `events.ex`.
- Introduces an `alias Tau.TUI.App.Events` in `input.ex` — must verify there
  is no circular dependency (Events → Input exists for event routing; if
  `Input` imports `Events`, a cycle forms). **This requires explicit audit.**
  If Events already depends on Input, this proposal is not viable and collapses
  to a halt.

## Dependencies

- **Critical dependency:** verify that `events.ex` does NOT `alias` or call
  into `input.ex`. If it does, a circular module dependency results and this
  proposal cannot be applied without restructuring. This is the primary
  feasibility gate for the proposal.
- No other sub-problem must be resolved first.

## Confidence

low — the circular-dependency risk is a real blocker that has not been verified.
If `Events` calls into `Input` anywhere (likely, given the decomposition), this
proposal is invalid. Confidence becomes medium only after a negative grep result
confirms there is no current `Events → Input` dependency.

## Prior art / references

- This "promote the already-canonical copy" pattern is common in incremental
  refactors — the principle that the smallest behaviour-preserving diff is
  preferred for low-risk changes.
- Anti-pattern: sibling module coupling in decomposed MVU architectures (Elm
  community guidance on not importing sibling update modules into each other).
