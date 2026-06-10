defmodule Tau.Factory.Gate.MaskingPropertyTest do
  @moduledoc """
  Gating tests for AC-2 (D-305) and AC-3 (D-304) — `Tau.Factory.Gate.Masking.scan/2`.

  Written BEFORE production code exists (oracle-separation phase, D-304).
  These tests fail with a compile error / UndefinedFunctionError until the
  implementer creates `lib/tau/factory/gate/masking.ex`.

  Properties pin SPEC-FACTORY-GATE §4 B2 + gate-and-toolchain.md §2.2:
    P-MK1 assertion-deletion detection
    P-MK2 path-violation detection (path-based, independent of author)
    P-MK3 detection-only / no verdict
    P-MK4 rebase-invariance

  AC-2 (D-305): pure-predicate masking properties P-MK1..4.
  AC-3 (D-304): an edit to a declared gating-test path is flagged (path-based,
                not commit-attribution — D-305 closes #383).

  All property tests are tagged `:property` (OTP non-negotiable #6).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property
  @moduletag :ac_2
  @moduletag :ac_3
  @moduletag :d_305
  @moduletag :d_304

  alias Tau.Factory.Gate.Masking

  # ---------------------------------------------------------------------------
  # Helpers for constructing minimal unified diff fragments.
  # ---------------------------------------------------------------------------

  # A diff hunk that REMOVES an assert/refute line in the given file.
  defp diff_removing_assert(file_path, keyword \\ "assert") do
    """
    diff --git a/#{file_path} b/#{file_path}
    index aaaaaa..bbbbbb 100644
    --- a/#{file_path}
    +++ b/#{file_path}
    @@ -5,7 +5,6 @@ defmodule SomeTest do
       test "example" do
         result = SomeModule.run()
    -    #{keyword} result == :ok
         other = :noop
       end
     end
    """
  end

  # A diff hunk that modifies a file without removing any assertion.
  defp diff_modifying_without_assertion(file_path) do
    """
    diff --git a/#{file_path} b/#{file_path}
    index aaaaaa..bbbbbb 100644
    --- a/#{file_path}
    +++ b/#{file_path}
    @@ -1,3 +1,3 @@ defmodule SomeModule do
    -  def run, do: :old
    +  def run, do: :new
     end
    """
  end

  # A diff adding a line (no removal at all) in a given file.
  defp diff_adding_only(file_path) do
    """
    diff --git a/#{file_path} b/#{file_path}
    index aaaaaa..bbbbbb 100644
    --- a/#{file_path}
    +++ b/#{file_path}
    @@ -1,3 +1,4 @@ defmodule SomeModule do
       def run, do: :ok
    +  def extra, do: :new
     end
    """
  end

  defp file_path_gen do
    StreamData.bind(
      StreamData.string(:alphanumeric, min_length: 3, max_length: 10),
      fn name ->
        StreamData.constant("test/tau/#{name}_test.exs")
      end
    )
  end

  defp prod_file_path_gen do
    StreamData.bind(
      StreamData.string(:alphanumeric, min_length: 3, max_length: 10),
      fn name ->
        StreamData.constant("lib/tau/#{name}.ex")
      end
    )
  end

  # ---------------------------------------------------------------------------
  # P-MK1 — assertion-deletion detection.
  # Any hunk deleting/weakening an assertion yields a Finding.
  # ---------------------------------------------------------------------------

  property "P-MK1: AC-2 — a diff removing 'assert' yields a Finding" do
    check all(file_path <- file_path_gen()) do
      diff = diff_removing_assert(file_path, "assert")
      gating_paths = MapSet.new([])

      {status, findings} = Masking.scan(diff, gating_paths)

      assert status == :flagged
      assert length(findings) >= 1

      assert Enum.any?(findings, fn f ->
               Map.get(f, :path, Map.get(f, :file, "")) == file_path or
                 Map.get(f, :reason, Map.get(f, :kind, nil)) != nil
             end)
    end
  end

  property "P-MK1: AC-2 — a diff removing 'refute' yields a Finding" do
    check all(file_path <- file_path_gen()) do
      diff = diff_removing_assert(file_path, "refute")
      gating_paths = MapSet.new([])

      {status, findings} = Masking.scan(diff, gating_paths)

      assert status == :flagged
      assert length(findings) >= 1
    end
  end

  property "P-MK1: AC-2 — a diff that only adds lines yields no assertion-deletion Finding" do
    check all(
            file_path <- prod_file_path_gen(),
            gating_path <- file_path_gen(),
            file_path != gating_path
          ) do
      diff = diff_adding_only(file_path)
      gating_paths = MapSet.new([])

      {status, findings} = Masking.scan(diff, gating_paths)

      # No assertion deletions, no gating-path edit → must be clean.
      assert status == :clean
      assert findings == []
    end
  end

  # ---------------------------------------------------------------------------
  # P-MK2 — path-violation detection.
  # Any diff hunk whose path ∈ gating_paths yields a Finding, regardless of
  # whether an assertion is deleted. This is the AC-3 / D-304 property.
  # ---------------------------------------------------------------------------

  property "P-MK2: AC-3 / AC-2 — an edit to a declared gating-test path is flagged (path-based)" do
    check all(gating_path <- file_path_gen()) do
      # Modify the gating-test file without removing any assertion.
      diff = diff_modifying_without_assertion(gating_path)
      gating_paths = MapSet.new([gating_path])

      {status, findings} = Masking.scan(diff, gating_paths)

      assert status == :flagged,
             "Expected :flagged for edit to declared gating path #{gating_path}"

      assert length(findings) >= 1
    end
  end

  property "P-MK2: AC-3 — path-based detection is independent of commit author metadata" do
    # The same diff content, same path, but if gating_paths is empty (no declared
    # paths), the path-violation check must NOT fire (it's path-based, not heuristic).
    check all(gating_path <- file_path_gen()) do
      diff = diff_modifying_without_assertion(gating_path)

      # With the path in the declared set.
      {status_in, _} = Masking.scan(diff, MapSet.new([gating_path]))
      # With an EMPTY declared set.
      {status_out, findings_out} = Masking.scan(diff, MapSet.new([]))

      assert status_in == :flagged
      # When path is NOT in the declared set AND no assertion removed → clean.
      assert status_out == :clean
      assert findings_out == []
    end
  end

  property "P-MK2: AC-3 — a production-file edit with non-overlapping gating_paths is clean" do
    check all(
            prod_path <- prod_file_path_gen(),
            gating_path <- file_path_gen(),
            prod_path != gating_path
          ) do
      diff = diff_modifying_without_assertion(prod_path)
      # gating_path is declared but the diff touches prod_path.
      gating_paths = MapSet.new([gating_path])

      {status, findings} = Masking.scan(diff, gating_paths)

      assert status == :clean
      assert findings == []
    end
  end

  # ---------------------------------------------------------------------------
  # P-MK3 — detection-only / no verdict.
  # scan/2 NEVER returns :pass / :fail — only {:clean | :flagged, findings}.
  # ---------------------------------------------------------------------------

  property "P-MK3: AC-2 — scan/2 always returns {:clean | :flagged, list}, never a verdict atom" do
    check all(
            file_path <- file_path_gen(),
            remove_assert? <- StreamData.boolean(),
            in_gating_paths? <- StreamData.boolean()
          ) do
      diff =
        if remove_assert? do
          diff_removing_assert(file_path)
        else
          diff_adding_only(file_path)
        end

      gating_paths =
        if in_gating_paths? do
          MapSet.new([file_path])
        else
          MapSet.new([])
        end

      result = Masking.scan(diff, gating_paths)

      assert {status, findings} = result,
             "scan/2 must return a 2-tuple, got #{inspect(result)}"

      assert status in [:clean, :flagged],
             "status must be :clean or :flagged, not a verdict atom; got #{inspect(status)}"

      assert is_list(findings),
             "findings must be a list; got #{inspect(findings)}"

      # Verify it is NOT a verdict-shaped atom.
      refute status == :pass
      refute status == :fail
    end
  end

  # ---------------------------------------------------------------------------
  # P-MK4 — rebase-invariance.
  # Diffs d and d' that differ only by base commit (a rebase) but have identical
  # content hunks must yield the same scan result.
  # We model this by constructing two diffs with identical hunk content but
  # different "index" lines (simulating different base commits after a rebase).
  # ---------------------------------------------------------------------------

  property "P-MK4: AC-2 — scan/2 result is invariant to the diff's base-commit metadata" do
    check all(
            file_path <- file_path_gen(),
            remove_assert? <- StreamData.boolean(),
            gating? <- StreamData.boolean()
          ) do
      hunk =
        if remove_assert? do
          diff_removing_assert(file_path)
        else
          diff_adding_only(file_path)
        end

      # Rebase changes the index hash in the diff header — substitute with a
      # different fake hash to model a rebased diff. The hunk content is identical.
      diff_after_rebase =
        String.replace(hunk, ~r/index [0-9a-f]+\.\.[0-9a-f]+/, "index deadbee..cafebab")

      gating_paths =
        if gating? do
          MapSet.new([file_path])
        else
          MapSet.new([])
        end

      result_original = Masking.scan(hunk, gating_paths)
      result_rebased = Masking.scan(diff_after_rebase, gating_paths)

      # Both must have the same status.
      assert elem(result_original, 0) == elem(result_rebased, 0),
             "P-MK4 violated: scan status changed after rebase metadata change"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-3 example test — the concrete user-facing scenario: an implementer who
  # edits a declared gating-test path is caught by path-based scan (D-304/D-305).
  # ---------------------------------------------------------------------------

  @tag :ac_3
  @tag :d_304
  test "AC-3: implementer edit to a declared gating-test path is flagged (path-based, not commit attribution)" do
    gating_path = "test/tau/factory/gate/masking_property_test.exs"

    # The implementer modified the gating test file — no assertion deleted,
    # just a comment change. Path-based detection must still flag it.
    diff = """
    diff --git a/#{gating_path} b/#{gating_path}
    index aaaaaa..bbbbbb 100644
    --- a/#{gating_path}
    +++ b/#{gating_path}
    @@ -1,4 +1,4 @@ defmodule Tau.Factory.Gate.MaskingPropertyTest do
    -  # original comment
    +  # changed comment (implementer edit)
       use ExUnit.Case
    """

    gating_paths = MapSet.new([gating_path])

    {status, findings} = Masking.scan(diff, gating_paths)

    assert status == :flagged,
           "Expected :flagged when an edit touches a declared gating-test path"

    assert length(findings) >= 1
  end
end
