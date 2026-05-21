defmodule Tau.TUI.Render.Markdown do
  @moduledoc """
  TUI-path markdown renderer: parses CommonMark+GFM via Earmark and emits
  Ratatouille-compatible styled elements.

  This module is TUI-path only. The headless `tau run` path continues to use
  `Tau.Markdown` (ASCII output). Do not call this module from non-TUI code.

  Output: a list of `{content, attrs}` tuples where:
  - `content` is the display string for a Ratatouille `label`
  - `attrs` is a keyword list of Ratatouille element attributes
    (`color:`, `attributes: [:bold]`, etc.)

  The renderer is tolerant: unknown/unsupported constructs fall back to plain
  wrapped text. Unknown fenced code block languages fall back to unhighlighted
  text. Neither case raises.

  Pure module — no process, no state.
  """

  alias Tau.TUI.Render.Highlight

  @type styled_line :: {String.t(), keyword()}

  @doc """
  Renders `markdown_text` to a list of `{content, attrs}` tuples.

  Each tuple corresponds to one display line in the transcript pane.
  The caller (typically `Tau.TUI.App`) renders each tuple as a Ratatouille
  `label` with the associated attributes.

  ## Examples

      iex> Tau.TUI.Render.Markdown.render("# Hello")
      [{"# Hello", [attributes: [:bold]]}]

      iex> Tau.TUI.Render.Markdown.render("plain text")
      [{"plain text", []}]
  """
  @spec render(String.t()) :: [styled_line()]
  def render(text) when is_binary(text) do
    case Earmark.as_ast(text, smartypants: false) do
      {:ok, ast, _warnings} ->
        render_ast(ast)

      {:error, ast, _errors} ->
        # Even on parse errors, Earmark returns a partial AST; use it.
        render_ast(ast)
    end
  end

  # Block-level tags that deserve a blank-line spacer between them.
  @block_tags ~w[p h1 h2 h3 h4 h5 h6 ul ol pre blockquote hr table div]

  @spec render_ast(list()) :: [styled_line()]
  defp render_ast(ast) do
    ast
    |> Enum.reduce({[], false}, fn node, {acc, needs_spacer} ->
      is_block = block_node?(node)
      spacer = if needs_spacer and is_block, do: [{"", []}], else: []
      lines = render_node(node)
      {acc ++ spacer ++ lines, is_block and lines != []}
    end)
    |> elem(0)
  end

  defp block_node?({tag, _attrs, _children, _meta}), do: tag in @block_tags
  defp block_node?(_), do: false

  # Headings
  defp render_node({"h1", _attrs, children, _meta}) do
    text = extract_text(children)
    [{"# " <> text, [attributes: [:bold]]}]
  end

  defp render_node({"h2", _attrs, children, _meta}) do
    text = extract_text(children)
    [{"## " <> text, [attributes: [:bold]]}]
  end

  defp render_node({"h3", _attrs, children, _meta}) do
    text = extract_text(children)
    [{"### " <> text, [attributes: [:bold]]}]
  end

  defp render_node({"h4", _attrs, children, _meta}) do
    text = extract_text(children)
    [{"#### " <> text, [attributes: [:bold]]}]
  end

  defp render_node({"h5", _attrs, children, _meta}) do
    text = extract_text(children)
    [{"##### " <> text, [attributes: [:bold]]}]
  end

  defp render_node({"h6", _attrs, children, _meta}) do
    text = extract_text(children)
    [{"###### " <> text, [attributes: [:bold]]}]
  end

  # Paragraphs
  defp render_node({"p", _attrs, children, _meta}) do
    text = extract_text(children)
    [{text, []}]
  end

  # Unordered lists
  defp render_node({"ul", _attrs, items, _meta}) do
    Enum.flat_map(items, fn
      {"li", _a, children, _m} ->
        text = extract_text(children)
        [{"• " <> text, []}]

      other ->
        render_node(other)
    end)
  end

  # Ordered lists
  defp render_node({"ol", _attrs, items, _meta}) do
    items
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {{"li", _a, children, _m}, idx} ->
        text = extract_text(children)
        [{to_string(idx) <> ". " <> text, []}]

      {other, _idx} ->
        render_node(other)
    end)
  end

  # Code blocks (fenced)
  defp render_node({"pre", _attrs, [{"code", code_attrs, [code_text], _}], _meta})
       when is_binary(code_text) do
    lang = extract_lang(code_attrs)
    Highlight.highlight(code_text, lang)
  end

  defp render_node({"pre", _attrs, children, _meta}) do
    # Fallback: extract text
    text = extract_text(children)
    [{text, [color: :cyan]}]
  end

  # Inline code
  defp render_node({"code", _attrs, [text], _meta}) when is_binary(text) do
    [{"`" <> text <> "`", [color: :cyan]}]
  end

  # Blockquotes
  defp render_node({"blockquote", _attrs, children, _meta}) do
    inner = render_ast(children)
    Enum.map(inner, fn {text, attrs} -> {"▌ " <> text, attrs} end)
  end

  # Horizontal rule
  defp render_node({"hr", _attrs, _children, _meta}) do
    [{"─────────────────────────────", []}]
  end

  # Line breaks
  defp render_node({"br", _attrs, _children, _meta}) do
    [{"", []}]
  end

  # Tables (GFM)
  defp render_node({"table", _attrs, children, _meta}) do
    Enum.flat_map(children, &render_node/1)
  end

  defp render_node({"thead", _attrs, children, _meta}) do
    rows = Enum.flat_map(children, &render_table_row/1)
    rows ++ [{"", []}]
  end

  defp render_node({"tbody", _attrs, children, _meta}) do
    Enum.flat_map(children, &render_table_row/1)
  end

  defp render_node({"tr", _attrs, _children, _meta} = node) do
    render_table_row(node)
  end

  # Strong / bold — inline in paragraph text; when top-level, treat as paragraph
  defp render_node({"strong", _attrs, children, _meta}) do
    text = extract_text(children)
    [{text, [attributes: [:bold]]}]
  end

  # Emphasis / italic
  defp render_node({"em", _attrs, children, _meta}) do
    text = extract_text(children)
    # Underline as italic approximation in terminals lacking italic
    [{text, [attributes: [:underline]]}]
  end

  # Links
  defp render_node({"a", attrs, children, _meta}) do
    text = extract_text(children)
    href = Keyword.get(attrs, "href", "")
    [{text <> " (" <> href <> ")", []}]
  end

  # Div and span wrappers
  defp render_node({"div", _attrs, children, _meta}), do: render_ast(children)
  defp render_node({"span", _attrs, children, _meta}), do: render_ast(children)

  # Plain text node
  defp render_node(text) when is_binary(text) do
    if String.trim(text) == "" do
      []
    else
      [{text, []}]
    end
  end

  # Unknown node — fall back to text extraction
  defp render_node({_tag, _attrs, children, _meta}) do
    text = extract_text(children)

    if text == "" do
      []
    else
      [{text, []}]
    end
  end

  defp render_table_row({"tr", _attrs, cells, _meta}) do
    cell_texts =
      Enum.map(cells, fn
        {"th", _a, children, _m} -> extract_text(children)
        {"td", _a, children, _m} -> extract_text(children)
        other -> extract_text_from_node(other)
      end)

    [{Enum.join(cell_texts, " | "), []}]
  end

  defp render_table_row(other), do: render_node(other)

  # Extract a plain-text string from a list of AST children.
  defp extract_text(children) do
    Enum.map_join(children, "", &extract_text_from_node/1)
  end

  defp extract_text_from_node(text) when is_binary(text), do: text

  defp extract_text_from_node({"strong", _attrs, children, _meta}) do
    extract_text(children)
  end

  defp extract_text_from_node({"em", _attrs, children, _meta}) do
    extract_text(children)
  end

  defp extract_text_from_node({"code", _attrs, children, _meta}) do
    extract_text(children)
  end

  defp extract_text_from_node({"a", _attrs, children, _meta}) do
    extract_text(children)
  end

  defp extract_text_from_node({"br", _attrs, _children, _meta}), do: " "

  defp extract_text_from_node({_tag, _attrs, children, _meta}) do
    extract_text(children)
  end

  defp extract_lang(attrs) do
    class = Keyword.get(attrs, "class", "")
    # Earmark puts "language-elixir" style classes
    case Regex.run(~r/language-(\S+)/, class) do
      [_, lang] -> lang
      _ -> ""
    end
  end
end
