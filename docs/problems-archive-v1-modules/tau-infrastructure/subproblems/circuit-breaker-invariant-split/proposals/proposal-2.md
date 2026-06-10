---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: State accepts post-increment counts (State API change)

## Approach

Change `State.record_failure/2` and `State.record_success/2` to accept the
**post-increment** count directly, removing the `count + 1` arithmetic from
inside those functions. The façade `record_outcome/5` then passes
`Store.bump_*/1`'s return value directly into the struct field — no adjustment
needed. Promote `cooldown_ms` to a keyword opt in `State.check/2` with the
existing `@default_cooldown_ms` as the fallback. `State` is the changed contract;
`Store` is unchanged.

## Rationale

The root problem is that `State.record_failure/2` encodes a `count + 1`
increment internally while simultaneously receiving a pre-increment count from
its caller. That duality forces the façade to subtract 1 from Store's
post-increment result. If `State` is respecified so its functions receive the
**post-increment** count directly (the actual failure count after this event),
the façade can simply pass through `new_count = Store.bump_failure_count(provider)`
without any adjustment. The `State` module's semantics become: "I have been
handed the new count; decide what transition to make" — a simpler contract that
doesn't imply any knowledge of who performed the increment. This moves the
protocol boundary into `State` rather than the façade, which is the cleaner
owner: State owns the count semantics.

## Sketch

**`lib/tau/circuit_breaker/state.ex`** — `record_failure/2` and
`record_success/2` receive the post-increment count directly:

```elixir
@doc """
Records a provider-call failure and returns the updated state.

`new_failure_count` is the post-increment count (as returned by
`Store.bump_failure_count/1`). The function does NOT increment internally.
"""
@spec record_failure(t(), keyword()) :: t()
def record_failure(state, opts \\ [])

def record_failure(%__MODULE__{state: :closed} = s, opts) do
  threshold = Keyword.get(opts, :failure_threshold, @default_failure_threshold)
  # new_count is now the caller-supplied post-increment value stored in s.failure_count
  new_count = s.failure_count  # no +1; caller already holds post-bump value

  if new_count >= threshold do
    now_ms = Keyword.fetch!(opts, :now_ms)
    %__MODULE__{s | state: :open, failure_count: new_count, success_count: 0, opened_at_ms: now_ms}
  else
    s  # struct already has new_count in failure_count; no update needed
  end
end
```

The same pattern applies to `record_failure/2` in `:half_open` and to
`record_success/2`.

**`lib/tau/circuit_breaker.ex`** — `record_outcome/5` simplifies to:

```elixir
defp record_outcome(provider, current_state, {:error, _}, now_ms, opts) do
  new_count = Store.bump_failure_count(provider)
  row = current_struct(provider)
  # Pass post-increment count directly; no adjustment
  struct_post_bump = %State{row | failure_count: new_count}
  new_state = State.record_failure(struct_post_bump, Keyword.put(opts, :now_ms, now_ms))
  maybe_transition(provider, current_state, new_state)
end
```

**`State.check/2`** gains `cooldown_ms` opt (same as Proposal 1's `check/3`
sketch; omitted here for brevity).

D-044 row-layout impact: none. ETS counter columns and their positions are
unchanged. The adjustment was purely in-memory arithmetic; the stored value
(post-increment) is what it always was.

Existing struct construction in `current_struct/1` in the façade is unaffected:
it reads directly from ETS and already produces the post-increment count in
the field — the façade was subtracting 1 only to "undo" that, which will no
longer be needed.

## Tradeoffs

### Strengths

- `State` functions become semantically simpler: "given the new count, decide".
  No hidden `+1` inside the module.
- `Store.bump_*/1` API is unchanged; any caller of Store is unaffected.
- The façade's `record_outcome/5` simplifies: direct pass-through from Store to
  State, no arithmetic.
- The intent is self-documenting: `struct_post_bump = %State{row | failure_count: new_count}`
  makes the data flow obvious.
- `cooldown_ms` promotion resolves the asymmetric configurability.

### Weaknesses

- `State.record_failure/2` and `State.record_success/2` have subtly different
  semantics post-change: the struct field `failure_count` on entry now holds the
  post-increment value, not a pre-increment value. Any test that constructs a
  `%State{}` by hand and calls `record_failure/2` must be updated to pass the
  value that would be *after* a bump — a semantic break.
- The in-memory `s` struct returned has `failure_count: new_count` whether or
  not the threshold is crossed — meaning the `else` branch's `s` now has
  post-increment in the field, which is actually correct, but is a silent
  semantic shift that tests must cover explicitly.
- `State.record_failure/2`'s `@moduledoc` must be updated to clarify the
  "post-increment" contract; a reader who skips the doc and sees `new_count =
  s.failure_count` without the `+ 1` may be confused.
- More test churn than Proposal 1, since State tests typically construct structs
  with pre-bump field values to test threshold logic.

### Costs

- 2 files modified: `state.ex` (2–3 function bodies + moduledoc), `circuit_breaker.ex`
  (2 private clauses + comment).
- All tests that call `State.record_failure/2` or `record_success/2` with
  hand-constructed structs must be audited — the struct field semantics change.
- SPEC-CIRCUIT-BREAKER §4 B4 must be amended to document the new "post-increment
  input" contract for these functions.

## Dependencies

- No other subproblem needs to land first.
- SPEC-CIRCUIT-BREAKER §4 B4 must be amended in the same PR.

## Confidence

Medium. The arithmetic shift is small but the semantic change to `State`'s
pure-function contract is non-trivial; test suite coverage of `State` is the
determining factor. Confidence would rise to high after confirming the test
suite constructs `%State{}` structs with explicit `failure_count` values (rather
than relying on defaults) and that changing the expected value is straightforward.

## Prior art / references

- Erlang `:ets.update_counter/3` returns the post-increment value by design;
  accepting it directly is idiomatic in ETS-backed state machines.
- `SPEC-CIRCUIT-BREAKER.md` §4 B4 — the pure-state-machine contract that
  `record_failure/2` implements.
- Proposal 1 (this file's sibling) takes the opposite axis: changing Store
  instead of State.
