defmodule Tau.TUI.Editor do
  @kill_ring_cap 10

  @moduledoc """
  Pure value module for the TUI input editor.

  Holds multi-line input buffer, a grapheme-column cursor, a bounded
  kill-ring, and yank state. All operations are `editor -> editor` (or
  `editor -> {editor, text}`) — no process, no GenServer (D-149).

  Cursor positions are grapheme-column indices, never byte indices (D-142).
  The buffer is a non-empty list of lines; `[""]` is the empty editor.

  Kill-ring is capped at #{@kill_ring_cap} entries (D-144).
  """

  @type t :: %__MODULE__{
          lines: [String.t()],
          cursor: {non_neg_integer(), non_neg_integer()},
          kill_ring: [String.t()],
          last_kill: :none | :kill | :yank,
          yank_index: non_neg_integer()
        }

  defstruct lines: [""],
            cursor: {0, 0},
            kill_ring: [],
            last_kill: :none,
            yank_index: 0

  @doc "New empty editor."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Insert a single grapheme (or multi-character string) at cursor.
  Updates cursor to end of inserted text.
  """
  @spec insert(t(), String.t()) :: t()
  def insert(%__MODULE__{lines: lines, cursor: {row, col}} = ed, text) do
    line = Enum.at(lines, row, "")
    graphemes = String.graphemes(line)
    {before_cursor, after_cursor} = Enum.split(graphemes, col)

    inserted = String.graphemes(text)
    new_line = IO.iodata_to_binary([before_cursor, inserted, after_cursor])
    new_col = col + length(inserted)

    %{ed | lines: List.replace_at(lines, row, new_line), cursor: {row, new_col}, last_kill: :none}
  end

  @doc "Insert a newline at cursor (multi-line: D-145)."
  @spec newline(t()) :: t()
  def newline(%__MODULE__{lines: lines, cursor: {row, col}} = ed) do
    line = Enum.at(lines, row, "")
    graphemes = String.graphemes(line)
    {before_cursor, after_cursor} = Enum.split(graphemes, col)

    first = IO.iodata_to_binary(before_cursor)
    rest = IO.iodata_to_binary(after_cursor)

    new_lines =
      lines
      |> List.replace_at(row, first)
      |> List.insert_at(row + 1, rest)

    %{ed | lines: new_lines, cursor: {row + 1, 0}, last_kill: :none}
  end

  @doc "Delete the grapheme before the cursor (Backspace)."
  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{cursor: {0, 0}} = ed), do: ed

  def backspace(%__MODULE__{lines: lines, cursor: {row, 0}} = ed) when row > 0 do
    # Merge current line into previous
    prev = Enum.at(lines, row - 1, "")
    curr = Enum.at(lines, row, "")
    merged = prev <> curr
    prev_len = grapheme_length(prev)

    new_lines =
      lines
      |> List.replace_at(row - 1, merged)
      |> List.delete_at(row)

    %{ed | lines: new_lines, cursor: {row - 1, prev_len}, last_kill: :none}
  end

  def backspace(%__MODULE__{lines: lines, cursor: {row, col}} = ed) do
    line = Enum.at(lines, row, "")
    graphemes = String.graphemes(line)
    {before_cursor, after_cursor} = Enum.split(graphemes, col)

    new_before = List.delete_at(before_cursor, -1)
    new_line = IO.iodata_to_binary([new_before, after_cursor])

    %{ed | lines: List.replace_at(lines, row, new_line), cursor: {row, col - 1}, last_kill: :none}
  end

  @doc "Delete the grapheme at cursor (Delete-forward / Ctrl+D)."
  @spec delete_forward(t()) :: t()
  def delete_forward(%__MODULE__{lines: lines, cursor: {row, col}} = ed) do
    line = Enum.at(lines, row, "")
    graphemes = String.graphemes(line)
    len = length(graphemes)

    cond do
      col < len ->
        {before_cursor, after_cursor} = Enum.split(graphemes, col)
        new_line = IO.iodata_to_binary([before_cursor, tl(after_cursor)])
        %{ed | lines: List.replace_at(lines, row, new_line)}

      row < length(lines) - 1 ->
        # At end of line, merge next line in
        next = Enum.at(lines, row + 1, "")
        merged = line <> next

        new_lines =
          lines
          |> List.replace_at(row, merged)
          |> List.delete_at(row + 1)

        %{ed | lines: new_lines}

      true ->
        ed
    end
  end

  @doc "Move cursor one grapheme left."
  @spec move_char_left(t()) :: t()
  def move_char_left(%__MODULE__{cursor: {0, 0}} = ed), do: ed

  def move_char_left(%__MODULE__{cursor: {row, 0}} = ed) when row > 0 do
    prev = Enum.at(ed.lines, row - 1, "")
    %{ed | cursor: {row - 1, grapheme_length(prev)}}
  end

  def move_char_left(%__MODULE__{cursor: {row, col}} = ed) do
    %{ed | cursor: {row, col - 1}}
  end

  @doc "Move cursor one grapheme right."
  @spec move_char_right(t()) :: t()
  def move_char_right(%__MODULE__{lines: lines, cursor: {row, col}} = ed) do
    line = Enum.at(lines, row, "")
    len = grapheme_length(line)

    cond do
      col < len ->
        %{ed | cursor: {row, col + 1}}

      row < length(lines) - 1 ->
        %{ed | cursor: {row + 1, 0}}

      true ->
        ed
    end
  end

  @doc "Move cursor one word backward (Alt+B). Stops at word boundaries."
  @spec move_word_left(t()) :: t()
  def move_word_left(%__MODULE__{cursor: {row, col}} = ed) do
    line = Enum.at(ed.lines, row, "")
    graphemes = String.graphemes(line)
    # Skip whitespace, then skip non-whitespace
    before_cursor = Enum.take(graphemes, col) |> Enum.reverse()
    skipped = before_cursor |> skip_while(&word_char?/1) |> skip_while(&(!word_char?(&1)))
    new_col = col - (length(before_cursor) - length(skipped))
    %{ed | cursor: {row, max(0, new_col)}}
  end

  @doc "Move cursor one word forward (Alt+F). Stops at word boundaries."
  @spec move_word_right(t()) :: t()
  def move_word_right(%__MODULE__{lines: lines, cursor: {row, col}} = ed) do
    line = Enum.at(lines, row, "")
    graphemes = String.graphemes(line)
    after_cursor = Enum.drop(graphemes, col)
    skipped = after_cursor |> skip_while(&(!word_char?(&1))) |> skip_while(&word_char?/1)
    new_col = col + (length(after_cursor) - length(skipped))
    %{ed | cursor: {row, min(grapheme_length(line), new_col)}}
  end

  @doc "Move cursor to start of current line (Ctrl+A)."
  @spec move_line_start(t()) :: t()
  def move_line_start(%__MODULE__{cursor: {row, _}} = ed) do
    %{ed | cursor: {row, 0}}
  end

  @doc "Move cursor to end of current line (Ctrl+E)."
  @spec move_line_end(t()) :: t()
  def move_line_end(%__MODULE__{lines: lines, cursor: {row, _}} = ed) do
    len = grapheme_length(Enum.at(lines, row, ""))
    %{ed | cursor: {row, len}}
  end

  @doc "Move cursor up one line (clamped to line end)."
  @spec move_up(t()) :: t()
  def move_up(%__MODULE__{cursor: {0, _}} = ed), do: ed

  def move_up(%__MODULE__{lines: lines, cursor: {row, col}} = ed) do
    new_row = row - 1
    new_col = min(col, grapheme_length(Enum.at(lines, new_row, "")))
    %{ed | cursor: {new_row, new_col}}
  end

  @doc "Move cursor down one line (clamped to line end)."
  @spec move_down(t()) :: t()
  def move_down(%__MODULE__{lines: lines, cursor: {row, col}} = ed) do
    last = length(lines) - 1

    if row >= last do
      ed
    else
      new_row = row + 1
      new_col = min(col, grapheme_length(Enum.at(lines, new_row, "")))
      %{ed | cursor: {new_row, new_col}}
    end
  end

  @doc """
  Kill to end of current line (Ctrl+K). Killed text pushed to kill-ring.
  If cursor is at EOL and there is a next line, join the next line.
  Sequential kills coalesce into one ring entry.
  """
  @spec kill_to_line_end(t()) :: t()
  def kill_to_line_end(%__MODULE__{lines: lines, cursor: {row, col}} = ed) do
    line = Enum.at(lines, row, "")
    graphemes = String.graphemes(line)
    len = length(graphemes)

    {killed, new_lines} =
      if col == len and length(lines) > 1 and row < length(lines) - 1 do
        # At EOL: join next line (delete the newline between)
        next = Enum.at(lines, row + 1, "")
        merged_line = line <> next
        nl = List.delete_at(lines, row + 1)
        {"\n", List.replace_at(nl, row, merged_line)}
      else
        after_cursor = Enum.drop(graphemes, col)
        k = IO.iodata_to_binary(after_cursor)
        nl_str = IO.iodata_to_binary(Enum.take(graphemes, col))
        {k, List.replace_at(lines, row, nl_str)}
      end

    push_kill(%{ed | lines: new_lines, cursor: {row, col}}, killed)
  end

  @doc """
  Kill from start of line to cursor (Ctrl+U). Killed text pushed to kill-ring.
  Sequential kills coalesce.
  """
  @spec kill_to_line_start(t()) :: t()
  def kill_to_line_start(%__MODULE__{lines: lines, cursor: {row, col}} = ed) do
    line = Enum.at(lines, row, "")
    graphemes = String.graphemes(line)
    {before_cursor, after_cursor} = Enum.split(graphemes, col)

    killed = IO.iodata_to_binary(before_cursor)
    new_line = IO.iodata_to_binary(after_cursor)

    push_kill(%{ed | lines: List.replace_at(lines, row, new_line), cursor: {row, 0}}, killed)
  end

  @doc """
  Kill the word before the cursor (Ctrl+W). Killed text pushed to kill-ring.
  """
  @spec kill_word_back(t()) :: t()
  def kill_word_back(%__MODULE__{lines: lines, cursor: {row, col}} = ed) do
    line = Enum.at(lines, row, "")
    graphemes = String.graphemes(line)
    before_cursor = Enum.take(graphemes, col) |> Enum.reverse()

    # Skip trailing whitespace, then skip word characters (backward)
    after_skip_ws = skip_while(before_cursor, &(!word_char?(&1)))
    after_skip_word = skip_while(after_skip_ws, &word_char?/1)

    n_killed = length(before_cursor) - length(after_skip_word)

    if n_killed == 0 do
      ed
    else
      killed_graphemes = Enum.take(before_cursor, n_killed)
      killed = killed_graphemes |> Enum.reverse() |> IO.iodata_to_binary()
      remaining_before = Enum.drop(before_cursor, n_killed) |> Enum.reverse()
      after_cursor = Enum.drop(graphemes, col)
      new_line = IO.iodata_to_binary([remaining_before, after_cursor])
      new_col = col - n_killed

      push_kill(
        %{ed | lines: List.replace_at(lines, row, new_line), cursor: {row, new_col}},
        killed
      )
    end
  end

  @doc """
  Yank the most recent kill-ring entry at cursor (Ctrl+Y).
  Sets `last_kill: :yank` and `yank_index: 0`.
  """
  @spec yank(t()) :: t()
  def yank(%__MODULE__{kill_ring: []} = ed), do: ed

  def yank(%__MODULE__{kill_ring: [text | _]} = ed) do
    ed
    |> insert(text)
    |> Map.merge(%{last_kill: :yank, yank_index: 0})
  end

  @doc """
  Yank-pop: cycle the kill-ring (Alt+Y). Only valid immediately after
  yank or yank-pop. If last action was not a yank, returns ed unchanged.
  """
  @spec yank_pop(t()) :: t()
  def yank_pop(%__MODULE__{last_kill: last} = ed) when last != :yank, do: ed

  def yank_pop(%__MODULE__{kill_ring: []} = ed), do: ed

  def yank_pop(%__MODULE__{kill_ring: ring, yank_index: idx} = ed) do
    # Remove the previously yanked text and yank the next ring entry
    prev_text = Enum.at(ring, rem(idx, length(ring)))
    next_idx = rem(idx + 1, length(ring))
    next_text = Enum.at(ring, next_idx)

    # Delete prev_text characters before cursor (grapheme-count of prev_text)
    ed_deleted =
      Enum.reduce(1..grapheme_length(prev_text), ed, fn _, acc ->
        backspace(acc)
      end)

    ed_deleted
    |> insert(next_text)
    |> Map.merge(%{last_kill: :yank, yank_index: next_idx})
  end

  @doc "Return the full text content (lines joined with newline)."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{lines: lines}), do: Enum.join(lines, "\n")

  @doc """
  Return the list of lines for rendering, with cursor glyph injected.
  Returns `[{line_text, cursor_col | nil}]` where cursor_col marks which
  line/col gets the cursor glyph. Callers insert the glyph at that position.
  """
  @spec render_lines(t()) :: [{String.t(), non_neg_integer() | nil}]
  def render_lines(%__MODULE__{lines: lines, cursor: {cursor_row, cursor_col}}) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      if idx == cursor_row do
        {line, cursor_col}
      else
        {line, nil}
      end
    end)
  end

  @doc "True if the editor buffer is empty (all lines are empty strings)."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{lines: lines}), do: Enum.all?(lines, &(&1 == ""))

  # --- Private helpers -------------------------------------------------------

  defp grapheme_length(str), do: String.length(str)

  defp skip_while(list, pred) do
    Enum.drop_while(list, pred)
  end

  defp word_char?(g), do: String.match?(g, ~r/\w/)

  # Push a killed string onto the kill-ring.
  # If last_kill was :kill, coalesce: prepend to the head entry.
  # Otherwise push a new entry. Cap at @kill_ring_cap.
  defp push_kill(%__MODULE__{kill_ring: ring, last_kill: :kill} = ed, killed) when killed != "" do
    coalesced =
      case ring do
        [head | rest] -> [killed <> head | rest]
        [] -> [killed]
      end

    capped = Enum.take(coalesced, @kill_ring_cap)
    %{ed | kill_ring: capped, last_kill: :kill, yank_index: 0}
  end

  defp push_kill(%__MODULE__{kill_ring: ring} = ed, killed) when killed != "" do
    capped = Enum.take([killed | ring], @kill_ring_cap)
    %{ed | kill_ring: capped, last_kill: :kill, yank_index: 0}
  end

  defp push_kill(ed, ""), do: %{ed | last_kill: :kill}
end
