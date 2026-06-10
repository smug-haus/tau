---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Inline-eliminate via `Model` update helper — no new function, data-shape change

## Approach

Do not extract `bounded_append/2` as a named function at all. Instead, add a
`Model.append_transcript/2` function that takes the full `Model.t()` and an item
and returns an updated `Model.t()` — the cap logic is inlined inside it. Remove
both private copies of `bounded_append/2` and both `@transcript_cap` attributes.
Call-sites in `Events` and `Input` change from
`%{model | transcript: bounded_append(model.transcript, item)}` to
`Model.append_transcript(model, item)`, hiding the field name as well as the
cap. The `bounded_append_many/2` variant in `Events` becomes
`Model.append_transcript_many/2` on the same model-update axis.

## Rationale

The complecting here is not just "two modules own the helper" but that
call-sites in `Events` and `Input` must know (a) the field name `transcript`,
(b) the type `[{text, attrs}]`, and (c) the ring-buffer cap. A model-update
function hides all three behind a single operation. This is the
"tell, don't ask" style: instead of the caller extracting
`model.transcript`, transforming it, and putting it back, the model updates
itself. The cap constant remains private to `Model` (a private `@transcript_cap`
attribute), never shared. Call-sites shrink and carry less knowledge.

## Sketch

```elixir
# lib/tau/tui/app/model.ex  (additions)

@transcript_cap 500

@doc """
Append one `{text, attrs}` entry to the model's transcript, enforcing the
#{@transcript_cap}-entry ring-buffer cap. Returns the updated model.
"""
@spec append_transcript(t(), {String.t(), keyword()}) :: t()
def append_transcript(%__MODULE__{transcript: list} = model, item) do
  new_list = list ++ [item]

  trimmed =
    if length(new_list) > @transcript_cap do
      Enum.drop(new_list, length(new_list) - @transcript_cap)
    else
      new_list
    end

  %{model | transcript: trimmed}
end

@doc """
Append multiple `{text, attrs}` entries in order, applying the cap after each.
Returns the updated model.
"""
@spec append_transcript_many(t(), [{String.t(), keyword()}]) :: t()
def append_transcript_many(model, items) do
  Enum.reduce(items, model, &append_transcript(&2, &1))
end
```

```elixir
# lib/tau/tui/app/events.ex  (after change)
alias Tau.TUI.App.Model

# Remove: @transcript_cap 500, defp/def bounded_append/2, def bounded_append_many/2
# Before:
#   %{model | transcript: bounded_append(model.transcript, {text, attrs})}
# After:
#   Model.append_transcript(model, {text, attrs})

# Before:
#   %{model | transcript: bounded_append_many(model.transcript, items)}
# After:
#   Model.append_transcript_many(model, items)
```

```elixir
# lib/tau/tui/app/input.ex  (after change)
alias Tau.TUI.App.Model

# Remove: @transcript_cap 500, defp bounded_append/2
# Before:
#   %{model | transcript: bounded_append(model.transcript, {text, attrs})}
# After:
#   Model.append_transcript(model, {text, attrs})
```

File moves: none.
```

## Tradeoffs

### Strengths

- Call-sites in `Events` and `Input` are maximally lean: they neither know the
  field name `transcript` nor the type nor the cap — strongest information hiding
  of all proposals.
- Single definition of `@transcript_cap` and body; no extraction to new module.
- "Tell, don't ask" style is natural for MVU: callers hand the whole model in,
  get the whole model back.
- No module proliferation; `Model` already holds `transcript_pane_width/1` as a
  precedent for model-scoped helpers.
- `append_transcript_many/2` becomes available to `Input` at no extra cost.

### Weaknesses

- `Model` gains business logic (the cap rule) more deeply than Proposal 1: it
  now holds state + invariant + mutation operation, blurring the distinction
  between a data definition module and a logic module. Future reviewers may
  escalate this toward a fat-model anti-pattern.
- The function signature change is more invasive than Proposals 1–2: call-sites
  must be updated to pass the full model rather than just `model.transcript`.
  For deeply nested pattern-matched call-sites this may require unfolding a
  match to get the model in scope.
- The function body inlines the cap logic rather than delegating to a named
  `bounded_append` function; this is a minor loss of composability if the cap
  logic needs to be tested independently.
- `Events` currently exposes a public `def bounded_append/2` — removing it is
  a public API change for any external caller.

### Costs

- 3 files modified (`model.ex`, `events.ex`, `input.ex`), 0 new files.
- Call-site audit: all uses of `bounded_append` in `Events` and `Input` must
  be updated to pass `model` not `model.transcript`. Where `Events` or `Input`
  functions receive only the transcript list (not the full model) as a parameter,
  the parameter type must be widened — this may cascade into callers of those
  functions.
- Test changes: any test that calls `Events.bounded_append/2` directly or that
  passes `model.transcript` to the function must be updated to use the new
  model-update signature.

## Dependencies

- Same `if Code.ensure_loaded?` guard applies as Proposal 1.
- If call-sites in `Events` or `Input` use `bounded_append` on a raw list
  rather than `model.transcript` (verify with grep), the parameter widening
  cascades are larger than expected.

## Confidence

medium — the model-update idiom is clean and consistent with the rest of the
MVU style, but the call-site cascade when widening parameters from `list` to
`model` needs a prototype pass to confirm scope.

## Prior art / references

- MVU / Elm Architecture: update functions operate on the full model, returning
  the full model — the `append_transcript` shape mirrors this precisely.
- Elixir idiom: `Map.update/4`, `Keyword.update/4` — operations that take the
  container and return the container rather than operating on a value extracted
  from it.
