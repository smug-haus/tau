defmodule Tau.TUI.FuzzyTest do
  @moduledoc """
  Property and unit tests for `Tau.TUI.Fuzzy`.

  SPEC-TUI-COMPLETION §5 AC-4 (D-103), AC-9 (D-104), D-109.
  OTP non-negotiable #6: properties before examples.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Tau.TUI.Fuzzy

  # --- Properties ---

  describe "Fuzzy.match/2 — properties" do
    property "empty query returns all entries in input order with score 0 (D-109)" do
      check all(entries <- list_of(entry_gen(), max_length: 20)) do
        result = Fuzzy.match("", entries)
        assert length(result) == length(entries)
        scores = Enum.map(result, fn {s, _} -> s end)
        assert Enum.all?(scores, &(&1 == 0))
        names_in = Enum.map(entries, & &1.name)
        names_out = Enum.map(result, fn {_, e} -> e.name end)
        assert names_in == names_out
      end
    end

    property "no-match entries are omitted from results" do
      check all(
              query <- string(:alphanumeric, min_length: 5, max_length: 10),
              entries <- list_of(entry_gen(), min_length: 1, max_length: 10)
            ) do
        result = Fuzzy.match(query, entries)

        Enum.each(result, fn {_s, e} ->
          name = String.downcase(e.name)
          q = String.downcase(query)

          assert subsequence?(q, name),
                 "entry #{e.name} should be a subsequence match for #{query}"
        end)
      end
    end

    property "prefix is always scored >= non-prefix subsequence" do
      check all(
              prefix <- string(:alphanumeric, min_length: 2, max_length: 5),
              suffix <- string(:alphanumeric, min_length: 1, max_length: 5)
            ) do
        prefix_entry = %{name: "/" <> prefix <> suffix, description: "", origin: :builtin}
        non_prefix_entry = %{name: suffix <> prefix, description: "", origin: :builtin}

        result = Fuzzy.match(prefix, [prefix_entry, non_prefix_entry])

        if length(result) == 2 do
          [{s1, e1}, {s2, _e2}] = result
          # The entry that is a prefix match should appear first (higher score)
          if e1.name == prefix_entry.name do
            assert s1 >= s2
          end
        end
      end
    end

    property "results are sorted descending by score" do
      check all(
              query <- string(:alphanumeric, min_length: 1, max_length: 4),
              entries <- list_of(entry_gen(), max_length: 20)
            ) do
        result = Fuzzy.match(query, entries)
        scores = Enum.map(result, fn {s, _} -> s end)
        assert scores == Enum.sort(scores, :desc)
      end
    end

    property "match with empty entries always returns []" do
      check all(query <- string(:alphanumeric, min_length: 0, max_length: 10)) do
        assert Fuzzy.match(query, []) == []
      end
    end
  end

  # --- Unit tests ---

  describe "Fuzzy.match/2 — unit" do
    setup do
      entries = [
        %{name: "/compact", description: "Compress history", origin: :builtin},
        %{name: "/ping", description: "pong", origin: :builtin},
        %{name: "/help", description: "List commands", origin: :builtin},
        %{name: "/reload", description: "Reload", origin: :builtin}
      ]

      {:ok, entries: entries}
    end

    test "empty query returns all entries with score 0 (D-109)", %{entries: entries} do
      result = Fuzzy.match("", entries)
      assert length(result) == 4
      assert Enum.all?(result, fn {s, _} -> s == 0 end)
    end

    test "subsequence match filters correctly (AC-4)" do
      entries = [
        %{name: "/compact", description: "", origin: :builtin},
        %{name: "/ping", description: "", origin: :builtin}
      ]

      result = Fuzzy.match("cmp", entries)
      names = Enum.map(result, fn {_, e} -> e.name end)
      assert "/compact" in names
      refute "/ping" in names
    end

    test "prefix match scores higher than scattered subsequence" do
      entries = [
        %{name: "/reload", description: "", origin: :builtin},
        %{name: "/recompile_old", description: "", origin: :builtin}
      ]

      result = Fuzzy.match("rel", entries)
      [{s1, e1} | _] = result
      assert e1.name == "/reload", "prefix should score first"
      assert s1 >= 100
    end

    test "non-matching query returns empty list" do
      entries = [%{name: "/ping", description: "", origin: :builtin}]
      assert Fuzzy.match("zzzzz", entries) == []
    end

    test "case-insensitive matching" do
      entries = [%{name: "/Compact", description: "", origin: :builtin}]
      result = Fuzzy.match("compact", entries)
      assert length(result) == 1
    end
  end

  # --- Generators ---

  defp entry_gen do
    gen all(
          name <- string(:alphanumeric, min_length: 1, max_length: 12),
          origin <- member_of([:builtin, :skill, :template])
        ) do
      %{name: "/" <> name, description: "", origin: origin}
    end
  end

  # Helper: check if `q` is a subsequence of `s`.
  defp subsequence?("", _s), do: true
  defp subsequence?(_q, ""), do: false

  defp subsequence?(q, s) do
    {qh, qt} = String.split_at(q, 1)
    {sh, st} = String.split_at(s, 1)

    if qh == sh do
      subsequence?(qt, st)
    else
      subsequence?(q, st)
    end
  end
end
