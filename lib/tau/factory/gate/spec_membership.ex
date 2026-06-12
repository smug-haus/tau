defmodule Tau.Factory.Gate.SpecMembership do
  @moduledoc """
  Gate C5 — Spec-membership check (pure, D-322).

  A diff hunk touching a SPEC source-map boundary path without a corresponding
  `SPEC-*` or `D-NNN` token in the PR body ⇒ FAIL, naming that boundary
  (mechanizes the mechanizable half of INV-23 / HR-6).

  A diff touching only non-SPEC'd paths ⇒ PASS regardless of body.

  ## Spec

  SPEC-FACTORY-GATE §2 C5 / §4 B2 / D-322.

  Properties:
  - P-SP1 (SPEC'd-boundary-without-reference ⇒ fail naming it): if the diff
    touches a path in `source_maps` and the PR body carries no `SPEC-*` or
    `D-NNN` token, `check/3` returns `{:fail, [boundary]}`.
  - P-SP2 (non-SPEC'd-only ⇒ pass): if no changed path appears in
    `source_maps`, `check/3` returns `{:pass, []}` regardless of the PR body.

  ## Source maps

  `source_maps` is a list of `%{boundary: String.t(), paths: [String.t()]}` maps.
  Each element names a SPEC boundary and the file paths it owns.

  When `source_maps` is empty or `nil`, `check/3` returns `{:pass, []}`.
  """

  @typedoc "A source-map entry: `%{boundary: String.t(), paths: [String.t()]}`."
  @type source_map_entry :: %{boundary: String.t(), paths: [String.t()]}

  @doc """
  Check that a diff touching a SPEC source-map boundary carries a reference to
  that SPEC or a D-NNN token in the PR body.

  Returns `{:pass, []}` when all SPEC'd boundaries that are touched by the diff
  are referenced in the PR body, or `{:fail, [boundary]}` listing every
  unreferenced SPEC'd boundary.
  """
  @spec check(String.t(), String.t(), [source_map_entry()] | nil) ::
          {:pass, []} | {:fail, [String.t()]}
  def check(diff, pr_body, source_maps)

  def check(_diff, _pr_body, nil), do: {:pass, []}
  def check(_diff, _pr_body, []), do: {:pass, []}

  def check(diff, pr_body, source_maps)
      when is_binary(diff) and is_binary(pr_body) and is_list(source_maps) do
    changed_paths = extract_changed_paths(diff)
    referenced_tokens = extract_spec_and_d_tokens(pr_body)

    missing_boundaries =
      source_maps
      |> Enum.filter(fn %{paths: paths} ->
        Enum.any?(paths, &(&1 in changed_paths))
      end)
      |> Enum.reject(fn %{boundary: boundary} ->
        Enum.any?(referenced_tokens, &String.contains?(boundary, &1))
      end)
      |> Enum.map(& &1.boundary)

    case missing_boundaries do
      [] -> {:pass, []}
      _ -> {:fail, missing_boundaries}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Extract changed file paths from a unified diff (the `+++ b/<path>` lines).
  defp extract_changed_paths(diff) do
    diff
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\+\+\+ b\/(.+)$/, line) do
        [_, path] -> [path]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  # Extract SPEC-* and D-NNN tokens from the PR body.
  defp extract_spec_and_d_tokens(pr_body) do
    spec_tokens = Regex.scan(~r/SPEC-[A-Z0-9_-]+/, pr_body) |> List.flatten()
    d_tokens = Regex.scan(~r/\bD-\d+\b/, pr_body) |> List.flatten()
    MapSet.new(spec_tokens ++ d_tokens)
  end
end
