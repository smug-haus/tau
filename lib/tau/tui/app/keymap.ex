if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App.Keymap do
    @moduledoc """
    Terminal key-event routing for `Tau.TUI.App`. Handles the three Termbox
    event shapes (alt-chord, printable character, control/special key) and
    dispatches to sub-handlers.

    ## Contract

    Clause ordering in `handle_key/3`, `handle_readline_key/2`, and
    `handle_alt/3` is load-bearing (D-141, D-172). Do not reorder clauses.

    When the permission dialog is open (`pending_permissions` non-empty), ALL
    input is captured by the dialog — only `y`/`n` resolve the head request;
    every other keystroke is swallowed (D-172 / SPEC-PERMISSION-PROMPTS §7 AC-B4).
    This check MUST precede the normal event routing.
    """

    alias Tau.TUI.Editor
    alias Tau.TUI.App.Completion
    alias Tau.TUI.App.History, as: HistoryHelpers
    alias Tau.TUI.App.Input
    alias Tau.TUI.App.Permission

    @doc """
    Top-level terminal event router. Dispatches based on `pending_permissions`
    queue first, then by Termbox event shape.
    """
    @spec handle_event(map(), map()) :: map()
    def handle_event(model, event) when is_map(model) do
      case Map.get(model, :pending_permissions, []) do
        [_ | _] -> Permission.handle_permission_dialog_event(model, event)
        _ -> handle_event_normal(model, event)
      end
    end

    @doc """
    Route a normal (non-dialog) terminal event by Termbox shape.

    Termbox event shapes (clause ordering is load-bearing):
      - alt-chord:       `%{mod: N, key: _, ch: _, ...}` where `N != 0`
      - printable char:  `%{mod: 0, key: 0, ch: CP, ...}` where `CP != 0`
      - control/special: `%{mod: 0, key: N, ch: 0, ...}` where `N != 0`

    Clause 2 MUST guard `ch != 0` so printable chars do NOT fall through
    to clause 3 (key handler). Without the guard, `key=0` printable events
    match the `%{key: key}` clause and are silently dropped in
    `handle_readline_key/2`'s catch-all, breaking typed character input (AC-H2).
    """
    @spec handle_event_normal(map(), map()) :: map()
    def handle_event_normal(model, %{mod: mod} = event) when mod != 0 do
      ch = Map.get(event, :ch, 0)
      key = Map.get(event, :key, 0)
      handle_alt(model, ch, key)
    end

    def handle_event_normal(model, %{ch: ch}) when ch != 0, do: handle_char(model, ch)
    def handle_event_normal(model, %{key: key} = event), do: handle_key(model, key, event)
    def handle_event_normal(model, _), do: model

    @doc """
    Handle events with a `key:` code. Dispatches to sub-handlers; clause
    ordering is load-bearing.
    """
    @spec handle_key(map(), integer(), map()) :: map()
    def handle_key(model, key, _event) do
      case key do
        # Enter — context-aware: menu → accept, search → accept, busy → steer, else → submit/continue
        13 when model.menu != nil ->
          handle_menu_accept(model)

        13 when model.search != nil ->
          handle_search_accept(model)

        # D-077 / AC-2: Enter while busy enqueues a steering message delivered
        # at the next tool-round boundary (before the next provider call). The input
        # is cleared and the queued text is shown in the transcript for feedback.
        13 when model.status in [:streaming, :sending] or is_binary(model.status) ->
          Input.steer(model)

        # Enter with trailing backslash → strip backslash, insert newline.
        # Avoids submit, preserving existing multi-line structure (D-145).
        13 ->
          Input.submit_or_continue(model)

        # Ctrl+J — guaranteed newline at cursor (D-145)
        10 ->
          %{model | editor: Editor.newline(model.editor), search: nil}

        # Esc — context-aware
        27 when model.menu != nil ->
          %{model | menu: nil}

        27 when model.search != nil ->
          HistoryHelpers.search_cancel(model)

        # D-078 / AC-6: Esc while idle → clear the input editor, never quit.
        # Quit stays Ctrl+C (unconditional, registered in start_runtime_supervisor/0).
        # Context-aware: busy → cancel (ADR-0017 path); idle → clear input.
        27 when model.status == :idle ->
          Input.clear_input(model)

        27 ->
          Input.cancel(model)

        # Space (termbox quirk: key 32, not ch 32)
        32 when model.search != nil ->
          %{model | search: %{model.search | query: model.search.query <> " ", search_index: 0}}

        32 ->
          model |> editor_insert(" ") |> Completion.close_menu_if_whitespace()

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
          model |> editor_backspace() |> Completion.update_menu()

        # Readline chords and arrows delegate to further helpers
        _ ->
          handle_readline_key(model, key)
      end
    end

    @doc """
    Readline editing chords (Ctrl+A/E/W/U/K/Y/D/P/N/R) and arrow keys.
    Split from `handle_key/3` to keep cyclomatic complexity within bounds.

    Up/down arrows are edge-aware:
    - Up when cursor on first line → `history_prev` (existing behaviour)
    - Up when cursor on non-first line → `Editor.move_up`
    - Down when cursor on last line → `history_next` (existing behaviour)
    - Down when cursor on non-last line → `Editor.move_down`

    Ctrl+P / Ctrl+N remain unconditional history recall.
    """
    @spec handle_readline_key(map(), integer()) :: map()
    def handle_readline_key(model, key) do
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
          HistoryHelpers.history_next(model)

        16 ->
          HistoryHelpers.history_prev(model)

        18 ->
          HistoryHelpers.search_start(model)

        21 ->
          %{model | editor: Editor.kill_to_line_start(model.editor), search: nil}

        23 ->
          %{model | editor: Editor.kill_word_back(model.editor), search: nil}

        25 ->
          %{model | editor: Editor.yank(model.editor), search: nil}

        # Arrow up: menu navigation takes priority, then edge-aware cursor/history
        65_517 when model.menu != nil ->
          Completion.menu_navigate(model, -1)

        65_517 ->
          arrow_up(model)

        # Arrow down: menu navigation takes priority, then edge-aware cursor/history
        65_516 when model.menu != nil ->
          Completion.menu_navigate(model, 1)

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

    @doc """
    Handle Alt-chord events (mod != 0). Best-effort: degrade to no-op if
    termbox/tmux mangles the ESC-prefix (D-141).

    Receives `(model, ch, key)` where `ch` is the printable codepoint (0 for
    control keys) and `key` is the control-key code. Both are needed to
    distinguish Alt+Enter (`key=13, ch=0`) from Alt+arrow (`key=65_514, ch=0`)
    and other alt-chords that happen to carry `ch=0`.
    """
    @spec handle_alt(map(), integer(), integer()) :: map()
    def handle_alt(model, ?y, _key),
      do: %{model | editor: Editor.yank_pop(model.editor), search: nil}

    def handle_alt(model, ?b, _key),
      do: %{model | editor: Editor.move_word_left(model.editor), search: nil}

    def handle_alt(model, ?f, _key),
      do: %{model | editor: Editor.move_word_right(model.editor), search: nil}

    # D-078 / AC-3: Alt+Enter — enqueue a follow-up message delivered after the
    # whole turn completes. Termbox delivers Alt+Enter as mod != 0, ch = 0, key = 13.
    # Distinguish from other alt-chords with ch=0 (e.g. Alt+arrow: ch=0, key=65_514)
    # by also checking the key field.
    def handle_alt(model, 0, 13) do
      Input.followup(model)
    end

    # All other alt-chords (ch=0 with non-Return key, or unrecognised ch):
    # no-op (D-141: MUST NOT insert literal char).
    def handle_alt(model, _ch, _key), do: model

    # ---------------------------------------------------------------------------
    # Private helpers
    # ---------------------------------------------------------------------------

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
      model |> editor_insert(<<ch::utf8>>) |> Completion.update_menu()
    end

    # Edge-aware up arrow. On first buffer line → history_prev.
    # On interior lines → Editor.move_up (inter-line cursor movement).
    defp arrow_up(model) do
      {row, _col} = model.editor.cursor

      if row == 0 do
        HistoryHelpers.history_prev(model)
      else
        %{model | editor: Editor.move_up(model.editor), search: nil}
      end
    end

    # Edge-aware down arrow. On last buffer line → history_next.
    # On interior lines → Editor.move_down (inter-line cursor movement).
    defp arrow_down(model) do
      {row, _col} = model.editor.cursor
      last_row = length(model.editor.lines) - 1

      if row >= last_row do
        HistoryHelpers.history_next(model)
      else
        %{model | editor: Editor.move_down(model.editor), search: nil}
      end
    end

    # D-003 / AC-4: context-aware quit. On an empty prompt, stop the
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
        |> Completion.update_menu()
      end
    end

    defp editor_insert(model, text) do
      %{model | editor: Editor.insert(model.editor, text), search: nil}
    end

    defp editor_backspace(model) do
      %{model | editor: Editor.backspace(model.editor), search: nil}
    end

    # D-173: when menu has no entries, close menu and submit (unambiguous command).
    defp handle_menu_accept(%{menu: %{entries: []}} = model) do
      %{model | menu: nil} |> Input.submit_or_continue()
    end

    defp handle_menu_accept(model) do
      Completion.menu_accept(model)
    end

    defp handle_search_accept(%{search: nil} = model) do
      Input.submit(model)
    end

    defp handle_search_accept(model) do
      HistoryHelpers.search_accept(model)
    end
  end
end
