defmodule Tau.Settings do
  @moduledoc """
  Public accessors for merged settings.

  Settings come from the cascade (managed → user → project → local) and
  are published to `:persistent_term` by `Tau.Settings.Cache`. Read these
  via the helpers here rather than touching `:persistent_term` directly.
  """

  @persistent_key {Tau, :settings}

  @doc "Whole merged settings map. Mostly for debugging."
  @spec all() :: map()
  def all, do: :persistent_term.get(@persistent_key, %{})

  @doc "Get a top-level setting."
  @spec get(atom() | String.t(), term()) :: term()
  def get(key, default \\ nil), do: Map.get(all(), key, default)

  @doc """
  Resolve the data directory: settings → app env → `~/.tau/`.
  """
  @spec data_dir() :: Path.t()
  def data_dir do
    cond do
      d = get(:data_dir) -> d
      d = Application.get_env(:tau, :data_dir) -> d
      true -> Path.join(System.user_home!() || ".", ".tau")
    end
  end
end
