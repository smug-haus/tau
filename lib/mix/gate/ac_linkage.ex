defmodule Mix.Gate.AcLinkage do
  @moduledoc """
  Gate 5.1 — AC-to-test linkage.

  Parses every `AC-N` / `D-NNN` token from the `## Acceptance criteria`
  section of the draft-PR body and returns the subset not found (as a test
  name substring or `@tag`) in any of the supplied gating-test source strings.
  Tokens cited only outside that section (e.g. in a Background section) are
  background prose and are NOT checked. If no `## Acceptance criteria` heading
  exists in the PR body, the claims region is empty and `:ok` is returned.

  ## Meta-AC exemption

  An AC whose identifier is immediately followed by the marker `(meta)` (with
  optional surrounding `**` markdown bold) is a *meta-AC* — it is verified by
  CI wiring or inspection, not a unit gating test. Meta-ACs are exempt: they
  are never reported as missing.
  """

  @doc """
  Returns `:ok` when every `AC-N` / `D-NNN` token in the `## Acceptance
  criteria` section of `pr_body` appears in at least one of
  `gating_test_sources`, or `{:error, missing}` listing those that do not.

  Token format: `AC-N` (one or more digits) and `D-NNN` (one or more digits).
  Matching is case-insensitive on the tag side (`:ac_1`, `:d_200`) and
  substring on the test-name side (`"AC-1: ..."`, `"D-200: ..."`).
  """
  @spec ac_linkage(String.t(), [String.t()]) :: :ok | {:error, [String.t()]}
  def ac_linkage(pr_body, gating_test_sources)
      when is_binary(pr_body) and is_list(gating_test_sources) do
    ac_section = extract_acceptance_criteria_section(pr_body)
    meta_acs = parse_meta_ac_tokens(ac_section)
    claimed = parse_ac_tokens(ac_section)
    non_meta = Enum.reject(claimed, &MapSet.member?(meta_acs, &1))
    missing = Enum.reject(non_meta, &token_covered?(&1, gating_test_sources))

    case missing do
      [] -> :ok
      _ -> {:error, missing}
    end
  end

  # Extract the content of the "## Acceptance criteria" section from the PR body.
  # Starts after the heading whose text (stripped of leading #, trimmed, downcased)
  # begins with "acceptance criteria". Ends at the next markdown heading or EOF.
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

  # Parse AC-N tokens marked as meta (exempt from the linkage gate).
  # An AC is meta if ANY occurrence in the section text is immediately followed
  # by "(meta)" (optionally with surrounding ** bold markers and optional
  # whitespace between the token and the marker).
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

  # Check if a token (e.g. "AC-1" or "D-200") is covered in any source.
  # Normalises to tag form: "AC-1" -> "ac_1", "D-200" -> "d_200".
  defp token_covered?(token, sources) do
    tag_form = token |> String.downcase() |> String.replace("-", "_")

    Enum.any?(sources, fn source ->
      String.contains?(source, ":#{tag_form}") or
        String.contains?(source, "\"#{token}") or
        String.contains?(source, "\"#{tag_form}")
    end)
  end
end
