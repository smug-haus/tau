defmodule Tau.TUI.Fuzzy do
  @moduledoc """
  Pure subsequence fuzzy-matcher for TUI completion menus.

  Candidate-source-agnostic: entries need only a `:name` key. The same
  function is used for slash-command autocomplete (#333) and `@`-mention
  autocomplete (#344 — future).

  ## Scoring

  Scores a `query` against `entry.name` by subsequence matching with two
  boosts:

  - **Prefix boost**: +100 if `name` starts with `query` (case-insensitive).
  - **Contiguity boost**: +1 per consecutive matched character run (characters
    that are adjacent in both query and name score higher than scattered ones).

  An empty query returns all entries with score 0 in input order (D-109).
  A query with no subsequence match returns score -1 for that entry, and
  those entries are omitted from the result.

  ## Invariants (SPEC-TUI-COMPLETION D-109)

  - `match("", entries)` returns all entries in input order with score 0.
  - `match(q, [])` returns `[]`.
  - A strict prefix always scores ≥ a non-prefix subsequence (prefix boost).
  - Scores are integers; sorted descending.
  """

  @doc """
  Match `query` against `entries` by subsequence.

  Returns `[{score, entry}]` sorted by descending score (highest first),
  omitting entries that have no subsequence match. An empty `query` returns
  all entries with score 0 in input order.

  `entries` may be any map or struct with a `:name` key.
  """
  @spec match(String.t(), [map()]) :: [{integer(), map()}]
  def match("", entries) when is_list(entries) do
    Enum.map(entries, fn e -> {0, e} end)
  end

  def match(query, entries) when is_binary(query) and is_list(entries) do
    q = String.downcase(query)

    entries
    |> Enum.map(fn entry ->
      name = String.downcase(Map.get(entry, :name, ""))
      score = score(q, name)
      {score, entry}
    end)
    |> Enum.reject(fn {s, _} -> s < 0 end)
    |> Enum.sort_by(fn {s, _} -> -s end)
  end

  # Score `query` chars as a subsequence within `name`.
  # Returns -1 if not a subsequence.
  # Returns prefix_boost + contiguity_bonus otherwise.
  #
  # `name` typically includes a leading "/" (e.g. "/compact"); `query` is the
  # bare text the user typed after the "/" (e.g. "cmp"). The prefix boost fires
  # when the name's bare part (stripped of leading "/") starts with the query.
  defp score(query, name) do
    # Strip leading "/" from name for prefix comparison.
    bare_name = if String.starts_with?(name, "/"), do: String.slice(name, 1..-1//1), else: name

    case subsequence_positions(String.graphemes(query), String.graphemes(name), 0, []) do
      nil ->
        -1

      positions ->
        prefix_boost = if String.starts_with?(bare_name, query), do: 100, else: 0
        contiguity = contiguity_bonus(positions)
        prefix_boost + contiguity
    end
  end

  # Greedy subsequence match; returns list of matched positions in `name`, or nil.
  defp subsequence_positions([], _name_chars, _pos, acc), do: Enum.reverse(acc)

  defp subsequence_positions(_query_chars, [], _pos, _acc), do: nil

  defp subsequence_positions([qc | qrest], [nc | nrest], pos, acc) do
    if qc == nc do
      subsequence_positions(qrest, nrest, pos + 1, [pos | acc])
    else
      subsequence_positions([qc | qrest], nrest, pos + 1, acc)
    end
  end

  # Count the number of adjacent pairs in the position list.
  defp contiguity_bonus([]), do: 0
  defp contiguity_bonus([_]), do: 0

  defp contiguity_bonus([a, b | rest]) do
    bonus = if b == a + 1, do: 1, else: 0
    bonus + contiguity_bonus([b | rest])
  end
end
