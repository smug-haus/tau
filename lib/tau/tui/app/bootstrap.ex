if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App.Bootstrap do
    @moduledoc """
    TUI session initialisation and runtime supervisor lifecycle for
    `Tau.TUI.App`. Owns `init/1` (Ratatouille callback entry point),
    `run/0` (blocking loop), and the Ratatouille runtime supervisor helpers.
    """

    require Logger

    alias Tau.TUI.App.Model

    # Adaptive-tick intervals (mirrored from App for supervisor opts).
    @tick_interval_idle 250

    @doc """
    Ratatouille `init/1` callback. Starts the EventBridge, starts the Tau
    session, and returns the initial MVU model.

    Subscribes before starting the session so the synchronous
    `%Events.SessionStart{}` broadcast is not missed (D-004 / SPEC-USER-TURN §4).
    """
    @spec init(map()) :: Model.t()
    def init(context) do
      session_id = Tau.Session.generate_id()
      {:ok, _bridge_pid} = Tau.TUI.EventBridge.start_link(session_id)

      # CLI-supplied per-invocation overrides via Tau.TUI.RuntimeOpts.
      runtime_opts = Tau.TUI.RuntimeOpts.get()

      start_opts =
        [session_id: session_id]
        |> put_if(:provider, Map.get(runtime_opts, :provider))
        |> put_if(:model, Map.get(runtime_opts, :model))
        |> put_if(:provider_ctx, Map.get(runtime_opts, :provider_ctx))
        # SPEC-CODING-AGENT §4 B1 / D-037: coding_agent routes user messages
        # through the coding-agent dispatcher in `Tau.Session.process_user_message/2`.
        |> put_if(:coding_agent, Map.get(runtime_opts, :coding_agent))

      {:ok, ^session_id} = Tau.start_session(start_opts)

      Model.new(context, session_id, runtime_opts)
    end

    @doc "Run the TUI loop (blocking until the user quits)."
    @spec run() :: :ok | {:error, term()}
    def run do
      meta = %{app: Tau.TUI.App, supervisor: Ratatouille.Runtime.Supervisor}

      :telemetry.execute(
        [:tau, :tui, :start],
        %{system_time: System.system_time()},
        meta
      )

      case start_runtime_supervisor() do
        {:ok, sup_pid} ->
          ref = Process.monitor(sup_pid)
          reason = await_down(ref, sup_pid)

          :telemetry.execute(
            [:tau, :tui, :stop],
            %{system_time: System.system_time()},
            Map.put(meta, :reason, reason)
          )

          :ok

        {:error, reason} ->
          :telemetry.execute(
            [:tau, :tui, :exception],
            %{system_time: System.system_time()},
            Map.put(meta, :reason, reason)
          )

          Logger.error("TUI failed to start: " <> inspect(reason))
          {:error, reason}
      end
    end

    # ---------------------------------------------------------------------------
    # Private helpers
    # ---------------------------------------------------------------------------

    defp put_if(opts, _key, nil), do: opts
    defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

    defp start_runtime_supervisor do
      opts = [
        app: Tau.TUI.App,
        interval: @tick_interval_idle,
        # D-003 / AC-4: bare `{:ch, ?q}` is intentionally absent.
        # The `q` key is forwarded to `update/2` for context-sensitive handling:
        # quit on empty prompt, append on non-empty.
        # Ctrl-C (`{:key, 3}`) remains unconditional.
        quit_events: [{:key, 3}]
      ]

      case Tau.TUI.Supervisor.start_runtime(opts) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end
    end

    defp await_down(ref, pid) do
      receive do
        {:DOWN, ^ref, :process, ^pid, reason} -> reason
        _other -> await_down(ref, pid)
      end
    end
  end
end
