---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Encode the impedance in a typed converter function (thin façade within State)

## Approach

Leave `Store.bump_*/1` returning post-increment and leave `State.record_failure/2`
accepting pre-increment struct values. Instead, add a single named conversion
function — `State.from_bump/2` — that encapsulates the `new_count - 1` adjustment
and the struct rebuild in one place. `record_outcome/5` in the façade calls
`State.from_bump(row, new_count)` to produce the pre-bump struct, then passes
the result to `record_failure/2` / `record_success/2`. The adjustment is no
longer anonymous arithmetic in the façade; it is a named, typed, testable
operation inside the module that owns the struct. Promote `cooldown_ms` to a
keyword opt in `State.check/2`.

## Rationale

Both Proposals 1 and 2 change the semantics of an existing API contract — one
on the Store side, one on the State side — which requires updating the SPEC and
all tests that depend on those APIs. Proposal 3 takes a different axis:
behaviour-preserving refactor. Neither Store's return convention nor State's
`record_failure/2` contract changes. Instead, the knowledge that "a Store bump
returns post-increment and State needs pre-increment" is isolated in a named
function that can be read, documented, and tested in isolation. The façade stops
doing private arithmetic and delegates to `State.from_bump/2`, which is the
module that owns the struct and therefore the natural home for "how to construct
a pre-bump struct from a post-bump count."

## Sketch

**`lib/tau/circuit_breaker/state.ex`** — add `from_bump/3`:

```elixir
@doc """
Constructs a `%State{}` ready to pass to `record_failure/2` or `record_success/2`
from a Store row and a post-increment counter value returned by
`Store.bump_failure_count/1` or `Store.bump_success_count/1`.

The Store's `:ets.update_counter/3` primitive returns the post-increment value.
`record_failure/2` and `record_success/2` both perform `count + 1` internally
and therefore expect the pre-increment count in the struct field. This function
converts between the two conventions once, in the place that owns the struct
semantics.

  iex> Tau.CircuitBreaker.State.from_bump(%State{failure_count: 3}, :failure, 4)
  %State{failure_count: 3}
"""
@spec from_bump(t(), :failure | :success, pos_integer()) :: t()
def from_bump(%__MODULE__{} = state, :failure, post_increment_count) do
  %__MODULE__{state | failure_count: post_increment_count - 1}
end

def from_bump(%__MODULE__{} = state, :success, post_increment_count) do
  %__MODULE__{state | success_count: post_increment_count - 1}
end
```

**`lib/tau/circuit_breaker.ex`** — `record_outcome/5` becomes:

```elixir
defp record_outcome(provider, current_state, {:ok, _}, now_ms, opts) do
  new_count = Store.bump_success_count(provider)
  row = current_struct(provider)
  struct_pre_bump = State.from_bump(row, :success, new_count)
  new_state = State.record_success(struct_pre_bump, Keyword.put(opts, :now_ms, now_ms))
  maybe_transition(provider, current_state, new_state)
end

defp record_outcome(provider, current_state, {:error, _}, now_ms, opts) do
  new_count = Store.bump_failure_count(provider)
  row = current_struct(provider)
  struct_pre_bump = State.from_bump(row, :failure, new_count)
  new_state = State.record_failure(struct_pre_bump, Keyword.put(opts, :now_ms, now_ms))
  maybe_transition(provider, current_state, new_state)
end
```

The façade's comment block at lines 116–123 is removed; the explanation belongs
in `State.from_bump/3`'s `@doc`. The façade no longer needs to know the
convention.

**`State.check/2` → `check/3`**: same as Proposals 1 and 2; `cooldown_ms` added
as a keyword opt with `@default_cooldown_ms` fallback.

D-044 row-layout impact: none. No counter column semantics change.

## Tradeoffs

### Strengths

- Both `Store` and `State.record_failure/2`/`record_success/2` contracts are
  unchanged; zero test churn on the Store side, zero test churn on the State
  side for existing callers.
- The conversion logic becomes named (`from_bump/3`), documented (`@doc`),
  testable (a simple property: `from_bump(s, :failure, n).failure_count == n - 1`),
  and owned by the correct module (`State` owns the struct).
- Behaviour-preserving: no semantic change to any existing public function.
- SPEC amendment is additive (add `from_bump/3` to §4 B4 interface list); no
  existing contract row needs rewriting.
- The façade's private helper comment becomes dead weight and is deleted cleanly.

### Weaknesses

- The `new_count - 1` arithmetic is not eliminated; it is relocated. A reviewer
  reading `State.from_bump/3` still sees the subtraction. The problem is made
  explicit but not absent.
- `from_bump/3` is a narrow adapter function with limited reuse value outside
  the façade — it may feel like over-engineering for what is essentially a
  one-line conversion.
- Adds a function to the `State` module whose sole purpose is to paper over an
  impedance mismatch; if the mismatch is ever fixed at the Store or State level
  (Proposals 1 or 2), `from_bump/3` becomes dead code.
- The `:failure | :success` atom discriminator in `from_bump/3` is a mild form
  of stringly-typed dispatch; a future developer could call it with the wrong
  atom and the compiler won't catch it until runtime if the struct is well-typed.

### Costs

- 1 file meaningfully modified: `state.ex` (add 1 function + @doc). `circuit_breaker.ex`
  is a 2-line mechanical change (replace anonymous adjustment with named call).
- No test churn on existing `State` or `Store` tests.
- SPEC-CIRCUIT-BREAKER §4 B4: additive amendment (1 new function entry).
- Net change is small: ~20 lines added, ~5 removed.

## Dependencies

- No other subproblem needs to land first.
- SPEC-CIRCUIT-BREAKER §4 B4 must be amended to add `from_bump/3` to the
  interface table.

## Confidence

High. The change is purely additive and behaviour-preserving. The arithmetic
is unchanged; only its location and documentation change. No migration risk.
Confidence is supported by the fact that the existing comment in the façade
(lines 116–123) already explains the invariant that `from_bump/3` would encode;
the conversion is not new logic.

## Prior art / references

- The "adapter function" pattern for impedance mismatch between two well-owned
  modules — common in OTP codebases where ETS primitives and pure FSM modules
  have differing counter conventions.
- `SPEC-CIRCUIT-BREAKER.md` §4 B4 — the existing interface contract that
  `record_failure/2` and `record_success/2` live in.
- Proposal 1 and Proposal 2 (siblings) take the API-changing axis; this proposal
  is the behaviour-preserving alternative.
