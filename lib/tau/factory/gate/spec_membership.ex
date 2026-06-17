defmodule Tau.Factory.Gate.SpecMembership do
  @moduledoc """
  Gate C5 — Spec-before-code mechanized (D-322 / INV-23 / HR-6).

  A diff hunk touching a SPEC source-map boundary with no `SPEC-*` / `D-NNN`
  token in the PR body ⇒ FAIL naming that boundary.

  A diff touching only non-SPEC'd paths ⇒ PASS regardless of body.

  This module is **pure** (no I/O). I/O (loading the diff, reading the PR
  body, loading source-maps from `docs/spec/`) lives in the gate-half caller
  inside `Tau.Factory.Gate`.

  ## Contract (SPEC-FACTORY-GATE §4 B2)

  `check/3 :: (diff, pr_body, source_maps) -> {:pass, []} | {:fail, [boundary]}`

  Where `source_maps` is a list of `{boundary_path, spec_ref}` pairs from the
  Appendix B of each `docs/spec/SPEC-*.md` (the catalog in `spec-before-code.md`).

  ## Properties (P-SP1, P-SP2)

  - P-SP1 (SPEC'd-boundary-without-reference ⇒ FAIL): when the diff touches a
    path that matches a source-map boundary and the PR body contains no
    `SPEC-*`/`D-NNN` token, `check/3` returns `{:fail, [boundary]}`.
  - P-SP2 (non-SPEC'd-only ⇒ PASS): when every path touched by the diff is
    absent from all source-map boundaries, `check/3` returns `{:pass, []}`.
  """

  @typedoc "A source-map entry: `{boundary_path :: String.t(), spec_ref :: String.t()}`."
  @type source_map_entry :: {String.t(), String.t()}

  @doc """
  Check that every SPEC'd boundary touched by `diff` is referenced in `pr_body`.

  Returns `{:pass, []}` when all touched SPEC'd boundaries are covered, or
  `{:fail, [boundary]}` listing every uncovered boundary path.

  A boundary is "covered" when `pr_body` contains at least one `SPEC-*` token
  (e.g. `"SPEC-FACTORY-GATE"`) or at least one `D-NNN` token (e.g. `"D-322"`).
  """
  @spec check(String.t(), String.t(), [source_map_entry()]) ::
          {:pass, []} | {:fail, [String.t()]}
  def check(diff, pr_body, source_maps)
      when is_binary(diff) and is_binary(pr_body) and is_list(source_maps) do
    touched_paths = extract_touched_paths(diff)

    violated_boundaries =
      source_maps
      |> Enum.filter(fn {boundary_path, _spec_ref} ->
        path_touched?(boundary_path, touched_paths) and
          not pr_body_references_spec_or_dnnn?(pr_body)
      end)
      |> Enum.map(fn {boundary_path, _spec_ref} -> boundary_path end)
      |> Enum.uniq()

    case violated_boundaries do
      [] -> {:pass, []}
      _ -> {:fail, violated_boundaries}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Extract the set of paths touched by the unified diff.
  # Parses `--- a/path` and `+++ b/path` lines (skipping /dev/null).
  defp extract_touched_paths(diff) do
    diff
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      cond do
        String.starts_with?(line, "--- a/") ->
          path = String.slice(line, 6, byte_size(line))
          if String.trim(path) == "/dev/null", do: [], else: [String.trim(path)]

        String.starts_with?(line, "+++ b/") ->
          path = String.slice(line, 6, byte_size(line))
          if String.trim(path) == "/dev/null", do: [], else: [String.trim(path)]

        true ->
          []
      end
    end)
    |> MapSet.new()
  end

  # Returns true when `boundary_path` matches any path in `touched_paths`.
  # Matching is exact or prefix (a boundary_path directory prefix matches any
  # touched path under it).
  defp path_touched?(boundary_path, touched_paths) do
    Enum.any?(touched_paths, fn touched ->
      touched == boundary_path or String.starts_with?(touched, boundary_path <> "/")
    end)
  end

  # Returns true when `pr_body` contains at least one `SPEC-*` or `D-NNN` token.
  defp pr_body_references_spec_or_dnnn?(pr_body) do
    String.match?(pr_body, ~r/\bSPEC-[A-Z]/) or
      String.match?(pr_body, ~r/\bD-\d+\b/)
  end
end
