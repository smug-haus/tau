if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App do
    @moduledoc """
    Ratatouille MVU app implementation. Only compiled when the optional
    `:ratatouille` dep is loaded; the parent `Tau.TUI.start/0` checks
    `Code.ensure_loaded?/1` before delegating here.
    """

    @behaviour Ratatouille.App

    import Ratatouille.View
    alias Ratatouille.Runtime.Subscription

    @tick_interval 250

    @impl true
    def init(_context) do
      {:ok, session_id} = Tau.start_session([])
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:" <> session_id)

      %{
        session_id: session_id,
        input: "",
        transcript: [],
        tool_output: [],
        status: :idle,
        last_assistant: nil
      }
    end

    @impl true
    def update(model, msg) do
      case msg do
        {:event, %{key: 13}} -> submit(model)
        {:event, %{key: 27}} -> cancel(model)
        {:event, %{ch: ch}} when ch != 0 -> append_input(model, <<ch::utf8>>)
        {:event, %{key: 127}} -> backspace(model)
        {:event, %{key: 8}} -> backspace(model)
        :tick -> model
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
      {:ok, runtime} =
        Ratatouille.Runtime.start_link(
          app: __MODULE__,
          interval: @tick_interval,
          quit_events: [{:ch, ?q}, {:key, 3}]
        )

      ref = Process.monitor(runtime)

      receive do
        {:DOWN, ^ref, :process, ^runtime, _reason} -> :ok
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
