defmodule Tau.TUI.Render.Wrap do
  @moduledoc """
  Width-correct word-wrap and hard-clip for Unicode text.

  Replaces `Tau.TUI.App.wrap/2` and `chunk_string/3` which used
  `String.length/1` (codepoints, not display columns) and
  `binary-size(n)` (bytes, not graphemes) respectively.

  Invariants:
  - Every output line's `Tau.TUI.Render.Width.of/1` ≤ `columns`.
  - Every output line is valid UTF-8 (`String.valid?/1`).
  - No grapheme cluster is split at a byte boundary.
  - `columns ≥ 1` is required.

  Note: at very narrow `columns` values (typically `columns = 1`), wide
  (East-Asian / emoji) graphemes whose display width exceeds `columns` are
  replaced with a single space. This is the only way to simultaneously
  satisfy the width invariant and avoid infinite loops. All replacement
  characters are valid UTF-8.

  Pure module — no process, no state.
  """

  alias Tau.TUI.Render.Width

  @doc """
  Word-wraps `text` to fit within `columns` display columns.

  Splits on whitespace (preserving words); hard-breaks words wider than
  `columns` on grapheme boundaries (never byte boundaries). Returns a
  list of lines. An empty string returns `[""]`.

  ## Examples

      iex> Tau.TUI.Render.Wrap.wrap("hello world", 5)
      ["hello", "world"]

      iex> Tau.TUI.Render.Wrap.wrap("", 10)
      [""]

      iex> Tau.TUI.Render.Wrap.wrap("你好世界", 4)
      ["你好", "世界"]
  """
  @spec wrap(String.t(), pos_integer()) :: [String.t()]
  def wrap(text, columns)
      when is_binary(text) and is_integer(columns) and columns >= 1 do
    text
    |> split_into_tokens()
    |> do_wrap(columns)
  end

  # Split text into a flat list of tokens: alternating word/whitespace runs
  # operating on grapheme clusters (never bytes or codepoints).
  defp split_into_tokens(text) do
    text
    |> String.graphemes()
    |> Enum.chunk_by(&whitespace?/1)
    |> Enum.map(&Enum.join/1)
  end

  defp whitespace?(g), do: String.match?(g, ~r/^\s$/u)

  defp do_wrap([], _columns), do: [""]
  defp do_wrap([""], _columns), do: [""]

  defp do_wrap(tokens, columns) do
    {lines, current_line, _current_width} =
      Enum.reduce(tokens, {[], "", 0}, fn token, {lines, cur, cur_w} ->
        if whitespace?(token) do
          handle_whitespace(token, lines, cur, cur_w, columns)
        else
          handle_word(token, lines, cur, cur_w, columns)
        end
      end)

    finalize(lines, current_line)
  end

  defp handle_whitespace(token, lines, cur, cur_w, columns) do
    # Don't start a line with whitespace
    if cur == "" do
      {lines, cur, cur_w}
    else
      token_w = Width.of(token)

      if cur_w + token_w <= columns do
        {lines, cur <> token, cur_w + token_w}
      else
        # Trailing whitespace overflows — treat as a break point, drop it
        {lines, cur, cur_w}
      end
    end
  end

  defp handle_word(token, lines, cur, cur_w, columns) do
    word_w = Width.of(token)

    if word_w > columns do
      # Word wider than columns — must hard-break on grapheme boundaries
      hard_break(token, columns, lines, cur, cur_w)
    else
      # Try to fit on the current line.
      # cur_w includes any trailing space from the previous whitespace token;
      # we check cur_w (not trimmed) so we don't exceed columns with the space.
      if cur_w + word_w <= columns do
        {lines, cur <> token, cur_w + word_w}
      else
        # Start a new line; trim trailing space from the committed line.
        {[String.trim_trailing(cur) | lines], token, word_w}
      end
    end
  end

  # Hard-break a single word (wider than `columns`) into chunks on grapheme
  # boundaries. Fills the current line first, then emits full-width chunks.
  defp hard_break(word, columns, acc_lines, cur_line, cur_width) do
    graphemes = String.graphemes(word)
    do_hard_break(graphemes, columns, acc_lines, cur_line, cur_width, "", 0)
  end

  defp do_hard_break([], _cols, lines, cur, cur_w, "", _chunk_w) do
    {lines, cur, cur_w}
  end

  defp do_hard_break([], _cols, lines, cur, _cur_w, chunk, chunk_w) do
    if cur == "" do
      {lines, chunk, chunk_w}
    else
      {[String.trim_trailing(cur) | lines], chunk, chunk_w}
    end
  end

  defp do_hard_break([g | rest], cols, lines, cur, cur_w, chunk, chunk_w) do
    g_w = Width.grapheme(g)

    cond do
      # Zero-width grapheme: always include, no column advance
      g_w == 0 ->
        do_hard_break(rest, cols, lines, cur, cur_w, chunk <> g, chunk_w)

      # Grapheme is wider than the entire column budget — replace with space
      # to avoid an infinite loop. This is only reachable at very narrow panes
      # (e.g. cols=1) with wide chars (e.g. CJK at 2 columns).
      g_w > cols ->
        # A space fits in 1 column; add it to the chunk/cur.
        space_w = 1

        if cur == "" and chunk_w + space_w <= cols do
          do_hard_break(rest, cols, lines, cur, cur_w, chunk <> " ", chunk_w + space_w)
        else
          # Flush cur and chunk separately, emit space on new line
          flushed_lines = flush_lines(cur, chunk, cur_w, chunk_w, lines)
          do_hard_break(rest, cols, flushed_lines, " ", space_w, "", 0)
        end

      # Try adding g to the combined cur+chunk budget
      cur_w + chunk_w + g_w <= cols ->
        do_hard_break(rest, cols, lines, cur, cur_w, chunk <> g, chunk_w + g_w)

      # cur+chunk is full — flush cur+chunk together as one line
      cur != "" or chunk != "" ->
        committed = String.trim_trailing(cur <> chunk)

        if committed == "" do
          do_hard_break([g | rest], cols, lines, "", 0, "", 0)
        else
          do_hard_break([g | rest], cols, [committed | lines], "", 0, "", 0)
        end

      true ->
        # Both empty, chunk_w + g_w > cols — shouldn't happen since g_w <= cols
        # but guard it anyway
        do_hard_break(rest, cols, lines, cur, cur_w, chunk <> g, chunk_w + g_w)
    end
  end

  defp flush_lines(cur, chunk, _cur_w, _chunk_w, lines) do
    combined = String.trim_trailing(cur <> chunk)

    if combined == "" do
      lines
    else
      [combined | lines]
    end
  end

  defp finalize(lines, last_line) do
    trimmed = String.trim_trailing(last_line)

    result =
      if trimmed == "" and lines == [] do
        [""]
      else
        Enum.reverse([trimmed | lines])
      end

    # Remove any blank intermediate lines that arise from leading
    # whitespace, but preserve a single [""] for truly-blank input.
    case result do
      [""] ->
        [""]

      _ ->
        filtered = Enum.reject(result, &(&1 == ""))

        case filtered do
          [] -> [""]
          _ -> filtered
        end
    end
  end
end
