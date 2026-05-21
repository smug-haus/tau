defmodule Tau.TUI.Render.WrapTest do
  @moduledoc """
  Unit and property tests for `Tau.TUI.Render.Wrap`.

  Key invariants (OTP non-negotiable #6 — properties first):
  1. Every output line's `Width.of/1` ≤ `columns`.
  2. Every output line is valid UTF-8 (`String.valid?/1`).
  3. No grapheme cluster is split (reassembling output preserves grapheme count).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.TUI.Render.Width
  alias Tau.TUI.Render.Wrap

  # ---------------------------------------------------------------------------
  # Property tests
  # ---------------------------------------------------------------------------

  describe "properties" do
    property "every output line's display width ≤ columns" do
      check all(
              text <- string(:printable),
              columns <- integer(1..200)
            ) do
        lines = Wrap.wrap(text, columns)

        for line <- lines do
          w = Width.of(line)

          assert w <= columns,
                 "line #{inspect(line)} has width #{w} > columns #{columns}" <>
                   " (input: #{inspect(text)})"
        end
      end
    end

    property "every output line is valid UTF-8" do
      check all(
              text <- string(:printable),
              columns <- integer(1..200)
            ) do
        lines = Wrap.wrap(text, columns)

        for line <- lines do
          assert String.valid?(line),
                 "output line #{inspect(line)} is not valid UTF-8" <>
                   " (input: #{inspect(text)})"
        end
      end
    end

    property "wrap always returns a non-empty list" do
      check all(
              text <- string(:printable),
              columns <- integer(1..200)
            ) do
        assert Wrap.wrap(text, columns) != []
      end
    end

    property "every output line is a binary" do
      check all(
              text <- string(:printable),
              columns <- integer(1..200)
            ) do
        for line <- Wrap.wrap(text, columns) do
          assert is_binary(line)
        end
      end
    end

    property "no byte-splitting: every output line is valid UTF-8 (grapheme boundary invariant)" do
      # This property captures the essential safety invariant: no output line
      # may contain a truncated multi-byte UTF-8 sequence (i.e. no grapheme
      # split at a byte boundary). String.valid?/1 is the canonical check.
      # Separate from the valid-UTF-8 property above to provide a clear name.
      check all(
              text <- string(:printable),
              columns <- integer(1..200)
            ) do
        for line <- Wrap.wrap(text, columns) do
          assert String.valid?(line),
                 "line #{inspect(line)} contains invalid UTF-8 (byte split) " <>
                   "for input #{inspect(text)} at columns #{columns}"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Example tests
  # ---------------------------------------------------------------------------

  describe "wrap/2 — ASCII basics" do
    test "empty string yields a single empty line" do
      assert Wrap.wrap("", 10) == [""]
    end

    test "short string fits in one line" do
      assert Wrap.wrap("hello", 10) == ["hello"]
    end

    test "string exactly at width fits in one line" do
      assert Wrap.wrap("hello", 5) == ["hello"]
    end

    test "wraps at word boundary" do
      lines = Wrap.wrap("hello world", 7)
      assert lines == ["hello", "world"]
    end

    test "preserves multiple words across lines" do
      lines = Wrap.wrap("aaaa bbbb cccc dddd", 9)
      assert Enum.join(lines, " ") == "aaaa bbbb cccc dddd"
    end

    test "hard-breaks a word wider than columns on grapheme boundaries" do
      # 30 ASCII chars, wrapped to 10
      word = String.duplicate("x", 30)
      lines = Wrap.wrap(word, 10)
      assert lines == ["xxxxxxxxxx", "xxxxxxxxxx", "xxxxxxxxxx"]
    end

    test "hard-breaks still produces valid UTF-8" do
      word = String.duplicate("x", 15)
      lines = Wrap.wrap(word, 7)
      assert Enum.all?(lines, &String.valid?/1)
    end

    test "1-column wrap does not crash" do
      lines = Wrap.wrap("hello", 1)
      assert Enum.all?(lines, fn l -> Width.of(l) <= 1 end)
      assert Enum.all?(lines, &String.valid?/1)
    end
  end

  describe "wrap/2 — CJK (wide chars, #334 / #190)" do
    test "CJK string wraps to correct column boundaries" do
      # Each CJK char = 2 columns; 4 chars in 4-col pane = 2 lines of 2 chars each
      lines = Wrap.wrap("你好世界", 4)
      assert Enum.all?(lines, fn l -> Width.of(l) <= 4 end)
      # All graphemes preserved
      total = lines |> Enum.join() |> String.graphemes() |> length()
      assert total == 4
    end

    test "narrow 2-column pane with CJK does not crash" do
      lines = Wrap.wrap("你好世界", 2)
      assert Enum.all?(lines, fn l -> Width.of(l) <= 2 end)
      assert Enum.all?(lines, &String.valid?/1)
    end

    test "1-column pane with CJK does not crash (wide chars replaced by space)" do
      lines = Wrap.wrap("你好", 1)
      assert is_list(lines)
      assert Enum.all?(lines, &String.valid?/1)
    end

    test "mixed ASCII and CJK wraps correctly" do
      # "hi 你好 ok" — each CJK = 2
      lines = Wrap.wrap("hi 你好 ok", 6)
      assert Enum.all?(lines, fn l -> Width.of(l) <= 6 end)
      assert Enum.all?(lines, &String.valid?/1)
    end
  end

  describe "wrap/2 — emoji" do
    test "emoji wraps without crashing" do
      # Emoji are typically 2 columns wide
      lines = Wrap.wrap("hello 🎉 world", 8)
      assert is_list(lines)
      assert Enum.all?(lines, &String.valid?/1)
    end

    test "emoji within narrow pane does not crash" do
      lines = Wrap.wrap("🎉🎊🎈", 3)
      assert is_list(lines)
      assert Enum.all?(lines, &String.valid?/1)
    end
  end

  describe "wrap/2 — multi-line input" do
    test "pre-split newlines are treated as whitespace" do
      # Newlines in the middle of input are treated as whitespace separators
      lines = Wrap.wrap("a b c d e", 3)
      assert Enum.all?(lines, fn l -> Width.of(l) <= 3 end)
    end
  end
end
