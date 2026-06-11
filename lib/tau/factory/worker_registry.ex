defmodule Tau.Factory.WorkerRegistry do
  @moduledoc """
  Registry for `Tau.Factory.Worker` processes, keyed by `worker_id`.

  Each Worker registers itself under its `worker_id` when it starts.
  Callers resolve live pids via `Registry.lookup/2` — never by storing
  a pid at spawn time ([C218], SPEC-FACTORY-FLEET §4 D-311).

  `keys: :unique` enforces one-worker-per-id; a duplicate `worker_id`
  causes the second registration to fail.

  See `docs/spec/SPEC-FACTORY-FLEET.md`, D-309–D-311.
  """

  @doc """
  Returns the child spec for starting this registry.

  Options:
    - `:name` — atom; registered name for the Registry process (required).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Start the WorkerRegistry with the given options.

  Required options:
    - `:name` — atom; registered name for the Registry process.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Registry.start_link(keys: :unique, name: name)
  end
end
