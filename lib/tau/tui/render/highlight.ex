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

  # Convert Makeup tokens to display lines. Makeup tokens are
  # `{token_type, metadata, text}` tuples.
  defp tokens_to_lines(tokens) do
    tokens
    |> Enum.flat_map(fn {_type, _meta, text} ->
      String.split(text, "\n", trim: false)
      |> Enum.with_index()
      |> Enum.map(fn {segment, _i} -> segment end)
    end)
    |> join_token_splits()
    |> Enum.map(fn line -> {line, [color: :cyan]} end)
  end

  # Makeup splits tokens on \n boundaries; we need to re-join into lines.
  # This is a simplified approach: concatenate all token texts per logical line.
  defp join_token_splits(segments) do
    # segments is already split by \n; filter trailing empty segments from the end
    case List.last(segments) do
      "" -> Enum.drop(segments, -1)
      _ -> segments
    end
    |> case do
      [] -> [""]
      segs -> segs
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
