defmodule Tau.TUI.Render.Highlight do
  @moduledoc """
  Syntax highlighting for fenced code blocks in the TUI transcript pane.

  Uses Makeup (pure Elixir, no native dep) for highlighting. Languages not
  supported by Makeup fall back to unhighlighted (but still wrapped) code
  — they never crash or raise.

  TUI-path only. The headless `tau run` path is unaffected.

  Pure module — no process, no state.
  """

  @type styled_line :: {String.t(), keyword()}

  # Map common fence languages to Makeup lexer modules.
  # Lexers not in this map fall back to unhighlighted plain text.
  @known_lexers %{
    "elixir" => Makeup.Lexers.ElixirLexer,
    "ex" => Makeup.Lexers.ElixirLexer,
    "exs" => Makeup.Lexers.ElixirLexer,
    "erlang" => Makeup.Lexers.ErlangLexer,
    "erl" => Makeup.Lexers.ErlangLexer
  }

  # Map Makeup token-type atoms to terminal colours. Token types are
  # inspected per-grapheme; unrecognised families default to :white.
  # Coverage: keyword, string, comment, number, operator, name, function.
  @token_colors %{
    # Keywords — magenta
    :keyword => :magenta,
    :keyword_declaration => :magenta,
    :keyword_namespace => :magenta,
    :keyword_pseudo => :magenta,
    :keyword_reserved => :magenta,
    :keyword_type => :magenta,
    # Strings and char literals — yellow
    :string => :yellow,
    :string_char => :yellow,
    :string_doc => :yellow,
    :string_double => :yellow,
    :string_heredoc => :yellow,
    :string_interpol => :yellow,
    :string_other => :yellow,
    :string_single => :yellow,
    :string_symbol => :yellow,
    # Comments — dark (green approximation in most terminals)
    :comment => :green,
    :comment_doc => :green,
    :comment_multiline => :green,
    :comment_single => :green,
    :comment_special => :green,
    # Numbers — cyan
    :number => :cyan,
    :number_float => :cyan,
    :number_hex => :cyan,
    :number_integer => :cyan,
    :number_oct => :cyan,
    # Operators — red
    :operator => :red,
    :operator_word => :red,
    # Names — white (default terminal fg)
    :name => :white,
    :name_attribute => :white,
    :name_builtin => :cyan,
    :name_builtin_pseudo => :cyan,
    :name_class => :yellow,
    # Function names — blue
    :name_function => :blue,
    :name_function_magic => :blue,
    # Other names
    :name_label => :white,
    :name_namespace => :white,
    :name_other => :white,
    :name_tag => :white,
    :name_variable => :white,
    :name_variable_class => :white,
    :name_variable_global => :white,
    :name_variable_instance => :white,
    :name_variable_magic => :white,
    # Punctuation — white
    :punctuation => :white,
    # Whitespace — transparent (white, no-op visually)
    :whitespace => :white,
    # Error tokens — red
    :error => :red,
    :token_error => :red
  }

  defp token_color(type), do: Map.get(@token_colors, type, :white)

  @doc """
  Highlights `code` using the lexer for `language`.

  Returns a list of `{line_text, attrs}` tuples (one per line). Unknown
  languages return plain lines with a `color: :cyan` attribute (monospace
  convention). The function never raises.

  ## Examples

      iex> lines = Tau.TUI.Render.Highlight.highlight("def foo, do: :ok", "elixir")
      iex> is_list(lines) and length(lines) > 0
      true
  """
  @spec highlight(String.t(), String.t()) :: [styled_line()]
  def highlight(code, language) when is_binary(code) and is_binary(language) do
    case Map.get(@known_lexers, String.downcase(language)) do
      nil ->
        plain_lines(code)

      lexer_mod ->
        try do
          tokens = lexer_mod.lex(code, [])
          tokens_to_lines(tokens)
        rescue
          _ -> plain_lines(code)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Convert Makeup tokens to display lines with per-token colour attrs.
  # Makeup tokens are `{token_type, metadata, text}` tuples.
  #
  # Strategy: split each token's text on "\n", then fold into logical lines.
  # Each logical line accumulates segments; we pick the colour of the last
  # non-whitespace token on that line as the line's attrs (terminal labels
  # render a single attrs list per label, not per-character). This gives
  # distinct colours across lines: comments → green, keywords → magenta, etc.
  defp tokens_to_lines(tokens) do
    # Build a list of {line_text, dominant_color} by folding token segments.
    {lines_rev, cur_text, cur_color} =
      Enum.reduce(tokens, {[], "", :white}, fn {type, _meta, raw_text}, {lines, text, color} ->
        text_str = if is_binary(raw_text), do: raw_text, else: IO.iodata_to_binary(raw_text)
        segments = String.split(text_str, "\n", trim: false)
        tok_color = token_color(type)

        case segments do
          [only] ->
            # Single segment: no newline in this token
            new_color = if tok_color != :white, do: tok_color, else: color
            {lines, text <> only, new_color}

          [first | rest] ->
            # Token spans a newline: commit current line + first segment
            head_color = if tok_color != :white, do: tok_color, else: color
            committed_line = {text <> first, head_color}

            # Intermediate lines (all but last segment)
            {inter_lines, last_seg} = split_middle_lines(rest, tok_color)

            new_lines = inter_lines ++ [committed_line | lines]
            {new_lines, last_seg, tok_color}
        end
      end)

    # Commit the final partial line
    all_lines = [{cur_text, cur_color} | lines_rev]

    all_lines
    |> Enum.reverse()
    |> drop_trailing_empty()
    |> case do
      [] -> [{"", [color: :cyan]}]
      ls -> Enum.map(ls, fn {text, color} -> {text, [color: color]} end)
    end
  end

  # Split a list of segments (from String.split on "\n") into intermediate
  # complete lines and the final partial segment. All but the last segment
  # are complete lines.
  defp split_middle_lines([last], _color), do: {[], last}

  defp split_middle_lines([head | tail], color) do
    {inter, last} = split_middle_lines(tail, color)
    {[{head, color} | inter], last}
  end

  # Drop a single trailing empty-text line (artifact of a final "\n").
  defp drop_trailing_empty([]), do: []

  defp drop_trailing_empty(lines) do
    case List.last(lines) do
      {"", _} -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  # Plain (unhighlighted) lines for unknown languages.
  defp plain_lines(code) do
    code
    |> String.split("\n", trim: false)
    |> Enum.map(fn line -> {line, [color: :cyan]} end)
    |> case do
      [] -> [{"", [color: :cyan]}]
      lines -> lines
    end
  end
end
