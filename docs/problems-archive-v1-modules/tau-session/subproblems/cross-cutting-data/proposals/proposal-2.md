---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Introduce typed accessor functions in Data to replace dynamic-key access

## Approach

Keep the existing `defstruct` unchanged. Extract all dynamic-map-key access
patterns that reference `Tau.Session.Data` fields into typed accessor and
updater functions on `Tau.Session.Data` itself, so that no sub-module ever
calls `Map.get/3` or `Map.put/3` on the `data` struct. Concretely:

1. Add `Data.get_queue/2 :: (t(), :steering | :followup) -> :queue.queue()` and
   `Data.put_queue/3 :: (t(), :steering | :followup, :queue.queue()) -> t()` to
   `data.ex`, replacing the dynamic dispatch currently in `queue.ex:enqueue/4`.
2. Add `Data.replace_field/3 :: (t(), atom(), term()) -> t()` that wraps
   `struct!(data, [{key, value}])`, replacing `provider_turn.ex:maybe_replace/3`.
3. Replace `Map.get(data, :persona_lifetime, :turn)` in `provider_turn.ex:337`
   with `data.persona_lifetime` (identical to Proposal 1 for this one callsite).
4. Update callers in `queue.ex` and `provider_turn.ex` to call the new
   `Data.*` functions.

The dynamic-key dispatch is not eliminated — it is moved into `Data` where it
is co-located with the struct definition and can be documented and typed.

## Rationale

The complecting hypothesis identifies the field contract as complected with
each sub-module. By moving dynamic field access into `Data`, the struct becomes
the single owner of its own field-access contract: sub-modules deal only in
named, typed functions, not in runtime atom keys. This is the "localise the
contract to its owner" decomplecting move. `queue.ex` currently knows that
`data` has two queue fields with specific names — that knowledge belongs in
`Data`. `provider_turn.ex:maybe_replace/3` knows the struct accepts dynamic
key updates — that should be a `Data`-level decision. Co-locating accessor
logic in `Data` also makes it possible to annotate each accessor's return type
precisely, giving Dialyzer its best chance at coverage.

## Sketch

```elixir
# lib/tau/session/data.ex — new accessors

@doc "Return the queue for `tier` (:steering or :followup)."
@spec get_queue(t(), :steering | :followup) :: :queue.queue()
def get_queue(%__MODULE__{steering_queue: q}, :steering), do: q
def get_queue(%__MODULE__{followup_queue: q}, _),          do: q

@doc "Replace the queue for `tier` with `new_queue`."
@spec put_queue(t(), :steering | :followup, :queue.queue()) :: t()
def put_queue(%__MODULE__{} = data, :steering, q), do: %{data | steering_queue: q}
def put_queue(%__MODULE__{} = data, _,          q), do: %{data | followup_queue: q}

@doc """
Replace field `key` with `value`. Raises `KeyError` on unknown key.
Intended for use only by sub-modules with a runtime-determined key;
prefer dot-access where the key is statically known.
"""
@spec replace_field(t(), atom(), term()) :: t()
def replace_field(%__MODULE__{} = data, key, value), do: struct!(data, [{key, value}])
```

```elixir
# lib/tau/session/queue.ex — updated enqueue/4 (no Map.get/Map.put)
def enqueue(%Tau.Session.Data{} = data, msg, tier, from_state) do
  queue = Tau.Session.Data.get_queue(data, tier)
  queue_size = :queue.len(queue)

  if queue_size >= @queue_cap do
    # ... cap branch unchanged ...
  else
    new_data = Tau.Session.Data.put_queue(data, tier, :queue.in(msg, queue))
    {:keep_state, new_data}
  end
end
```

```elixir
# lib/tau/session/provider_turn.ex — updated maybe_replace/3
@spec maybe_replace(Tau.Session.Data.t(), atom(), term()) :: Tau.Session.Data.t()
def maybe_replace(data, _key, nil), do: data
def maybe_replace(data, key, value), do: Tau.Session.Data.replace_field(data, key, value)
```

File touches: `lib/tau/session/data.ex` (additions), `lib/tau/session/queue.ex`
(~5 line change), `lib/tau/session/provider_turn.ex` (~2 line change).

## Tradeoffs

### Strengths

- Field-access contract is fully owned by `Data`; no sub-module needs to know
  the runtime field name of either queue.
- `get_queue/2` and `put_queue/3` are fully typed with pattern-matched clauses;
  Dialyzer can verify they return `:queue.queue()` and `t()` respectively.
- `replace_field/3` is the single, documented, runtime-dispatch escape hatch;
  its use is easy to audit with a single grep.
- Minimal churn — total diff is ~25 lines across three files.
- Accessor test coverage can be added to `data_test.exs` without touching the
  FSM integration tests.

### Weaknesses

- `replace_field/3` still uses `struct!/2` with a runtime key; Dialyzer cannot
  verify that `key` is a valid struct field name from the call-site in
  `provider_turn.ex`. The benefit is that the weakness is now contained inside
  `Data`, not scattered across sub-modules.
- Adds public API surface to `Data` (three functions). If the field names change,
  the accessors must be updated alongside — two places instead of one. This is
  the expected tradeoff for indirection, but it is a real cost.
- `maybe_replace/3` in `provider_turn.ex` becomes a thin one-liner delegating
  to `Data.replace_field/3`; it could be inlined, but that would scatter the
  dynamic-dispatch call back into `provider_turn.ex`.

### Costs

- ~25 lines added/changed across three files.
- New public functions on `Data` expand the module's surface — minimal but
  non-zero documentation burden.
- No migration cost for callers: both changed functions (`enqueue/4`,
  `maybe_replace/3`) have stable signatures; only their internals change.

## Dependencies

- `Tau.Session.Data` struct already in place (no prerequisite).
- No other modules or PRs required before this.

## Confidence

High. The accessor pattern is a standard Elixir idiom for struct field
encapsulation. The typed pattern-matched clauses in `get_queue/2` and
`put_queue/3` are straightforward to implement and verify. `struct!/2` is
well-established for the escape hatch.

## Prior art / references

- Elixir `Kernel.struct!/2` documentation.
- `Tau.Session.Meta` in `session.ex` — already a typed struct with no external
  map-key access; the same encapsulation principle applied here.
- `lib/tau/session/model_swap.ex:maybe_replace/3` — the naming and purpose are
  identical to `provider_turn.ex:maybe_replace/3`; they could be unified, but
  that is a separate concern.
