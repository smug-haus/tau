if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App.History do
    @moduledoc """
    History navigation and reverse-search helpers for `Tau.TUI.App`.
    All functions take and return the MVU model map (or struct); they are
    pure with no side effects.

    ## Contract

    Navigation is linear: `history_prev/1` moves toward older entries,
    `history_next/1` moves toward newer entries / restores the draft.
    Reverse search (Ctrl+R, D-147) enters a sub-state stored in `model.search`.
    """

    alias Tau.TUI.Editor
    alias Tau.TUI.History

    @doc """
    Navigate to the previous (older) history entry. Restores the editor
    to the entry text, splitting on `\\n` to preserve multi-line structure.
    """
    @spec history_prev(map()) :: map()
    def history_prev(model) do
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

    @doc """
    Navigate to the next (newer) history entry or restore the draft.
    Same multi-line restore semantics as `history_prev/1`.
    """
    @spec history_next(map()) :: map()
    def history_next(model) do
      {new_hist, entry} = History.next(model.history)

      case entry do
        nil ->
          %{model | history: new_hist}

        text ->
          new_editor = restore_editor_from_text(text)
          %{model | history: new_hist, editor: new_editor, search: nil}
      end
    end

    @doc """
    Reconstruct an `Editor` from a potentially multi-line history entry.
    Splits on `\\n`; places the cursor at the end of the last line.
    """
    @spec restore_editor_from_text(String.t()) :: Editor.t()
    def restore_editor_from_text(text) do
      lines = String.split(text, "\n")
      last_row = length(lines) - 1
      last_col = String.length(Enum.at(lines, last_row, ""))

      %Editor{lines: lines, cursor: {last_row, last_col}}
    end

    @doc """
    Enter or advance reverse-search mode (Ctrl+R, D-147).
    Entering while already in search cycles to the next-older match.
    """
    @spec search_start(map()) :: map()
    def search_start(model) do
      case model.search do
        nil ->
          %{model | search: %{query: "", pre_search_editor: model.editor, search_index: 0}}

        %{query: q, search_index: idx} ->
          next_idx = idx + 1
          %{model | search: %{model.search | query: q, search_index: next_idx}}
      end
    end

    @doc """
    Accept the current search match and exit search mode.
    Falls back to submit when called with no active search.
    """
    @spec search_accept(map()) :: map()
    def search_accept(%{search: nil} = model) do
      # Delegate to submit via the caller's submit path.
      model
    end

    def search_accept(%{search: %{query: query}, history: hist} = model) do
      case search_nth_match(hist, query, Map.get(model.search, :search_index, 0)) do
        {:match, text} ->
          new_editor = restore_editor_from_text(text)
          %{model | editor: new_editor, search: nil}

        :no_match ->
          %{model | search: nil}
      end
    end

    @doc """
    Find the Nth match (0-indexed) for `query` in `history` entries.
    Wraps around when `n` exceeds the match count. Returns `:no_match` when
    no entry contains the query substring (case-insensitive).
    """
    @spec search_nth_match(History.t(), String.t(), non_neg_integer()) ::
            {:match, String.t()} | :no_match
    def search_nth_match(%History{entries: entries}, query, n) do
      lower = String.downcase(query)
      matches = Enum.filter(entries, fn e -> String.contains?(String.downcase(e), lower) end)

      case matches do
        [] -> :no_match
        _ -> {:match, Enum.at(matches, rem(n, length(matches)))}
      end
    end

    def search_nth_match(_hist, _query, _n), do: :no_match

    @doc """
    Cancel reverse search and restore the pre-search editor state (D-147).
    """
    @spec search_cancel(map()) :: map()
    def search_cancel(%{search: %{pre_search_editor: pre}} = model) do
      %{model | editor: pre, search: nil}
    end

    def search_cancel(model), do: %{model | search: nil}
  end
end
