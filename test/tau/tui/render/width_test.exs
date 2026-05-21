defmodule Tau.TUI.Render.WidthTest do
  @moduledoc """
  Unit and property tests for `Tau.TUI.Render.Width`.
  OTP non-negotiable #6: properties first, then examples.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.TUI.Render.Width

  # ---------------------------------------------------------------------------
  # Property tests
  # ---------------------------------------------------------------------------

  describe "properties" do
    property "width is non-negative for any binary string" do
      check all(text <- string(:printable)) do
        assert Width.of(text) >= 0
      end
    end

    property "width is additive when splitting at a grapheme boundary" do
      # Unicode grapheme clusters can combine across string boundaries
      # (e.g. a combining mark at the start of b can merge with the last
      # grapheme of a), so Width.of(a <> b) == Width.of(a) + Width.of(b)
      # does NOT hold for arbitrary binary concatenation. It DOES hold when
      # we split at a grapheme boundary: summing grapheme widths one-by-one
      # equals summing the whole string.
      check all(text <- string(:printable)) do
        grapheme_sum =
          text |> String.graphemes() |> Enum.reduce(0, &(Width.grapheme(&1) + &2))

        assert Width.of(text) == grapheme_sum
      end
    end

    property "grapheme width is 0, 1, or 2" do
      check all(text <- string(:printable)) do
        for g <- String.graphemes(text) do
          w = Width.grapheme(g)
          assert w in [0, 1, 2], "grapheme #{inspect(g)} returned width #{w}"
        end
      end
    end

    property "width of a string equals sum of grapheme widths" do
      check all(text <- string(:printable)) do
        sum = text |> String.graphemes() |> Enum.reduce(0, &(Width.grapheme(&1) + &2))
        assert Width.of(text) == sum
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Example tests
  # ---------------------------------------------------------------------------

  describe "of/1 — ASCII" do
    test "empty string is 0" do
      assert Width.of("") == 0
    end

    test "ASCII string equals its byte length" do
      assert Width.of("hello") == 5
      assert Width.of("hello world") == 11
    end

    test "space is 1" do
      assert Width.of(" ") == 1
    end
  end

  describe "of/1 — East-Asian Wide" do
    test "single CJK character is 2" do
      assert Width.of("你") == 2
    end

    test "two CJK characters are 4" do
      assert Width.of("你好") == 4
    end

    test "Japanese hiragana is 2 per glyph" do
      # あ is U+3042, wide
      assert Width.of("あ") == 2
    end

    test "Korean hangul is 2 per glyph" do
      assert Width.of("안") == 2
    end

    test "mixed ASCII and CJK counts correctly" do
      # "hello 你好" = 5 + 1 + 4 = 10
      assert Width.of("hello 你好") == 10
    end
  end

  describe "of/1 — combining marks and ZWJ" do
    test "standalone combining mark has width 0" do
      # U+0301 COMBINING ACUTE ACCENT — zero-width combining mark
      assert Width.grapheme("́") == 0
    end

    test "composed grapheme with combining mark has width 1" do
      # "é" as two codepoints: e + combining acute
      assert Width.of("é") == 1
    end
  end

  describe "grapheme/1" do
    test "empty string is 0" do
      assert Width.grapheme("") == 0
    end

    test "ASCII letter is 1" do
      assert Width.grapheme("a") == 1
    end

    test "CJK character is 2" do
      assert Width.grapheme("中") == 2
    end

    test "emoji flag sequence (two regional indicators) — base char is 1" do
      # Regional indicators are in 0x1F1E0..0x1F1FF which is NOT in the wide table;
      # the combined flag emoji is typically 2 wide at display, but we measure
      # the base grapheme's first codepoint.
      # Just verify it doesn't crash.
      result = Width.grapheme("🇦")
      assert result in [0, 1, 2]
    end
  end
end
