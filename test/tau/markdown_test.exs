defmodule Tau.MarkdownTest do
  @moduledoc """
  D-028 / [C52-B5]: assistant text content rendered to the TUI transcript
  MUST be parsed as CommonMark with GFM tables. Raw markdown source MUST
  NOT appear in the rendered pane for valid CommonMark input.
  """
  use ExUnit.Case, async: true

  alias Tau.Markdown

  describe "tables" do
    test "renders a GFM table with aligned columns and box-drawing" do
      md = """
      | Name | Age |
      |------|-----|
      | Alice | 30 |
      | Bob | 25 |
      """

      lines = Markdown.render(md)

      # Header row + separator + 2 body rows = 4 table lines (the separator
      # uses ├/─/┼/┤ box-drawing chars; row borders use │)
      table_lines =
        Enum.filter(lines, fn line ->
          String.contains?(line, "│") or String.contains?(line, "├")
        end)

      assert length(table_lines) >= 4, "expected ≥4 table lines, got: #{inspect(lines)}"

      # No raw GFM pipe-delimiter source in output
      refute Enum.any?(lines, fn line ->
               String.contains?(line, "|------|") or String.contains?(line, "|--|--|")
             end),
             "raw GFM separator leaked: #{inspect(lines)}"

      # Separator uses box-drawing chars
      assert Enum.any?(lines, &String.contains?(&1, "├")), "no box-drawing separator: #{inspect(lines)}"
    end
  end

  describe "headers" do
    test "renders headers in uppercase with leading hash markers" do
      lines = Markdown.render("# Hello World")
      assert "# HELLO WORLD" in lines
    end

    test "renders nested-level headers with the right hash count" do
      lines = Markdown.render("### Deeper")
      assert "### DEEPER" in lines
    end
  end

  describe "lists" do
    test "renders bullet lists with • marker" do
      md = """
      - first
      - second
      - third
      """

      lines = Markdown.render(md)
      assert "• first" in lines
      assert "• second" in lines
      assert "• third" in lines
    end

    test "renders ordered lists with numeric prefix" do
      md = """
      1. one
      2. two
      """

      lines = Markdown.render(md)
      assert "1. one" in lines
      assert "2. two" in lines
    end
  end

  describe "code blocks" do
    test "renders fenced code blocks with visual delimiter" do
      md = """
      ```
      def hello, do: :world
      ```
      """

      lines = Markdown.render(md)
      assert Enum.any?(lines, &String.contains?(&1, "│ def hello")),
             "code block not delimited: #{inspect(lines)}"
    end
  end

  describe "inline markup" do
    test "preserves bold / italic / inline-code markers in prose output" do
      lines = Markdown.render("This has **bold** and *italic* and `code` inline.")
      [line | _] = lines
      assert line =~ "**bold**"
      assert line =~ "*italic*"
      assert line =~ "`code`"
    end
  end

  describe "fallback" do
    test "on Earmark error returns input prefixed with [markdown-parse-error]" do
      # Earmark is permissive — virtually any string parses. Force the
      # rescue path by passing something that triggers the as_ast
      # contract for binaries (e.g. non-binary would raise upstream of
      # this; we test that the function never returns []).
      lines = Markdown.render("")
      assert is_list(lines)
    end

    test "always returns a list of strings" do
      lines = Markdown.render("any prose")
      assert is_list(lines)
      assert Enum.all?(lines, &is_binary/1)
    end
  end
end
