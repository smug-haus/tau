defmodule Tau.TUI.Render.HighlightTest do
  @moduledoc """
  Unit tests for `Tau.TUI.Render.Highlight`.

  AC-6 (SPEC-USER-TURN): highlighted code blocks must render in multiple
  colours. A known language (Elixir) must produce ≥ 2 distinct colour
  values across its output lines. An unknown language falls back to a
  uniform unhighlighted style.
  """
  use ExUnit.Case, async: true

  alias Tau.TUI.Render.Highlight

  describe "highlight/2 — known language (Elixir)" do
    test "returns a list of {text, attrs} tuples" do
      lines = Highlight.highlight("def foo, do: :ok", "elixir")
      assert is_list(lines)
      assert lines != []
      assert Enum.all?(lines, fn {text, attrs} -> is_binary(text) and is_list(attrs) end)
    end

    test "produces ≥ 2 distinct colours across lines (AC-6)" do
      # A multi-token snippet that exercises keywords, names, strings,
      # and comments — enough token diversity to guarantee colour variety.
      code = """
      # a comment
      def greet(name) do
        "Hello, " <> name
      end
      x = 42
      """

      lines = Highlight.highlight(code, "elixir")
      colors = lines |> Enum.map(fn {_text, attrs} -> Keyword.get(attrs, :color) end) |> Enum.uniq()

      assert match?([_, _ | _], colors),
             "expected ≥ 2 distinct colours for highlighted Elixir; got #{inspect(colors)}\n" <>
               "lines: #{inspect(lines)}"
    end

    test "produces the same output for 'ex' and 'exs' aliases" do
      code = "def foo, do: :ok"
      assert Highlight.highlight(code, "ex") == Highlight.highlight(code, "elixir")
      assert Highlight.highlight(code, "exs") == Highlight.highlight(code, "elixir")
    end

    test "keywords and comments get different colours" do
      # keyword 'def' → :magenta; comment '# hi' → :green
      kw_lines = Highlight.highlight("def foo, do: :ok", "elixir")
      comment_lines = Highlight.highlight("# hello world", "elixir")

      kw_colors = kw_lines |> Enum.map(fn {_, a} -> Keyword.get(a, :color) end) |> MapSet.new()

      comment_colors =
        comment_lines |> Enum.map(fn {_, a} -> Keyword.get(a, :color) end) |> MapSet.new()

      # keywords and comments occupy disjoint colour sets for Elixir
      refute MapSet.equal?(kw_colors, comment_colors),
             "keywords and comments must have different dominant colours; " <>
               "kw=#{inspect(kw_colors)} comment=#{inspect(comment_colors)}"
    end

    test "never raises on valid code" do
      assert is_list(Highlight.highlight("x = 1 + 2", "elixir"))
    end
  end

  describe "highlight/2 — unknown language (fallback)" do
    test "returns {text, attrs} tuples for unknown language" do
      lines = Highlight.highlight("some code", "cobol")
      assert is_list(lines)
      assert lines != []
      assert Enum.all?(lines, fn {text, attrs} -> is_binary(text) and is_list(attrs) end)
    end

    test "empty language string uses fallback" do
      lines = Highlight.highlight("code", "")
      assert is_list(lines)
      assert lines != []
    end

    test "does not raise on empty code" do
      assert is_list(Highlight.highlight("", "elixir"))
      assert is_list(Highlight.highlight("", "python"))
    end
  end

  describe "highlight/2 — multiline code" do
    test "produces one entry per logical line" do
      code = "def foo do\n  :ok\nend"
      lines = Highlight.highlight(code, "elixir")
      # 3 lines of code → 3 entries (no trailing empty line artefact)
      assert match?([_, _, _], lines),
             "expected 3 lines for 3-line snippet; got: #{inspect(lines)}"
    end
  end
end
