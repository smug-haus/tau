defmodule Tau.Permissions.RuleSet do
  @moduledoc """
  Compiles permission rules from settings into a precompiled tuple stored in
  `:persistent_term` under `{Tau.Permissions, :rule_set}`.

  Evaluation (`Tau.Permissions.Evaluator.evaluate/4`) is pure and stateless;
  it reads the precompiled rule set straight from `:persistent_term` and
  returns `:allow | :deny | :ask`. No GenServer call on the hot path.

  M0 stub: publishes an empty rule set (allow-all-but-prompt-defaults).
  """
  use GenServer

  @persistent_key {Tau.Permissions, :rule_set}

  @doc "Get the current compiled rule set."
  @spec get() :: tuple()
  def get, do: :persistent_term.get(@persistent_key, {})

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :persistent_term.put(@persistent_key, {})
    {:ok, %{}}
  end
end
