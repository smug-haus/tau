if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App.View do
    @moduledoc """
    Ratatouille view rendering for `Tau.TUI.App`. Owns `render/1` (the
    `@behaviour Ratatouille.App` callback body), the menu panel, the prompt
    bar, the cursor glyph, and the status-bar model builder.
    """

    import Ratatouille.View

    alias Tau.TUI.Render.Wrap
    alias Tau.TUI.Editor
    alias Tau.TUI.SubagentTree
    alias Tau.TUI.StatusBar
    alias Tau.TUI.App.Permission

    # D-026: a solid block cursor (U+2588 "█") MUST be appended after the
    # current input so the user can see the insertion point. Unicode block
    # renders in all common terminal emulators; it is visually distinct from
    # typed characters and requires no timer or animation (v1: no blinking).
    @cursor_glyph "█"

    @menu_max_entries 8

    @doc """
    Top-level Ratatouille view for `Tau.TUI.App`. Renders the transcript pane,
    the permission dialog (when active), and the slash-command menu (when open).
    """
    @spec render(map()) :: term()
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

        # D-172 / SPEC-PERMISSION-PROMPTS §7 AC-B1: render the permission
        # approval dialog when the queue is non-empty.
        if Map.get(model, :pending_permissions, []) != [] do
          Permission.render_permission_dialog(model)
        end

        # SPEC-TUI-COMPLETION §4 B2 (D-102): render the slash-command menu
        # inline above the prompt bar when the menu is open.
        if model.menu != nil do
          render_menu(model)
        end
      end
    end

    @doc """
    Render up to `@menu_max_entries` entries as an inline panel above the prompt.
    The selected row is highlighted with bold. Row format:
    `"/name  — description  [origin]"`.
    """
    @spec render_menu(map()) :: term()
    def render_menu(%{menu: %{entries: entries, selected: selected}} = _model) do
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

    @doc """
    Build the status-bar model map for `StatusBar.render/1`, mixing in the
    session_id, session status, and coding-agent info that StatusBar needs.

    D-162 (AC-H1): session_id MUST be passed so `render_text/1` can emit
    `"session: <id>"` as the first segment (smoke-gate `~r/session:/` assertion).
    D-171: permissions_mode passed to StatusBar for the mode indicator.
    """
    @spec status_bar_model(map()) :: map()
    def status_bar_model(model) do
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

    @doc """
    Build prompt bar labels for the Ratatouille `bar` DSL.
    Renders one label per logical editor line with cursor glyph injection (D-142).
    In search mode, shows the live match as a prefix.
    """
    @spec build_prompt_labels(map()) :: [term()]
    def build_prompt_labels(model) do
      lines = Editor.render_lines(model.editor)

      prefix =
        if model.search != nil do
          # Show the live match in the prompt, honouring the current search_index
          # so the displayed entry matches what search_accept/1 would accept (D-147).
          match_text =
            case Tau.TUI.App.History.search_nth_match(
                   model.history,
                   model.search.query,
                   model.search.search_index
                 ) do
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

    # ---------------------------------------------------------------------------
    # Private helpers
    # ---------------------------------------------------------------------------

    defp status_bar(model) do
      StatusBar.render(status_bar_model(model))
    end

    defp prompt(model) do
      # Variables must be computed before entering the view DSL macro.
      prompt_labels = build_prompt_labels(model)

      bar do
        prompt_labels
      end
    end

    # Inject the cursor glyph at grapheme position `col` in `line`.
    defp inject_cursor(line, col) do
      graphemes = String.graphemes(line)
      {before_cursor, after_cursor} = Enum.split(graphemes, col)
      IO.iodata_to_binary([before_cursor, @cursor_glyph, after_cursor])
    end

    defp menu_entry_text(%{name: name, description: desc, origin: origin}) do
      origin_tag = "[" <> to_string(origin) <> "]"

      if desc != "" do
        name <> "  — " <> desc <> "  " <> origin_tag
      else
        name <> "  " <> origin_tag
      end
    end
  end
end
