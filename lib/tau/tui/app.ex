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
    alias Tau.TUI.StatusBar
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

    # Valid permissions modes for /perms command (AC-B6, D-170).
    @valid_perms_modes [:default, :accept_edits, :plan]

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
        # Editor replaces the bare `input` string field.
        editor: Editor.new(),
        # Per-cwd history, pre-loaded from Store.
        history: history,
        # Transient Ctrl+R reverse-search sub-state (D-147).
        # nil = normal mode; map = search mode with :query, :pre_search_editor,
        # and :search_index for cycling through matches.
        search: nil,
        # Remember data_dir and cwd for Store.append on submit.
        history_data_dir: data_dir,
        history_cwd: cwd,
        transcript: [],
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
        menu: nil,
        # D-170 / SPEC-PERMISSION-PROMPTS §7: permission approval dialog.
        # Queue of %PermissionRequest{} structs pending user decision.
        # The dialog renders the head request as a modal; y/n resolve it.
        pending_permissions: [],
        # D-171: active permissions mode — :default | :accept_edits | :plan.
        # Seeded from RuntimeOpts at init; changed via /perms <mode> command.
        permissions_mode: Map.get(runtime_opts, :permissions_mode, :default),
        # D-160..D-169 / SPEC-TUI-HEADLESS §5d: status surface fields.
        # AC-1: seed provider and model at init so the status bar shows the
        # active model on the FIRST rendered frame (not only after the first
        # SessionStart tick drain). Fall back to Tau.Provider.default/0 and
        # provider.default_model/0 so "no model" never appears at launch.
        provider: init_provider(runtime_opts),
        model: init_model(runtime_opts),
        # Accumulated token usage from the session (folded from Tau.Cost ETS).
        usage: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0},
        # context_tokens: latest completed turn's input_tokens (overwrite, not sum —
        # S-4 / D-169: avoids >100% bug). Pre-first-turn reads 0.
        context_tokens: 0,
        # context_window: resolved via context_window/1 optional callback.
        # nil = unknown (fall back to compaction_threshold_tokens, render ~NN%).
        context_window: nil,
        # compaction: :idle | :running. Driven by CompactionStarted/Finished events.
        compaction: :idle,
        # warn_level: prior level for transition-only telemetry (D-168).
        warn_level: :ok
      }
    end

    defp put_if(opts, _key, nil), do: opts
    defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

    # AC-1 (D-160): resolve the active provider at init time so the status bar
    # shows the real provider on the first rendered frame. Falls back to the
    # application default when none is specified via CLI.
    defp init_provider(runtime_opts) do
      Map.get(runtime_opts, :provider) || Tau.Provider.default()
    end

    # AC-1 (D-160): resolve the active model at init time so the status bar
    # shows the real model id on the first rendered frame. Falls back to the
    # provider's default_model/0 when none is specified via CLI.
    defp init_model(runtime_opts) do
      case Map.get(runtime_opts, :model) do
        nil ->
          provider = init_provider(runtime_opts)

          if is_atom(provider) and function_exported?(provider, :default_model, 0) do
            provider.default_model()
          else
            nil
          end

        model ->
          model
      end
    end

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

        # Delegate the remaining session-state events to a sub-handler to
        # keep update/2 cyclomatic complexity within the Credo limit (≤ 25).
        event ->
          update_session_event(model, event)
      end
    end

    # Sub-handler for session-state events that do not fit the primary
    # update/2 case without exceeding the complexity budget.
    # D-160, D-103, D-170, D-082, D-150..D-154 all live here.
    defp update_session_event(model, event) do
      case event do
        # D-160 / SPEC-TUI-HEADLESS §5d: seed model/provider/context_window
        # from SessionStart. context_window resolved via optional callback.
        %Tau.Session.Events.SessionStart{model: m, provider: p} = e ->
          on_session_start_status(model, e, m, p)

        # D-160: ModelSwapped — update model segment in the status bar.
        # Do NOT string-scrape the accompanying SystemNotice (D-160 rationale).
        %Tau.Session.Events.ModelSwapped{} = e ->
          on_model_swapped(model, e)

        # D-163: CompactionStarted — transition compaction to :running.
        %Tau.Session.Events.CompactionStarted{} ->
          on_compaction_started(model)

        # D-164: CompactionFinished — clear compaction indicator regardless
        # of outcome (S-2: MUST fire on every :compacting exit, incl. abort/error).
        %Tau.Session.Events.CompactionFinished{} ->
          on_compaction_finished(model)

        # D-103 (SPEC-TUI-COMPLETION §4 B1): store the catalog and re-filter
        # the menu if it is currently open. Broadcast arrives at SessionStart
        # and after /reload (D-108).
        %Tau.Session.Events.CommandCatalog{entries: entries} ->
          model
          |> Map.put(:catalog, entries)
          |> update_menu()

        # D-170 / SPEC-PERMISSION-PROMPTS §7 AC-B1, AC-B8:
        # Push a PermissionRequest onto the pending_permissions queue.
        # The dialog renders the head; resolving it pops the head (AC-B2/B3).
        # Pure MVU state — no new process (OTP non-negotiables #3/#8).
        %Tau.Session.Events.PermissionRequest{} = req ->
          on_permission_request(model, req)

        # D-082 / SPEC-USER-TURN §6: restore queued steering messages to
        # the input editor when a cancel is issued mid-turn. The FSM drains the
        # steering queue back to the user via this event. The TUI repopulates the
        # editor with the first queued message (joining multiple with "\n" as a
        # best-effort single-line representation; the multi-line editor handles
        # multi-line content natively). Idempotent: re-delivery of the same
        # event replaces the editor with the same content.
        %Tau.Session.Events.QueueRestored{messages: msgs} when msgs != [] ->
          on_queue_restored(model, msgs)

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
    #
    # D-172 / SPEC-PERMISSION-PROMPTS §7 AC-B4: when the permission
    # dialog is open (pending_permissions non-empty), ALL input is captured by
    # the dialog. Only y/n resolve the head; every other keystroke is swallowed.
    # This check MUST precede the normal event routing (load-bearing clause order).
    defp handle_event(model, event) when is_map(model) do
      case Map.get(model, :pending_permissions, []) do
        [_ | _] -> handle_permission_dialog_event(model, event)
        _ -> handle_event_normal(model, event)
      end
    end

    defp handle_event_normal(model, %{mod: mod} = event) when mod != 0 do
      ch = Map.get(event, :ch, 0)
      key = Map.get(event, :key, 0)
      handle_alt(model, ch, key)
    end

    defp handle_event_normal(model, %{ch: ch}) when ch != 0, do: handle_char(model, ch)
    defp handle_event_normal(model, %{key: key} = event), do: handle_key(model, key, event)
    defp handle_event_normal(model, _), do: model

    # D-172 (AC-B2 / AC-B3 / AC-B4): permission dialog input handler.
    # y → allow_once and pop head; n → deny_once and pop head;
    # any other keystroke is swallowed (modal capture, AC-B4).
    defp handle_permission_dialog_event(model, %{ch: ?y}) do
      resolve_permission(model, :allow_once)
    end

    defp handle_permission_dialog_event(model, %{ch: ?n}) do
      resolve_permission(model, :deny_once)
    end

    # All other events are swallowed while the dialog is open (AC-B4).
    defp handle_permission_dialog_event(model, _event), do: model

    # Resolve the head permission request with `verdict`, pop it from the queue,
    # and (when a real session is running) call decide_permission/3.
    defp resolve_permission(%{pending_permissions: [head | rest]} = model, verdict) do
      # decide_permission/3 is a cast (non-blocking); call directly like Tau.send/2.
      Tau.Session.decide_permission(model.session_id, head.tool_call_id, verdict)
      %{model | pending_permissions: rest}
    end

    defp resolve_permission(model, _verdict), do: model

    # Handle events with a `key:` code. Dispatches to sub-handlers to keep
    # cyclomatic complexity within bounds. Clause ordering is load-bearing.
    defp handle_key(model, key, _event) do
      case key do
        # Enter — context-aware: menu → accept, search → accept, busy → steer, else → submit/continue
        13 when model.menu != nil ->
          menu_accept(model)

        13 when model.search != nil ->
          search_accept(model)

        # D-077 / AC-2: Enter while busy enqueues a steering message delivered
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

        # D-078 / AC-6: Esc while idle → clear the input editor, never quit.
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

    # D-078 / AC-3: Alt+Enter — enqueue a follow-up message delivered
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

              # D-158 / AC-3 (SPEC-TUI-HEADLESS §5c): live region — one line
              # per *running* sub-agent, derived from model.subagents every
              # frame so the tool-call count and activity excerpt update each
              # tick without a static frozen marker in the transcript.
              # Each line: "▶ sub-agent: <label> · <N> tool calls · <excerpt>"
              for {_id, node} <- model.subagents,
                  node.state == :running,
                  line <- [SubagentTree.format_live_line(node)],
                  sub <- Wrap.wrap(line, model.wrap_width) do
                label(content: sub)
              end
            end
          end
        end

        # D-172 / SPEC-PERMISSION-PROMPTS §7 AC-B1: render the
        # permission approval dialog when the queue is non-empty. Renders as
        # an inline panel below the transcript (Ratatouille has no overlay
        # primitive). Captures all input while open (AC-B4).
        if Map.get(model, :pending_permissions, []) != [] do
          render_permission_dialog(model)
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

    # D-172 / SPEC-PERMISSION-PROMPTS §7 AC-B1:
    # Render the permission approval dialog for the head of the queue.
    # Shows tool name, one-line argument summary, decision_reason, and options.
    defp render_permission_dialog(%{pending_permissions: [req | _]}) do
      args_summary =
        case req.arguments do
          args when map_size(args) == 0 -> ""
          args -> Enum.map_join(args, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
        end

      row do
        column(size: 12) do
          panel title: "Permission required — [y] allow once  [n] deny" do
            label(content: "tool: " <> req.name)

            if args_summary != "" do
              label(content: "args: " <> args_summary)
            end

            label(content: "reason: " <> req.decision_reason)
            label(content: "")
            label(content: "[y] allow once    [n] deny")
          end
        end
      end
    end

    defp render_permission_dialog(_model), do: nil

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

    # D-162 / SPEC-TUI-HEADLESS §5d: delegate to the pure StatusBar module.
    # The coding-agent segment is included when model.coding_agent is set, as before
    # (AC-9 regression: SPEC-CODING-AGENT §4 B1 must still render).
    defp status_bar(model) do
      StatusBar.render(status_bar_model(model))
    end

    # Build the status-bar model map for StatusBar.render/1, mixing in the
    # session_id, session status, and coding-agent info that StatusBar needs.
    # D-162 (AC-H1): session_id MUST be passed so render_text/1 can emit
    # "session: <id>" as the first segment (smoke-gate ~r/session:/ assertion).
    # D-171: permissions_mode passed to StatusBar for the mode indicator.
    defp status_bar_model(model) do
      base = %{
        session_id: Map.get(model, :session_id),
        model: Map.get(model, :model),
        provider: Map.get(model, :provider),
        usage:
          Map.get(model, :usage, %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0}),
        context_tokens: Map.get(model, :context_tokens, 0),
        context_window: Map.get(model, :context_window),
        compaction: Map.get(model, :compaction, :idle),
        status: model.status,
        permissions_mode: Map.get(model, :permissions_mode, :default)
      }

      # SPEC-CODING-AGENT §4 B1: append coding-agent segment when present (AC-9 regression).
      if model.coding_agent do
        Map.put(base, :coding_agent_label, inspect(model.coding_agent))
      else
        base
      end
    end

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

    # D-173: when the menu is open but has no entries (e.g. user
    # typed a complete command not in the autocomplete set like /perms), Enter
    # closes the menu and submits — the command is unambiguous and unambiguous
    # submission is the expected UX (no matches = no autocomplete needed).
    defp menu_accept(%{menu: %{entries: [], selected: _}} = model) do
      %{model | menu: nil} |> submit_or_continue()
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
        # D-173 / SPEC-PERMISSION-PROMPTS §7 AC-B6:
        # Intercept /perms <mode> in the TUI layer before sending to the session.
        # The mode is changed locally in the model; if a session is running,
        # set_permissions_mode/2 is called asynchronously (D-096: busy when not
        # :awaiting_user). AC-B7: when status != :idle the FSM rejects the call
        # and the local model update is also suppressed.
        if String.starts_with?(text, "/perms") do
          handle_perms_command(model, text)
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
    end

    # D-173 / SPEC-PERMISSION-PROMPTS §7 AC-B6/AC-B7:
    # Handle the /perms <mode> slash command in the TUI layer.
    # mode ∈ {:default, :accept_edits, :plan}.
    # AC-B7: while :streaming/:sending the mode does not change (FSM rejects).
    # No/invalid argument: no-op that reports current mode + valid set.
    defp handle_perms_command(model, text) do
      arg =
        case String.split(text, " ", parts: 2) do
          ["/perms", rest] -> String.trim(rest)
          _ -> ""
        end

      mode =
        case arg do
          "default" -> :default
          "accept_edits" -> :accept_edits
          "plan" -> :plan
          _ -> nil
        end

      model_cleared = %{model | editor: Editor.new(), search: nil}

      cond do
        mode == nil ->
          # No/invalid argument: report current mode + valid set (AC-B6).
          valid_set = Enum.map_join(@valid_perms_modes, ", ", &to_string/1)

          notice =
            "permissions_mode is #{model.permissions_mode}. " <>
              "Valid modes: #{valid_set}"

          %{model_cleared | transcript: bounded_append(model_cleared.transcript, {notice, []})}

        model.status in [:streaming, :sending] or is_binary(model.status) ->
          # AC-B7: mid-turn, do not change mode (FSM rejects :busy per D-096).
          model_cleared

        true ->
          # AC-B6: set mode locally and call FSM; set_permissions_mode/2 is a
          # cast (non-blocking), called directly like Tau.send/2.
          Tau.Session.set_permissions_mode(model.session_id, mode)
          %{model_cleared | permissions_mode: mode}
      end
    end

    defp cancel(model) do
      Tau.cancel(model.session_id)
      %{model | status: :idle}
    end

    # D-077 / AC-2: steer — enqueue the current editor text as a steering
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

    # D-078 / AC-3: followup — enqueue the current editor text as a
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

    # D-078 / AC-6: clear_input — clear the editor without quitting.
    # Called on Esc while idle. Never quits (quit stays Ctrl+C).
    defp clear_input(model) do
      %{model | editor: Editor.new(), search: nil}
    end

    # D-150 / D-158 (SPEC-TUI-HEADLESS §5c): fold SubagentStart into the tree.
    # No static start marker is appended to the transcript — the running sub-agent
    # appears in the live region (rendered every frame from model.subagents by render/1)
    # so the tool-call count and activity excerpt update live (AC-3).
    # The permanent `└─` end marker is appended by on_subagent_end/2 when the
    # node transitions to a terminal state (AC-2).
    # If the fold rejects the event (unknown kind, D-152), model is unchanged.
    defp on_subagent_start(model, e) do
      new_tree = SubagentTree.fold(model.subagents, e)

      if Map.has_key?(new_tree, e.subagent_id) do
        %{model | subagents: new_tree}
      else
        # Unknown kind — tree unchanged (D-152).
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

    # D-170 / SPEC-PERMISSION-PROMPTS §7 AC-B1, AC-B8:
    # Enqueue a PermissionRequest. Pure MVU — no process (OTP non-negotiables #3/#8).
    defp on_permission_request(model, req) do
      queue = Map.get(model, :pending_permissions, [])
      Map.put(model, :pending_permissions, queue ++ [req])
    end

    # D-082 / SPEC-USER-TURN §6: restore queued steering messages to the
    # editor from a %QueueRestored{} event. Extracted from update/2 to keep
    # cyclomatic complexity within bounds.
    defp on_queue_restored(model, msgs) do
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
    end

    defp on_message_start(model, _e), do: %{model | status: :streaming, last_assistant: ""}

    defp on_message_update(model, %{message: msg}) do
      text =
        msg.content
        |> Enum.filter(&match?(%{type: :text}, &1))
        |> Enum.map_join("", & &1.text)

      %{model | last_assistant: text}
    end

    defp on_message_end(model, %{message: msg} = e) do
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

      # D-169 / S-4: context_tokens is OVERWRITTEN with the latest turn's
      # input_tokens (not cumulative). Pre-first-turn reads 0. This avoids the
      # >100% context-bar bug. Source: Tau.Cost.for_session/1 ETS table.
      session_counters = cost_for_session(model.session_id)
      session_msg = e.message
      # Extract this turn's input_tokens directly from the message usage field.
      turn_input_tokens = get_in(session_msg, [Access.key(:usage, %{}), :input_tokens]) || 0

      # D-169: context_tokens = latest turn's input_tokens (overwrite, never sum).
      new_context_tokens = turn_input_tokens

      # Telemetry: emit only on warn_level transition (D-168).
      pct =
        StatusBar.context_pct(
          new_context_tokens,
          Map.get(model, :context_window) ||
            Application.get_env(:tau, :compaction_threshold_tokens, 120_000)
        )

      new_warn = StatusBar.warn_level(pct)
      prior_warn = Map.get(model, :warn_level, :ok)

      if new_warn != prior_warn do
        :telemetry.execute(
          [:tau, :tui, :status, :update],
          %{system_time: System.system_time()},
          %{context_pct: pct, warn_level: new_warn, session_id: model.session_id}
        )
      end

      model
      |> Map.put(:status, :idle)
      |> Map.put(:transcript, bounded_append_many(model.transcript, transcript_lines))
      |> Map.put(:last_assistant, nil)
      |> Map.put(:usage, session_counters)
      |> Map.put(:context_tokens, new_context_tokens)
      |> Map.put(:warn_level, new_warn)
    end

    # Read session counters from the Tau.Cost ETS table (the source of truth).
    # Tolerates the table being unavailable (test isolation without Tracker running).
    defp cost_for_session(session_id) do
      try do
        Tau.Cost.for_session(session_id)
      rescue
        ArgumentError ->
          %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0}
      end
    end

    # B1 rule (D-151): ToolStart/ToolEnd on the parent topic are no-ops.
    # Calls owned by a sub-agent: the live region and end marker own the
    # visual representation. Non-owned calls: tool_output was removed in
    # FIX-3; a future PR may surface non-owned tool calls in the transcript.
    defp on_tool_start(model, _e), do: model

    defp on_tool_end(model, _e), do: model

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

    # D-160 / SPEC-TUI-HEADLESS §5d: seed model/provider fields from the
    # SessionStart event. The context_window is resolved once via the optional
    # context_window/1 callback; nil means use the fallback (~NN%).
    defp on_session_start_status(model, _e, m, p) do
      context_window = resolve_context_window(p, m)
      %{model | model: m, provider: p, context_window: context_window}
    end

    # D-160: update the model segment when the user does /model <id>.
    # Resolves the new context_window for the swapped model.
    defp on_model_swapped(model, %{to: new_model}) do
      provider = Map.get(model, :provider)
      context_window = resolve_context_window(provider, new_model)
      %{model | model: new_model, context_window: context_window}
    end

    # Resolve context_window via the optional context_window/1 callback.
    # Ensures the module is loaded first (function_exported?/3 only works on
    # loaded modules; in production all provider modules are loaded at startup;
    # in tests we must load explicitly to avoid false negatives).
    defp resolve_context_window(provider, model_id)
         when is_atom(provider) and is_binary(model_id) do
      _ = Code.ensure_loaded(provider)

      if function_exported?(provider, :context_window, 1) do
        provider.context_window(model_id)
      else
        nil
      end
    end

    defp resolve_context_window(_provider, _model_id), do: nil

    # D-163: CompactionStarted — transition to :running.
    defp on_compaction_started(model), do: %{model | compaction: :running}

    # D-164 / S-2: CompactionFinished — clear to :idle regardless of outcome.
    # This MUST fire on every exit from the :compacting FSM state, including abort/error,
    # so the "compacting…" indicator never sticks in the status bar.
    defp on_compaction_finished(model), do: %{model | compaction: :idle}

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
