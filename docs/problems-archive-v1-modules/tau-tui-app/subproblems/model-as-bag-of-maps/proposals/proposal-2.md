---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Typed accessor/updater functions on `Model` — thin façade that owns all field defaults

## Approach

Add a small set of public `get_*` and `put_*` functions (or a general `update/2`
multi-field updater) directly on `Tau.TUI.App.Model` that centralize field
defaults and struct mutation. Consumer modules (`Events`, `View`, `Keymap`,
`Permission`) call `Model.context_window(model)`, `Model.warn_level(model)`,
`Model.update(model, status: :idle, warn_level: :ok)`, etc., instead of either
`Map.get/3` or raw struct access. The canonical default for every field lives
once, in `Model`, co-located with `Model.new/1`.

## Rationale

The root complaint is that default values for fields are scattered across
`Map.get(model, :field, default)` calls in multiple consumer files, where they
can silently diverge from `Model.new/1`. This proposal decomplects the
"canonical default" concern from the "field access" concern by making `Model`
the single owner of both. Consumers become callers of typed functions rather
than map-readers; `@spec` annotations on those functions enforce `Model.t()` as
both input and output; Dialyzer follows the types through the indirection.

## Sketch

**New in `model.ex`** — typed field accessors for fields that have non-nil
defaults and are currently accessed via `Map.get/3` with fallbacks:

```elixir
defmodule Tau.TUI.App.Model do
  # ... existing struct/typedefs unchanged ...

  @doc "Current context window size, or the fallback compaction threshold."
  @spec context_window(t()) :: pos_integer()
  def context_window(%__MODULE__{context_window: nil}),
    do: Application.get_env(:tau, :compaction_threshold_tokens, 120_000)
  def context_window(%__MODULE__{context_window: w}), do: w

  @doc "Multi-field struct updater. Only listed fields may be set; unknown keys raise at compile time."
  @spec update(t(), keyword()) :: t()
  def update(%__MODULE__{} = model, fields) when is_list(fields) do
    struct!(model, fields)
  end
end
```

**Updated callsite in `events.ex`** (on_message_end/2):

```elixir
# Before
pct = StatusBar.context_pct(
  new_context_tokens,
  Map.get(model, :context_window) || Application.get_env(...)
)
prior_warn = Map.get(model, :warn_level, :ok)
model
|> Map.put(:status, :idle)
|> Map.put(:warn_level, new_warn)
...

# After
pct = StatusBar.context_pct(new_context_tokens, Model.context_window(model))
prior_warn = model.warn_level
Model.update(model, status: :idle, warn_level: new_warn, ...)
```

**Updated callsite in `view.ex`** (status_bar_model/1):

```elixir
@spec status_bar_model(Model.t()) :: map()
def status_bar_model(model) do
  %{
    session_id: model.session_id,
    usage: model.usage,
    context_tokens: model.context_tokens,
    context_window: Model.context_window(model),   # uses the canonical fallback
    compaction: model.compaction,
    permissions_mode: model.permissions_mode,
    ...
  }
end
```

**Updated callsite in `permission.ex`**:

```elixir
def on_permission_request(%Model{} = model, req) do
  Model.update(model, pending_permissions: model.pending_permissions ++ [req])
end
```

**`struct!/2` enforces field names at runtime** (compile-time for literals);
Dialyzer enforces `Model.t()` at the function boundary. No need for a per-field
`get_*` function when the default is simply the struct field value — those sites
use `model.field` directly.

## Tradeoffs

### Strengths

- Canonical defaults live in exactly one place (`Model`) rather than being
  copied into each consumer; a future change to the compaction-threshold fallback
  only updates `Model.context_window/1`.
- `struct!/2` inside `Model.update/2` raises at the callsite for unknown keys,
  providing a better error message than a silent struct bypass.
- `@spec status_bar_model(Model.t())` and all consumer specs are now typed
  correctly without requiring that every single `map.field` access also be
  changed — `Model.context_window/1` is the only callsite that needs the
  fallback logic.
- Adds a stable internal API surface on `Model` that can be extended (e.g.,
  derived projections like `Model.status_bar_projection/1`) without touching
  consumer modules again.

### Weaknesses

- Adds indirection: `Model.context_window(model)` is less familiar at first
  glance than `model.context_window`; reviewers must know the function exists to
  understand why it is called instead of direct access.
- `Model.update/2` with `struct!/2` raises at runtime, not at compile time, for
  dynamically-constructed keyword lists. If a caller builds the keyword list
  programmatically, bad keys are not caught until the update executes.
- Does not prevent future contributors from re-introducing `Map.get` at new
  callsites — same enforcement gap as Proposal 1, without Proposal 1's
  simplicity argument.
- Slightly larger API surface on `Model` than Proposal 1; more functions to
  test and document.

### Costs

- Write `Model.context_window/1` (and any other accessor needed for non-trivial
  defaults); write `Model.update/2`.
- Update all `Map.get/3` and `Map.put/2` callsites to use either `model.field`
  (trivial) or the new accessors (where defaults are non-trivial).
- Update `@spec` annotations as in Proposal 1 — identical cost.
- ~5 new functions in `model.ex`; ~30–40 callsite edits across consumer files.

## Dependencies

- None. The struct already exists. `struct!/2` is a built-in.

## Confidence

Medium. `struct!/2` is a well-established Elixir idiom for typed multi-field
updates; the accessor pattern is common in larger Elixir codebases. Confidence
would be raised by confirming that Dialyzer propagates `Model.t()` through
`Model.update/2` without losing type information (depends on Dialyzer's
structural inference for `struct!/2`).

## Prior art / references

- Elixir `struct!/2` documentation — raises `KeyError` for unknown keys, unlike
  `Map.merge`.
- Pattern used in `Phoenix.Socket` (accessor functions for socket state, not raw
  map access, to keep defaults centralized).
- Elixir Forum discussion on "typed struct accessors" — common recommendation to
  co-locate defaults with the struct constructor.
