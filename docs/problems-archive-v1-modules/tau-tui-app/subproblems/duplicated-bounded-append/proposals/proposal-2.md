---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: New `Tau.TUI.App.Transcript` sub-module with typed operations

## Approach

Create a new `lib/tau/tui/app/transcript.ex` module (`Tau.TUI.App.Transcript`)
that defines a dedicated `t()` type for the transcript list, the cap constant,
`append/2`, `append_many/2`, and a `new/0` constructor. Replace the
`transcript :: [{String.t(), keyword()}]` inline type in `Model.t()` with
`Transcript.t()`. All call-sites in `Events` and `Input` delegate to
`Transcript.append/2` and `Transcript.append_many/2`. Both private copies and
both `@transcript_cap` attributes are deleted.

## Rationale

The problem is not merely "which existing module should own the helper" but that
the transcript is an opaque data structure (a ring-buffer of tuples with a
semantically-significant cap) whose internal representation is currently leaked
throughout `Events`, `Input`, and `Model`. Giving the transcript its own module
makes the ring-buffer cap a property of the type, not of its consumers.
`Events` and `Input` are then free of transcript-invariant knowledge entirely —
they call `Transcript.append/2` without knowing the cap exists. This is a
stronger decomplection than moving the function to `Model`: `Model` would still
encode the cap number; a `Transcript` module hides it behind an opaque boundary.
It also gives `bounded_append_many/2` a natural name (`append_many/2`) without
the redundant qualifier.

## Sketch

```elixir
# lib/tau/tui/app/transcript.ex  (new file)

defmodule Tau.TUI.App.Transcript do
  @moduledoc """
  Ring-buffer transcript for the TUI. Each entry is a `{text, attrs}` tuple.
  The buffer is capped at #{@cap} entries; oldest entries are dropped on overflow.
  """

  @cap 500

  @opaque t :: [entry()]
  @type entry :: {String.t(), keyword()}

  @doc "Empty transcript."
  @spec new() :: t()
  def new(), do: []

  @doc "Append a single entry, dropping the oldest when over cap."
  @spec append(t(), entry()) :: t()
  def append(list, item) do
    new_list = list ++ [item]

    if length(new_list) > @cap do
      Enum.drop(new_list, length(new_list) - @cap)
    else
      new_list
    end
  end

  @doc "Append multiple entries in order."
  @spec append_many(t(), [entry()]) :: t()
  def append_many(list, items) do
    Enum.reduce(items, list, &append(&2, &1))
  end
end
```

```elixir
# lib/tau/tui/app/model.ex  (modified type annotation only)

alias Tau.TUI.App.Transcript

defstruct [
  # ...
  :transcript,  # type changes to Transcript.t()
  # ...
]

@type t :: %__MODULE__{
        # ...
        transcript: Transcript.t(),
        # ...
      }

# new/1 constructor: change `transcript: []` to `transcript: Transcript.new()`
```

```elixir
# lib/tau/tui/app/events.ex  (after change)
alias Tau.TUI.App.Transcript

# Remove: @transcript_cap, all bounded_append* definitions
# All call-sites become:
%{model | transcript: Transcript.append(model.transcript, item)}
%{model | transcript: Transcript.append_many(model.transcript, items)}
```

```elixir
# lib/tau/tui/app/input.ex  (after change)
alias Tau.TUI.App.Transcript

# Remove: @transcript_cap, defp bounded_append/2
# All call-sites become:
%{model | transcript: Transcript.append(model.transcript, item)}
```

File move: `(new)` → `lib/tau/tui/app/transcript.ex`
```

## Tradeoffs

### Strengths

- True decomplection: `Events` and `Input` no longer encode _any_ knowledge of
  the cap or the ring-buffer semantics — all of that knowledge lives in one module.
- The `@opaque t()` annotation makes the internal representation of the
  transcript an implementation detail; no consumer can accidentally pattern-match
  on the list structure without going through `Transcript`.
- `Transcript.new()` and `Transcript.append/2` are unit-testable without
  Ratatouille loaded — no `if Code.ensure_loaded?` guard needed.
- Natural home for future transcript operations (e.g. serialisation, replay,
  search) without touching `Events`, `Input`, or `Model`.
- Eliminates `@transcript_cap` in two places simultaneously.

### Weaknesses

- Introduces a new module: adds a file, a dependency edge, and a concept to the
  sub-module inventory (now 10, not 9 sub-modules). Reviewers may view this as
  over-engineering for a 15-line helper.
- The `@opaque` annotation means code that currently pattern-matches `model.transcript`
  as a raw list (e.g. `Enum.map(model.transcript, fn {text, attrs} -> ...)`) outside
  `Transcript` would produce a dialyzer opacity violation. Auditing all consumers is
  required before the `@opaque` annotation can land safely.
- `bounded_append_many/2` is renamed to `append_many/2` — a public API name change
  for the currently-public function in `Events`. Any external caller using
  `Events.bounded_append_many/2` breaks.
- Slightly more indirection than Proposal 1 for a minimal change.

### Costs

- 1 new file, 3 modified files (`model.ex`, `events.ex`, `input.ex`).
- Auditing `@opaque` impact: grep for `model.transcript` and `Enum.*transcript`
  across all sub-modules to confirm no raw list access outside `Transcript` —
  estimated 15–20 min.
- If `@opaque` is deferred (use `@type` instead), the audit becomes simpler but
  the encapsulation benefit is reduced.
- Tests that assert on `model.transcript` as a list will dialyze-warn under
  `@opaque`; those tests need to use `Transcript` accessors or be treated as
  white-box tests acknowledged to pierce the opaque boundary.

## Dependencies

- None of the sibling sub-problems must be resolved first.
- If the `model-as-bag-of-maps` sibling (sub-problem 2) is addressed
  concurrently, the `Model.t()` type annotation change for `transcript` will
  have a merge conflict with that PR's struct changes. Best serialized after or
  coordinated with that sub-problem.

## Confidence

medium — the new module and function bodies are trivial; the main risk is the
`@opaque` annotation audit, which could reveal widespread raw-list access that
forces the opaque annotation to be deferred to a follow-up PR.

## Prior art / references

- Elixir stdlib: `MapSet`, `Queue` are opaque types whose internals are hidden
  behind a module boundary — the same pattern applied to the transcript.
- Hickey "Simple Made Easy" (2011): distinguishing "simple" (one concern) from
  "easy" (familiar); a `Transcript` module is simpler even if it adds a file.
