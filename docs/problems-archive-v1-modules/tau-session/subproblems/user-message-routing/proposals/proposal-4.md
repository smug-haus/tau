---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Data-shape change — introduce a %UserMessageDecision{} struct; session.ex pattern-matches on result

## Approach

Define a `%Tau.Session.UserMessageDecision{}` struct with a `phase` field
(`:postpone | :enqueue | :dispatch`) and phase-specific payload fields.
Add `Tau.Session.Queue.decide/4` which computes which phase applies and returns
a `%UserMessageDecision{}` — pure, no side effects. Add
`Tau.Session.Queue.execute_decision/2` which takes a `%UserMessageDecision{}`
and `data`, performs the side effects (telemetry, broadcast, enqueue,
classification, dispatch) and returns an FSM action tuple. The three
`handle_event` clauses in `session.ex` collapse into a single clause that calls
`Queue.decide/4 |> Queue.execute_decision(data)`. The six classify arms are
expressed in `execute_decision/2` via `SlashCommand.dispatch/2` (same as
Proposals 1 and 3).

## Rationale

The existing complecting is rooted in the absence of a type that represents "the
routing decision": the FSM clause bodies compute the decision and execute its
effects in the same expression. Introducing `%UserMessageDecision{}` separates
the decision (what should happen?) from the execution (do it). This is a
data-shape change rather than a control-flow extraction: `decide/4` is pure and
testable without FSM machinery; `execute_decision/2` owns all side effects and
can be independently tested with a fixed `%UserMessageDecision{}`. The struct
makes the three phases named and pattern-matchable, surfacing the routing
invariants in the type system rather than in implicit guards.

## Sketch

```elixir
# lib/tau/session/user_message_decision.ex — new struct
defmodule Tau.Session.UserMessageDecision do
  @moduledoc """
  The routing decision for a {:user_message} event.

  Computed by Queue.decide/4 (pure). Executed by Queue.execute_decision/2.
  """
  @type t ::
    %__MODULE__{phase: :postpone, from_state: atom()}
    | %__MODULE__{phase: :enqueue, tier: :steering | :followup, from_state: atom()}
    | %__MODULE__{phase: :dispatch, msg: Tau.Message.User.t(), from_state: atom()}

  defstruct [:phase, :tier, :msg, :from_state]
end
```

```elixir
# lib/tau/session/queue.ex — two new functions
alias Tau.Session.UserMessageDecision

@spec decide(Tau.Message.User.t(), :steering | atom(), atom(), Tau.Session.Data.t()) ::
        UserMessageDecision.t()
def decide(_msg, _tier, state, %{command_task: t}) when t != nil do
  %UserMessageDecision{phase: :postpone, from_state: state}
end
def decide(msg, tier, state, _data) when state != :awaiting_user do
  tier_atom = if tier == :steering, do: :steering, else: :followup
  %UserMessageDecision{phase: :enqueue, tier: tier_atom, from_state: state}
end
def decide(msg, _tier, :awaiting_user, _data) do
  %UserMessageDecision{phase: :dispatch, msg: msg, from_state: :awaiting_user}
end

@spec execute_decision(UserMessageDecision.t(), Tau.Session.Data.t()) ::
        Tau.Session.Data.fsm_result()
def execute_decision(%UserMessageDecision{phase: :postpone, from_state: state}, data) do
  handle_postpone(data, state)
end
def execute_decision(%UserMessageDecision{phase: :enqueue, tier: tier, from_state: state}, data) do
  enqueue(data, data[:pending_msg], tier, state)
  # Note: msg is threaded via data or via a wrapper; see cost note below
end
def execute_decision(%UserMessageDecision{phase: :dispatch, msg: msg}, data) do
  Tau.Session.emit_user_message_telemetry(:delivered, data, :awaiting_user)
  msg
  |> Tau.Session.SlashCommand.classify_slash_command(data.skills, data.prompt_templates, data.cwd)
  |> Tau.Session.SlashCommand.dispatch(data)
end
```

