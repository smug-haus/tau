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
    alias Tau.TUI.Render.{Wrap, Markdown}
    alias Tau.TUI.Fuzzy
    alias Tau.TUI.Editor
    alias Tau.TUI.History
    alias Tau.TUI.History.Store
    alias Tau.Commands.Builtin

    # Adaptive tick: 16 ms while a turn is streaming (last_assistant non-nil);
    # 250 ms while idle. Ratatouille re-reads subscribe/1 each cycle, so the
    # interval tracks model state without any process changes.
    @tick_interval_streaming 16
    @tick_interval_idle 250

    # Bounded transcript: keep at most this many lines in the model list.
    # Older lines are dropped from the head (ring-buffer semantics). The
    # Ratatouille `panel` already clips to the visible height; the cap
    # prevents unbounded memory growth across long sessions.
    @transcript_cap 500

    @impl true
    def init(context) do
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
      # `update/2`'s `:tick` clause drains it. The drain interval is
      # adaptive: 16 ms while streaming, 250 ms while idle.
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

      # Derive initial wrap width from the Ratatouille context (window
      # dimensions). Falls back to 80 if context is unavailable (unit tests).
      initial_width = get_in(context, [:window, :width]) || 80

      # D-140: data_dir injected from Settings; Store.load/2 uses it to
      # locate the per-cwd history JSONL without touching global state.
      data_dir = Tau.Settings.data_dir()
      cwd = File.cwd!()
      history = Store.load(data_dir, cwd)

      %{
        session_id: session_id,
        # #338: editor replaces the bare `input` string field.
        editor: Editor.new(),
        # #338: per-cwd history, pre-loaded from Store.
        history: history,
        # #338: transient Ctrl+R reverse-search sub-state (D-147).
        # nil = normal mode; map = search mode with :query and :pre_search_editor.
        search: nil,
        # #338: remember data_dir and cwd for Store.append on submit.
        history_data_dir: data_dir,
        history_cwd: cwd,
        transcript: [],
        tool_output: [],
        status: :idle,
        last_assistant: nil,
        coding_agent: Map.get(runtime_opts, :coding_agent),
        wrap_width: transcript_pane_width(initial_width),
        # SPEC-TUI-COMPLETION §4 B1 (D-103): catalog received via
        # CommandCatalog broadcast. Nil until the first broadcast arrives;
        # D-104 mandates the builtins floor is used when nil.
        catalog: nil,
        # SPEC-TUI-COMPLETION §4 B2 (D-102): MVU menu sub-state.
        # nil = closed; non-nil = open with query/entries/selected.
        menu: nil
      }
    end

    defp put_if(opts, _key, nil), do: opts
    defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

    # Derive the transcript pane's usable wrap width from the terminal
    # width. Ratatouille's `column(size: 12)` uses a 12/12 grid so the
    # transcript panel fills the full width. Subtract 2 for panel borders.
    defp transcript_pane_width(terminal_width) when terminal_width >= 4 do
      terminal_width - 2
    end

    defp transcript_pane_width(_terminal_width), do: 1

    @impl true
    def update(model, msg) do
      case msg do
        {:event, event} ->
          handle_event(model, event)

        # Resize: update wrap_width so subsequent wraps use the new terminal width
        {:resize, %{w: w}} ->
          %{model | wrap_width: transcript_pane_width(w)}

        {:resize, _} ->
          model

        :tick ->
          drain_bridge(model)

        %Tau.Session.Events.MessageStart{} = e ->
          on_message_start(model, e)

        %Tau.Session.Events.MessageUpdate{} = e ->
          on_message_update(model, e)

        %Tau.Session.Events.MessageEnd{} = e ->
          on_message_end(model, e)

        %Tau.Session.Events.ToolStart{} = e ->
          on_tool_start(model, e)

        %Tau.Session.Events.ToolEnd{} = e ->
          on_tool_end(model, e)

        %Tau.Session.Events.Cancelled{} = e ->
          on_cancelled(model, e)

        %Tau.Session.Events.SessionEnd{} = e ->
          on_session_end(model, e)

        %Tau.Session.Events.SystemNotice{text: t} ->
          %{model | transcript: bounded_append(model.transcript, {t, []})}

        # D-103 (SPEC-TUI-COMPLETION §4 B1): store the catalog and re-filter
        # the menu if it is currently open. Broadcast arrives at SessionStart
        # and after /reload (D-108).
        %Tau.Session.Events.CommandCatalog{entries: entries} ->
          model
          |> Map.put(:catalog, entries)
          |> update_menu()

        _ ->
          model
      end
    end

    # Route terminal key events to sub-handlers by event shape.
    # Ordering: key-with-code first (Ctrl/special), then ch (character), then catch-all.
    defp handle_event(model, %{key: key} = event), do: handle_key(model, key, event)
    defp handle_event(model, %{mod: mod, ch: ch}) when mod != 0, do: handle_alt(model, ch)
    defp handle_event(model, %{ch: ch}), do: handle_char(model, ch)
    defp handle_event(model, _), do: model

    # Handle events with a `key:` code. Dispatches to sub-handlers to keep
    # cyclomatic complexity within bounds. Clause ordering is load-bearing.
    defp handle_key(model, key, _event) do
      case key do
        # Enter — context-aware: menu → accept, search → accept, else → submit
        13 when model.menu != nil ->
          menu_accept(model)

        13 when model.search != nil ->
          search_accept(model)

        13 ->
          submit(model)

        # Ctrl+J — guaranteed newline (D-145)
        10 ->
          %{model | editor: Editor.newline(model.editor), search: nil}

        # Esc — context-aware
        27 when model.menu != nil ->
          %{model | menu: nil}

        27 when model.search != nil ->
          search_cancel(model)

        27 ->
          cancel(model)

        # Space (termbox quirk: key 32, not ch 32)
        32 when model.search != nil ->
          %{model | search: %{model.search | query: model.search.query <> " "}}

        32 ->
          model |> editor_insert(" ") |> close_menu_if_whitespace()

        # Backspace (key 127 and 8)
        bsp when bsp in [127, 8] and model.search != nil ->
          %{model | search: %{model.search | query: String.slice(model.search.query, 0..-2//1)}}

        bsp when bsp in [127, 8] ->
          model |> editor_backspace() |> update_menu()

        # Readline chords and arrows delegate to further helpers
        _ ->
          handle_readline_key(model, key)
      end
    end

    # Readline editing chords (Ctrl+A/E/W/U/K/Y/D/P/N/R) and arrow keys.
    # Split from handle_key/3 to keep cyclomatic complexity within bounds.
    defp handle_readline_key(model, key) do
      case key do
        1 -> %{model | editor: Editor.move_line_start(model.editor), search: nil}
        4 -> %{model | editor: Editor.delete_forward(model.editor), search: nil}
        5 -> %{model | editor: Editor.move_line_end(model.editor), search: nil}
        11 -> %{model | editor: Editor.kill_to_line_end(model.editor), search: nil}
        14 -> history_next(model)
        16 -> history_prev(model)
        18 -> search_start(model)
        21 -> %{model | editor: Editor.kill_to_line_start(model.editor), search: nil}
        23 -> %{model | editor: Editor.kill_word_back(model.editor), search: nil}
        25 -> %{model | editor: Editor.yank(model.editor), search: nil}
        65_517 when model.menu != nil -> menu_navigate(model, -1)
        65_517 -> history_prev(model)
        65_516 when model.menu != nil -> menu_navigate(model, 1)
        65_516 -> history_next(model)
        65_515 -> %{model | editor: Editor.move_char_left(model.editor), search: nil}
        65_514 -> %{model | editor: Editor.move_char_right(model.editor), search: nil}
        _ -> model
      end
    end

    # Handle Alt-chord events (mod != 0). Best-effort: degrade to no-op
    # if termbox/tmux mangles the ESC-prefix (D-141).
    defp handle_alt(model, ?y), do: %{model | editor: Editor.yank_pop(model.editor), search: nil}

    defp handle_alt(model, ?b),
      do: %{model | editor: Editor.move_word_left(model.editor), search: nil}

    defp handle_alt(model, ?f),
      do: %{model | editor: Editor.move_word_right(model.editor), search: nil}

    # All other alt-chords: no-op (D-141: MUST NOT insert literal char).
    defp handle_alt(model, _ch), do: model

    # Handle printable character events (ch != 0, no mod).
    # D-003: `q` is context-aware on empty prompt.
    defp handle_char(model, 0), do: model

    defp handle_char(model, ?q) when model.search == nil do
      quit_or_append(model)
    end

    defp handle_char(model, ch) when model.search != nil do
      %{model | search: %{model.search | query: model.search.query <> <<ch::utf8>>}}
    end

    defp handle_char(model, ch) do
      model |> editor_insert(<<ch::utf8>>) |> update_menu()
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
              # Show the bounded transcript list. Each entry is {text, attrs};
              # wrap the text and apply attrs to every wrapped sub-line so that
              # styling (bold, colour) reaches the terminal (AC-6 / D-028).
              for {text, attrs} <- model.transcript,
                  sub <- Wrap.wrap(text, model.wrap_width) do
                label([{:content, sub} | attrs])
              end

              # Progressive streaming: also render last_assistant mid-turn
              # so partial assistant text is visible before MessageEnd.
              if model.last_assistant && model.last_assistant != "" do
                for sub <- Wrap.wrap("[streaming] " <> model.last_assistant, model.wrap_width) do
                  label(content: sub)
                end
              end
            end
          end
        end

        # SPEC-TUI-COMPLETION §4 B2 (D-102): render the slash-command menu
        # inline above the prompt bar when the menu is open. Ratatouille has
        # no overlay primitive; a second row renders below the transcript.
        if model.menu != nil do
          render_menu(model)
        end
      end
    end

    # Render up to @menu_max_entries entries as an inline panel above the prompt.
    # The selected row is highlighted with bold. Row format:
    #   "/name  — description  [origin]"
    @menu_max_entries 8

    defp render_menu(%{menu: %{entries: entries, selected: selected}} = _model) do
      visible = Enum.take(entries, @menu_max_entries)

      row do
        column(size: 12) do
          panel title: "commands (↑↓ navigate · Enter select · Esc dismiss)" do
            visible
            |> Enum.with_index()
            |> Enum.map(fn {{_score, entry}, idx} ->
              text = menu_entry_text(entry)

              if idx == selected do
                label(content: "> " <> text, attributes: [:bold])
              else
                label(content: "  " <> text)
              end
            end)
          end
        end
      end
    end

    defp menu_entry_text(%{name: name, description: desc, origin: origin}) do
      origin_tag = "[" <> to_string(origin) <> "]"

      if desc != "" do
        name <> "  — " <> desc <> "  " <> origin_tag
      else
        name <> "  " <> origin_tag
      end
    end

    @impl true
    def subscribe(%{last_assistant: la}) when is_binary(la) and la != "" do
      Subscription.interval(@tick_interval_streaming, :tick)
    end

    def subscribe(_model), do: Subscription.interval(@tick_interval_idle, :tick)

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
        interval: @tick_interval_idle,
        # D-003 ([C7] / AC-4): bare `{:ch, ?q}` is intentionally absent.
        # The `q` key is forwarded to `update/2` where it is handled
        # context-sensitively: quit on empty prompt, append on non-empty.
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
      # Render multi-line editor: one label per logical line.
      # The cursor glyph is injected at the grapheme-column position (D-142).
      # Search mode shows a prefix indicating active Ctrl+R.
      # Variables must be computed before entering the view DSL macro.
      prompt_labels = build_prompt_labels(model)

      bar do
        prompt_labels
      end
    end

    defp build_prompt_labels(model) do
      lines = Editor.render_lines(model.editor)
      prefix = if model.search != nil, do: "(search `" <> model.search.query <> "`) ", else: "> "

      lines
      |> Enum.with_index()
      |> Enum.map(fn {{line, cursor_col}, idx} ->
        line_prefix = if idx == 0, do: prefix, else: "  "

        content =
          if cursor_col != nil do
            inject_cursor(line, cursor_col)
          else
            line
          end

        label(content: line_prefix <> content)
      end)
    end

    # Inject the cursor glyph at grapheme position `col` in `line`.
    defp inject_cursor(line, col) do
      graphemes = String.graphemes(line)
      {before_cursor, after_cursor} = Enum.split(graphemes, col)
      IO.iodata_to_binary([before_cursor, @cursor_glyph, after_cursor])
    end

    # D-003 ([C7] / AC-4): context-aware quit. On an empty prompt, stop the
    # Ratatouille runtime supervisor so the TUI exits cleanly. The supervisor
    # is located via the registered `Tau.TUI.Supervisor` DynamicSupervisor
    # rather than storing its pid in the model (which would require a
    # Ratatouille API extension). On a non-empty prompt, append "q" as
    # ordinary input.
    defp quit_or_append(model) do
      if Editor.empty?(model.editor) do
        spawn(fn ->
          Tau.TUI.Supervisor
          |> DynamicSupervisor.which_children()
          |> Enum.each(fn {_, pid, _, _} -> Supervisor.stop(pid) end)
        end)

        model
      else
        model
        |> editor_insert("q")
        |> update_menu()
      end
    end

    # Insert a character string into the editor.
    defp editor_insert(model, text) do
      %{model | editor: Editor.insert(model.editor, text), search: nil}
    end

    # Backspace in the editor.
    defp editor_backspace(model) do
      %{model | editor: Editor.backspace(model.editor), search: nil}
    end

    # History navigation: prev (older). On empty editor, navigate to
    # most recent entry. On non-empty, allow navigation from any state.
    defp history_prev(model) do
      current_text = Editor.text(model.editor)
      {new_hist, entry} = History.prev(model.history, current_text)

      case entry do
        nil ->
          %{model | history: new_hist}

        text ->
          new_editor = Editor.new() |> Editor.insert(text) |> Editor.move_line_end()
          %{model | history: new_hist, editor: new_editor, search: nil}
      end
    end

    # History navigation: next (newer / restore draft).
    defp history_next(model) do
      {new_hist, entry} = History.next(model.history)

      case entry do
        nil ->
          %{model | history: new_hist}

        text ->
          new_editor = Editor.new() |> Editor.insert(text) |> Editor.move_line_end()
          %{model | history: new_hist, editor: new_editor, search: nil}
      end
    end

    # Ctrl+R: enter reverse-search mode (D-147).
    defp search_start(model) do
      case model.search do
        nil ->
          %{model | search: %{query: "", pre_search_editor: model.editor}}

        %{query: q} ->
          # Already in search: extend query with an additional character
          # is handled via the char handler; this just re-enters.
          %{model | search: %{query: q, pre_search_editor: model.editor}}
      end
    end

    # Accept the current search match and exit search mode (D-147).
    defp search_accept(%{search: nil} = model), do: submit(model)

    defp search_accept(%{search: %{query: query}, history: hist} = model) do
      case History.search(hist, query) do
        {:match, text} ->
          new_editor = Editor.new() |> Editor.insert(text) |> Editor.move_line_end()
          %{model | editor: new_editor, search: nil}

        :no_match ->
          %{model | search: nil}
      end
    end

    # Esc in search mode: restore pre-search buffer (D-147).
    defp search_cancel(%{search: %{pre_search_editor: pre}} = model) do
      %{model | editor: pre, search: nil}
    end

    defp search_cancel(model), do: %{model | search: nil}

    # --- Menu helpers (SPEC-TUI-COMPLETION) ---

    # Builtins floor: used when no catalog has been received yet (D-104).
    defp catalog_floor do
      Builtin.table()
      |> Enum.map(fn {name, mod} ->
        desc =
          if function_exported?(mod, :description, 0), do: mod.description(), else: ""

        %{name: name, description: desc, origin: :builtin}
      end)
      |> Enum.sort_by(& &1.name)
    end

    # Derive the current candidate list: use received catalog or fall back to builtins.
    defp effective_catalog(%{catalog: nil}), do: catalog_floor()
    defp effective_catalog(%{catalog: entries}), do: entries

    # After any input change, recompute whether the menu should be open/closed/re-filtered.
    # Menu opens when input is a /-prefixed whitespace-free token.
    # Menu stays open and re-filters while the token remains whitespace-free.
    # Menu closes if the input becomes empty, has whitespace, or no longer starts with /.
    defp update_menu(model) do
      input = Editor.text(model.editor)
      trimmed = String.trim_leading(input)

      if String.starts_with?(trimmed, "/") and not String.contains?(trimmed, " ") do
        # Menu should be open; compute the query (everything after the /).
        query = String.slice(trimmed, 1..-1//1)
        candidates = effective_catalog(model)

        ranked = Fuzzy.match(query, candidates)

        selected = clamp(Map.get(model.menu || %{}, :selected, 0), length(ranked) - 1)

        %{model | menu: %{query: query, entries: ranked, selected: selected}}
      else
        # Input doesn't look like a slash-command token — close the menu.
        %{model | menu: nil}
      end
    end

    # Close menu if the input now contains whitespace (space was typed).
    defp close_menu_if_whitespace(model) do
      input = Editor.text(model.editor)

      if String.contains?(input, " ") do
        %{model | menu: nil}
      else
        model
      end
    end

    # Move the selection by `delta` rows, clamped to [0, count-1].
    defp menu_navigate(%{menu: nil} = model, _delta), do: model

    defp menu_navigate(%{menu: menu} = model, delta) do
      count = length(menu.entries)
      new_selected = clamp(menu.selected + delta, count - 1)
      %{model | menu: %{menu | selected: new_selected}}
    end

    # Accept the currently-selected menu entry: fill input with `name <> " "` and close menu.
    # D-106: MUST NOT submit the turn.
    defp menu_accept(%{menu: nil} = model), do: model

    defp menu_accept(%{menu: %{entries: [], selected: _}} = model) do
      %{model | menu: nil}
    end

    defp menu_accept(%{menu: %{entries: entries, selected: selected}} = model) do
      idx = clamp(selected, length(entries) - 1)
      {_score, entry} = Enum.at(entries, idx)
      new_editor = Editor.new() |> Editor.insert(entry.name <> " ")
      %{model | editor: new_editor, menu: nil}
    end

    defp clamp(_n, max) when max < 0, do: 0
    defp clamp(n, _max) when n < 0, do: 0
    defp clamp(n, max) when n > max, do: max
    defp clamp(n, _max), do: n

    defp submit(model) do
      text = Editor.text(model.editor)

      cond do
        # D-145: backslash before Enter → insert newline into editor buffer
        # (the portable multi-line path). Strip the trailing backslash and
        # replace it with a newline in the editor.
        String.ends_with?(text, "\\") ->
          # Remove the backslash and insert a real newline
          stripped = String.slice(text, 0..-2//1)

          new_editor =
            Editor.new()
            |> Editor.insert(stripped)
            |> Editor.newline()

          %{model | editor: new_editor, search: nil}

        Editor.empty?(model.editor) ->
          model

        true ->
          # Normal submit
          Tau.send(model.session_id, text)
          new_hist = History.push(model.history, text)
          Store.append(model.history_data_dir, model.history_cwd, text)

          %{
            model
            | editor: Editor.new(),
              history: new_hist,
              search: nil,
              transcript: bounded_append(model.transcript, {"> " <> text, []}),
              status: :sending
          }
      end
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
              # D-028 / [C52-B5]: render markdown (CommonMark + GFM tables)
              # in the TUI pane. Render.Markdown emits {content, attrs} tuples;
              # carry both through model.transcript so render/1 can apply attrs
              # to each label (AC-6: bold/colour/underline reach the terminal).
              styled_lines = Markdown.render(t)
              [{"[assistant]", []} | styled_lines]

            # Thinking models (Qwen3, DeepSeek-R1) emit chain-of-thought
            # via Thinking* events. Surface them so a long think doesn't
            # look like the TUI is hung.
            %{type: :thinking, text: t} when is_binary(t) and t != "" ->
              [{"[thinking] " <> t, []}]

            %{type: :tool_call, name: n} ->
              [{"[tool_call] " <> n <> "(...)", []}]

            _ ->
              []
          end
        end)

      %{
        model
        | status: :idle,
          transcript: bounded_append_many(model.transcript, transcript_lines),
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
          transcript: bounded_append(model.transcript, {"[cancelled: " <> reason_str <> "]", []}),
          last_assistant: nil
      }
    end

    defp on_session_end(model, %{reason: reason}) do
      reason_str = inspect(reason)

      %{
        model
        | status: "ended: " <> reason_str,
          transcript:
            bounded_append(model.transcript, {"[session ended: " <> reason_str <> "]", []}),
          last_assistant: nil
      }
    end

    # Bounded ring-buffer helpers: keep at most @transcript_cap entries.
    # Each entry is a {text, attrs} tuple. Drop oldest entries from the head
    # when the cap is exceeded. The display shows recent content; older content
    # is gone from the model (not just clipped at render time, preventing
    # unbounded memory growth).
    defp bounded_append(list, item) do
      new_list = list ++ [item]

      if length(new_list) > @transcript_cap do
        Enum.drop(new_list, length(new_list) - @transcript_cap)
      else
        new_list
      end
    end

    defp bounded_append_many(list, items) do
      Enum.reduce(items, list, &bounded_append(&2, &1))
    end
  end
end
