defmodule Tau.Hooks.Dispatcher do
  @moduledoc """
  Walks the registered hooks for a given event in priority order
  (managed → user → project → local → programmatic), short-circuiting on
  `{:halt, _}` or `{:deny, _}`.

  Each invocation is wrapped in `[:tau, :hook, :run, :start | :stop |
  :exception]` telemetry. Hooks must return one of the values documented
  on `Tau.Hook` — anything else logs a warning and is treated as `:cont`.
  """

  require Logger

  @type event :: Tau.Hook.event()
  @type payload :: map()
  @type outcome ::
          {:cont, payload()}
          | {:halt, reason :: term()}
          | {:deny, String.t()}

  @doc "Run all hooks registered for `event` against `payload`. Sequential."
  @spec run(event(), payload()) :: outcome()
  def run(event, payload) do
    hooks = lookup(event)

    Enum.reduce_while(hooks, {:cont, payload}, fn mod, {:cont, p} ->
      run_one(mod, event, p)
    end)
  end

  defp run_one(mod, event, payload) do
    started = System.monotonic_time()

    :telemetry.execute([:tau, :hook, :run, :start], %{system_time: System.system_time()}, %{
      hook: mod,
      event: event
    })

    result =
      try do
        mod.handle(event, payload)
      rescue
        e ->
          Logger.warning("Hook #{inspect(mod)} crashed: #{Exception.message(e)}")

          :telemetry.execute(
            [:tau, :hook, :run, :exception],
            %{duration: System.monotonic_time() - started},
            %{hook: mod, event: event, error: Exception.message(e)}
          )

          :cont
      end

    :telemetry.execute(
      [:tau, :hook, :run, :stop],
      %{duration: System.monotonic_time() - started},
      %{hook: mod, event: event, result: result}
    )

    case result do
      :cont -> {:cont, {:cont, payload}}
      {:cont, p} when is_map(p) -> {:cont, {:cont, p}}
      {:halt, _} = h -> {:halt, h}
      {:deny, _} = d -> {:halt, d}
      _other -> {:cont, {:cont, payload}}
    end
  end

  defp lookup(event) do
    case Registry.lookup(Tau.Hooks.Registry, event) do
      [] -> []
      list -> Enum.map(list, fn {_pid, mod} -> mod end)
    end
  end
end
