defmodule Tau.Factory.Gate.Masking do
  @moduledoc """
  Gate 5.2 — Masking detection (pure module, detection-only, no I/O).

  Scans a unified diff for:
  1. Deleted or weakened assertion lines (`-  assert`, `-  refute`, etc.)
  2. Any diff hunk whose file path is in the declared gating-test path set
     (path-based, independent of commit attribution — D-304/INV-6).

  Detection-only: returns `{:clean | :flagged, findings}` — **no verdict**.
  Every flagged item is surfaced to the critic as a mandatory review item.
  There is no self-authored bypass tag. The verdict is the critic's.

  ## Spec

  SPEC-FACTORY-GATE §2 C3 / §4 B2. Properties:
  - P-MK1 (assertion-deletion): any hunk deleting/weakening an assertion yields
    a Finding.
  - P-MK2 (path-violation): any diff hunk whose path ∈ gating_paths yields a
    Finding, independent of commit author metadata.
  - P-MK3 (detection-only): `scan/2` never returns `:pass`/`:fail`.
  - P-MK4 (rebase-invariance): diffs differing only by index hash yield the
    same scan result.

  ## Finding shape

  Each finding is a map:
  - `:path` — the file path from the diff `+++ b/` header.
  - `:reason` — `:assertion_deleted` or `:gating_path_edited`.
  - `:line` — original-file line number (assertion deletions) or 0 (path edits).
  - `:removed` — the removed content string (assertion deletions) or `nil`.
  """

  @assertion_keywords ~w[assert refute assert_receive assert_raise]

  @typedoc "A finding map produced by `scan/2`."
  @type finding :: %{
          path: String.t() | nil,
          reason: :assertion_deleted | :gating_path_edited,
          line: non_neg_integer(),
          removed: String.t() | nil
        }

  @doc """
  Scan `unified_diff` for masking violations.

  `gating_paths` is a `MapSet` of repo-relative file paths declared as
  gating-test paths for this PR (frozen at scope-freeze).

  Returns `{:clean, []}` when no violations are found, or
  `{:flagged, findings}` with one or more `Finding` maps.
  """
  @spec scan(String.t(), MapSet.t(String.t())) ::
          {:clean, []} | {:flagged, [finding()]}
  def scan(unified_diff, gating_paths)
      when is_binary(unified_diff) do
    lines = String.split(unified_diff, "\n")
    findings = parse_diff_lines(lines, nil, 0, gating_paths, [])

    case findings do
      [] -> {:clean, []}
      _ -> {:flagged, findings}
    end
  end

  # ---------------------------------------------------------------------------
  # Diff line state machine
  # ---------------------------------------------------------------------------

  defp parse_diff_lines([], _file, _orig_line, _gating_paths, acc),
    do: Enum.reverse(acc)

  defp parse_diff_lines([h | t], current_file, orig_line, gating_paths, acc) do
    cond do
      String.starts_with?(h, "+++ b/") ->
        file = String.slice(h, 6..-1//1)
        # Check: entering a new diff section for a gating-test path.
        # We flag the path-violation once per file section when the first
        # non-header diff line appears. Defer to the hunk processing below.
        parse_diff_lines(t, file, orig_line, gating_paths, acc)

      String.starts_with?(h, "@@") ->
        orig = parse_hunk_orig_line(h)
        # Emit a path-violation finding for the gating path when we enter a hunk.
        acc2 =
          if gating_path_modified?(current_file, gating_paths, acc) do
            [%{path: current_file, reason: :gating_path_edited, line: 0, removed: nil} | acc]
          else
            acc
          end

        parse_diff_lines(t, current_file, orig, gating_paths, acc2)

      String.starts_with?(h, "-") and not String.starts_with?(h, "---") ->
        content = String.slice(h, 1..-1//1)

        acc2 =
          if assertion_line?(content) do
            [
              %{
                path: current_file,
                reason: :assertion_deleted,
                line: orig_line,
                removed: content
              }
              | acc
            ]
          else
            acc
          end

        parse_diff_lines(t, current_file, orig_line + 1, gating_paths, acc2)

      String.starts_with?(h, "+") and not String.starts_with?(h, "+++") ->
        parse_diff_lines(t, current_file, orig_line, gating_paths, acc)

      true ->
        parse_diff_lines(t, current_file, orig_line + 1, gating_paths, acc)
    end
  end

  # Returns true iff current_file is in gating_paths AND no path-violation
  # finding for it has been emitted yet (to avoid duplicates per file).
  defp gating_path_modified?(nil, _gating_paths, _acc), do: false

  defp gating_path_modified?(file, gating_paths, acc) do
    MapSet.member?(gating_paths, file) and
      not Enum.any?(acc, fn f ->
        Map.get(f, :path) == file and Map.get(f, :reason) == :gating_path_edited
      end)
  end

  defp assertion_line?(content) do
    Enum.any?(@assertion_keywords, &String.contains?(content, &1))
  end

  defp parse_hunk_orig_line(hunk_header) do
    case Regex.run(~r/@@ -(\d+)/, hunk_header) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end
end
