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
    alias Tau.TUI.SubagentTree
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
        # nil = normal mode; map = search mode with :query, :pre_search_editor,
        # and :search_index for cycling through matches.
        search: nil,
        # #338: remember data_dir and cwd for Store.append on submit.
        history_data_dir: data_dir,
        history_cwd: cwd,
        transcript: [],
        tool_output: [],
        # D-150 (SPEC-TUI-HEADLESS §5c): sub-agent tree — pure derived
        # render state, folded synchronously by on_subagent_*/2 handlers.
        # Map of subagent_id => %SubagentTree.SubagentNode{}.
        # No GenServer; no process. OTP non-negotiables #1/#3.
        subagents: %{},
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

        # D-082 (#339 / SPEC-USER-TURN §6): restore queued steering messages to
        # the input editor when a cancel is issued mid-turn. The FSM drains the
        # steering queue back to the user via this event. The TUI repopulates the
        # editor with the first queued message (joining multiple with "\n" as a
        # best-effort single-line representation; the #338 multi-line editor
        # handles multi-line content natively). Idempotent: re-delivery of the
        # same event replaces the editor with the same content.
        %Tau.Session.Events.QueueRestored{messages: msgs} when msgs != [] ->
          text =
            msgs
            |> Enum.map(fn
              %Tau.Message.User{content: content} ->
                content
                |> Enum.filter(&match?(%{type: :text}, &1))
                |> Enum.map_join("\n", & &1.text)

              s when is_binary(s) ->
                s

              _ ->
                ""
            end)
            |> Enum.reject(&(&1 == ""))
            |> Enum.join("\n")

          new_editor = restore_editor_from_text(text)
          %{model | editor: new_editor}

        %Tau.Session.Events.QueueRestored{} ->
          model

        # D-150..D-154 (SPEC-TUI-HEADLESS §5c): sub-agent lifecycle events.
        # Fold into the sub-agent tree AND append boxed markers to the transcript.
        # SubagentStart: add node + append start marker line.
        %Tau.Session.Events.SubagentStart{} = e ->
          on_subagent_start(model, e)

        # SubagentProgress: update node state (tool_calls, last_activity).
        %Tau.Session.Events.SubagentProgress{} = e ->
          on_subagent_progress(model, e)

        # SubagentCost: update node cost fields.
        %Tau.Session.Events.SubagentCost{} = e ->
          on_subagent_cost(model, e)

        # SubagentEnd: transition node to terminal state + append end marker line.
        %Tau.Session.Events.SubagentEnd{} = e ->
          on_subagent_end(model, e)

        _ ->
          model
      end
    end

    # Route terminal key events to sub-handlers by event shape.
    # FIX-8: mod-bearing events MUST reach handle_alt regardless of whether
    # `key` is also present. Check mod first so alt-chords are not shadowed
    # by the key-only handler. D-141: unrecognised alt-chords MUST be no-ops.
    #
    # Termbox event shapes (clause ordering is load-bearing):
    #   alt-chord:       %{mod: N, key: _, ch: _, ...}  where N != 0
    #   printable char:  %{mod: 0, key: 0, ch: CP, ...} where CP != 0
    #   control/special: %{mod: 0, key: N, ch: 0, ...}  where N != 0
    #
    # Clause 2 MUST guard `ch != 0` so printable chars do NOT fall through
    # to clause 3 (key handler). Without the guard, key=0 printable events
    # match the `%{key: key}` clause and are silently dropped in
    # handle_readline_key's catch-all, breaking typed character input (AC-H2).
    defp handle_event(model, %{mod: mod} = event) when mod != 0 do
      ch = Map.get(event, :ch, 0)
      key = Map.get(event, :key, 0)
      handle_alt(model, ch, key)
    end

    defp handle_event(model, %{ch: ch}) when ch != 0, do: handle_char(model, ch)
    defp handle_event(model, %{key: key} = event), do: handle_key(model, key, event)
    defp handle_event(model, _), do: model

    # Handle events with a `key:` code. Dispatches to sub-handlers to keep
    # cyclomatic complexity within bounds. Clause ordering is load-bearing.
    defp handle_key(model, key, _event) do
      case key do
        # Enter — context-aware: menu → accept, search → accept, busy → steer, else → submit/continue
        13 when model.menu != nil ->
          menu_accept(model)

        13 when model.search != nil ->
          search_accept(model)

        # D-077 (#339 / AC-2): Enter while busy enqueues a steering message delivered
        # at the next tool-round boundary (before the next provider call). The input
        # is cleared and the queued text is shown in the transcript for feedback.
        13 when model.status in [:streaming, :sending] or is_binary(model.status) ->
          steer(model)

        # FIX-2: Enter with trailing backslash → strip backslash, insert newline.
        # Avoids submit, preserving existing multi-line structure (D-145).
        13 ->
          submit_or_continue(model)

        # Ctrl+J — guaranteed newline at cursor (D-145)
        10 ->
          %{model | editor: Editor.newline(model.editor), search: nil}

        # Esc — context-aware
        27 when model.menu != nil ->
          %{model | menu: nil}

        27 when model.search != nil ->
          search_cancel(model)

        # D-078 (#339 / AC-6): Esc while idle → clear the input editor, never quit.
        # Quit stays Ctrl+C (unconditional, registered in start_runtime_supervisor/0).
        # Context-aware: busy → cancel (existing ADR-0017 path); idle → clear input.
        27 when model.status == :idle ->
          clear_input(model)

        27 ->
          cancel(model)

        # Space (termbox quirk: key 32, not ch 32)
        32 when model.search != nil ->
          %{model | search: %{model.search | query: model.search.query <> " ", search_index: 0}}

        32 ->
          model |> editor_insert(" ") |> close_menu_if_whitespace()

        # Backspace (key 127 and 8)
        bsp when bsp in [127, 8] and model.search != nil ->
          %{
            model
            | search: %{
                model.search
                | query: String.slice(model.search.query, 0..-2//1),
                  search_index: 0
              }
          }

        bsp when bsp in [127, 8] ->
          model |> editor_backspace() |> update_menu()

        # Readline chords and arrows delegate to further helpers
        _ ->
          handle_readline_key(model, key)
      end
    end

    # Readline editing chords (Ctrl+A/E/W/U/K/Y/D/P/N/R) and arrow keys.
    # Split from handle_key/3 to keep cyclomatic complexity within bounds.
    #
    # FIX-1: Up/down arrows are edge-aware:
    #   - Up when cursor on first line → history_prev (existing behaviour)
    #   - Up when cursor on non-first line → Editor.move_up
    #   - Down when cursor on last line → history_next (existing behaviour)
    #   - Down when cursor on non-last line → Editor.move_down
    # Ctrl+P/Ctrl+N remain unconditional history recall.
    defp handle_readline_key(model, key) do
      case key do
        1 ->
          %{model | editor: Editor.move_line_start(model.editor), search: nil}

        4 ->
          %{model | editor: Editor.delete_forward(model.editor), search: nil}

        5 ->
          %{model | editor: Editor.move_line_end(model.editor), search: nil}

        11 ->
          %{model | editor: Editor.kill_to_line_end(model.editor), search: nil}

        14 ->
          history_next(model)

        16 ->
          history_prev(model)

        18 ->
          search_start(model)

        21 ->
          %{model | editor: Editor.kill_to_line_start(model.editor), search: nil}

        23 ->
          %{model | editor: Editor.kill_word_back(model.editor), search: nil}

        25 ->
          %{model | editor: Editor.yank(model.editor), search: nil}

        # Arrow up: menu navigation takes priority, then edge-aware cursor/history
        65_517 when model.menu != nil ->
          menu_navigate(model, -1)

        65_517 ->
          arrow_up(model)

        # Arrow down: menu navigation takes priority, then edge-aware cursor/history
        65_516 when model.menu != nil ->
          menu_navigate(model, 1)

        65_516 ->
          arrow_down(model)

        65_515 ->
          %{model | editor: Editor.move_char_left(model.editor), search: nil}

        65_514 ->
          %{model | editor: Editor.move_char_right(model.editor), search: nil}

        _ ->
          model
      end
    end

    # FIX-1: Edge-aware up arrow. On first buffer line → history_prev.
    # On interior lines → Editor.move_up (inter-line cursor movement).
    defp arrow_up(model) do
      {row, _col} = model.editor.cursor

      if row == 0 do
        history_prev(model)
      else
        %{model | editor: Editor.move_up(model.editor), search: nil}
      end
    end

    # FIX-1: Edge-aware down arrow. On last buffer line → history_next.
    # On interior lines → Editor.move_down (inter-line cursor movement).
    defp arrow_down(model) do
      {row, _col} = model.editor.cursor
      last_row = length(model.editor.lines) - 1

      if row >= last_row do
        history_next(model)
      else
        %{model | editor: Editor.move_down(model.editor), search: nil}
      end
    end

    # Handle Alt-chord events (mod != 0). Best-effort: degrade to no-op
    # if termbox/tmux mangles the ESC-prefix (D-141).
    # FIX-3: Ctrl+R search mode — Ctrl+R while already in search cycles to next match.
    #
    # Note: handle_alt/3 receives (model, ch, key) where ch is the printable
    # codepoint (0 for control keys) and key is the control-key code. Both are
    # needed to distinguish Alt+Enter (key=13, ch=0) from Alt+arrow (key=65_514,
    # ch=0) and other alt-chords that happen to carry ch=0.
    defp handle_alt(model, ?y, _key),
      do: %{model | editor: Editor.yank_pop(model.editor), search: nil}

    defp handle_alt(model, ?b, _key),
      do: %{model | editor: Editor.move_word_left(model.editor), search: nil}

    defp handle_alt(model, ?f, _key),
      do: %{model | editor: Editor.move_word_right(model.editor), search: nil}

    # D-078 (#339 / AC-3): Alt+Enter — enqueue a follow-up message delivered
    # after the whole turn completes. Termbox delivers Alt+Enter as mod != 0,
    # ch = 0, key = 13 (Return). Distinguish from other alt-chords with ch=0
    # (e.g. Alt+arrow: ch=0, key=65_514) by also checking the key field.
    #
    # Fallback documented in case Alt+Enter is unreliable in some terminals
    # (e.g. tmux mangles Alt-chords): document Ctrl+J (key 10) as an alternative
    # follow-up trigger in the on-screen help (AC-7).
    defp handle_alt(model, 0, 13) do
      followup(model)
    end

    # All other alt-chords (ch=0 with non-Return key, or unrecognised ch):
    # no-op (D-141: MUST NOT insert literal char).
    defp handle_alt(model, _ch, _key), do: model

    # Handle printable character events (ch != 0, no mod).
    # D-003: `q` is context-aware on empty prompt.
    defp handle_char(model, 0), do: model

    defp handle_char(model, ?q) when model.search == nil do
      quit_or_append(model)
    end

    defp handle_char(model, ch) when model.search != nil do
      new_search = %{model.search | query: model.search.query <> <<ch::utf8>>, search_index: 0}
      %{model | search: new_search}
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

    # D-078 (#339 / AC-7): honest status-bar keybinding hint. The hint changes
    # based on whether the session is busy or idle. Claude Code's dishonest hint
    # (claiming "esc to interrupt" when Esc only moves queued prompts) is exactly
    # the bug #339 exists to beat.
    defp status_bar(model) do
      hint = status_bar_hint(model.status)

      bar do
        label(
          content:
            "session: " <>
              model.session_id <>
              status_bar_coding_agent(model) <>
              " | status: " <>
              to_string(model.status) <>
              " | " <>
              hint
        )
      end
    end

    # Busy states: streaming/sending/cancelled status strings.
    defp status_bar_hint(:idle) do
      "<Enter> submit · <Esc> clear · <Ctrl-C> quit"
    end

    defp status_bar_hint(:streaming), do: status_bar_hint_busy()
    defp status_bar_hint(:sending), do: status_bar_hint_busy()

    defp status_bar_hint(status) when is_binary(status) do
      # Covers cancelled/ended status strings — session is not actively busy
      # but also not cleanly idle; show idle hint so user can type.
      "<Enter> submit · <Esc> clear · <Ctrl-C> quit"
    end

    defp status_bar_hint(_), do: status_bar_hint_busy()

    defp status_bar_hint_busy do
      "<Enter> steer · <Alt+Enter> follow-up · <Esc> interrupt"
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
      # Search mode shows a prefix indicating active Ctrl+R and the current match.
      # Variables must be computed before entering the view DSL macro.
      prompt_labels = build_prompt_labels(model)

      bar do
        prompt_labels
      end
    end

    defp build_prompt_labels(model) do
      lines = Editor.render_lines(model.editor)

      prefix =
        if model.search != nil do
          # FIX-3 / FIX-C1: show the live match in the prompt, honouring the
          # current search_index so the displayed entry matches what
          # search_accept/1 would accept at the current cycle position (D-147).
          match_text =
            case search_nth_match(model.history, model.search.query, model.search.search_index) do
              {:match, t} -> t
              :no_match -> ""
            end

          "(reverse-i-search '" <> model.search.query <> "': " <> match_text <> ") "
        else
          "> "
        end

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
    #
    # FIX f-12: restore multi-line entries by splitting on "\n" and rebuilding
    # real lines rather than inserting a "\n"-joined flat string.
    defp history_prev(model) do
      current_text = Editor.text(model.editor)
      {new_hist, entry} = History.prev(model.history, current_text)

      case entry do
        nil ->
          %{model | history: new_hist}

        text ->
          new_editor = restore_editor_from_text(text)
          %{model | history: new_hist, editor: new_editor, search: nil}
      end
    end

    # History navigation: next (newer / restore draft).
    # FIX f-12: same multi-line restore as history_prev.
    defp history_next(model) do
      {new_hist, entry} = History.next(model.history)

      case entry do
        nil ->
          %{model | history: new_hist}

        text ->
          new_editor = restore_editor_from_text(text)
          %{model | history: new_hist, editor: new_editor, search: nil}
      end
    end

    # Reconstruct an Editor from a potentially multi-line text.
    # Splits on "\n" so that each logical line becomes a separate buffer line.
    defp restore_editor_from_text(text) do
      lines = String.split(text, "\n")
      last_row = length(lines) - 1
      last_col = String.length(Enum.at(lines, last_row, ""))

      %Editor{lines: lines, cursor: {last_row, last_col}}
    end

    # Ctrl+R: enter reverse-search mode (D-147).
    # FIX-3: entering Ctrl+R while already in search mode advances to
    # the next-older match (cycles) rather than resetting.
    defp search_start(model) do
      case model.search do
        nil ->
          %{model | search: %{query: "", pre_search_editor: model.editor, search_index: 0}}

        %{query: q, search_index: idx} ->
          # Already in search: cycle to next match index for same query
          next_idx = idx + 1
          %{model | search: %{model.search | query: q, search_index: next_idx}}
      end
    end

    # Accept the current search match and exit search mode (D-147).
    defp search_accept(%{search: nil} = model), do: submit(model)

    defp search_accept(%{search: %{query: query}, history: hist} = model) do
      case search_nth_match(hist, query, Map.get(model.search, :search_index, 0)) do
        {:match, text} ->
          new_editor = restore_editor_from_text(text)
          %{model | editor: new_editor, search: nil}

        :no_match ->
          %{model | search: nil}
      end
    end

    # Find the Nth match (0-indexed) for a query in history entries.
    # Falls back to the first match when N exceeds the match count.
    defp search_nth_match(%History{entries: entries}, query, n) do
      lower = String.downcase(query)
      matches = Enum.filter(entries, fn e -> String.contains?(String.downcase(e), lower) end)

      case matches do
        [] -> :no_match
        _ -> {:match, Enum.at(matches, rem(n, length(matches)))}
      end
    end

    defp search_nth_match(_hist, _query, _n), do: :no_match

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

    # FIX-2: submit_or_continue checks for trailing backslash BEFORE submitting.
    # If the grapheme immediately before the cursor is `\`, strip it and insert
    # a real newline at cursor position instead of submitting the turn (D-145).
    # This preserves existing multi-line structure and cursor position.
    defp submit_or_continue(model) do
      ed = model.editor
      {row, col} = ed.cursor
      line = Enum.at(ed.lines, row, "")
      graphemes = String.graphemes(line)

      if col > 0 and Enum.at(graphemes, col - 1) == "\\" do
        # Backslash immediately before cursor: delete it and insert newline
        ed_no_bs = Editor.backspace(ed)
        ed_newline = Editor.newline(ed_no_bs)
        %{model | editor: ed_newline, search: nil}
      else
        submit(model)
      end
    end

    defp submit(model) do
      text = Editor.text(model.editor)

      if Editor.empty?(model.editor) do
        model
      else
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

    # D-077 (#339 / AC-2): steer — enqueue the current editor text as a steering
    # message (delivered at the next tool-round boundary, before the next provider
    # call). Only enqueues when the editor is non-empty. Clears the editor and
    # appends a "[queued steer]" notice to the transcript for user feedback.
    defp steer(model) do
      text = Editor.text(model.editor)

      if Editor.empty?(model.editor) do
        model
      else
        Tau.steer(model.session_id, text)

        %{
          model
          | editor: Editor.new(),
            search: nil,
            transcript: bounded_append(model.transcript, {"[queued steer] " <> text, []})
        }
      end
    end

    # D-078 (#339 / AC-3): followup — enqueue the current editor text as a
    # follow-up message (delivered after the whole turn completes). Clears the
    # editor and appends a "[queued follow-up]" notice to the transcript.
    # Also used for Alt+Enter while idle (falls back to normal submit in that case).
    defp followup(model) do
      text = Editor.text(model.editor)

      cond do
        Editor.empty?(model.editor) ->
          model

        model.status == :idle ->
          # Idle: treat as normal submit (both tiers collapse to "run now").
          submit(model)

        true ->
          Tau.send(model.session_id, text)

          %{
            model
            | editor: Editor.new(),
              search: nil,
              transcript: bounded_append(model.transcript, {"[queued follow-up] " <> text, []})
          }
      end
    end

    # D-078 (#339 / AC-6): clear_input — clear the editor without quitting.
    # Called on Esc while idle. Never quits (quit stays Ctrl+C).
    defp clear_input(model) do
      %{model | editor: Editor.new(), search: nil}
    end

    # D-150 (SPEC-TUI-HEADLESS §5c): fold SubagentStart into the tree and
    # append a boxed start marker to the transcript (AC-1).
    # If the fold rejects the event (unknown kind, D-152), skip the marker too.
    defp on_subagent_start(model, e) do
      new_tree = SubagentTree.fold(model.subagents, e)

      if Map.has_key?(new_tree, e.subagent_id) do
        node = new_tree[e.subagent_id]
        marker = SubagentTree.format_start_marker(node)

        %{
          model
          | subagents: new_tree,
            transcript: bounded_append(model.transcript, {marker, []})
        }
      else
        # Unknown kind — tree unchanged, no marker (D-152).
        model
      end
    end

    # D-151 (SPEC-TUI-HEADLESS §5c): fold SubagentProgress — updates the node's
    # tool_calls count and last_activity. No transcript line; the end marker
    # carries the final rollup (AC-3).
    defp on_subagent_progress(model, e) do
      %{model | subagents: SubagentTree.fold(model.subagents, e)}
    end

    # D-153 (SPEC-TUI-HEADLESS §5c): fold SubagentCost — updates cost fields
    # in the node. Does NOT affect the parent's own cost display (R4/AC-4).
    defp on_subagent_cost(model, e) do
      %{model | subagents: SubagentTree.fold(model.subagents, e)}
    end

    # D-154 (SPEC-TUI-HEADLESS §5c): fold SubagentEnd — transitions node to
    # terminal state and appends the boxed end marker to the transcript (AC-2).
    # If the fold ignores the event (unknown subagent_id, D-152), skip marker.
    defp on_subagent_end(model, e) do
      new_tree = SubagentTree.fold(model.subagents, e)

      case Map.get(new_tree, e.subagent_id) do
        nil ->
          # Unknown subagent_id — no node, no marker (D-152).
          model

        node ->
          marker = SubagentTree.format_end_marker(node)

          %{
            model
            | subagents: new_tree,
              transcript: bounded_append(model.transcript, {marker, []})
          }
      end
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

            # B1 rule (D-151): if this tool call's id is owned by a known
            # sub-agent, do NOT render it as a bare [tool_call] line —
            # the sub-agent start/end markers own the visual representation.
            # For Agent tool calls without an owned id, fall back to the
            # legacy inline render (backwards compat).
            %{type: :tool_call, id: tcid, name: n} when is_binary(tcid) ->
              if SubagentTree.tool_call_owned?(model.subagents, tcid) do
                []
              else
                [{"[tool_call] " <> n <> "(...)", []}]
              end

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

    defp on_tool_start(model, %{tool_call_id: tcid, name: n, arguments: args}) do
      # B1 rule (D-151): skip tool calls owned by a known sub-agent — the
      # sub-agent marker owns the render. Still record non-owned calls.
      if SubagentTree.tool_call_owned?(model.subagents, tcid) do
        model
      else
        %{model | tool_output: model.tool_output ++ ["▶ " <> n <> " " <> inspect(args)]}
      end
    end

    defp on_tool_end(model, %{tool_call_id: tcid, result: %{content: c, is_error: e}}) do
      # B1 rule (D-151): skip tool results owned by a known sub-agent.
      if SubagentTree.tool_call_owned?(model.subagents, tcid) do
        model
      else
        prefix = if e, do: "✗", else: "✓"

        summary =
          if is_binary(c),
            do: String.slice(c, 0..160),
            else: c |> inspect() |> String.slice(0..160)

        %{model | tool_output: model.tool_output ++ [prefix <> " " <> summary]}
      end
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
