if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App.CompletionPropertyTest do
    @moduledoc """
    Properties for `Tau.TUI.App.Completion`. Pins the fuzzy-match
    precedence and whitespace-token gate invariants.
    """
    use ExUnit.Case, async: true
    use ExUnitProperties

    @moduletag :property

    alias Tau.TUI.App.Completion
    alias Tau.TUI.Editor

    defp command_name_gen do
      StreamData.bind(
        StreamData.string(:ascii, min_length: 1, max_length: 10),
        fn s -> StreamData.constant("/" <> String.replace(s, ~r/[^a-z]/, "a")) end
      )
    end

    defp catalog_gen do
      StreamData.list_of(
        StreamData.bind(command_name_gen(), fn name ->
          StreamData.constant(%{name: name, description: "", origin: :builtin})
        end),
        min_length: 1,
        max_length: 8
      )
    end

    defp slash_token_gen do
      StreamData.bind(
        StreamData.string(:ascii, min_length: 0, max_length: 8),
        fn s ->
          token = "/" <> String.replace(s, ~r/\s/, "")
          StreamData.constant(token)
        end
      )
    end

    property "menu opens for any /-prefixed whitespace-free token" do
      check all(
              token <- slash_token_gen(),
              catalog <- catalog_gen()
            ) do
        editor = %Editor{lines: [token], cursor: {0, String.length(token)}}
        model = %{editor: editor, catalog: catalog, menu: nil}
        result = Completion.update_menu(model)
        # When input is a /-prefixed non-whitespace token, menu should be non-nil
        assert result.menu != nil
      end
    end

    property "close_menu_if_whitespace closes menu when input contains space" do
      check all(
              prefix <- StreamData.string(:ascii, min_length: 1, max_length: 5),
              suffix <- StreamData.string(:ascii, min_length: 1, max_length: 5)
            ) do
        text = prefix <> " " <> suffix
        editor = %Editor{lines: [text], cursor: {0, String.length(text)}}

        model = %{
          editor: editor,
          menu: %{query: "", entries: [], selected: 0}
        }

        result = Completion.close_menu_if_whitespace(model)
        assert result.menu == nil
      end
    end

    property "clamp always returns a value in [0, max]" do
      check all(
              n <- StreamData.integer(-100..200),
              max <- StreamData.integer(0..100)
            ) do
        result = Completion.clamp(n, max)
        assert result >= 0
        assert result <= max
      end
    end

    property "clamp returns 0 when max < 0" do
      check all(
              n <- StreamData.integer(-100..100),
              max <- StreamData.integer(-100..-1)
            ) do
        assert Completion.clamp(n, max) == 0
      end
    end

    property "menu_navigate keeps selection within [0, count-1]" do
      check all(
              count <- StreamData.integer(1..10),
              selected <- StreamData.integer(0..(count - 1)),
              delta <- StreamData.integer(-20..20)
            ) do
        entries =
          Enum.map(1..count, fn i ->
            {0.5, %{name: "/cmd#{i}", description: "", origin: :builtin}}
          end)

        model = %{
          editor: %Editor{lines: [""], cursor: {0, 0}},
          menu: %{entries: entries, selected: selected, query: ""}
        }

        result = Completion.menu_navigate(model, delta)
        assert result.menu.selected >= 0
        assert result.menu.selected <= count - 1
      end
    end
  end
end
