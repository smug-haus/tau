---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Typed sub-structs replace `map()` fields — decompose `Model.t()` into composable domain structs

## Approach

Several fields of `Model.t()` that are currently typed as `map()` or `nil | map()`
(`usage`, `search`, `menu`) are accessed by consumers via `Map.get/3` because
their shapes are not typed. Introduce named structs for each of these field types
(`Model.Usage.t()`, `Model.Search.t()`, `Model.Menu.t()`), replace the
corresponding `map()` type annotations in `Model.t()` with the new struct types,
and update callsites to use struct field access throughout. Consumer `@spec`
annotations change from `map()` to `Model.t()`. This is an API-breaking data
shape change, not a callsite-only cleanup.

## Rationale

The `Map.get/3` calls in `View.status_bar_model/1` and `Events.on_message_end/2`
are not only a callsite discipline failure — they reflect genuinely untyped
sub-shapes within `Model.t()`. When `usage` is typed as `map()`, consumers have
no choice but to use `Map.get`; when it is `Model.Usage.t()` with enforced keys,
the compiler rejects `Map.get`. This proposal attacks the root cause (missing
type discipline on nested fields) rather than only its surface symptom (consumers
using `Map.get`). After the change, `Map.get` cannot be reintroduced without
breaking Dialyzer.

## Sketch

**New modules** (three small structs):

```elixir
# lib/tau/tui/app/model/usage.ex
defmodule Tau.TUI.App.Model.Usage do
  @enforce_keys [:input_tokens, :output_tokens, :cache_read, :cache_write]
  defstruct [:input_tokens, :output_tokens, :cache_read, :cache_write]

  @type t :: %__MODULE__{
    input_tokens: non_neg_integer(),
    output_tokens: non_neg_integer(),
    cache_read: non_neg_integer(),
    cache_write: non_neg_integer()
  }

  @spec zero() :: t()
  def zero, do: %__MODULE__{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0}
end

# lib/tau/tui/app/model/search.ex
defmodule Tau.TUI.App.Model.Search do
  @enforce_keys [:query, :search_index]
  defstruct [:query, :search_index]

  @type t :: %__MODULE__{query: String.t(), search_index: non_neg_integer()}
end

# lib/tau/tui/app/model/menu.ex
defmodule Tau.TUI.App.Model.Menu do
  # shape TBD from completion.ex usage — proposal commits to extracting whatever
  # shape the completion sub-module relies on
  @enforce_keys [:items, :selected]
  defstruct [:items, :selected]
  @type t :: %__MODULE__{items: [map()], selected: non_neg_integer()}
end
```

**Updated `Model.t()` type** (model.ex):

```elixir
@type t :: %__MODULE__{
  # ... unchanged fields ...
  usage: Model.Usage.t(),
  search: nil | Model.Search.t(),
  menu: nil | Model.Menu.t(),
  # ...
}
```

**Updated `Model.new/1`**:

```elixir
usage: Model.Usage.zero(),
search: nil,
menu: nil,
```

**Updated `View.status_bar_model/1`**:

```elixir
@spec status_bar_model(Model.t()) :: map()
def status_bar_model(model) do
  %{
    usage: model.usage,            # Model.Usage.t() — StatusBar already accepts map
    context_tokens: model.context_tokens,
    ...
  }
end
```

**Updated `Events.on_message_end/2`**:

```elixir
# Before: Map.get(model, :warn_level, :ok)
# After:  model.warn_level   (unchanged — warn_level is already a typed field)

# cost_for_session now returns a Model.Usage.t() instead of a plain map
# (requires updating Tau.Cost.for_session/1 return type — see Dependencies)
```

**File moves**:
- `lib/tau/tui/app/model/usage.ex` (new)
- `lib/tau/tui/app/model/search.ex` (new)
- `lib/tau/tui/app/model/menu.ex` (new)

## Tradeoffs

### Strengths

- Makes `Map.get` structurally impossible for typed sub-fields; Dialyzer flags
  it as a type error rather than a style warning.
- Aligns `Model.t()` field types with the Elixir idiom for typed data: structs
  with `@enforce_keys`, not anonymous maps.
- `Model.Usage.zero()` replaces the in-line `%{input_tokens: 0, ...}` literal
  duplicated in `Model.new/1` and `events.ex:266` — single source for the zero
  value.
- The sub-structs are independently testable and documentable.

### Weaknesses

- API-breaking: any code that constructs a `%{input_tokens: ..., output_tokens:
  ...}` plain map and assigns it to `model.usage` (e.g., test fixtures, the
  `cost_for_session` helper) must be updated to use `%Model.Usage{...}`.
- The `menu` sub-struct's shape must be reverse-engineered from `Completion`
  module usage before the struct can be defined — the problem statement does not
  inventory the `menu` map's keys, so the sketch above is a placeholder.
- `StatusBar.render/1` currently accepts a plain `map()` for `usage`; changing
  to `Model.Usage.t()` may require updating `StatusBar` as well (a module outside
  the nominal scope of this problem).
- Three new files increases the module count and the `alias` surface in consumer
  files.
- Larger diff than Proposals 1 and 2; harder to review atomically.

### Costs

- Three new struct modules (~15–20 lines each).
- Update `Model.t()` type spec (3 field type changes).
- Update `Model.new/1` (3 constructor expressions).
- Update `Tau.Cost.for_session/1` return type and all callers that unpack the
  plain map — at minimum `events.ex`.
- Update all test fixtures that build a `%{input_tokens: ...}` map to build
  `%Model.Usage{...}` instead.
- Reverse-engineer and lock down the `menu` map shape from `Completion` module
  before writing `Model.Menu.t()`.
- Estimated: largest diff of the four proposals; 2–3x the edit count of
  Proposal 1 due to cascading type updates.

## Dependencies

- `Tau.Cost.for_session/1` return type must change from `map()` to
  `Model.Usage.t()` (or a compatible map that `struct!/2` can accept).
- `Completion` module's menu shape must be audited to define `Model.Menu.t()`
  correctly — a read-only exploration pass is needed first.
- `StatusBar.render/1` may need a type annotation update if it pattern-matches
  on `usage` as a plain map.

## Confidence

Low-medium. The struct-extraction pattern is sound but the cascading type update
cost is underspecified — `menu` and `search` shapes are not fully inventoried in
the problem statement. Confidence would increase after auditing `completion.ex`
and `history.ex` to confirm the concrete field sets.

## Prior art / references

- Elixir struct documentation — recommended pattern for typed nested data.
- Phoenix `%Plug.Conn{}` with sub-structs (e.g., `conn.private`, `conn.params`)
  — demonstrates that nested anonymous maps eventually get promoted to structs as
  type discipline matters.
- Ecto `%Ecto.Changeset{}` sub-field structs — same pattern at the ORM layer.
