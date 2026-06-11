defmodule Tau.Factory.UnitRegistry do
  @moduledoc """
  Registry for `Tau.Factory.Unit` processes, keyed by `unit_id`.

  Each Unit registers itself under its `unit_id` when it starts.
  Callers look up units via `Registry.lookup/2`.

  See `docs/spec/SPEC-FACTORY-CORE.md` §5, D-340.
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
      shutdown: 5000
    }
  end

  @doc """
  Start the UnitRegistry with the given options.

  Required options:
    - `:name` — atom; registered name for the Registry process.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Registry.start_link(keys: :unique, name: name)
  end

  @doc """
  Look up a unit by `unit_id` in the given registry.

  Returns `[{pid, value}]` (standard `Registry.lookup/2` result).
  """
  @spec lookup(atom(), String.t()) :: [{pid(), term()}]
  def lookup(registry, unit_id) do
    Registry.lookup(registry, unit_id)
  end
end
