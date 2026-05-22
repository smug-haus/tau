defmodule Tau.TUI.EditorTest do
  @moduledoc """
  Property and unit tests for `Tau.TUI.Editor`.

  Properties first (OTP non-negotiable #6) — invariant-bearing module.

  D-142: grapheme-cursor invariant — no grapheme is ever split.
  D-144: kill-ring capped at 10 entries.
  D-145: multi-line via newline/1.
  D-149: pure value module — no process, no GenServer.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.TUI.Editor
  alias Tau.TUI.History

  # --- Properties (OTP non-negotiable #6: properties before examples) --------

  describe "property: grapheme-cursor invariant (D-142)" do
    property "insert/2 never splits a UTF-8 grapheme" do
      check all(
              text <- string(:utf8, min_length: 0, max_length: 20),
              insert_text <- string(:printable, min_length: 1, max_length: 5)
            ) do
        ed = Editor.new() |> Editor.insert(text)
        ed2 = Editor.insert(ed, insert_text)
        full = Editor.text(ed2)
        # Every grapheme in output is a valid grapheme (no split codepoints)
        assert String.valid?(full)
        # Grapheme count is sum of original + inserted
        assert String.length(full) == String.length(text) + String.length(insert_text)
      end
    end

    property "backspace/1 never splits a grapheme — cursor remains valid" do
      check all(text <- string(:utf8, min_length: 1, max_length: 20)) do
        ed = Editor.new() |> Editor.insert(text)
        ed2 = Editor.backspace(ed)
        # Result is always valid UTF-8
        assert String.valid?(Editor.text(ed2))
        # Length decrements by exactly one grapheme (or stays same if empty)
        original_len = String.length(text)

        if original_len > 0 do
          assert String.length(Editor.text(ed2)) == original_len - 1
        else
          assert Editor.text(ed2) == ""
        end
      end
    end

    property "move_char_left/right keeps cursor in [0, len] and text unchanged" do
      check all(text <- string(:utf8, min_length: 0, max_length: 15)) do
        ed = Editor.new() |> Editor.insert(text)
        ed_left = Editor.move_char_left(ed)
        ed_right = Editor.move_char_right(ed)

        # Text is unchanged by cursor movement
        assert Editor.text(ed_left) == text
        assert Editor.text(ed_right) == text

        # Cursor stays within bounds
        {_row_l, col_l} = ed_left.cursor
        {_row_r, col_r} = ed_right.cursor
        assert col_l >= 0
        assert col_r >= 0
        line_len = String.length(text)
        assert col_l <= line_len
        assert col_r <= line_len
      end
    end
  end

  describe "property: kill-ring cap (D-144)" do
    property "kill_ring never exceeds 10 entries after any sequence of kills" do
      check all(n <- integer(1..20)) do
        ed =
          Enum.reduce(1..n, Editor.new() |> Editor.insert("hello world"), fn _, acc ->
            acc
            |> Editor.move_line_start()
            |> Editor.kill_to_line_end()
            |> Editor.insert("hello world")
          end)

        assert length(ed.kill_ring) <= 10
      end
    end
  end

  describe "property: text/1 roundtrip" do
    property "insert + text recovers the inserted string (ASCII)" do
      check all(text <- string(:ascii, min_length: 0, max_length: 50)) do
        ed = Editor.new() |> Editor.insert(text)
        assert Editor.text(ed) == text
      end
    end
  end

  describe "property: newline inserts exactly one logical line break (D-145)" do
    property "newline/1 increases line count by 1" do
      check all(text <- string(:printable, min_length: 0, max_length: 20)) do
        ed = Editor.new() |> Editor.insert(text)
        line_count_before = length(ed.lines)
        ed2 = Editor.newline(ed)
        assert length(ed2.lines) == line_count_before + 1
      end
    end
  end

  # --- Unit tests (examples) --------------------------------------------------

  describe "new/0" do
    test "starts empty with cursor at origin" do
      ed = Editor.new()
      assert ed.lines == [""]
      assert ed.cursor == {0, 0}
      assert ed.kill_ring == []
      assert ed.last_kill == :none
    end
  end

  describe "insert/2" do
    test "inserts at cursor position" do
      ed = Editor.new() |> Editor.insert("hello")
      assert Editor.text(ed) == "hello"
      assert ed.cursor == {0, 5}
    end

    test "inserts in the middle after move_line_start" do
      ed =
        Editor.new()
        |> Editor.insert("world")
        |> Editor.move_line_start()
        |> Editor.insert("hello ")

      assert Editor.text(ed) == "hello world"
    end
  end

  describe "newline/1 (D-145)" do
    test "splits line at cursor" do
      ed =
        Editor.new()
        |> Editor.insert("ab")
        |> Editor.move_line_start()
        |> Editor.insert("X")
        |> Editor.newline()

      # Cursor after 'X', newline splits: ["X", "ab"] with cursor at {1, 0}
      assert ed.cursor == {1, 0}
      assert length(ed.lines) == 2
    end

    test "text/1 joins lines with newline" do
      ed = Editor.new() |> Editor.insert("line1") |> Editor.newline() |> Editor.insert("line2")
      assert Editor.text(ed) == "line1\nline2"
    end
  end

  describe "backspace/1" do
    test "removes last character" do
      ed = Editor.new() |> Editor.insert("hello") |> Editor.backspace()
      assert Editor.text(ed) == "hell"
    end

    test "no-op on empty editor" do
      ed = Editor.new() |> Editor.backspace()
      assert Editor.text(ed) == ""
      assert ed.cursor == {0, 0}
    end

    test "merges lines when at column 0" do
      ed =
        Editor.new()
        |> Editor.insert("line1")
        |> Editor.newline()
        |> Editor.insert("line2")
        |> Editor.move_line_start()
        |> Editor.backspace()

      assert Editor.text(ed) == "line1line2"
      assert length(ed.lines) == 1
    end
  end

  describe "move_line_start/1 and move_line_end/1 (AC-3)" do
    test "Ctrl+A moves to column 0" do
      ed = Editor.new() |> Editor.insert("hello") |> Editor.move_line_start()
      assert ed.cursor == {0, 0}
    end

    test "Ctrl+E moves to end of line" do
      ed =
        Editor.new() |> Editor.insert("hello") |> Editor.move_line_start() |> Editor.move_line_end()

      assert ed.cursor == {0, 5}
    end

    test "insert after Ctrl+A prepends" do
      ed =
        Editor.new()
        |> Editor.insert("hello")
        |> Editor.move_line_start()
        |> Editor.insert("X")

      assert Editor.text(ed) == "Xhello"
    end

    test "insert after Ctrl+E appends" do
      ed =
        Editor.new()
        |> Editor.insert("hello")
        |> Editor.move_line_start()
        |> Editor.move_line_end()
        |> Editor.insert("Z")

      assert Editor.text(ed) == "helloZ"
    end
  end

  describe "kill_word_back/1 (Ctrl+W — AC-4)" do
    test "kills the word before cursor" do
      ed = Editor.new() |> Editor.insert("alpha beta") |> Editor.kill_word_back()
      assert Editor.text(ed) == "alpha "
      assert hd(ed.kill_ring) == "beta"
    end

    test "no-op at start of line" do
      ed =
        Editor.new()
        |> Editor.insert("hello")
        |> Editor.move_line_start()
        |> Editor.kill_word_back()

      assert Editor.text(ed) == "hello"
    end
  end

  describe "kill_to_line_end/1 (Ctrl+K — AC-5)" do
    test "kills from cursor to end of line" do
      ed =
        Editor.new()
        |> Editor.insert("hello world")
        |> Editor.move_line_start()
        |> Editor.kill_to_line_end()

      assert Editor.text(ed) == ""
      assert hd(ed.kill_ring) == "hello world"
    end

    test "at EOL on a multi-line editor: joins next line" do
      ed =
        Editor.new()
        |> Editor.insert("line1")
        |> Editor.newline()
        |> Editor.insert("line2")
        |> Editor.move_up()
        |> Editor.move_line_end()
        |> Editor.kill_to_line_end()

      # The newline between lines is killed; lines merged
      assert length(ed.lines) == 1
      assert Editor.text(ed) == "line1line2"
      assert hd(ed.kill_ring) == "\n"
    end
  end

  describe "kill_to_line_start/1 (Ctrl+U — AC-5)" do
    test "kills from start to cursor" do
      ed =
        Editor.new()
        |> Editor.insert("abcdef")
        |> Editor.move_line_start()
        |> Editor.kill_to_line_end()
        |> Editor.insert("abcdef")
        |> Editor.kill_to_line_start()

      assert Editor.text(ed) == ""
      assert hd(ed.kill_ring) == "abcdef"
    end

    test "after Ctrl+A, Ctrl+K kills entire line and Ctrl+Y restores (AC-5)" do
      ed =
        Editor.new()
        |> Editor.insert("abcdef")
        |> Editor.move_line_start()
        |> Editor.kill_to_line_end()

      assert Editor.text(ed) == ""
      ed2 = Editor.yank(ed)
      assert Editor.text(ed2) == "abcdef"
    end
  end

  describe "yank/1 (Ctrl+Y — AC-4, AC-5)" do
    test "inserts most recent kill-ring entry at cursor" do
      ed =
        Editor.new()
        |> Editor.insert("alpha beta")
        |> Editor.kill_word_back()
        |> Editor.yank()

      assert Editor.text(ed) == "alpha beta"
    end

    test "no-op when kill-ring is empty" do
      ed = Editor.new() |> Editor.insert("hello") |> Editor.yank()
      assert Editor.text(ed) == "hello"
    end
  end

  describe "yank_pop/1 (Alt+Y — AC-6)" do
    test "cycles to next kill-ring entry after yank" do
      # Build two distinct kill-ring entries
      ed =
        Editor.new()
        |> Editor.insert("first")
        |> Editor.kill_to_line_start()
        |> Editor.insert("second")
        |> Editor.kill_to_line_start()
        |> Editor.yank()

      yanked_text = Editor.text(ed)
      assert yanked_text == "second"

      ed2 = Editor.yank_pop(ed)
      assert Editor.text(ed2) == "first"
    end

    test "no-op if last action was not a yank" do
      ed = Editor.new() |> Editor.insert("hello")
      ed2 = Editor.yank_pop(ed)
      assert Editor.text(ed2) == "hello"
    end
  end

  describe "kill-ring cap (D-144)" do
    test "kill_ring has at most 10 entries after 15 kills" do
      ed =
        Enum.reduce(1..15, Editor.new(), fn i, acc ->
          acc
          |> Editor.insert("word#{i} ")
          |> Editor.kill_word_back()
        end)

      assert length(ed.kill_ring) <= 10
    end
  end

  describe "empty?/1" do
    test "true for new editor" do
      assert Editor.empty?(Editor.new())
    end

    test "false after inserting text" do
      refute Editor.empty?(Editor.new() |> Editor.insert("x"))
    end

    test "true after inserting and backspacing back to empty" do
      ed = Editor.new() |> Editor.insert("x") |> Editor.backspace()
      assert Editor.empty?(ed)
    end
  end

  describe "render_lines/1" do
    test "single line returns one element with cursor_col" do
      ed = Editor.new() |> Editor.insert("hello")
      [{line, cursor_col}] = Editor.render_lines(ed)
      assert line == "hello"
      assert cursor_col == 5
    end

    test "multi-line: cursor line gets col, others get nil" do
      ed =
        Editor.new()
        |> Editor.insert("line1")
        |> Editor.newline()
        |> Editor.insert("line2")

      [{_, c1}, {_, c2}] = Editor.render_lines(ed)
      assert c1 == nil
      assert c2 == 5
    end
  end

  describe "D-149 structural check: no GenServer or behaviour" do
    test "Editor module does not use GenServer" do
      # Structural check: get_in(:attributes) from the beam module info
      attributes = Editor.__info__(:attributes)
      behaviours = Keyword.get(attributes, :behaviour, [])
      refute GenServer in behaviours, "Editor must not use GenServer (D-149)"
    end

    test "History module does not use GenServer" do
      attributes = History.__info__(:attributes)
      behaviours = Keyword.get(attributes, :behaviour, [])
      refute GenServer in behaviours, "History must not use GenServer (D-149)"
    end
  end
end
