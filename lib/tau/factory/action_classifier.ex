defmodule Tau.Factory.ActionClassifier.Action do
  @moduledoc """
  Struct representing an action to be classified by `Tau.Factory.ActionClassifier`.

  The `kind` field is an atom identifying the action type. The `@destructive`
  denylist in `ActionClassifier` keys on this field (INV-24 #2).
  """

  @enforce_keys [:kind]
  defstruct [:kind]

  @type t :: %__MODULE__{
          kind: atom()
        }
end

defmodule Tau.Factory.ActionClassifier do
  @moduledoc """
  Pure action classifier enforcing INV-20 / D-319 (no unilateral destruction).

  `classify/1` is a total pure function over `%Action{}` that denies every
  action whose `kind` is in the `@destructive` denylist and allows all others.

  The denylist is data (a `MapSet` of atoms — INV-24 #2: pattern-match on
  atoms/structs, no string-keyed dispatch). Adding a new destructive class is
  one `MapSet` entry, not a new code path.

  A `{:deny, :destructive}` verdict routes to the Coordinator as E-DESTRUCTIVE
  via `Tau.Factory.Escalation.classify({:destructive, action})`, and the action
  **never auto-executes** (INV-20 `□(destructive(a) → escalate ∧ ¬auto_execute)`).

  `MergeAuthority` and every other effecting path MUST call `classify/1` before
  executing; a deny verdict is delivered to K as E-DESTRUCTIVE (FC-7).

  Properties before examples (INV-24 #6): this module is property-testable —
  for all `%Action{kind: k}`, `classify/1` returns `:allow` iff `k ∉ @destructive`
  and `{:deny, :destructive}` iff `k ∈ @destructive`. The function never raises.

  See `docs/arch/04-software-architecture/governance.md §4`.
  """

  alias Tau.Factory.ActionClassifier.Action

  # The denylist is data — one list entry to add a new destructive class (INV-24 #2).
  # Used as a compile-time list in the guard (Elixir guards require compile-time literals).
  @destructive [
    :force_push,
    :history_rewrite,
    :release,
    :external_publish,
    :data_migration
  ]

  @doc """
  Classifies an action as `:allow` or `{:deny, :destructive}`.

  The function is total over `%Action{}`: it never raises for any valid struct.
  Any `kind` present in the `@destructive` denylist returns `{:deny, :destructive}`;
  all other kinds return `:allow`.

  ## Examples

      iex> classify(%Action{kind: :force_push})
      {:deny, :destructive}

      iex> classify(%Action{kind: :read_file})
      :allow
  """
  @spec classify(Action.t()) :: :allow | {:deny, :destructive}
  def classify(%Action{kind: k}) when k in @destructive, do: {:deny, :destructive}
  def classify(%Action{}), do: :allow
end
