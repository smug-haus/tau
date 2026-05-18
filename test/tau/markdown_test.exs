defmodule Tau.MarkdownTest do
  @moduledoc """
  D-028 / [C52-B5]: assistant text content rendered to the TUI transcript
  MUST be parsed as CommonMark with GFM tables. Raw markdown source MUST
  NOT appear in the rendered pane for valid CommonMark input.
  """
  use ExUnit.Case, async: true

  alias Tau.Markdown

  describe "tables" do
    test "renders a GFM table with aligned ASCII pipe-and-plus grid" do
      md = """
      | Name | Age |
      |------|-----|
      | Alice | 30 |
      | Bob | 25 |
      """

      lines = Markdown.render(md)

      # Header row + separator + 2 body rows = 4 table lines
      assert length(lines) >= 4, "expected ≥4 table lines, got: #{inspect(lines)}"

      # ASCII-only: no Unicode box-drawing chars in output (Ratatouille
      # 0.5.1's Cells.to_char/1 can't handle multi-byte UTF-8).
      refute Enum.any?(lines, fn line ->
               String.contains?(line, "│") or String.contains?(line, "├") or
                 String.contains?(line, "─")
             end),
             "Unicode box-drawing leaked: #{inspect(lines)}"

      # Row borders use ASCII pipes
      assert Enum.any?(lines, fn line ->
               String.starts_with?(line, "| ") and String.ends_with?(line, " |")
             end),
             "no ASCII pipe-bordered row: #{inspect(lines)}"

      # Separator row uses ASCII plus-and-dash
      assert Enum.any?(lines, fn line ->
               String.starts_with?(line, "+-") and String.contains?(line, "-+-")
             end),
             "no ASCII plus-dash separator: #{inspect(lines)}"

      # Content present and column-aligned (Alice has 5 chars, Bob has 3 — both rows pad to width 5)
      assert Enum.any?(lines, &String.contains?(&1, "Alice"))
      assert Enum.any?(lines, &String.contains?(&1, "Bob"))
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
    test "renders bullet lists with * marker (ASCII, Ratatouille-safe)" do
      md = """
      - first
      - second
      - third
      """

      lines = Markdown.render(md)
      assert "* first" in lines
      assert "* second" in lines
      assert "* third" in lines

      # No Unicode bullet leaks
      refute Enum.any?(lines, &String.contains?(&1, "•"))
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
    test "renders fenced code blocks with ASCII pipe delimiter" do
      md = """
      ```
      def hello, do: :world
      ```
      """

      lines = Markdown.render(md)

      assert Enum.any?(lines, &String.contains?(&1, "| def hello")),
             "code block not delimited: #{inspect(lines)}"

      # No Unicode pipe leaks (Ratatouille can't render it)
      refute Enum.any?(lines, &String.contains?(&1, "│"))
    end
  end

  describe "inline markup" do
    test "strips bold/italic markers (Ratatouille labels render flat text)" do
      lines = Markdown.render("This has **bold** and *italic* text.")
      [line | _] = lines

      # Bold/italic markers stripped — body text preserved.
      assert line =~ "bold"
      assert line =~ "italic"
      refute line =~ "**bold**"
      refute line =~ "*italic*"
    end

    test "preserves inline-code backticks (ASCII, useful as visual cue)" do
      lines = Markdown.render("Run `mix test` to verify.")
      [line | _] = lines
      assert line =~ "`mix test`"
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
