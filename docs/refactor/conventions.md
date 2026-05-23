# Project conventions (binding on extraction subagents)

## 1. Sub-module organisation patterns

Three existing patterns to follow. Pick by which fits the cluster:

**Façade + pure-logic + persistence-owner** (`Tau.CircuitBreaker` example):
- Parent module is the public API façade
- One sibling module holds pure FSM logic with `@type t :: %__MODULE__{}`
- One sibling module owns the ETS table / GenServer state
- File: `lib/tau/circuit_breaker.ex` + `state.ex` + `store.ex`

This is the reference shape for `Tau.Session` after decomposition:
`Tau.Session` (façade) + `Tau.Session.Data` (typed `defstruct`) +
nine concern modules.

**Behaviour facade + implementations** (`Tau.CodingAgent` example):
- Parent defines `@callback`
- Sub-modules implement
- File: `lib/tau/coding_agent.ex` + sub-modules

**Per-concern grouping, no parent** (`Tau.Permissions`, `Tau.Memory`):
- Flat namespace; each module is a pure helper
- No central façade

## 2. `defstruct` usage

Reference: `lib/tau/session/events.ex` — fourteen event structs, each with
`@enforce_keys`, `defstruct`, and `@type t :: %__MODULE__{...}`.

Convention for new sub-module structs:

```elixir
defmodule Tau.Session.Data do
  @moduledoc """
  Typed FSM data for `Tau.Session`. Replaces the prior 69-field anonymous
  map; every helper now has a typed argument.
  """

  @enforce_keys [:id, :cwd, :provider, :original_provider, :model,
                 :persistence, :persist_handle]
  defstruct [
    :id, :cwd, :provider, # ...
  ]

  @type t :: %__MODULE__{
    id: String.t(),
    cwd: String.t(),
    # ...
  }

  @doc "Build initial FSM data from start_link opts + preload events."
  @spec new(keyword()) :: t()
  def new(opts), do: # ...
end
```

## 3. Property test conventions

Reference: `test/tau/circuit_breaker/state_property_test.exs`.

```elixir
defmodule Tau.Session.QueueProperty do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  property "steering_queue FIFO order is preserved across enqueue/dequeue" do
    check all msgs <- list_of(message_generator()) do
      # ...
    end
  end

  defp message_generator do
    # inline generator, no shared test/support module
  end
end
```

- `@moduletag :property` so `mix test.property` finds them
- `use ExUnitProperties`
- Inline generators (no `test/support/generators.ex`)
- File naming: `<module>_property_test.exs` next to existing example tests

## 4. Documentation style

Reference modules: `Tau.CircuitBreaker`, `Tau.CircuitBreaker.State`,
`Tau.Permissions.Mode`, `Tau.Commands.Builtin`, `Tau.Provider.Event`.

**`@moduledoc`** — Clojure-core inspired: one paragraph stating intent.
Optionally followed by `## Contract` / `## States` / `## Telemetry`
sections describing durable invariants. NOT a narrative of how the
module came to exist.

**`@doc`** — One paragraph contract per public function. "Takes X,
returns Y. Errors on Z." Avoid prose. Iex examples allowed but NOT
executed as doctests (codebase has none).

**`@typedoc`** — Brief description of what the type represents and any
guard-rail invariants.

**`@spec`** — Every public function. Use Dialyzer-friendly signatures.
`String.t()`, `non_neg_integer()`, `pid()`, etc. Union types where
appropriate.

**Pragmas:** `@behaviour` and `@impl` where applicable; `@derive` rarely
seen; no `@deprecated`.

## 5. Naming collisions to avoid

| Proposed (don't) | Use instead | Why |
|---|---|---|
| `Tau.Session.Persistence` | `Tau.Session.Journal` | `Tau.Persistence` is a top-level behaviour |
| `Tau.Session.Provider` | `Tau.Session.ProviderTurn` | `Tau.Provider` is a top-level behaviour |
| `Tau.Session.Permissions` | `Tau.Session.ToolDispatch` | `Tau.Permissions` is a top-level namespace |
| `Tau.Session.Model` | `Tau.Session.ModelSwap` | "model" is ambiguous (LLM model string vs MVU model) |

## 6. Build invariants

- `mix.exs` configures dialyzer with `[:error_handling, :unknown,
  :extra_return, :missing_return]`. PLT lives in `priv/plts/`.
- `.credo.exs` strict mode; `Credo.Check.Readability.ModuleDoc: false`
  (no requirement that every module have `@moduledoc`); cyclomatic-
  complexity max 25; line length 110; nesting limit 5.
- `mix format --check-formatted` is a hard gate.
- `mix test --seed 0` baseline: 1,401 tests, 117 properties, 0 failures.

## 7. Comment hygiene (ADR-0023 Layer 6/7)

**Allowed in new module docstrings / inline comments:**
- `ADR-NNNN`, `D-NNN`, `AC-N`, `SPEC-X §Y` references to durable invariants
- OTP non-negotiable numbers (`#1` through `#8`)
- `Unicode Annex #N`, `RFC NNNN` and similar standard references
- WHY explanations of non-obvious behaviour (load-bearing clause order,
  protocol quirks, race conditions)

**Forbidden:**
- GitHub issue/PR numbers in any form: `(#NNN)`, `Pre-#NN`, `see #NN`
- Internal review-cycle tags: `[C##-B##]`, `C##`, `B##-FIX`
- Process-history tags: `FIX-N`, `BLOCKING-N`, `f-N`, `critic S#`,
  `Pi's default`
- Refactor-process language: "Phase ...", "Step ...", "After extraction..."
- Narration of how the function came to be here ("moved from session.ex")
- Pseudo-prose explaining what well-named code already says

## 8. Worktree discipline

Per `.claude/rules/worktree-discipline.md`. Subagent briefs must include:

- `isolation: worktree` is mandatory
- The agent operates only in its worktree; never in the parent
- Tests run in the worktree
- Build cache isolation via `XDG_DATA_HOME=<worktree>/.xdg-data` if any
  Burrito / mix release work happens (not applicable to refactor PRs)
- On completion: capture-before-destroy before any `git worktree remove`
