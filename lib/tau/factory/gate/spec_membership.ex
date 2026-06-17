defmodule Tau.Factory.Gate.SpecMembership do
  @moduledoc """
  Gate half — spec-membership check (pure module, no I/O).

  Mechanises INV-23 (spec-before-code): a diff that touches a SPEC source-map
  boundary path without a `SPEC-*`/`D-NNN` token in the PR body receives a FAIL
  naming every untokenised boundary.

  D-322 — `SpecMembership.check/3 :: (diff, pr_body, source_maps) ->
    {:pass, []} | {:fail, [boundary]}`.

  ## Rules

  - P-SP1: the diff touches a path listed in `source_maps` AND `pr_body`
    contains neither a `D-NNN` token nor the boundary's spec name
    ⇒ `{:fail, [boundary, …]}` naming every failing boundary.
  - P-SP1b: the diff touches a SPEC'd boundary AND `pr_body` contains a
    `D-NNN` token OR the boundary's spec name ⇒ `{:pass, []}`.
  - P-SP2: the diff touches only paths NOT in any `source_maps` entry
    ⇒ `{:pass, []}` regardless of `pr_body`.
  - P-SP2b: `source_maps = []` ⇒ `{:pass, []}` unconditionally.

  ## Arguments

  - `diff` — a unified diff string (the PR diff).
  - `pr_body` — the PR body Markdown string.
  - `source_maps` — a list of `%{spec: spec_name, path: file_path}` maps, one
    entry per SPEC'd boundary file.  Multiple entries for the same spec are
    allowed.  An empty list ⇒ always pass.
  """

  @typedoc "A SPEC source-map entry: `%{spec: String.t(), path: String.t()}`."
  @type source_map_entry :: %{spec: String.t(), path: String.t()}

  @typedoc "A failed boundary: either a map or a human-readable string."
  @type boundary :: source_map_entry() | String.t()

  @doc """
  Check spec membership for `diff` against `source_maps`, using `pr_body` to
  locate any satisfying `SPEC-*`/`D-NNN` token.

  Returns `{:pass, []}` when every touched SPEC'd boundary is satisfied, or
  `{:fail, failed_boundaries}` listing every boundary the diff touched without
  a matching token in the PR body.
  """
  @spec check(String.t(), String.t(), [source_map_entry()]) ::
          {:pass, []} | {:fail, [boundary()]}
  def check(diff, pr_body, source_maps)
      when is_binary(diff) and is_binary(pr_body) and is_list(source_maps) do
    case source_maps do
      [] ->
        {:pass, []}

      _ ->
        touched_paths = extract_touched_paths(diff)
        d_nnn_present = has_d_nnn_token?(pr_body)

        failing =
          source_maps
          |> Enum.filter(fn %{path: path} -> MapSet.member?(touched_paths, path) end)
          |> Enum.reject(fn %{spec: spec_name} ->
            d_nnn_present or String.contains?(pr_body, spec_name)
          end)

        case failing do
          [] -> {:pass, []}
          _ -> {:fail, failing}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Extract the set of file paths touched by the unified diff.
  # Matches lines like:
  #   diff --git a/<path> b/<path>
  # and takes the b-side path (the post-change side).
  @spec extract_touched_paths(String.t()) :: MapSet.t(String.t())
  defp extract_touched_paths(diff) when is_binary(diff) do
    diff_header = ~r/^diff --git a\/.+ b\/(.+)$/m

    Regex.scan(diff_header, diff, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  # Returns true if the PR body contains at least one `D-NNN` token
  # (three or more digits after the dash).
  @spec has_d_nnn_token?(String.t()) :: boolean()
  defp has_d_nnn_token?(pr_body) do
    Regex.match?(~r/\bD-\d{3,}\b/, pr_body)
  end
end
