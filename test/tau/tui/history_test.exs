defmodule Tau.TUI.HistoryTest do
  @moduledoc """
  Property and unit tests for `Tau.TUI.History` and `Tau.TUI.History.Store`.

  Properties first (OTP non-negotiable #6) — invariant-bearing module.

  D-143: history capped at 100 entries, consecutive duplicates suppressed.
  D-146: per-cwd path derivation (sha256 hex).
  D-147: Ctrl+R search mode.
  D-140: Store.load/2 uses injected data_dir, not global.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.TUI.History
  alias Tau.TUI.History.Store

  # --- Properties (OTP non-negotiable #6) ------------------------------------

  describe "property: history cap (D-143)" do
    property "push/2 never exceeds 100 entries" do
      check all(
              texts <-
                list_of(string(:printable, min_length: 1, max_length: 20),
                  min_length: 1,
                  max_length: 150
                )
            ) do
        hist = Enum.reduce(texts, History.new(), fn t, acc -> History.push(acc, t) end)
        assert length(hist.entries) <= 100
      end
    end

    property "push/2 suppresses consecutive duplicates" do
      check all(text <- string(:printable, min_length: 1, max_length: 20)) do
        hist =
          History.new()
          |> History.push(text)
          |> History.push(text)
          |> History.push(text)

        # Only one copy in entries (no adjacent dups)
        assert length(hist.entries) == 1
        assert hd(hist.entries) == text
      end
    end

    property "no adjacent duplicate entries after any sequence of pushes" do
      check all(
              texts <-
                list_of(string(:printable, min_length: 1, max_length: 10),
                  min_length: 2,
                  max_length: 30
                )
            ) do
        hist = Enum.reduce(texts, History.new(), fn t, acc -> History.push(acc, t) end)
        # Verify no two adjacent entries are identical
        pairs = Enum.zip(hist.entries, tl(hist.entries))
        assert Enum.all?(pairs, fn {a, b} -> a != b end)
      end
    end
  end

  describe "property: prev/next roundtrip" do
    property "navigating prev then next n times restores position" do
      check all(
              entries <-
                list_of(string(:printable, min_length: 1, max_length: 10),
                  min_length: 1,
                  max_length: 10
                ),
              n <- integer(1..5)
            ) do
        hist = Enum.reduce(entries, History.new(), fn t, acc -> History.push(acc, t) end)

        if length(hist.entries) >= n do
          # Navigate back n steps
          {hist_back, _} =
            Enum.reduce(1..n, {hist, ""}, fn _, {h, _} ->
              History.prev(h, "")
            end)

          # Navigate forward n steps
          {hist_fwd, _} =
            Enum.reduce(1..n, {hist_back, ""}, fn _, {h, _} ->
              History.next(h)
            end)

          # Should be back to nil cursor (present)
          assert hist_fwd.cursor == nil
        end
      end
    end
  end

  # --- Unit tests (examples) --------------------------------------------------

  describe "History.new/0" do
    test "starts empty" do
      h = History.new()
      assert h.entries == []
      assert h.cursor == nil
      assert h.draft == ""
    end
  end

  describe "History.push/2 (D-143)" do
    test "push adds entry (most recent first)" do
      h = History.new() |> History.push("first") |> History.push("second")
      assert h.entries == ["second", "first"]
    end

    test "push ignores empty string" do
      h = History.new() |> History.push("") |> History.push("hello")
      assert h.entries == ["hello"]
    end

    test "push resets cursor to nil" do
      h = History.new() |> History.push("first")
      {h2, _} = History.prev(h, "")
      h3 = History.push(h2, "new")
      assert h3.cursor == nil
    end

    test "push caps at 100 entries" do
      h = Enum.reduce(1..105, History.new(), fn i, acc -> History.push(acc, "entry#{i}") end)
      assert length(h.entries) == 100
      # Most recent 100 entries are kept (entry6..entry105)
      assert hd(h.entries) == "entry105"
    end

    test "consecutive duplicate suppressed" do
      h = History.new() |> History.push("foo") |> History.push("foo")
      assert h.entries == ["foo"]
    end

    test "non-consecutive duplicates are NOT suppressed" do
      h = History.new() |> History.push("foo") |> History.push("bar") |> History.push("foo")
      assert h.entries == ["foo", "bar", "foo"]
    end
  end

  describe "History.prev/2 and History.next/1 (AC-7)" do
    setup do
      h =
        History.new()
        |> History.push("first prompt")
        |> History.push("second prompt")

      {:ok, history: h}
    end

    test "prev returns most recent entry first", %{history: h} do
      {_h2, entry} = History.prev(h, "")
      assert entry == "second prompt"
    end

    test "prev twice returns older entry", %{history: h} do
      {h2, _} = History.prev(h, "")
      {_h3, entry} = History.prev(h2, "")
      assert entry == "first prompt"
    end

    test "prev at oldest returns nil", %{history: h} do
      {h2, _} = History.prev(h, "")
      {h3, _} = History.prev(h2, "")
      {_h4, entry} = History.prev(h3, "")
      assert entry == nil
    end

    test "next after prev returns newer entry", %{history: h} do
      {h2, _} = History.prev(h, "")
      {h3, _} = History.prev(h2, "")
      {_h4, entry} = History.next(h3)
      assert entry == "second prompt"
    end

    test "next at present returns nil", %{history: h} do
      {_h2, entry} = History.next(h)
      assert entry == nil
    end

    test "next at cursor=0 restores draft", %{history: h} do
      {h2, _} = History.prev(h, "in progress")
      {_h3, entry} = History.next(h2)
      assert entry == "in progress"
    end

    test "prev saves in-progress draft on first navigation", %{history: h} do
      draft = "my draft text"
      {h2, _} = History.prev(h, draft)
      assert h2.draft == draft
    end
  end

  describe "History.search/2 (AC-9 — D-147)" do
    setup do
      h =
        History.new()
        |> History.push("first prompt")
        |> History.push("second prompt")
        |> History.push("unrelated")

      {:ok, history: h}
    end

    test "returns most recent matching entry" do
      h =
        History.new()
        |> History.push("first prompt")
        |> History.push("second prompt")

      assert {:match, "second prompt"} = History.search(h, "prompt")
    end

    test "case-insensitive match" do
      h = History.new() |> History.push("Hello World")
      assert {:match, "Hello World"} = History.search(h, "hello")
    end

    test "no_match when query absent" do
      h = History.new() |> History.push("foo")
      assert :no_match = History.search(h, "bar")
    end

    test "empty query returns no_match" do
      h = History.new() |> History.push("anything")
      assert :no_match = History.search(h, "")
    end
  end

  # --- Store unit tests (D-140, D-146) ----------------------------------------

  describe "History.Store" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "tau-history-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "history_path uses sha256 of cwd (D-146)", %{tmp_dir: tmp_dir} do
      cwd = "/some/project/path"
      path = Store.history_path(tmp_dir, cwd)
      expected_hex = :crypto.hash(:sha256, cwd) |> Base.encode16(case: :lower)
      assert Path.basename(path) == expected_hex <> ".jsonl"
      assert String.starts_with?(path, Path.join(tmp_dir, "history"))
    end

    test "load/2 returns empty history when file does not exist", %{tmp_dir: tmp_dir} do
      h = Store.load(tmp_dir, "/nonexistent/cwd")
      assert h.entries == []
    end

    test "append/3 creates the file and load/2 reads it back (D-140)", %{tmp_dir: tmp_dir} do
      cwd = "/test/project"
      :ok = Store.append(tmp_dir, cwd, "first entry")
      :ok = Store.append(tmp_dir, cwd, "second entry")
      h = Store.load(tmp_dir, cwd)
      # Most recent first (load reverses and takes cap)
      assert "second entry" in h.entries
      assert "first entry" in h.entries
      assert hd(h.entries) == "second entry"
    end

    test "load/2 does NOT touch ~/.tau (D-140)", %{tmp_dir: tmp_dir} do
      home_tau = Path.join(System.user_home!(), ".tau")
      cwd = "/isolated/cwd"
      Store.append(tmp_dir, cwd, "isolated entry")
      # The file should not be in the real ~/.tau
      home_path = Store.history_path(home_tau, cwd)
      refute File.exists?(home_path), "Store must write to tmp_dir, not ~/.tau (D-140)"
    end

    test "append/3 ignores empty string", %{tmp_dir: tmp_dir} do
      cwd = "/empty/test"
      :ok = Store.append(tmp_dir, cwd, "")
      h = Store.load(tmp_dir, cwd)
      assert h.entries == []
    end

    test "load/2 tail-truncates to 100 entries (D-143)", %{tmp_dir: tmp_dir} do
      cwd = "/cap/test"
      # Append 105 entries
      for i <- 1..105 do
        Store.append(tmp_dir, cwd, "entry#{i}")
      end

      h = Store.load(tmp_dir, cwd)
      assert length(h.entries) == 100
      # Most recent 100 are kept (entry6..entry105, reversed)
      assert hd(h.entries) == "entry105"
    end

    test "different cwds get different paths (D-146)", %{tmp_dir: tmp_dir} do
      path1 = Store.history_path(tmp_dir, "/path/one")
      path2 = Store.history_path(tmp_dir, "/path/two")
      refute path1 == path2
    end
  end
end
