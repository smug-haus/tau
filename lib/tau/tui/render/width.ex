defmodule Tau.TUI.Render.Width do
  @moduledoc """
  Display-column width of Unicode graphemes and strings.

  Rules (Unicode Standard Annex #11 / East Asian Width):
  - ASCII printable (U+0020..U+007E): 1 column.
  - East-Asian Wide and Fullwidth: 2 columns.
  - Combining marks, zero-width joiners, variation selectors, control chars: 0 columns.
  - Everything else: 1 column.

  This module is the single source of truth for display-width measurement
  in the TUI rendering pipeline. It replaces the `String.length/1` call in
  `Tau.TUI.App.wrap/2` which incorrectly counts codepoints rather than
  display columns, causing #334 (crash) and #190 (UTF-8 corruption).

  Pure module — no process, no state.
  """

  @doc """
  Returns the display-column width of a single grapheme cluster.

  ## Examples

      iex> Tau.TUI.Render.Width.grapheme("a")
      1
      iex> Tau.TUI.Render.Width.grapheme("你")
      2
      iex> Tau.TUI.Render.Width.grapheme("\\u0301")
      0
  """
  @spec grapheme(String.t()) :: 0 | 1 | 2
  def grapheme(""), do: 0

  def grapheme(<<cp::utf8, _rest::binary>>) do
    cond do
      zero_width?(cp) -> 0
      wide?(cp) -> 2
      true -> 1
    end
  end

  @doc """
  Returns the total display-column width of `string`.

  Iterates grapheme clusters and sums their widths.

  ## Examples

      iex> Tau.TUI.Render.Width.of("hello")
      5
      iex> Tau.TUI.Render.Width.of("你好")
      4
      iex> Tau.TUI.Render.Width.of("")
      0
  """
  @spec of(String.t()) :: non_neg_integer()
  def of(string) when is_binary(string) do
    string
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc -> acc + grapheme(g) end)
  end

  # ---------------------------------------------------------------------------
  # Private: zero-width codepoints
  # Combining marks, control characters, zero-width spaces, variation selectors.
  # ---------------------------------------------------------------------------

  # Control characters and DEL
  defp zero_width?(cp) when cp <= 0x001F, do: true
  defp zero_width?(0x007F), do: true
  defp zero_width?(cp) when cp in 0x0080..0x009F, do: true
  # Soft hyphen (invisible)
  defp zero_width?(0x00AD), do: true
  # Combining diacritical marks (Latin/Greek/Cyrillic/Arabic/Hebrew/etc.)
  defp zero_width?(cp) when cp in 0x0300..0x036F, do: true
  defp zero_width?(cp) when cp in 0x0483..0x0489, do: true
  defp zero_width?(cp) when cp in 0x0591..0x05BD, do: true
  defp zero_width?(0x05BF), do: true
  defp zero_width?(cp) when cp in 0x05C1..0x05C2, do: true
  defp zero_width?(cp) when cp in 0x05C4..0x05C5, do: true
  defp zero_width?(0x05C7), do: true
  defp zero_width?(cp) when cp in 0x0610..0x061A, do: true
  defp zero_width?(cp) when cp in 0x064B..0x065F, do: true
  defp zero_width?(0x0670), do: true
  defp zero_width?(cp) when cp in 0x06D6..0x06DC, do: true
  defp zero_width?(cp) when cp in 0x06DF..0x06E4, do: true
  defp zero_width?(cp) when cp in 0x06E7..0x06E8, do: true
  defp zero_width?(cp) when cp in 0x06EA..0x06ED, do: true
  defp zero_width?(cp) when cp in 0x0730..0x074A, do: true
  defp zero_width?(cp) when cp in 0x07A6..0x07B0, do: true
  defp zero_width?(cp) when cp in 0x07EB..0x07F3, do: true
  defp zero_width?(cp) when cp in 0x0816..0x0823, do: true
  defp zero_width?(cp) when cp in 0x0825..0x0827, do: true
  defp zero_width?(cp) when cp in 0x0829..0x082D, do: true
  defp zero_width?(cp) when cp in 0x0900..0x0903, do: true
  defp zero_width?(0x093C), do: true
  defp zero_width?(cp) when cp in 0x093E..0x094E, do: true
  defp zero_width?(cp) when cp in 0x0951..0x0957, do: true
  defp zero_width?(cp) when cp in 0x0962..0x0963, do: true
  # Zero-width space, ZWJ, ZWNJ, BOM, and related
  defp zero_width?(0x200B), do: true
  defp zero_width?(0x200C), do: true
  defp zero_width?(0x200D), do: true
  defp zero_width?(0xFEFF), do: true
  # Variation selectors
  defp zero_width?(cp) when cp in 0xFE00..0xFE0F, do: true
  defp zero_width?(cp) when cp in 0xE0100..0xE01EF, do: true
  # Combining marks (general ranges)
  defp zero_width?(cp) when cp in 0x1DC0..0x1DFF, do: true
  defp zero_width?(cp) when cp in 0x20D0..0x20FF, do: true
  defp zero_width?(cp) when cp in 0xFE20..0xFE2F, do: true
  defp zero_width?(_), do: false

  # ---------------------------------------------------------------------------
  # Private: East-Asian Wide / Fullwidth codepoints (Unicode 15.1)
  # ---------------------------------------------------------------------------

  defp wide?(cp) when cp in 0x1100..0x115F, do: true
  defp wide?(cp) when cp in 0x231A..0x231B, do: true
  defp wide?(cp) when cp in 0x2329..0x232A, do: true
  defp wide?(cp) when cp in 0x23E9..0x23F3, do: true
  defp wide?(cp) when cp in 0x23F8..0x23FA, do: true
  defp wide?(cp) when cp in 0x25FD..0x25FE, do: true
  defp wide?(cp) when cp in 0x2614..0x2615, do: true
  defp wide?(cp) when cp in 0x2648..0x2653, do: true
  defp wide?(0x267F), do: true
  defp wide?(0x2693), do: true
  defp wide?(0x26A1), do: true
  defp wide?(cp) when cp in 0x26AA..0x26AB, do: true
  defp wide?(cp) when cp in 0x26BD..0x26BE, do: true
  defp wide?(cp) when cp in 0x26C4..0x26C5, do: true
  defp wide?(0x26CE), do: true
  defp wide?(0x26D4), do: true
  defp wide?(0x26EA), do: true
  defp wide?(cp) when cp in 0x26F2..0x26F3, do: true
  defp wide?(0x26F5), do: true
  defp wide?(0x26FA), do: true
  defp wide?(0x26FD), do: true
  defp wide?(0x2702), do: true
  defp wide?(0x2705), do: true
  defp wide?(cp) when cp in 0x2708..0x270D, do: true
  defp wide?(0x270F), do: true
  defp wide?(0x2712), do: true
  defp wide?(0x2714), do: true
  defp wide?(0x2716), do: true
  defp wide?(0x271D), do: true
  defp wide?(0x2721), do: true
  defp wide?(0x2728), do: true
  defp wide?(cp) when cp in 0x2733..0x2734, do: true
  defp wide?(0x2744), do: true
  defp wide?(0x2747), do: true
  defp wide?(0x274C), do: true
  defp wide?(0x274E), do: true
  defp wide?(cp) when cp in 0x2753..0x2755, do: true
  defp wide?(0x2757), do: true
  defp wide?(cp) when cp in 0x2763..0x2764, do: true
  defp wide?(cp) when cp in 0x2795..0x2797, do: true
  defp wide?(0x27A1), do: true
  defp wide?(0x27B0), do: true
  defp wide?(0x27BF), do: true
  defp wide?(cp) when cp in 0x2B1B..0x2B1C, do: true
  defp wide?(0x2B50), do: true
  defp wide?(0x2B55), do: true
  defp wide?(cp) when cp in 0x2E80..0x2EFF, do: true
  defp wide?(cp) when cp in 0x2F00..0x2FDF, do: true
  defp wide?(cp) when cp in 0x2FF0..0x2FFF, do: true
  defp wide?(cp) when cp in 0x3000..0x303F, do: true
  defp wide?(cp) when cp in 0x3040..0x309F, do: true
  defp wide?(cp) when cp in 0x30A0..0x30FF, do: true
  defp wide?(cp) when cp in 0x3100..0x312F, do: true
  defp wide?(cp) when cp in 0x3130..0x318F, do: true
  defp wide?(cp) when cp in 0x3190..0x319F, do: true
  defp wide?(cp) when cp in 0x31A0..0x31BF, do: true
  defp wide?(cp) when cp in 0x31C0..0x31EF, do: true
  defp wide?(cp) when cp in 0x31F0..0x31FF, do: true
  defp wide?(cp) when cp in 0x3200..0x32FF, do: true
  defp wide?(cp) when cp in 0x3300..0x33FF, do: true
  defp wide?(cp) when cp in 0x3400..0x4DBF, do: true
  defp wide?(cp) when cp in 0x4E00..0x9FFF, do: true
  defp wide?(cp) when cp in 0xA000..0xA48F, do: true
  defp wide?(cp) when cp in 0xA490..0xA4CF, do: true
  defp wide?(cp) when cp in 0xA960..0xA97F, do: true
  defp wide?(cp) when cp in 0xAC00..0xD7AF, do: true
  defp wide?(cp) when cp in 0xD7B0..0xD7FF, do: true
  defp wide?(cp) when cp in 0xF900..0xFAFF, do: true
  defp wide?(cp) when cp in 0xFE10..0xFE1F, do: true
  defp wide?(cp) when cp in 0xFE30..0xFE4F, do: true
  defp wide?(cp) when cp in 0xFE50..0xFE6F, do: true
  defp wide?(cp) when cp in 0xFF00..0xFF60, do: true
  defp wide?(cp) when cp in 0xFFE0..0xFFE6, do: true
  defp wide?(cp) when cp in 0x1B000..0x1B0FF, do: true
  defp wide?(cp) when cp in 0x1B100..0x1B12F, do: true
  defp wide?(cp) when cp in 0x1B130..0x1B16F, do: true
  defp wide?(0x1F004), do: true
  defp wide?(0x1F0CF), do: true
  defp wide?(cp) when cp in 0x1F200..0x1F2FF, do: true
  defp wide?(cp) when cp in 0x1F300..0x1F64F, do: true
  defp wide?(cp) when cp in 0x1F900..0x1F9FF, do: true
  defp wide?(cp) when cp in 0x1FA00..0x1FA6F, do: true
  defp wide?(cp) when cp in 0x1FA70..0x1FAFF, do: true
  defp wide?(cp) when cp in 0x20000..0x2A6DF, do: true
  defp wide?(cp) when cp in 0x2A700..0x2B73F, do: true
  defp wide?(cp) when cp in 0x2B740..0x2B81F, do: true
  defp wide?(cp) when cp in 0x2B820..0x2CEAF, do: true
  defp wide?(cp) when cp in 0x2CEB0..0x2EBEF, do: true
  defp wide?(cp) when cp in 0x2F800..0x2FA1F, do: true
  defp wide?(cp) when cp in 0x30000..0x3134F, do: true
  defp wide?(_), do: false
end
