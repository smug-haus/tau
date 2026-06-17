defmodule Oban.Job do
  @moduledoc """
  Stub Oban.Job struct for use when Oban is not a project dependency.

  Real Oban.Job is an Ecto schema. This stub provides the minimal fields
  needed for `Tau.Factory.StepJob.perform/1` to run in tests and at runtime
  when the full Oban package is not present.
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
