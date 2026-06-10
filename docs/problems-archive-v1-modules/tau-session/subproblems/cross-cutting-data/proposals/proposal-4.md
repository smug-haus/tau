---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Add a Data behaviour with a typed contract callback

## Approach

Introduce a `Tau.Session.Data.Contract` behaviour that declares one required
callback: `@callback validate(map()) :: {:ok, t()} | {:error, term()}`. The
current `Data.new/1` is renamed `Data.build/1` and calls
`Contract.validate/1` as a post-construction assertion. Every sub-module
function head that currently takes `data` with no pattern match is annotated
with `@spec` using the existing `Tau.Session.Data.t()` type; where the
function previously called `Map.get(data, :field, default)`, the default is
removed and `data.field` is used, relying on the struct guarantee.

Separately, the two dynamic-key patterns in `queue.ex` and
`provider_turn.ex:maybe_replace/3` are replaced with typed delegates on `Data`
(same as Proposal 2's `get_queue/2`, `put_queue/3`, and `replace_field/3`),
but these are framed as implementing the behaviour's internal contract, not as
standalone accessors.

The end state: `Data.new/1` (public, unchanged signature) calls `Data.build/1`
then `Tau.Session.Data.Contract.validate!/1` (raises on invalid shape) before
returning `{:ok, struct}`.

## Rationale

The acceptance criterion requires that sub-modules "pattern-match on
`%Tau.Session.Data{}`". This proposal makes that enforceable at runtime on
the construction path: `validate!/1` confirms the struct is well-formed
before any FSM clause can observe it. The behaviour adds a seam for testing —
a test double can implement `Tau.Session.Data.Contract` and inject a
pre-built struct — and makes explicit that `Data` is not just a dumb struct
but a typed contract between the FSM and its sub-modules. The tactical edits
(remove defensive default, typed delegates) are identical to Proposals 1 and 2
but are now presented as enforcement of the behaviour contract rather than
isolated fixes.

## Sketch

```elixir
# lib/tau/session/data/contract.ex
defmodule Tau.Session.Data.Contract do
  @moduledoc """
  Behaviour declaring the invariants that every `Tau.Session.Data` value
  must satisfy at construction time.
  """
  alias Tau.Session.Data

  @doc """
  Assert that `data` satisfies all structural invariants.
  Raises `ArgumentError` if any invariant is violated.
  """
  @callback validate(Data.t()) :: {:ok, Data.t()} | {:error, term()}

  @doc "Calls validate/1; raises on error."
  @spec validate!(Data.t()) :: Data.t()
  def validate!(%Data{} = data) do
    case Data.DefaultContract.validate(data) do
      {:ok, d} -> d
      {:error, reason} -> raise ArgumentError, "Data invariant violated: #{inspect(reason)}"
    end
  end
end

# lib/tau/session/data/default_contract.ex
defmodule Tau.Session.Data.DefaultContract do
  @behaviour Tau.Session.Data.Contract

  @impl true
  def validate(%Tau.Session.Data{} = data) do
    with :ok <- assert_queues_initialised(data),
         :ok <- assert_child_session_ids(data) do
      {:ok, data}
    end
  end

  defp assert_queues_initialised(%{steering_queue: q, followup_queue: q2})
       when not is_nil(q) and not is_nil(q2), do: :ok
  defp assert_queues_initialised(_), do: {:error, :queues_not_initialised}

  defp assert_child_session_ids(%{child_session_ids: %MapSet{}}), do: :ok
  defp assert_child_session_ids(_), do: {:error, :child_session_ids_not_mapset}
end

# lib/tau/session/data.ex — new/1 calls validate! at the end
def new(opts) do
  # ... existing build logic ...
  data = %__MODULE__{...}
  {:ok, Tau.Session.Data.Contract.validate!(data)}
end
```

```elixir
# Removing the defensive default in provider_turn.ex:337 — same as Proposal 1
if msg.stop_reason == :end_turn and data.persona_lifetime == :turn do

# queue.ex — same get_queue/put_queue delegates as Proposal 2
# (framed as part of the Contract enforcement surface)
```

File touches: new files `lib/tau/session/data/contract.ex`,
`lib/tau/session/data/default_contract.ex`; minor edits to `data.ex`,
`queue.ex`, `provider_turn.ex`.

## Tradeoffs

### Strengths

- Makes the data invariants explicit and machine-checked at construction time,
  not just statically documented in the type spec.
- The `Contract` behaviour provides a testing seam: tests can inject a
  `MockContract` that skips expensive validation for unit tests.
- Any future invariant (e.g. "tool_iterations must be ≤ max_tool_iterations
  at init") can be added to `DefaultContract.validate/1` without touching
  `Data` itself.
- The acceptance criterion's "no `Map.get(data, :field, default)` defensive
  reads" is enforced by construction — if the struct is always valid,
  defaults are never needed.

### Weaknesses

- Introduces a behaviour for a concern (construction-time validation) that the
  existing `@enforce_keys` already addresses structurally. The behaviour adds
  ceremony without adding correctness beyond what `@enforce_keys` already
  provides for required fields.
- `validate!` raises at runtime; Dialyzer cannot verify at compile time that
  all invariants hold. The primary value is test documentation and fast-fail
  at session start, not type safety.
- Two new modules (`Contract`, `DefaultContract`) for what is mechanically a
  ~10-line change to `data.ex`. The complexity-to-benefit ratio is lower than
  Proposals 1 and 2 for the stated acceptance criterion.
- The behaviour callback `validate/1` is not required by OTP non-negotiables
  (invariant 2): extensibility seams should be behaviours, but a construction
  validator is not an extensibility seam — it is an internal guard. Using a
  behaviour here may set a precedent for over-behaviourising internal helpers.

### Costs

- ~60 lines added across two new files plus minor edits to three existing files.
- Adds a runtime call (the `validate!` invocation in `new/1`) at session
  construction — trivially fast but measurably present.
- New modules must be added to the application's compile graph; any tooling
  that lists `Tau.Session.Data.*` modules (documentation, Credo) sees two
  additional modules.

## Dependencies

- `Tau.Session.Data` struct already in place (no prerequisite).
- The `DefaultContract` logic assumes `@enforce_keys` already covers required
  fields; it only adds invariants beyond what the struct enforces structurally.

## Confidence

Medium. The behaviour-and-contract pattern is well understood in Elixir; the
specific application here (construction-time validation) is slightly unusual
and may be seen as over-engineering for the problem. The tactical callsite
fixes (remove defensive default, typed delegates) are high-confidence; the
behaviour scaffolding carries medium confidence that it will be accepted as
proportionate.

## Prior art / references

- `Tau.Provider` behaviour — the project's canonical use of behaviours for
  extensibility seams; the pattern here is similar but applied to a validation
  contract rather than an adapter.
- Ecto changesets — the canonical Elixir pattern for runtime struct validation;
  the `validate!/1` function mirrors `Ecto.Changeset.apply_action!/2`.
- OTP non-negotiables §2: "Extensibility seams MUST be behaviours" — the
  rationale for choosing a behaviour over a plain function.
