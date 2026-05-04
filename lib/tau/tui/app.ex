if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App do
    @moduledoc """
    Ratatouille MVU app implementation. Only compiled when the optional
    `:ratatouille` dep is loaded; the parent `Tau.TUI.start/0` checks
    `Code.ensure_loaded?/1` before delegating here.
    """

    @behaviour Ratatouille.App

    require Logger

    import Ratatouille.View
    alias Ratatouille.Runtime.Subscription

    @tick_interval 250

    @impl true
    def init(_context) do
      # D-004 (SPEC-USER-TURN [C6]): the bridge MUST subscribe to PubSub
      # BEFORE `Tau.start_session/1` returns. `Session.init/1`
      # synchronously broadcasts `%Events.SessionStart{}`; subscribing
      # afterwards loses it. Pre-generate the id, start the bridge, then
      # start the session.
      #
      # Bridge rationale: Ratatouille 0.5.1's runtime does NOT forward
      # arbitrary mailbox messages to `update/2` — only its declared
      # subscriptions (here, `:tick`). Without `Tau.TUI.EventBridge` the
      # PubSub broadcasts would queue in the runtime's mailbox forever,
      # the transcript pane stays empty, and the user never sees an
      # assistant response. The bridge holds a queue per session;
      # `update/2`'s `:tick` clause drains it.
      session_id = Tau.Session.generate_id()
      {:ok, _bridge_pid} = Tau.TUI.EventBridge.start_link(session_id)

      # CLI-supplied per-invocation overrides flow via Tau.TUI.RuntimeOpts
      # (Ratatouille's `init/1` arity is fixed, so this is the seam).
      runtime_opts = Tau.TUI.RuntimeOpts.get()

      start_opts =
        [session_id: session_id]
        |> put_if(:provider, Map.get(runtime_opts, :provider))
        |> put_if(:model, Map.get(runtime_opts, :model))
        |> put_if(:provider_ctx, Map.get(runtime_opts, :provider_ctx))

      {:ok, ^session_id} = Tau.start_session(start_opts)

      %{
        session_id: session_id,
        input: "",
        transcript: [],
        tool_output: [],
        status: :idle,
        last_assistant: nil
      }
    end

    defp put_if(opts, _key, nil), do: opts
    defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

    @impl true
    def update(model, msg) do
      case msg do
        {:event, %{key: 13}} -> submit(model)
        {:event, %{key: 27}} -> cancel(model)
        # Termbox / Ratatouille deliver Space as `key: 32` (the SPC special
        # key), NOT as `ch: 32`. The `ch != 0` clause below therefore
        # never fires for spaces, and they were silently dropped. Map
        # the special key to a literal space here.
        {:event, %{key: 32}} -> append_input(model, " ")
        {:event, %{ch: ch}} when ch != 0 -> append_input(model, <<ch::utf8>>)
        {:event, %{key: 127}} -> backspace(model)
        {:event, %{key: 8}} -> backspace(model)
        :tick -> drain_bridge(model)
        %Tau.Session.Events.MessageStart{} = e -> on_message_start(model, e)
        %Tau.Session.Events.MessageUpdate{} = e -> on_message_update(model, e)
        %Tau.Session.Events.MessageEnd{} = e -> on_message_end(model, e)
        %Tau.Session.Events.ToolStart{} = e -> on_tool_start(model, e)
        %Tau.Session.Events.ToolEnd{} = e -> on_tool_end(model, e)
        %Tau.Session.Events.Cancelled{} = e -> on_cancelled(model, e)
        %Tau.Session.Events.SessionEnd{} = e -> on_session_end(model, e)
        _ -> model
      end
    end

    # Each tick, fold every event the bridge has buffered through the
    # same handlers used by the unit tests (which call update/2 directly).
    # This is the integration the unit tests don't exercise.
    defp drain_bridge(model) do
      model.session_id
      |> Tau.TUI.EventBridge.drain()
      |> Enum.reduce(model, fn event, acc -> update(acc, event) end)
    end

    @impl true
    def render(model) do
      view top_bar: status_bar(model),
           bottom_bar: prompt(model) do
        row do
          column(size: 12) do
            panel title: "transcript", height: :fill do
              for line <- Enum.take(model.transcript, -200) do
                label(content: line)
              end
            end
          end
        end
      end
    end

    @impl true
    def subscribe(_model), do: Subscription.interval(@tick_interval, :tick)

    @doc "Run the TUI loop (blocking until the user quits)."
    def run do
      meta = %{app: __MODULE__, supervisor: Ratatouille.Runtime.Supervisor}

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

    defp start_runtime_supervisor do
      opts = [
        app: __MODULE__,
        interval: @tick_interval,
        quit_events: [{:ch, ?q}, {:key, 3}]
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

    # --- Helpers --------------------------------------------------------

    defp status_bar(model) do
      bar do
        label(
          content:
            "session: " <>
              model.session_id <>
              " | status: " <>
              to_string(model.status) <>
              " | <Enter> submit · <Esc> cancel · <Ctrl-C> quit"
        )
      end
    end

    defp prompt(model) do
      bar do
        label(content: "> " <> model.input)
      end
    end

    defp append_input(model, ch), do: %{model | input: model.input <> ch}

    defp backspace(%{input: ""} = m), do: m
    defp backspace(model), do: %{model | input: String.slice(model.input, 0..-2//1)}

    defp submit(%{input: ""} = m), do: m

    defp submit(model) do
      Tau.send(model.session_id, model.input)

      %{
        model
        | input: "",
          transcript: model.transcript ++ ["> " <> model.input],
          status: :sending
      }
    end

    defp cancel(model) do
      Tau.cancel(model.session_id)
      %{model | status: :idle}
    end

    defp on_message_start(model, _e), do: %{model | status: :streaming, last_assistant: ""}

    defp on_message_update(model, %{message: msg}) do
      text =
        msg.content
        |> Enum.filter(&match?(%{type: :text}, &1))
        |> Enum.map_join("", & &1.text)

      %{model | last_assistant: text}
    end

    defp on_message_end(model, %{message: msg}) do
      transcript_lines =
        for block <- msg.content do
          case block do
            %{type: :text, text: t} -> "[assistant] " <> t
            %{type: :tool_call, name: n} -> "[tool_call] " <> n <> "(...)"
            _ -> nil
          end
        end
        |> Enum.reject(&is_nil/1)

      %{
        model
        | status: :idle,
          transcript: model.transcript ++ transcript_lines,
          last_assistant: nil
      }
    end

    defp on_tool_start(model, %{name: n, arguments: args}) do
      %{model | tool_output: model.tool_output ++ ["▶ " <> n <> " " <> inspect(args)]}
    end

    defp on_tool_end(model, %{result: %{content: c, is_error: e}}) do
      prefix = if e, do: "✗", else: "✓"

      summary =
        if is_binary(c),
          do: String.slice(c, 0..160),
          else: c |> inspect() |> String.slice(0..160)

      %{model | tool_output: model.tool_output ++ [prefix <> " " <> summary]}
    end

    defp on_cancelled(model, %{reason: reason}) do
      reason_str = inspect(reason)

      %{
        model
        | status: "cancelled: " <> reason_str,
          transcript: model.transcript ++ ["[cancelled: " <> reason_str <> "]"],
          last_assistant: nil
      }
    end

    defp on_session_end(model, %{reason: reason}) do
      reason_str = inspect(reason)

      %{
        model
        | status: "ended: " <> reason_str,
          transcript: model.transcript ++ ["[session ended: " <> reason_str <> "]"],
          last_assistant: nil
      }
    end
  end
end
