defmodule Tau.Factory.Gate.AcLinkage do
  @moduledoc """
  Gate 5.1 — AC-to-test linkage (pure module, no I/O).

  Every `AC-N` / `D-NNN` token in the PR body's declared `## Acceptance
  criteria` section must appear in a gating-test name or `@tag`; meta-ACs
  (`AC-N (meta)`) are exempt.

  This module owns the *decision logic* only. I/O (reading PR-body files,
  reading gating-test source files) lives in the Mix task shim.

  ## Spec

  SPEC-FACTORY-GATE §2 C2 / §4 B2. Properties:
  - P-AC1 (soundness): `check/2 = {:pass, []}` iff every non-meta token in the
    acceptance section is covered.
  - P-AC2 (scope-tightness): tokens outside the acceptance section are ignored.
  - P-AC3 (meta-exemption): a `(meta)`-marked AC is never reported missing.
  - P-AC4 (monotone): adding a gating test never turns `:pass` into `:fail`.

  ## TestMeta shape

  Each element of `gating_tests` MUST be a map exposing:
  - `:name` — the test description string (e.g. `"AC-1: some test desc"`)
  - `:tags` — a list of atoms (e.g. `[:ac_1, :property]`)
  """

  @typedoc "An `AC-N` or `D-NNN` token string, e.g. `\"AC-1\"` or `\"D-200\"`."
  @type token :: String.t()

  @typedoc "Minimal test metadata map: `%{name: String.t(), tags: [atom()]}`."
  @type test_meta :: %{name: String.t(), tags: [atom()]}

  @doc """
  Check that every non-meta `AC-N`/`D-NNN` token in the `## Acceptance
  criteria` section of `pr_body` is covered by at least one element in
  `gating_tests`.

  A token is covered when either:
  - it appears as a substring in the test's `:name`, OR
  - its normalised tag form (e.g. `"AC-1"` → `:ac_1`) is in the test's `:tags`.

  Returns `{:pass, []}` when all tokens are covered, or
  `{:fail, missing_tokens}` listing every uncovered non-meta token.
  """
  @spec check(String.t(), [test_meta()]) :: {:pass, []} | {:fail, [token()]}
  def check(pr_body, gating_tests)
      when is_binary(pr_body) and is_list(gating_tests) do
    ac_section = extract_acceptance_criteria_section(pr_body)
    meta_acs = parse_meta_ac_tokens(ac_section)
    claimed = parse_ac_tokens(ac_section)
    non_meta = Enum.reject(claimed, &MapSet.member?(meta_acs, &1))
    missing = Enum.reject(non_meta, &token_covered_by_metas?(&1, gating_tests))

    case missing do
      [] -> {:pass, []}
      _ -> {:fail, missing}
    end
  end

  # ---------------------------------------------------------------------------
  # Section extraction
  # ---------------------------------------------------------------------------

  # Extract the content of the "## Acceptance criteria" section from the PR body.
  # Starts after the heading whose text (stripped, downcased) begins with
  # "acceptance criteria". Ends at the next markdown heading or EOF.
  # Returns "" if no such heading is found.
  defp extract_acceptance_criteria_section(pr_body) do
    lines = String.split(pr_body, "\n")
    heading_pattern = ~r/^[#]{1,6}\s/

    ac_heading_idx =
      Enum.find_index(lines, fn line ->
        stripped = line |> String.replace(~r/^#+\s*/, "") |> String.trim() |> String.downcase()

        String.starts_with?(stripped, "acceptance criteria") and
          String.match?(line, heading_pattern)
      end)

    case ac_heading_idx do
      nil ->
        ""

      idx ->
        lines
        |> Enum.drop(idx + 1)
        |> Enum.take_while(&(not String.match?(&1, heading_pattern)))
        |> Enum.join("\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Token parsing
  # ---------------------------------------------------------------------------

  # Parse AC-N tokens marked as meta (exempt from the linkage gate).
  defp parse_meta_ac_tokens(section_text) do
    meta_pattern = ~r/\bAC-(\d+)\s*\(meta\)/

    Regex.scan(meta_pattern, section_text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&"AC-#{&1}")
    |> MapSet.new()
  end

  # Parse all AC-N and D-NNN tokens from the given text.
  defp parse_ac_tokens(section_text) do
    ac_pattern = ~r/\bAC-\d+\b/
    d_pattern = ~r/\bD-\d+\b/

    ac_tokens = Regex.scan(ac_pattern, section_text) |> List.flatten()
    d_tokens = Regex.scan(d_pattern, section_text) |> List.flatten()

    (ac_tokens ++ d_tokens) |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # Coverage check against TestMeta list
  # ---------------------------------------------------------------------------

  # Check if a token is covered by any element in the gating-test metadata list.
  # Coverage:
  #   - token appears as a word-boundary match in the test name (not as a substring
  #     of a longer token, e.g. "AC-4" must not match inside "AC-40"), OR
  #   - its normalised tag form is in the test's :tags list.
  defp token_covered_by_metas?(token, gating_tests) do
    tag_atom = token |> String.downcase() |> String.replace("-", "_") |> String.to_atom()
    # Build a regex that matches the token only at a word boundary (not inside a longer token).
    token_regex = Regex.compile!("\\b#{Regex.escape(token)}\\b")

    Enum.any?(gating_tests, fn meta ->
      name = Map.get(meta, :name, "")
      tags = Map.get(meta, :tags, [])

      Regex.match?(token_regex, name) or tag_atom in tags
    end)
  end
end
