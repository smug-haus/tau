---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Remove remaining defensive reads; keep existing struct as-is

## Approach

`Tau.Session.Data` already exports a `defstruct`, `@enforce_keys`, and
`@type t :: %__MODULE__{}`, and `Data.new/1` already returns `{:ok,
%Tau.Session.Data{}}`. The acceptance criterion is therefore mostly satisfied by
the existing code. This proposal closes the remaining gaps with minimal
surgical edits:

1. Replace `Map.get(data, :persona_lifetime, :turn)` in
   `provider_turn.ex:337` with `data.persona_lifetime` — the struct
   guarantees the field is always present.
2. Replace the dynamic-key `Map.get(data, queue_field)` and
   `Map.put(data, queue_field, new_queue)` in `queue.ex:enqueue/4` with
   explicit `case` branches that destructure and reconstruct
   `%Tau.Session.Data{}` by name.
3. Replace `Map.put(data, key, value)` in `provider_turn.ex:maybe_replace/3`
   with `struct!(data, [{key, value}])` — preserves the dynamic-key idiom
   while asserting the key exists in the struct (raises `KeyError` on unknown
   fields, giving Dialyzer a tighter type).
4. Add `%Tau.Session.Data{}` struct-match guards to the two public function
   heads in `queue.ex` and to `provider_turn.ex:179` that currently receive
   bare `data` with no type annotation at the pattern level.

No module is added or removed; no field is renamed.

## Rationale

The problem statement's complecting hypothesis has already been partially
resolved: the struct, enforce_keys, and type spec exist. The remaining gaps
are three callsites where sub-modules treat the struct as a plain map. This
proposal addresses exactly those three callsites without any structural
reorganisation. The defensive `Map.get(data, :persona_lifetime, :turn)` is
dead-code noise — the struct default is `:turn` and `@enforce_keys` does not
include it, so nil cannot appear. Removing the default signals that the
contract is now statically enforced. The queue dynamic-key pattern is the
only legitimate holdout: it dispatches on a runtime-selected field, which is
not naturally expressible with dot-access; replacing it with explicit branches
makes the field access visible to Dialyzer and eliminates silent fallback to
`nil`.

## Sketch

```elixir
# queue.ex — replace Map.get/Map.put dispatch with explicit branches
def enqueue(%Tau.Session.Data{} = data, msg, tier, from_state) do
  {queue, tier_atom} =
    case tier do
      :steering -> {data.steering_queue, :steering}
      _         -> {data.followup_queue, :followup}
    end

  if :queue.len(queue) >= @queue_cap do
    # ... existing cap branch unchanged ...
    {:keep_state_and_data, []}
  else
    new_queue = :queue.in(msg, queue)
    new_data =
      case tier do
        :steering -> %{data | steering_queue: new_queue}
        _         -> %{data | followup_queue: new_queue}
      end
    {:keep_state, new_data}
  end
end

# provider_turn.ex:337 — remove defensive default
if msg.stop_reason == :end_turn and data.persona_lifetime == :turn do

# provider_turn.ex:179 — use struct!/2 for dynamic-key update
def maybe_replace(data, _key, nil), do: data
def maybe_replace(%Tau.Session.Data{} = data, key, value),
  do: struct!(data, [{key, value}])
```

File touches: `lib/tau/session/queue.ex`, `lib/tau/session/provider_turn.ex`.

## Tradeoffs

### Strengths

- Minimal diff: two files, ~10 changed lines; reviewable in one pass.
- No new modules, no API changes, no test rewrites.
- Eliminates the only remaining `Map.get(data, :field, default)` defensive
  read that the struct now makes superfluous (`persona_lifetime`).
- `struct!/2` in `maybe_replace/3` raises on unknown field names, converting
  a silent runtime bug into a fast-fail crash — aligns with "let it crash".
- Fully satisfies the acceptance criterion as written.

### Weaknesses

- Does not address `coding_agent_turn.ex:112` / `coding_agent_turn.ex:504`
  (`Map.get(data.coding_agent_state, :session_id)`), which are reads into
  the nested `coding_agent_state` map, not into the `Data` struct itself.
  The problem statement's acceptance criterion is silent on nested maps, but
  a reader doing a grep for `Map.get(data` will still find them.
- `maybe_replace/3` with `struct!/2` still uses runtime key dispatch; Dialyzer
  cannot verify that `key` names an existing field. The type spec remains
  `atom()` for `key`, which is weaker than a union of field-name literals.
- The `case tier` duplication in `enqueue/4` (once for the read, once for
  the write) is mild redundancy introduced by eliminating the dynamic key.

### Costs

- Estimated diff: ~15 lines changed across two files.
- No migration cost: the public API of neither module changes.
- Test surface: no test changes required; the struct has been in place since
  a prior PR; these edits only tighten existing callsites.

## Dependencies

- `Tau.Session.Data` must export `defstruct` and `@type t` (already done).
- No other changes required first.

## Confidence

High. The changes are mechanical and local; the struct already exists; the
three callsites are straightforwardly identified. Prior art: the
`compaction.ex` and `model_swap.ex` sub-modules already use `data.field`
notation exclusively with no `Map.get` reads, confirming the pattern is
already established in the project.

## Prior art / references

- `lib/tau/session/compaction.ex` — uses `data.field` exclusively; exemplar.
- `lib/tau/session/model_swap.ex` — uses `data.field` and struct-update
  syntax exclusively; exemplar.
- Elixir docs: `Kernel.struct!/2` — raises on unknown key.
