defmodule Tau.Permissions.RuleSet do
  @moduledoc """
  Compiles permission rules from settings into a tuple of
  `{decision, matcher, compiled_rule}` triples and stores them in
  `:persistent_term` for lock-free reads.

  Listens for `{:settings_reloaded, settings}` messages from
  `Tau.Settings.Cache` and recompiles.
  """
  use GenServer

  @persistent_key {Tau.Permissions, :rule_set}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Get the compiled rule-set tuple."
  @spec get() :: tuple()
  def get, do: :persistent_term.get(@persistent_key, {})

  @impl true
  def init(_opts) do
    publish(compile_from_settings())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:settings_reloaded, settings}, state) do
    publish(compile_from_settings(settings))
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp compile_from_settings(settings \\ nil) do
    settings = settings || Tau.Settings.Cache.get()
    perms = Map.get(settings, :permissions) || Map.get(settings, "permissions") || %{}
    Tau.Permissions.Parser.compile(perms)
  end

  defp publish(rules) do
    :persistent_term.put(@persistent_key, List.to_tuple(rules))
  end
end
