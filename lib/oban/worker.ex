defmodule Oban.Worker do
  @moduledoc """
  Minimal `Oban.Worker` behaviour stub.

  Real `Oban.Worker` is a macro-heavy behaviour backed by Ecto queues.
  This stub provides the minimal callback definition so worker modules
  can declare `@behaviour Oban.Worker` and implement `perform/1` without
  the full Oban package.

  Superseded when Oban is added as a real Hex dependency.
  """

  @callback perform(Oban.Job.t()) ::
              :ok
              | {:ok, term()}
              | {:cancel, term()}
              | {:error, term()}
              | {:snooze, non_neg_integer()}
end
