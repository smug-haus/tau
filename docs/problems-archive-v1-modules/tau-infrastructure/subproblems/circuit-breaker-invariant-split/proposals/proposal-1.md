---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Store returns pre-increment counts (Store API change)

## Approach

Change `Store.bump_failure_count/1` and `Store.bump_success_count/1` to return
the **pre-increment** value — the count as it was before the atomic bump. Remove
the `new_count - 1` adjustment in `record_outcome/5` entirely; pass the returned
pre-increment value directly to `State.record_failure/2` and
`State.record_success/2` as `s.failure_count` / `s.success_count` in the struct.
Promote `cooldown_ms` to a caller-threadable keyword opt in `State.check/2` with
`@default_cooldown_ms` as the fallback.

## Rationale

The `new_count - 1` adjustment in the façade exists solely because Store returns
post-increment while State expects pre-increment as its struct field. The
adjustment is a hidden protocol: it encodes the Store's internal counter
convention in the façade's private logic. By making Store return the
pre-increment value (the value before the `:ets.update_counter/3` bump), the
façade can directly populate the struct field `failure_count: pre_count` and pass
it to `State.record_failure/2` without arithmetic. The two modules are
decomplected: Store's return semantics no longer need to be known outside Store.
Promoting `cooldown_ms` completes the pattern established by `failure_threshold`
and `success_threshold`, making the asymmetry visible.

## Sketch

**`lib/tau/circuit_breaker/store.ex`** — change both bump functions to use
`:ets.update_counter/3` with a three-element operation tuple that returns the
pre-increment value:

```elixir
@spec bump_failure_count(module()) :: non_neg_integer()
def bump_failure_count(provider) do
  # {position, increment, threshold, reset} — threshold=0 means "return old value"
  # Use update_counter with explicit operations list to capture pre-bump value:
  # [{pos, 1}] returns post-bump; to get pre-bump, subtract 1 is status quo.
  # Alternative: :ets.update_counter(@table, provider, [{3, 0}, {3, 1}])
  # The first op reads the current value; the second increments. Return the read.
  [pre, _post] = :ets.update_counter(@table, provider, [{3, 0}, {3, 1}])
  pre
end

@spec bump_success_count(module()) :: non_neg_integer()
def bump_success_count(provider) do
  [pre, _post] = :ets.update_counter(@table, provider, [{4, 0}, {4, 1}])
  pre
end
```

**`lib/tau/circuit_breaker.ex`** — `record_outcome/5` simplifies to:

```elixir
defp record_outcome(provider, current_state, {:ok, _}, now_ms, opts) do
  pre_count = Store.bump_success_count(provider)
  row = current_struct(provider)
  struct_pre_bump = %State{row | success_count: pre_count}
  new_state = State.record_success(struct_pre_bump, Keyword.put(opts, :now_ms, now_ms))
  maybe_transition(provider, current_state, new_state)
end

defp record_outcome(provider, current_state, {:error, _}, now_ms, opts) do
  pre_count = Store.bump_failure_count(provider)
  row = current_struct(provider)
  struct_pre_bump = %State{row | failure_count: pre_count}
  new_state = State.record_failure(struct_pre_bump, Keyword.put(opts, :now_ms, now_ms))
  maybe_transition(provider, current_state, new_state)
end
```

The comment block at lines 116–123 is removed; no workaround exists to document.

**`lib/tau/circuit_breaker/state.ex`** — `check/2` gains a `cooldown_ms` opt:

```elixir
@spec check(t(), non_neg_integer(), keyword()) :: state_atom()
def check(state, now_ms, opts \\ [])

def check(%__MODULE__{state: :closed}, _now_ms, _opts), do: :closed

def check(%__MODULE__{state: :open, opened_at_ms: opened_at_ms}, now_ms, opts) do
  cooldown_ms = Keyword.get(opts, :cooldown_ms, @default_cooldown_ms)
  if now_ms >= opened_at_ms + cooldown_ms, do: :half_open, else: :open
end

def check(%__MODULE__{state: :half_open}, _now_ms, _opts), do: :half_open
```

D-044 row-layout impact: none. Counter columns (positions 3 and 4) are not
renamed; the ETS schema is unchanged. The multi-operation `:ets.update_counter/3`
call reads and increments in a single atomic operation — no TOCTOU gap.

## Tradeoffs

### Strengths

- Eliminates the `new_count - 1` adjustment at the call site and the comment that
  explains it — the protocol leak is gone.
- No change to `State`'s function signatures or struct field semantics; State
  remains the pre-increment consumer it always was.
- `cooldown_ms` joins `failure_threshold` and `success_threshold` as a threadable
  opt; the asymmetry is resolved.
- The multi-op `update_counter` form is atomic — correct under concurrent bumps.
- D-044 row layout unchanged; no migration required.

### Weaknesses

- `Store.bump_*/1` now returns the pre-increment value, which is less intuitive
  for a function named "bump" (callers might expect the post-bump result).
- Two-op `update_counter` form `[{pos, 0}, {pos, 1}]` is less common and may
  surprise maintainers; the comment burden moves from the façade to the Store.
- Any other caller of `bump_*/1` that expected post-increment semantics (e.g. a
  test asserting `== 1` after the first bump) breaks silently at the type level
  — `@spec` returns the same type.
- `State.check/2` arity change to `/3` with a default opt is a spec amendment;
  any dialyzer-typed call site using the 2-arity form is unaffected (default
  opts = old behaviour), but the SPEC-CIRCUIT-BREAKER §4 B4 interface entry must
  be updated.

### Costs

- 2 files modified: `store.ex` (2 function bodies), `circuit_breaker.ex` (2
  private clauses + comment removal), `state.ex` (1 function head + 1 clause).
- All existing tests that call `Store.bump_*/1` and assert on the return value
  must be audited and updated.
- SPEC-CIRCUIT-BREAKER §4 must be amended to reflect the new Store return
  contract and the new `check/3` opt.

## Dependencies

- No other subproblem needs to land first.
- SPEC-CIRCUIT-BREAKER §4 B4 and the D-044 row-layout entry must be amended in
  the same PR.

## Confidence

Medium. The `:ets.update_counter/3` multi-op form is standard OTP; the
arithmetic is straightforward. Confidence would rise to high after verifying no
existing caller of `bump_*/1` relies on post-increment semantics in its
assertions (a quick `grep` suffices).

## Prior art / references

- OTP `:ets.update_counter/3` multi-op form: https://www.erlang.org/doc/man/ets.html#update_counter-3
- `SPEC-CIRCUIT-BREAKER.md` D-044 (ETS row layout pinned by SPEC)
- The existing comment at `lib/tau/circuit_breaker.ex:116–123` documents the
  exact arithmetic mismatch this proposal resolves.
