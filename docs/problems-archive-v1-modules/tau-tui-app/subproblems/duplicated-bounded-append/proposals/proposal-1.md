---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Extract `bounded_append` into `Tau.TUI.App.Model` as a public function

## Approach

Move `bounded_append/2`, `bounded_append_many/2`, and `@transcript_cap` from
`Events` and `Input` into `Tau.TUI.App.Model`. Expose them as public functions
on the module that already owns the `transcript` field's type definition and
invariants. Delete both private copies from `Events` and `Input`; replace their
call-sites with `Model.bounded_append/2` and `Model.bounded_append_many/2`.

## Rationale

`Model` already declares `transcript :: [{String.t(), keyword()}]` and is the
canonical owner of the `Model.t()` struct. Functions that enforce an invariant
on `model.transcript` (the ring-buffer cap) belong to that owner module —
colocation of data definition and data invariant is the Hickey "compose, don't
complect" principle. Extracting to `Model` does not require a new module,
does not change the public API surface of `Events` or `Input`, and gives future
consumers (e.g. a new sub-module) a single import target instead of a copy.
The cap constant lives in exactly one place, eliminating silent divergence.

## Sketch

```elixir
# lib/tau/tui/app/model.ex

defmodule Tau.TUI.App.Model do
  @transcript_cap 500

  # ... existing struct + typedoc unchanged ...

  @doc """
  Append `item` to `list`, dropping the oldest entry when the transcript cap
  is exceeded. Ring-buffer semantics: cap is #{@transcript_cap}.
  """
  @spec bounded_append([{String.t(), keyword()}], {String.t(), keyword()}) ::
          [{String.t(), keyword()}]
  def bounded_append(list, item) do
    new_list = list ++ [item]

    if length(new_list) > @transcript_cap do
      Enum.drop(new_list, length(new_list) - @transcript_cap)
    else
      new_list
    end
  end

  @doc """
  Append multiple items in order, applying the cap after each.
  """
  @spec bounded_append_many([{String.t(), keyword()}], [{String.t(), keyword()}]) ::
          [{String.t(), keyword()}]
  def bounded_append_many(list, items) do
    Enum.reduce(items, list, &bounded_append(&2, &1))
  end
end
```

```elixir
# lib/tau/tui/app/events.ex  (after change)
# Remove: @transcript_cap 500, defp bounded_append/2, def bounded_append/2,
#         def bounded_append_many/2
# Add alias at top if not already present:
alias Tau.TUI.App.Model

# All call-sites become:
Model.bounded_append(model.transcript, item)
Model.bounded_append_many(model.transcript, items)
```

```elixir
# lib/tau/tui/app/input.ex  (after change)
# Remove: @transcript_cap 500, defp bounded_append/2
# Add alias:
alias Tau.TUI.App.Model

# All call-sites become:
Model.bounded_append(model.transcript, item)
```

File moves: none — changes are in-place edits to existing files.
```

## Tradeoffs

### Strengths

- Natural home: `Model` already owns the `transcript` type; collocating the
  ring-buffer invariant with the field declaration is directly traceable.
- Zero new modules: no new file, no new dependency edge.
- Eliminates duplication completely: `@transcript_cap` and body exist once.
- `bounded_append_many/2` becomes accessible to `Input` and future consumers
  without further copy.
- Behaviour-preserving: call-sites change only in qualification; the function
  bodies are identical.

### Weaknesses

- `Model` will now hold some logic, moving it slightly away from a pure
  data-shape module. Reviewers may object to a "fat model" precedent.
- `Events` currently has a public `def bounded_append/2` with `@doc` and
  `@spec`; removing it is an API change for any external caller that happens to
  call `Events.bounded_append/2` directly (unlikely but must be audited).
- The `Model` module is already wrapped in `if Code.ensure_loaded?(Ratatouille.Runtime)`;
  the extracted function will only be available in environments where that
  condition is true, which is fine for TUI use but slightly surprising for
  anyone trying to unit-test it in isolation without Ratatouille loaded.

### Costs

- 2 files modified (`events.ex`, `input.ex`), 1 file modified to add functions
  (`model.ex`).
- Audit: grep for direct calls to `Events.bounded_append` to ensure no external
  callers are silently broken (~5 min).
- No test changes required if behaviour is preserved identically; existing tests
  that exercise transcript append continue to pass.

## Dependencies

- No other sub-problem must be resolved first.
- The `if Code.ensure_loaded?` guard in `model.ex` must be understood to
  confirm the extracted functions are reachable in all test environments.

## Confidence

medium — the approach is straightforward and fits Elixir idiom, but the
`if Code.ensure_loaded?` compilation guard in `model.ex` requires a quick
prototype to confirm the function is reachable in non-Ratatouille test
environments.

## Prior art / references

- Elixir idiom: data module owns its invariant helpers (`Date`, `Map`, `String`
  all follow this pattern in stdlib).
- `Tau.TUI.App.Model` already holds `transcript_pane_width/1` — a helper
  scoped to the model — confirming the precedent for non-pure-struct helpers
  in this module.
