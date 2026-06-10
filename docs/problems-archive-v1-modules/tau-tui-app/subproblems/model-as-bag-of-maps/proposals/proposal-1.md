---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Mechanical callsite replacement — `Map.get/put` → struct field syntax

## Approach

Replace every `Map.get(model, :field, default)` and `Map.put(model, :field, val)`
call in `Events`, `Input`, `Keymap`, `View`, and `Permission` with direct struct
field access (`model.field`) and struct update syntax (`%{model | field: val}`).
Update all `@spec` annotations that use `map()` as input or output to use
`Model.t()`. Remove any `Map.get` call whose fallback default re-states a value
already present in `Model.new/1`. No new modules, no new abstractions — pure
callsite cleanup, one file at a time.

## Rationale

The complecting hypothesis is clear: the anonymous-map access style migrated from
the pre-decomposition `app.ex` without being updated to use the struct that was
simultaneously introduced. The complecting is not architectural — it is a uniform
callsite smell. A mechanical callsite replacement eliminates the smell at its
source: every consumer module is forced through the compiler's field-access path,
`@enforce_keys` protection applies at all mutation sites, and Dialyzer can
typecheck field names. No behaviour changes, no new dependencies.

## Sketch

**Events** — `events.ex:83,84,241,252–257`:

```elixir
# Before
@spec update_session_event(map(), term()) :: map()
# ...
Map.get(model, :context_window) || Application.get_env(...)
prior_warn = Map.get(model, :warn_level, :ok)
model
|> Map.put(:status, :idle)
|> Map.put(:transcript, bounded_append_many(model.transcript, transcript_lines))
|> Map.put(:last_assistant, nil)
|> Map.put(:usage, session_counters)
|> Map.put(:context_tokens, new_context_tokens)
|> Map.put(:warn_level, new_warn)

# After
@spec update_session_event(Model.t(), term()) :: Model.t()
# ...
model.context_window || Application.get_env(...)
prior_warn = model.warn_level
%{model | status: :idle,
          transcript: bounded_append_many(model.transcript, transcript_lines),
          last_assistant: nil,
          usage: session_counters,
          context_tokens: new_context_tokens,
          warn_level: new_warn}
```

**View** — `view.ex:117–129`:

```elixir
# Before
@spec status_bar_model(map()) :: map()
def status_bar_model(model) do
  base = %{
    session_id: Map.get(model, :session_id),
    usage: Map.get(model, :usage, %{input_tokens: 0, ...}),
    context_tokens: Map.get(model, :context_tokens, 0),
    compaction: Map.get(model, :compaction, :idle),
    permissions_mode: Map.get(model, :permissions_mode, :default)
    ...
  }
end

# After
@spec status_bar_model(Model.t()) :: map()
def status_bar_model(model) do
  base = %{
    session_id: model.session_id,
    usage: model.usage,
    context_tokens: model.context_tokens,
    compaction: model.compaction,
    permissions_mode: model.permissions_mode,
    ...
  }
end
```

**Keymap** — `keymap.ex:31`:

```elixir
# Before
case Map.get(model, :pending_permissions, []) do

# After
case model.pending_permissions do
```

**Permission** — `permission.ex:40–41`:

```elixir
# Before
queue = Map.get(model, :pending_permissions, [])
Map.put(model, :pending_permissions, queue ++ [req])

# After
%{model | pending_permissions: model.pending_permissions ++ [req]}
```

All `@spec` lines using `map()` for `Model.t()` inputs/outputs updated to
`Model.t()` via `alias Tau.TUI.App.Model` at the top of each consumer module.

## Tradeoffs

### Strengths

- Directly addresses the acceptance criterion: no `Map.get/3` or `Map.put/2`
  remains on `Model.t()` values; all specs use `Model.t()`.
- Zero runtime behaviour change — pure syntax migration; safe to apply
  incrementally file by file.
- Enables Dialyzer to catch field-name typos at every callsite immediately
  after each file is updated.
- Lowest cognitive overhead for reviewers — each diff is a uniform substitution
  with obvious before/after.
- Removes the hidden default re-statement problem: `Map.get(model, :usage, %{...})`
  can silently differ from `Model.new/1`'s seed; `model.usage` cannot.

### Weaknesses

- Does not add any new abstraction; if a consumer needs to mutate multiple
  fields together as a logical unit, it still does so via a flat `%{model | ...}`
  update spread across the call site.
- No enforcement that future contributors avoid reverting to `Map.get` — the fix
  is one Credo rule away but that rule is not part of this proposal.
- The fix to `View.status_bar_model/1` removes defaults that currently paper
  over missing fields (e.g., `usage: %{input_tokens: 0, ...}`) — after the
  change, a test that constructs an incomplete `Model.t()` will crash rather
  than silently returning a zeroed-out default. That is the correct behaviour,
  but it may surface latent test-setup gaps.

### Costs

- Approximately 30–40 callsite edits across five files; mechanical but tedious.
- Every file touched requires a new `alias Tau.TUI.App.Model` import and a
  corresponding `@moduledoc` cross-reference.
- Test runs after each file change to confirm no test setup was relying on the
  defaulting behaviour of `Map.get`.

## Dependencies

- None. The struct and `@enforce_keys` already exist in `Model.t()`; no new
  modules or behaviours required.

## Confidence

Medium. The approach is straightforward and the target callsites are fully
inventoried in the problem statement. Confidence would be high after one file
(e.g., `events.ex`) is updated and `mix test` and `mix dialyzer` both pass
cleanly, confirming no hidden test fixtures rely on the `Map.get` defaults.

## Prior art / references

- Elixir official docs: struct field access vs `Map.get` — struct syntax is the
  idiomatic path and the compiler enforces it; `Map.get` defeats enforcement.
- `mix credo --strict` `Credo.Check.Refactor.MapGet` — a community Credo rule
  that flags this exact pattern.
- The problem statement's own inventory (`events.ex:84`, `view.ex:118–138`,
  `keymap.ex:31`, `permission.ex:40`) gives the full callsite list.
