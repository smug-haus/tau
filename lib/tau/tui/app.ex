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
        # SPEC-CODING-AGENT §4 B1 / D-037: when the user invoked tau
        # with `--coding-agent <name>`, the session FSM routes user
        # messages through the coding-agent dispatcher instead of
        # `data.provider.stream/3`. The TUI's submit path is unchanged
        # (`Tau.send/2` → cast → FSM); the routing decision lives in
        # `Tau.Session.process_user_message/2`.
        |> put_if(:coding_agent, Map.get(runtime_opts, :coding_agent))

      {:ok, ^session_id} = Tau.start_session(start_opts)

      %{
        session_id: session_id,
        input: "",
        transcript: [],
        tool_output: [],
        status: :idle,
        last_assistant: nil,
        coding_agent: Map.get(runtime_opts, :coding_agent)
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

    # Hardcoded panel width for word-wrap. Ratatouille's `label` is
    # single-line and clips at the panel edge; we pre-wrap long
    # transcript entries into multiple sublines so nothing is lost.
    # TODO: derive from `Ratatouille` window width via the resize
    # event so wrapping adapts to terminal size.
    @wrap_width 100

    @impl true
    def render(model) do
      view top_bar: status_bar(model),
           bottom_bar: prompt(model) do
        row do
          column(size: 12) do
            panel title: "transcript", height: :fill do
              for line <- Enum.take(model.transcript, -200),
                  sub <- wrap(line, @wrap_width) do
                label(content: sub)
              end
            end
          end
        end
      end
    end

    @doc false
    @spec wrap(String.t(), pos_integer()) :: [String.t()]
    def wrap("", _width), do: [""]

    def wrap(line, width) when is_binary(line) and is_integer(width) and width > 0 do
      line
      |> String.split(~r/\s+/, trim: false)
      |> Enum.reduce({[], ""}, fn word, {lines, current} ->
        cond do
          # Word longer than the wrap width on its own — hard-break
          # mid-word (rare; long URLs, hashes).
          String.length(word) > width ->
            chunks = chunk_string(word, width)
            new_current = List.last(chunks) || ""

            new_lines =
              cond do
                current == "" and length(chunks) > 1 ->
                  Enum.reverse(Enum.drop(chunks, -1)) ++ lines

                current == "" ->
                  lines

                length(chunks) == 1 ->
                  [current | lines]

                true ->
                  Enum.reverse(Enum.drop(chunks, -1)) ++ [current | lines]
              end

            {new_lines, new_current}

          current == "" ->
            {lines, word}

          String.length(current) + 1 + String.length(word) <= width ->
            {lines, current <> " " <> word}

          true ->
            {[current | lines], word}
        end
      end)
      |> finalize_wrap()
    end

    defp finalize_wrap({lines, ""}), do: Enum.reverse(lines)
    defp finalize_wrap({lines, last}), do: Enum.reverse([last | lines])

    defp chunk_string(s, n) do
      chunks = for <<chunk::binary-size(n) <- s>>, do: chunk
      rest_len = byte_size(s) - length(chunks) * n

      if rest_len > 0 do
        chunks ++ [binary_part(s, byte_size(s) - rest_len, rest_len)]
      else
        chunks
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
              status_bar_coding_agent(model) <>
              " | status: " <>
              to_string(model.status) <>
              " | <Enter> submit · <Esc> cancel · <Ctrl-C> quit"
        )
      end
    end

    # SPEC-CODING-AGENT §4 B1: when the TUI was launched with
    # `--coding-agent`, surface the adapter in the status bar so the
    # user can tell at a glance that "Send" is routed through a
    # subprocess agent rather than the configured `Tau.Provider`.
    defp status_bar_coding_agent(%{coding_agent: nil}), do: ""
    defp status_bar_coding_agent(%{coding_agent: mod}), do: " | agent: " <> inspect(mod)
    defp status_bar_coding_agent(_), do: ""

    # D-026 ([C51-B3]): a solid block cursor (U+2588 "█") MUST be appended
    # after the current input so the user can see the insertion point.
    # Unicode block renders in all common terminal emulators; it is
    # visually distinct from typed characters and requires no timer or
    # animation (v1 constraint: no blinking).
    @cursor_glyph "█"

    defp prompt(model) do
      bar do
        label(content: "> " <> model.input <> @cursor_glyph)
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
        msg.content
        |> Enum.flat_map(fn block ->
          case block do
            %{type: :text, text: t} ->
              # D-028 / [C52-B5]: render markdown (CommonMark + GFM
              # tables) rather than echo raw source.
              ["[assistant]" | Tau.Markdown.render(t)]

            # Thinking models (Qwen3, DeepSeek-R1) emit chain-of-thought
            # via Thinking* events. Surface them so a long think doesn't
            # look like the TUI is hung.
            %{type: :thinking, text: t} when is_binary(t) and t != "" ->
              ["[thinking] " <> t]

            %{type: :tool_call, name: n} ->
              ["[tool_call] " <> n <> "(...)"]

            _ ->
              []
          end
        end)

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
