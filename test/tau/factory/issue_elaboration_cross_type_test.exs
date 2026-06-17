defmodule Tau.Factory.IssueElaborationCrossTypeTest do
  @moduledoc """
  Gating test for D-369 cross-type file-collision conformance (issue #640).

  ## What this test enforces

  **D-369 — Over-declaration in the cross-type case.** The elaboration contract
  states: "over-declaration is always preferred over under-declaration: uncertain
  file membership → include." This test exercises the specific cross-type scenario
  where one issue cites `lib/foo.ex:42` (file:line — currently placed only in
  `:codepoints`) and a second issue cites the same `lib/foo.ex` without a line
  (placed in `:files`).

  Under the over-declaration principle, a file cited with a line number is NOT
  excluded from `:files` — the codepoint is a narrower signal, but the file
  membership is still declared, so it must be included in `:files` as well.

  ### The bug (pre-impl state)

  `elaborate_issue/1` (line 183 of `issue_selector.ex`) computes:

      whole_files = MapSet.difference(all_files, codepointed_files)

  This explicitly removes a file from `:files` when it appears with a line
  number, placing it only in `:codepoints`. `ConflictCheck.clear?/2` then checks
  `:files` and `:codepoints` as independent MapSet disjointness tests with no
  cross-field check between a codepoint's file path and the peer scope's `:files`
  set. Both issues pass the check (`:clear`) despite both touching the same file.

  ### The conformant behaviour

  When an issue cites `lib/foo.ex:42`, the conformant elaborator MUST include
  `lib/foo.ex` in `:files` (over-declaration) AND produce a codepoint entry
  `{"lib/foo.ex", :line_42}` in `:codepoints`. This guarantees that the
  `ConflictCheck.disjoint_files` clause catches the collision with any other
  scope that also declares `lib/foo.ex` in its `:files`.

  This test exercises the REAL `IssueSelector.select/1` and `ConflictCheck` API --
  no hand-built scope bypasses the real entry point.
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.ConflictCheck
  alias Tau.Factory.IssueSelector
  alias Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique_name(:cross_type_ledger)

    start_supervised!(
      {Writer, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  defp gh_stub(issues) do
    fn _milestone -> {:ok, issues} end
  end

  defp issue(number, title, opts \\ []) do
    %{
      "number" => number,
      "title" => title,
      "body" => Keyword.get(opts, :body, ""),
      "labels" => Keyword.get(opts, :labels, [])
    }
  end

  # ---------------------------------------------------------------------------
  # D-369(d): cross-type file collision -- one issue cites file:line, the other
  # cites the same file without a line. Both touch the same file; must conflict.
  #
  # SPEC D-369: "over-declaration is always preferred over under-declaration:
  # uncertain file membership -> include." A codepoint citation (`file:line`)
  # does NOT constitute permission to exclude the file from `:files`. The file
  # is still declared; its membership is certain -- include it in both `:files`
  # AND `:codepoints`.
  #
  # PRE-IMPL FAILURE: `elaborate_issue/1` removes the file from `:files` when
  # it appears with a line number (the `MapSet.difference` on line 183 of
  # `issue_selector.ex`). `ConflictCheck.clear?/2` then returns `:clear` for
  # the cross-type pair (it only checks `:files` and `:codepoints` independently,
  # not the cross-field overlap). The `assert MapSet.member?(scope_a.files, ...)`
  # assertion fails immediately, confirming the bug.
  # ---------------------------------------------------------------------------
  @tag :d_369
  test "D-369(d): issue citing file:line and issue citing the same file (no line) must conflict via ConflictCheck" do
    ledger_a = start_ledger()
    ledger_b = start_ledger()

    shared_file = "lib/tau/factory/issue_selector.ex"

    # Issue A: cites the shared file WITH a line number.
    # Under the current (buggy) elaborator this produces:
    #   scope_a = %{files: #{}, codepoints: #{{"lib/tau/factory/issue_selector.ex", :line_42}}}
    # Under the conformant elaborator it must produce:
    #   scope_a = %{files: #{"lib/tau/factory/issue_selector.ex"},
    #               codepoints: #{{"lib/tau/factory/issue_selector.ex", :line_42}}}
    body_a = "Modifies #{shared_file}:42 to fix the selector logic."

    # Issue B: cites the same file WITHOUT a line number.
    # Produces: scope_b = %{files: #{"lib/tau/factory/issue_selector.ex"}, codepoints: #{}}
    body_b = "Also touches #{shared_file} for a related reason."

    issue_a = issue(500, "Issue A -- file:line citation", body: body_a)
    issue_b = issue(501, "Issue B -- whole-file citation", body: body_b)

    {_raw_a, scope_a, _hash_a, _branch_a} =
      IssueSelector.select(
        ledger: ledger_a,
        milestone: "M10",
        gh_fun: gh_stub([issue_a])
      )

    {_raw_b, scope_b, _hash_b, _branch_b} =
      IssueSelector.select(
        ledger: ledger_b,
        milestone: "M10",
        gh_fun: gh_stub([issue_b])
      )

    assert is_map(scope_a),
           "D-369(d): scope_a must be a ConflictCheck.scope() map; got: #{inspect(scope_a)}"

    assert is_map(scope_b),
           "D-369(d): scope_b must be a ConflictCheck.scope() map; got: #{inspect(scope_b)}"

    # Over-declaration: the shared file MUST appear in scope_a.files even though
    # it was cited with a line number. A codepoint citation means "we know line 42
    # is touched -- but the whole file is touched too, so declare it." Under-declaring
    # by removing it from :files violates D-369 "uncertain file membership -> include."
    assert MapSet.member?(scope_a.files, shared_file),
           "D-369(d): over-declaration requires '#{shared_file}' to appear in scope_a.files " <>
             "even though it was cited with a line number. A file:line citation must add " <>
             "the file to BOTH :files and :codepoints (over-declaration). " <>
             "Got scope_a.files=#{inspect(scope_a.files)}, scope_a.codepoints=#{inspect(scope_a.codepoints)}"

    # Sanity check: scope_a must also retain the codepoint entry.
    codepoint_paths_a = scope_a.codepoints |> MapSet.to_list() |> Enum.map(&elem(&1, 0))

    assert shared_file in codepoint_paths_a,
           "D-369(d): file:line citation must also produce a codepoint entry for '#{shared_file}'; " <>
             "scope_a.codepoints=#{inspect(scope_a.codepoints)}"

    # scope_b: whole-file cite -> must be in :files (no codepoints expected).
    assert MapSet.member?(scope_b.files, shared_file),
           "D-369(d): whole-file citation must appear in scope_b.files; " <>
             "got: #{inspect(scope_b.files)}"

    # Soundness witness (the V3 conflict check): since both scopes declare the
    # shared file in :files, ConflictCheck.clear?/2 MUST return {:conflict, _}.
    # This is the same admission path Scheduler.admit/3 uses.
    in_flight = %{"unit-500" => scope_a}
    result = ConflictCheck.clear?(scope_b, in_flight)

    assert result != :clear,
           "D-369(d): an issue citing '#{shared_file}:42' and another citing '#{shared_file}' " <>
             "(no line) must conflict -- both touch the same file. " <>
             "ConflictCheck.clear?/2 returned :clear (cross-type over-declaration bug present); " <>
             "scope_a=#{inspect(scope_a)}, scope_b=#{inspect(scope_b)}"

    assert match?({:conflict, _}, result),
           "D-369(d): expected {:conflict, _} for cross-type file collision; " <>
             "got: #{inspect(result)}"
  end
end
