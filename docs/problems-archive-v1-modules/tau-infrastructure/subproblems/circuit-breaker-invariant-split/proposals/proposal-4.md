---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Merge Store.bump_* and State.record_* into a single atomic operation (unification)

## Approach

Replace the two-step pattern (Store bumps the counter; façade reads the row;
façade reconstructs a struct; State decides the transition) with a single
`Store.bump_and_decide/3` function that performs the `:ets.update_counter/3`
bump, reads the row in the same ETS call sequence, and returns a `{new_count,
state_decision}` tuple by inlining the State threshold logic inline. The façade
`record_outcome/5` receives a ready-made decision and calls `maybe_transition/3`
directly. `State.record_failure/2` and `State.record_success/2` remain as pure
functions for testing and documentation, but the façade no longer calls them
during normal operation. Promote `cooldown_ms` to a keyword opt on
`Store.bump_and_decide/3` (and on `State.check/3` for consistency).

## Rationale

The `new_count - 1` adjustment exists because two separately-owned modules share
a counter protocol across a layer boundary, with the façade bridging them. A
deeper fix is to ask: does this boundary need to exist? The façade's
`record_outcome/5` performs three distinct steps — bump, read-row, decide — that
are currently in three separate locations. Unifying bump + decide in `Store`
eliminates the boundary entirely: `Store` already owns the ETS row and its
counter columns; it can apply the threshold logic inline without reconstructing a
struct. The `State` module becomes documentation-only for the threshold rules
rather than a runtime call site, decomplecting "what is the decision algorithm"
(State) from "executing the decision" (Store, which owns the mutable data).

## Sketch

**`lib/tau/circuit_breaker/store.ex`** — add `bump_and_decide/3`:

```elixir
@type bump_decision :: :no_transition | {:transition, State.state_atom()}

@doc """
Atomically bumps the failure or success counter for `provider`, reads the
updated row, and applies the State threshold logic to return a transition
decision.

Returns `{new_count, :no_transition}` or `{new_count, {:transition, new_state}}`.

Opts:
  - `:failure_threshold` (default 5)
  - `:success_threshold` (default 1)
  - `:now_ms` (required; used when transitioning to :open)
  - `:cooldown_ms` (default 30_000; used by State.check/3 before probing)
"""
@spec bump_and_decide(module(), :failure | :success, keyword()) ::
        {non_neg_integer(), bump_decision()}
def bump_and_decide(provider, kind, opts) do
  {counter_pos, threshold_key, default_threshold} =
    case kind do
      :failure -> {3, :failure_threshold, 5}
      :success -> {4, :success_threshold, 1}
    end

  new_count = :ets.update_counter(@table, provider, {counter_pos, 1})
  threshold = Keyword.get(opts, threshold_key, default_threshold)
  row = get(provider)

  decision =
    if new_count >= threshold do
      new_state_atom = if kind == :failure, do: :open, else: :closed
      {:transition, new_state_atom}
    else
      :no_transition
    end

  {new_count, decision}
end
```

**`lib/tau/circuit_breaker.ex`** — `record_outcome/5` becomes:

```elixir
defp record_outcome(provider, current_state, {:ok, _}, now_ms, opts) do
  {_count, decision} = Store.bump_and_decide(provider, :success, Keyword.put(opts, :now_ms, now_ms))
  case decision do
    :no_transition -> :ok
    {:transition, new_state_atom} -> maybe_transition(provider, current_state, new_state_atom)
  end
end

defp record_outcome(provider, current_state, {:error, _}, now_ms, opts) do
  {_count, decision} = Store.bump_and_decide(provider, :failure, Keyword.put(opts, :now_ms, now_ms))
  case decision do
    :no_transition -> :ok
    {:transition, new_state_atom} -> maybe_transition(provider, current_state, new_state_atom)
  end
end
```

`State.record_failure/2` and `State.record_success/2` are retained as-is for
documentation and unit-testing the threshold logic in isolation. They are no
longer called by `record_outcome/5` in production.

**`State.check/2` → `check/3`**: `cooldown_ms` opt added (same as other
proposals).

D-044 row-layout impact: none. Counter column positions are unchanged;
`bump_and_decide/3` reads position 3/4 via `update_counter` as before.

## Tradeoffs

### Strengths

- The `new_count - 1` adjustment is gone with no arithmetic relocated; the
  boundary causing the impedance is closed.
- `record_outcome/5` is reduced to a bump + pattern match; its cognitive load
  drops substantially.
- `Store` is the natural owner of "bump + decide" since it already owns the
  ETS row and the counter primitives; the logic is co-located with the data.
- No changes to `State`'s existing public API — pure functions remain intact and
  testable independently.

### Weaknesses

- `Store` gains threshold-decision logic, which was previously cleanly separated
  into `State`. `Store` was a thin ETS wrapper; this proposal makes it a
  business-logic module. That is a scope expansion that may surprise maintainers
  who expect `Store` to be purely structural.
- `State.record_failure/2` and `record_success/2` are now dead code paths in
  production (called only by tests). This creates a latent divergence risk: the
  pure functions may drift from the inline threshold logic in `bump_and_decide/3`.
- The `:half_open` probe success logic is subtle (a single success closes the
  breaker from `:half_open`); inlining it in `bump_and_decide/3`'s `:success`
  arm must be done carefully and duplicates the `:half_open` guard already in
  `State.record_success/2`.
- `bump_and_decide/3` is harder to unit-test than the current split: it requires
  a live ETS table for every test case, whereas `State.record_failure/2` is a
  pure function. Tests must set up and tear down ETS state, raising test surface
  complexity.
- This is the highest-scope change of the four proposals; it is not purely
  behaviour-preserving if the inlined threshold logic ever diverges from the
  `State` functions.

### Costs

- 3 files meaningfully modified: `store.ex` (add `bump_and_decide/3`),
  `circuit_breaker.ex` (simplify `record_outcome/5`), `state.ex` (doc update
  noting functions are production-retired).
- Existing `State` tests are unaffected; new tests for `bump_and_decide/3`
  require ETS setup.
- SPEC-CIRCUIT-BREAKER §4 must be amended to add `bump_and_decide/3` to Store's
  interface list and note the production-retired status of `record_failure/2` /
  `record_success/2`.
- Higher review burden than Proposals 1–3 due to inlining `:half_open` guard logic.

## Dependencies

- No other subproblem needs to land first.
- SPEC-CIRCUIT-BREAKER §4 must be amended in the same PR.
- The inlined `:half_open` guard logic must be verified to be equivalent to
  `State.record_success/2`'s `:half_open` clause before the PR can be gated.

## Confidence

Medium-low. The unification idea is sound but the scope expansion of `Store` and
the risk of divergence between inlined and pure-function logic reduce confidence.
Confidence would rise to medium after prototyping `bump_and_decide/3` and
running the full test suite with both `State.record_*/2` (for pure tests) and
`bump_and_decide/3` (for integration tests) side by side.

## Prior art / references

- The "merge data + decision" pattern is common in ETS-backed rate-limiters
  (e.g., `ExRated`), where the ETS write and the decision to allow/deny are a
  single `:ets.update_counter/3` call with a threshold reset.
- `SPEC-CIRCUIT-BREAKER.md` §4 B4 — existing Store and State interface
  contracts; both must be amended.
- Proposal 3 (sibling) is the behaviour-preserving alternative; this proposal
  is the highest-scope option on the unification axis.
