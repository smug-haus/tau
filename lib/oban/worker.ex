defmodule Oban.Worker do
  @moduledoc """
  Stub Oban.Worker behaviour for use when Oban is not a project dependency.

  Real Oban.Worker is a macro-heavy behaviour backed by Ecto queues. This stub
  provides the minimal callback definition and `new/2` helper needed for
  `Tau.Factory.StepJob` to declare `@behaviour Oban.Worker` and be testable
  without the full Oban package.
  """

  @callback perform(Oban.Job.t()) ::
              :ok
              | {:ok, term()}
              | {:cancel, term()}
              | {:error, term()}
              | {:snooze, non_neg_integer()}

  @doc """
  Build an `Oban.Job` struct for the given worker module with `args`.

  This mirrors the `new/2` function injected by real `use Oban.Worker`.
  """
  @spec new(module(), map()) :: Oban.Job.t()
  def new(worker, args) when is_atom(worker) and is_map(args) do
    %Oban.Job{
      args: args,
      worker: to_string(worker)
    }
  end
end
