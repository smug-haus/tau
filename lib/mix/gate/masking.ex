defmodule Mix.Gate.Masking do
  @moduledoc """
  Gate 5.2 — Masking detection.

  Scans a unified diff for removed assertion lines. Detection-only: returns
  the list for the `critic` to review. A removed assertion is a `-`-prefixed
  line (not `---` file header) whose content contains `assert`, `refute`,
  `assert_receive`, or `assert_raise`.
  """

  @assertion_keywords ~w[assert refute assert_receive assert_raise]

  @doc """
  Scans `unified_diff` for removed assertion lines.

  Returns a list of maps `%{file: String.t(), line: integer(), removed: String.t()}`.
  `file` is the path from the `+++ b/` diff header. `line` is the original-file
  line number (parsed from `@@ -L,N` hunks). `removed` is the raw content of the
  `-` line (without the leading `-`).
  """
  @spec masking_violations(String.t()) :: [
          %{file: String.t(), line: integer(), removed: String.t()}
        ]
  def masking_violations(unified_diff) when is_binary(unified_diff) do
    lines = String.split(unified_diff, "\n")
    parse_diff_lines(lines, nil, 0, [])
  end

  # State machine over diff lines.
  # current_file — path of the file being diffed (nil until first "+++ b/").
  # orig_line    — current original-file line counter (reset per hunk).
  defp parse_diff_lines([], _file, _orig_line, acc), do: Enum.reverse(acc)

  defp parse_diff_lines([h | t], current_file, orig_line, acc) do
    cond do
      String.starts_with?(h, "+++ b/") ->
        file = String.slice(h, 6..-1//1)
        parse_diff_lines(t, file, orig_line, acc)

      String.starts_with?(h, "@@") ->
        orig = parse_hunk_orig_line(h)
        parse_diff_lines(t, current_file, orig, acc)

      String.starts_with?(h, "-") and not String.starts_with?(h, "---") ->
        content = String.slice(h, 1..-1//1)

        acc2 =
          if assertion_line?(content) do
            [%{file: current_file, line: orig_line, removed: content} | acc]
          else
            acc
          end

        parse_diff_lines(t, current_file, orig_line + 1, acc2)

      String.starts_with?(h, "+") and not String.starts_with?(h, "+++") ->
        parse_diff_lines(t, current_file, orig_line, acc)

      true ->
        parse_diff_lines(t, current_file, orig_line + 1, acc)
    end
  end

  defp assertion_line?(content) do
    Enum.any?(@assertion_keywords, &String.contains?(content, &1))
  end

  # Parse the original starting line from a hunk header like "@@ -3,7 +3,6 @@".
  defp parse_hunk_orig_line(hunk_header) do
    case Regex.run(~r/@@ -(\d+)/, hunk_header) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end
end
