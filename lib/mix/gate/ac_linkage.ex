defmodule Mix.Gate.AcLinkage do
  @moduledoc """
  Gate 5.1 — AC-to-test linkage (Mix shim).

  Thin shim over `Tau.Factory.Gate.AcLinkage`. Parses raw gating-test source
  strings into `TestMeta` maps (`%{name:, tags:}`) and delegates the decision
  logic to the pure module. No decision logic lives here.

  ## Meta-AC exemption

  An AC whose identifier is immediately followed by the marker `(meta)` (with
  optional surrounding `**` markdown bold) is a *meta-AC* — it is verified by
  CI wiring or inspection, not a unit gating test. Meta-ACs are exempt: they
  are never reported as missing.
  """

  alias Tau.Factory.Gate.AcLinkage, as: PureAcLinkage

  @doc """
  Returns `:ok` when every `AC-N` / `D-NNN` token in the `## Acceptance
  criteria` section of `pr_body` appears in at least one of
  `gating_test_sources`, or `{:error, missing}` listing those that do not.

  Token format: `AC-N` (one or more digits) and `D-NNN` (one or more digits).
  Matching is case-insensitive on the tag side (`:ac_1`, `:d_200`) and
  boundary-match on the test-name side (`"AC-1: ..."`, `"D-200: ..."`).
  """
  @spec ac_linkage(String.t(), [String.t()]) :: :ok | {:error, [String.t()]}
  def ac_linkage(pr_body, gating_test_sources)
      when is_binary(pr_body) and is_list(gating_test_sources) do
    gating_tests = Enum.flat_map(gating_test_sources, &parse_test_metas/1)

    case PureAcLinkage.check(pr_body, gating_tests) do
      {:pass, []} -> :ok
      {:fail, missing} -> {:error, missing}
    end
  end

  # ---------------------------------------------------------------------------
  # Source-string → TestMeta parser
  # ---------------------------------------------------------------------------

  # Parse a gating-test source string into a list of TestMeta maps.
  # Extracts test names (from `test "..."` and `property "..."` lines) and
  # @tag atoms (from `@tag :atom` and `@tag atom: value` lines).
  defp parse_test_metas(source) when is_binary(source) do
    lines = String.split(source, "\n")
    extract_test_metas(lines, [], [])
  end

  # Walk lines accumulating @tags, emitting a TestMeta when a test/property line is found.
  defp extract_test_metas([], _pending_tags, acc), do: acc

  defp extract_test_metas([line | rest], pending_tags, acc) do
    trimmed = String.trim(line)

    cond do
      # @tag :atom or @tag atom_name (bare atom)
      String.starts_with?(trimmed, "@tag :") ->
        tag_str = trimmed |> String.replace_prefix("@tag :", "") |> String.trim()
        tag = String.to_atom(tag_str)
        extract_test_metas(rest, [tag | pending_tags], acc)

      # @tag key: value — extract the key as a tag
      Regex.match?(~r/^@tag\s+[a-z_][a-z_0-9]*:/, trimmed) ->
        case Regex.run(~r/^@tag\s+([a-z_][a-z_0-9]*):/, trimmed) do
          [_, key] ->
            tag = String.to_atom(key)
            extract_test_metas(rest, [tag | pending_tags], acc)

          _ ->
            extract_test_metas(rest, pending_tags, acc)
        end

      # @moduletag :atom
      String.starts_with?(trimmed, "@moduletag :") ->
        tag_str = trimmed |> String.replace_prefix("@moduletag :", "") |> String.trim()
        tag = String.to_atom(tag_str)
        extract_test_metas(rest, [tag | pending_tags], acc)

      # test "name" or property "name"
      Regex.match?(~r/^(test|property)\s+"/, trimmed) ->
        case Regex.run(~r/^(?:test|property)\s+"([^"]*)"/, trimmed) do
          [_, name] ->
            meta = %{name: name, tags: pending_tags}
            # Reset pending tags after emitting a test (tags accumulate per test).
            extract_test_metas(rest, [], [meta | acc])

          _ ->
            extract_test_metas(rest, [], acc)
        end

      true ->
        extract_test_metas(rest, pending_tags, acc)
    end
  end
end
