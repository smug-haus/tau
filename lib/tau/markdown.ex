defmodule Tau.Markdown do
  @moduledoc """
  Renders CommonMark (with GFM tables) assistant text into terminal-formatted
  lines suitable for the Ratatouille transcript pane.

  Scope (D-028 / [C52-B5]): replaces the prior raw-text concatenation in
  `Tau.TUI.App.on_message_end/2`. Tables align as ASCII grids; headers,
  emphasis, code, and lists get visible treatment without bracket-leaking
  raw markdown into the rendered pane.

  Out of scope:
  - Syntax-highlighting code blocks.
  - Inline images / hyperlinks rendered as anything other than their text
    + URL (terminal hypertext is a separate concern).

  Render contract: input is a binary; output is a list of binaries, each
  one visual line. On Earmark parse error the renderer falls back to the
  input text prefixed with `[markdown-parse-error]` so the failure stays
  visible to the user (D-028 fallback requirement).

  Earmark emits string tags ("h1", "p", "table", etc.) — not atoms.
  """

  @doc """
  Render markdown text to a list of formatted terminal lines.
  """
  @spec render(binary()) :: [binary()]
  def render(text) when is_binary(text) do
    case Earmark.as_ast(text, gfm_tables: true) do
      {:ok, ast, _messages} ->
        ast
        |> Enum.flat_map(&render_block/1)
        |> Enum.reject(&(&1 == ""))

      {:error, ast, _messages} ->
        rendered =
          ast
          |> Enum.flat_map(&render_block/1)
          |> Enum.reject(&(&1 == ""))

        ["[markdown-parse-error] partial render follows:" | rendered]
    end
  rescue
    _ -> ["[markdown-parse-error] " <> text]
  end

  # ---------------------------------------------------------------------------
  # Block renderers
  # ---------------------------------------------------------------------------

  defp render_block({"p", _attrs, children, _meta}) do
    [render_inline(children)]
  end

  defp render_block({tag, _attrs, children, _meta}) when tag in ~w(h1 h2 h3 h4 h5 h6) do
    level = String.to_integer(String.last(tag))
    text = render_inline(children)
    [String.duplicate("#", level) <> " " <> String.upcase(text)]
  end

  defp render_block({"ul", _attrs, items, _meta}) do
    Enum.flat_map(items, fn
      {"li", _attrs, children, _meta} -> ["• " <> render_inline(children)]
      _ -> []
    end)
  end

  defp render_block({"ol", _attrs, items, _meta}) do
    items
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {{"li", _attrs, children, _meta}, idx} -> ["#{idx}. " <> render_inline(children)]
      _ -> []
    end)
  end

  defp render_block({"pre", _attrs, [{"code", _code_attrs, code_children, _code_meta}], _meta}) do
    body = render_inline(code_children)

    body
    |> String.split("\n")
    |> Enum.map(&("│ " <> &1))
  end

  defp render_block({"pre", _attrs, children, _meta}) do
    body = render_inline(children)

    body
    |> String.split("\n")
    |> Enum.map(&("│ " <> &1))
  end

  defp render_block({"blockquote", _attrs, children, _meta}) do
    children
    |> Enum.flat_map(&render_block/1)
    |> Enum.map(&("│ " <> &1))
  end

  defp render_block({"table", _attrs, rows, _meta}) do
    render_table(rows)
  end

  defp render_block({"hr", _attrs, _children, _meta}) do
    [String.duplicate("─", 60)]
  end

  defp render_block({"code", _attrs, children, _meta}) do
    ["│ " <> render_inline(children)]
  end

  defp render_block(text) when is_binary(text), do: [text]
  defp render_block({_tag, _attrs, _children, _meta}), do: []

  # ---------------------------------------------------------------------------
  # Tables — the marquee feature: align columns, render with box-drawing.
  # ---------------------------------------------------------------------------

  defp render_table(rows) do
    {header_row, body_rows} = collect_rows(rows)
    all_rows = if header_row, do: [header_row | body_rows], else: body_rows

    case all_rows do
      [] ->
        []

      _ ->
        widths = column_widths(all_rows)

        case header_row do
          nil ->
            Enum.map(body_rows, &format_row(&1, widths))

          _ ->
            [
              format_row(header_row, widths),
              format_separator(widths)
              | Enum.map(body_rows, &format_row(&1, widths))
            ]
        end
    end
  end

  defp collect_rows(rows) do
    Enum.reduce(rows, {nil, []}, fn
      {"thead", _attrs, tr_list, _meta}, {nil, body} ->
        header =
          tr_list
          |> Enum.flat_map(fn
            {"tr", _attrs, cells, _meta} -> [Enum.map(cells, &cell_text/1)]
            _ -> []
          end)
          |> List.first()

        {header, body}

      {"tbody", _attrs, tr_list, _meta}, {head, body} ->
        rows =
          Enum.flat_map(tr_list, fn
            {"tr", _attrs, cells, _meta} -> [Enum.map(cells, &cell_text/1)]
            _ -> []
          end)

        {head, body ++ rows}

      {"tr", _attrs, cells, _meta}, {head, body} ->
        {head, body ++ [Enum.map(cells, &cell_text/1)]}

      _, acc ->
        acc
    end)
  end

  defp cell_text({"td", _attrs, children, _meta}), do: render_inline(children)
  defp cell_text({"th", _attrs, children, _meta}), do: render_inline(children)
  defp cell_text(text) when is_binary(text), do: text
  defp cell_text(_), do: ""

  defp column_widths(rows) do
    max_cols = rows |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    for col <- 0..(max_cols - 1)//1 do
      rows
      |> Enum.map(fn row -> row |> Enum.at(col, "") |> String.length() end)
      |> Enum.max(fn -> 0 end)
    end
  end

  defp format_row(cells, widths) do
    body =
      cells
      |> Enum.with_index()
      |> Enum.map(fn {cell, idx} ->
        pad = Enum.at(widths, idx, String.length(cell))
        String.pad_trailing(cell, pad)
      end)
      |> Enum.join(" │ ")

    "│ " <> body <> " │"
  end

  defp format_separator(widths) do
    "├─" <>
      (widths
       |> Enum.map(&String.duplicate("─", &1))
       |> Enum.join("─┼─")) <>
      "─┤"
  end

  # ---------------------------------------------------------------------------
  # Inline renderers
  # ---------------------------------------------------------------------------

  defp render_inline(children) when is_list(children) do
    children
    |> Enum.map(&render_inline_node/1)
    |> Enum.join()
  end

  defp render_inline(text) when is_binary(text), do: text

  defp render_inline_node(text) when is_binary(text), do: text

  defp render_inline_node({"em", _attrs, children, _meta}), do: "*" <> render_inline(children) <> "*"

  defp render_inline_node({"strong", _attrs, children, _meta}),
    do: "**" <> render_inline(children) <> "**"

  defp render_inline_node({"code", _attrs, children, _meta}),
    do: "`" <> render_inline(children) <> "`"

  defp render_inline_node({"a", attrs, children, _meta}) do
    href = attrs |> Enum.find_value(fn {k, v} -> if k == "href", do: v end) || ""
    label = render_inline(children)

    if href == "" or href == label do
      label
    else
      label <> " (" <> href <> ")"
    end
  end

  defp render_inline_node({"img", attrs, _children, _meta}) do
    alt = attrs |> Enum.find_value(fn {k, v} -> if k == "alt", do: v end) || "image"
    src = attrs |> Enum.find_value(fn {k, v} -> if k == "src", do: v end) || ""
    "[image: " <> alt <> "]" <> if src == "", do: "", else: " (" <> src <> ")"
  end

  defp render_inline_node({"br", _attrs, _children, _meta}), do: "\n"

  defp render_inline_node({_tag, _attrs, children, _meta}), do: render_inline(children)

  defp render_inline_node(_), do: ""
end
