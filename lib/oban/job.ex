defmodule Oban.Job do
  @moduledoc """
  Minimal `Oban.Job` struct stub.

  Real `Oban.Job` is an Ecto schema. This stub provides the fields
  needed for workers that implement `@behaviour Oban.Worker` to be
  typeable and testable without the full Oban package.

  Superseded when Oban is added as a real Hex dependency.
  """

  @enforce_keys [:args]
  defstruct [:args, :id, :queue, :worker, :attempt, :max_attempts]

  @type t :: %__MODULE__{
          args: map(),
          id: non_neg_integer() | nil,
          queue: String.t() | nil,
          worker: String.t() | nil,
          attempt: non_neg_integer() | nil,
          max_attempts: non_neg_integer() | nil
        }
end
