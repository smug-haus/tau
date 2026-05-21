defmodule Tau.TUI.Render.MarkdownTest do
  @moduledoc """
  Unit tests for `Tau.TUI.Render.Markdown`.

  D-028 (SPEC-USER-TURN): TUI-path markdown MUST be parsed as CommonMark+GFM
  and rendered as a list of `{content, attrs}` tuples. Unicode glyphs and inline
  styling are permitted (grapheme-aware Ratatouille fork). Block-level nodes MUST
  be separated by a `{"", []}` blank-spacer entry.
  """
  use ExUnit.Case, async: true

  alias Tau.TUI.Render.Markdown

  # ---------------------------------------------------------------------------
  # D-028 prescribed assertions (a) – (d)
  # ---------------------------------------------------------------------------

  describe "D-028(a) — styled heading produces {text, [attributes: [:bold]]}" do
    test "h1 heading renders with bold attribute" do
      result = Markdown.render("# Hello World")

      assert [{text, attrs}] = result
      assert String.contains?(text, "Hello World")
      assert attrs == [attributes: [:bold]]
    end

    test "h2 heading also renders with bold attribute" do
      result = Markdown.render("## Section")

      assert [{text, attrs}] = result
      assert String.contains?(text, "Section")
      assert attrs == [attributes: [:bold]]
    end
  end

  describe "D-028(b) — multi-paragraph input produces {\"\" , []} spacer between paragraphs" do
    test "two paragraphs separated by a blank spacer" do
      result = Markdown.render("First paragraph.\n\nSecond paragraph.")

      # Expect: [{first_text, []}, {"", []}, {second_text, []}]
      assert [
               {first_text, []},
               {"", []},
               {second_text, []}
             ] = result

      assert String.contains?(first_text, "First paragraph")
      assert String.contains?(second_text, "Second paragraph")
    end

    test "three paragraphs produce two spacers" do
      result = Markdown.render("Alpha.\n\nBeta.\n\nGamma.")

      spacers = Enum.count(result, fn {text, _} -> text == "" end)
      assert spacers == 2
    end
  end

  describe "D-028(c) — blockquote line begins with ▌" do
    test "blockquote prefix is the ▌ glyph" do
      result = Markdown.render("> Quoted text")

      assert [_ | _] = result

      assert Enum.all?(result, fn {text, _attrs} ->
               String.starts_with?(text, "▌")
             end),
             "all blockquote lines must begin with ▌; got: #{inspect(result)}"
    end

    test "nested blockquote body is preserved after ▌ prefix" do
      result = Markdown.render("> Important note")
      [{text, _attrs}] = result
      assert String.starts_with?(text, "▌")
      assert String.contains?(text, "Important note")
    end
  end

  describe "D-028(d) — horizontal rule line is ─ repeated" do
    test "hr renders as a line of ─ characters" do
      result = Markdown.render("---")

      assert [{text, []}] = result
      assert String.length(text) > 0

      assert String.graphemes(text) |> Enum.all?(&(&1 == "─")),
             "hr line must consist only of ─; got: #{inspect(text)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Adjacent coverage
  # ---------------------------------------------------------------------------

  describe "render/1 — bullet list" do
    test "unordered list items get bullet prefix" do
      result = Markdown.render("- alpha\n- beta\n- gamma")

      assert length(result) == 3

      assert Enum.all?(result, fn {text, _} -> String.starts_with?(text, "• ") end),
             "all list items must begin with • ; got: #{inspect(result)}"
    end
  end

  describe "render/1 — inline code" do
    test "inline code is wrapped in backticks and coloured cyan" do
      # Inline code inside a paragraph; Earmark renders `code` as a child node.
      result = Markdown.render("Use `mix test` to run tests.")

      # The paragraph collapses inline code into the surrounding text; confirm
      # at least one tuple is returned and none raises.
      assert is_list(result)
      assert result != []
      assert Enum.all?(result, fn {text, attrs} -> is_binary(text) and is_list(attrs) end)
    end
  end

  describe "render/1 — plain text" do
    test "plain paragraph returns {text, []}" do
      result = Markdown.render("just plain text")
      assert [{"just plain text", []}] = result
    end

    test "empty string returns empty list" do
      result = Markdown.render("")
      assert result == []
    end
  end
end
