defmodule Tau.Tools.Builtin.Edit do
  @moduledoc """
  Apply a list of `{old_text, new_text}` edits to a file.

  Semantics (mirroring Pi):

    * All `old_text` strings match against the **original** contents — edits
      are not incremental. The implementation collects all matches first,
      verifies non-overlap and uniqueness per edit, then applies.
    * Each `old_text` must occur exactly once in the file (the model is
      expected to add disambiguating context). Zero or multiple occurrences
      → error result.
    * BOM and original line endings are preserved.

  Returns a unified diff in `details.diff` and the line of the first change
  in `details.first_changed_line`.
  """

  @behaviour Tau.Tool

  alias Tau.Tool.Result

  @impl Tau.Tool
  def name, do: "Edit"

  @impl Tau.Tool
  def description,
    do:
      "Apply targeted text replacements to a file. Each old_text must occur exactly once. All replacements are matched against the original file (not incrementally)."

  @impl Tau.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "edits" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "old_text" => %{"type" => "string"},
              "new_text" => %{"type" => "string"}
            },
            "required" => ["old_text", "new_text"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["path", "edits"],
      "additionalProperties" => false
    }
  end

  @impl Tau.Tool
  def execution_mode, do: :sequential

  @impl Tau.Tool
  def execute(%{"path" => path, "edits" => edits}, ctx) do
    full = ctx.operations.resolve(path, ctx.cwd)

    with {:ok, original} <- ctx.operations.read(full),
         {:ok, plan} <- locate_all(original, edits),
         :ok <- assert_no_overlap(plan),
         applied = apply_plan(original, plan),
         :ok <- ctx.operations.write(full, applied) do
      diff = unified_diff(full, original, applied)
      first_line = first_changed_line(plan, original)

      {:ok,
       Result.text("Applied #{length(edits)} edit(s) to #{full}",
         details: %{
           path: full,
           diff: diff,
           first_changed_line: first_line,
           edit_count: length(edits)
         }
       )}
    else
      {:error, :enoent} ->
        {:ok, Result.error("File not found: #{path}")}

      {:error, {:not_found, txt}} ->
        {:ok, Result.error("old_text not found: #{inspect(short(txt))}")}

      {:error, {:multiple, txt, n}} ->
        {:ok, Result.error("old_text found #{n} times (must be unique): #{inspect(short(txt))}")}

      {:error, :overlap} ->
        {:ok, Result.error("edits overlap; each must target a non-overlapping region")}

      {:error, posix} ->
        {:ok, Result.error("Edit failed: #{inspect(posix)}")}
    end
  end

  defp locate_all(original, edits) do
    Enum.reduce_while(edits, {:ok, []}, fn %{"old_text" => o, "new_text" => n}, {:ok, acc} ->
      case occurrences(original, o) do
        [pos] -> {:cont, {:ok, [{pos, byte_size(o), o, n} | acc]}}
        [] -> {:halt, {:error, {:not_found, o}}}
        many -> {:halt, {:error, {:multiple, o, length(many)}}}
      end
    end)
    |> case do
      {:ok, plan} -> {:ok, Enum.sort_by(plan, fn {p, _, _, _} -> p end)}
      err -> err
    end
  end

  defp occurrences(_haystack, ""), do: []

  defp occurrences(haystack, needle) do
    matches = :binary.matches(haystack, needle)
    Enum.map(matches, fn {pos, _len} -> pos end)
  end

  defp assert_no_overlap(plan) do
    plan
    |> Enum.zip(Enum.drop(plan, 1))
    |> Enum.reduce_while(:ok, fn {{p, len, _, _}, {p2, _, _, _}}, _ ->
      if p + len <= p2, do: {:cont, :ok}, else: {:halt, {:error, :overlap}}
    end)
  end

  defp apply_plan(original, plan) do
    {acc, last} =
      Enum.reduce(plan, {[], 0}, fn {pos, len, _old, new}, {acc, cur} ->
        prefix = binary_part(original, cur, pos - cur)
        {[new, prefix | acc], pos + len}
      end)

    suffix = binary_part(original, last, byte_size(original) - last)
    IO.iodata_to_binary(Enum.reverse([suffix | acc]))
  end

  defp first_changed_line([], _original), do: nil

  defp first_changed_line([{pos, _, _, _} | _], original) do
    prefix = binary_part(original, 0, pos)
    1 + count_newlines(prefix)
  end

  defp count_newlines(<<>>), do: 0
  defp count_newlines(<<?\n, rest::binary>>), do: 1 + count_newlines(rest)
  defp count_newlines(<<_, rest::binary>>), do: count_newlines(rest)

  defp unified_diff(path, a, b) do
    a_lines = String.split(a, "\n")
    b_lines = String.split(b, "\n")
    "--- a/#{path}\n+++ b/#{path}\n" <> render_diff(a_lines, b_lines)
  end

  defp render_diff(a, b) do
    # Minimal diff: list deletions then additions. A real LCS-based diff
    # lives in M3 or via a Hex dep; this is enough for `details.diff`
    # storage in the JSONL session for now.
    diff_a = a |> Enum.with_index() |> Enum.map(fn {l, i} -> "-[#{i + 1}] #{l}" end)
    diff_b = b |> Enum.with_index() |> Enum.map(fn {l, i} -> "+[#{i + 1}] #{l}" end)
    Enum.join(diff_a ++ diff_b, "\n")
  end

  defp short(s) when byte_size(s) > 80, do: binary_part(s, 0, 77) <> "..."
  defp short(s), do: s
end
