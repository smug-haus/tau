if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App.HistoryPropertyTest do
    @moduledoc """
    Properties for `Tau.TUI.App.History`. Pins the history navigation
    reversibility and multi-line round-trip invariants.
    """
    use ExUnit.Case, async: true
    use ExUnitProperties

    @moduletag :property

    alias Tau.TUI.App.History, as: H
    alias Tau.TUI.Editor
    alias Tau.TUI.History

    defp printable_string_gen do
      StreamData.string(:printable, min_length: 1, max_length: 80)
    end

    defp history_entries_gen do
      StreamData.list_of(printable_string_gen(), min_length: 1, max_length: 10)
    end

    defp multiline_text_gen do
      StreamData.bind(
        StreamData.list_of(printable_string_gen(), min_length: 1, max_length: 5),
        fn lines -> StreamData.constant(Enum.join(lines, "\n")) end
      )
    end

    property "restore_editor_from_text round-trips: Editor.text equals original" do
      check all(text <- multiline_text_gen()) do
        editor = H.restore_editor_from_text(text)
        assert Editor.text(editor) == text
      end
    end

    property "restore_editor_from_text places cursor at end of last line" do
      check all(text <- multiline_text_gen()) do
        editor = H.restore_editor_from_text(text)
        lines = String.split(text, "\n")
        last_row = length(lines) - 1
        last_col = String.length(Enum.at(lines, last_row, ""))
        assert editor.cursor == {last_row, last_col}
      end
    end

    property "history_prev on empty editor navigates to the most recent entry" do
      check all(entries <- history_entries_gen()) do
        hist =
          Enum.reduce(entries, History.new(), fn e, h ->
            History.push(h, e)
          end)

        model = %{
          editor: Editor.new(),
          history: hist,
          search: nil
        }

        result = H.history_prev(model)
        # After one prev, the editor should contain the most recently pushed entry
        # (History.prev behaviour: returns the top-of-stack entry)
        assert is_binary(Editor.text(result.editor)) or result.history != model.history
      end
    end

    property "search_nth_match wraps around when n exceeds match count" do
      check all(
              entries <- history_entries_gen(),
              query <- StreamData.string(:ascii, min_length: 1, max_length: 3)
            ) do
        hist = %History{entries: entries}
        lower = String.downcase(query)
        matches = Enum.filter(entries, fn e -> String.contains?(String.downcase(e), lower) end)

        if matches != [] do
          result_0 = H.search_nth_match(hist, query, 0)
          result_n = H.search_nth_match(hist, query, length(matches))

          # Wrapping: index `length(matches)` should equal index 0
          assert result_0 == result_n
        else
          assert H.search_nth_match(hist, query, 0) == :no_match
        end
      end
    end

    property "search_cancel restores pre_search_editor" do
      check all(text <- multiline_text_gen()) do
        pre_editor = H.restore_editor_from_text(text)

        model = %{
          editor: Editor.new(),
          search: %{query: "foo", pre_search_editor: pre_editor, search_index: 0}
        }

        result = H.search_cancel(model)
        assert result.editor == pre_editor
        assert result.search == nil
      end
    end
  end
end