```elixir
# lib/tau/session.ex — single handle_event clause
def handle_event(:cast, {:user_message, msg, tier}, state, data) do
  data
  |> Queue.decide(msg, tier, state)
  |> Queue.execute_decision(data)
end
```

**Note on the `msg` threading problem.** `decide/4` returns a struct; the
`:enqueue` arm needs `msg` in `execute_decision/2`. Two clean options: (A)
include `msg` in every `%UserMessageDecision{}` variant — adds a field but
keeps the struct self-contained; (B) pass `msg` as a third argument to
`execute_decision/3`. Option A is shown here; either is valid.

## Tradeoffs

### Strengths

- `decide/4` is a pure function: testable with `assert Queue.decide(msg, :followup, :running, data) == %UserMessageDecision{phase: :enqueue, tier: :followup, from_state: :running}` — no FSM, no process, no side effects.
- The three routing phases are named in the type system; Dialyzer can verify
  that all three are handled in `execute_decision/2`.
- `session.ex` becomes a single 2-line `handle_event` clause — strictly
  exceeds the acceptance criterion.
- The struct is the natural home for documentation of the invariants (D-077,
  D-078, ADR-0008).
- Pattern-matching on `%UserMessageDecision{}` in `execute_decision/2` means
  future phase additions (e.g. `:reject` for a rate-limit phase) require only
  adding a new struct variant and a new `execute_decision` clause, with the
  compiler flagging unhandled variants.

### Weaknesses

- Adds a new struct module (`UserMessageDecision`) for a decision with only 3
  variants — this is more abstraction than the problem strictly requires.
- The `execute_decision/2` function is not meaningfully simpler than the
  original clause bodies: it still has three branches, one of which calls
  `SlashCommand.dispatch/2`. The struct adds a naming layer without compressing
  logic.
- The `msg` field must appear in every `%UserMessageDecision{}` variant (or
  `execute_decision` must take three args) — a mild ergonomic awkwardness since
  `:postpone` does not use `msg`.
- Requires `SlashCommand.dispatch/2` as a prerequisite (same new function as
  Proposals 1 and 3); not standalone.
- Two new modules (`UserMessageDecision` + changes to `Queue`) for a narrowly-
  scoped refactor of three clause bodies — the abstraction may outlive the
  problem it solves.

### Costs

- One new struct module, two new functions in `Queue`, one new function in
  `SlashCommand` (`dispatch/2`).
- `decide/4` is purely additive — no existing function signatures change.
- Property tests for `decide/4` are simple and high-value: generators for
  `(msg, tier, state, data)` tuples covering all three branches.
- PR touches: `session.ex`, new `user_message_decision.ex`, `queue.ex`,
  `slash_command.ex` — four files, same as Proposal 3.

## Dependencies

- `SlashCommand.dispatch/2` (new; shared with Proposals 1 and 3).
- `Queue.enqueue/4` (already exists).
- `Queue.handle_postpone/2` (already exists).
- `Tau.Session.emit_user_message_telemetry/3` must remain public.

## Confidence

Low-medium. The struct gives a clean seam for property testing, but the extra
indirection (`decide` → `execute_decision`) for three cases that are already
well-understood may not be worth the complexity. Would raise to medium if a
property-test suite for `decide/4` is written and shows measurable coverage
improvement.

## Prior art / references

- Hickey, "Simple Made Easy" — reifying decisions into data values (the
  "complect data and logic" separation).
- `Tau.Session.Events` in `lib/tau/session/events.ex` — precedent for using
  structs to reify session-internal facts that flow between modules.
- `Tau.Session.Data.fsm_result()` type — precedent for typed return values
  from routing functions in this codebase.
- Erlang `:gen_statem` action tuples — the FSM already reifies state-machine
  actions as data; this proposal applies the same pattern one level up, to the
  routing decision.
