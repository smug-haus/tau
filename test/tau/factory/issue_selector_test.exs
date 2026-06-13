defmodule Tau.Factory.IssueSelectorTest do
  @moduledoc """
  Gating test for `Tau.Factory.IssueSelector` — the real `select_fun` (B10).

  P5c-4 / #469. Advances #458 (P5c) / #416 (M10).

  ## What the selector is (SPEC-FACTORY-CORE §4 B10, D-331, D-342)

  `IssueSelector.select/1` is the real `select_fun` the Coordinator loop
  (`lib/tau/factory/coordinator.ex` — `select_fun: (-> work_item | nil)`) calls
  to turn "open issues in the assigned milestone" into admittable work. It:

    1. reads open milestone issues via a **stubbable, read-only `gh` adapter**
       (`gh issue list --milestone <m> --state open --json number,title,...`),
       injected as a seam so the test never touches the network;
    2. **projects against the Ledger** (`Ledger.Reader.latest_unit_snapshots/1`)
       to DROP issues whose unit is already terminal (`:merged` / `:escalated`)
       — a READ-ONLY projection: L is the authority for *what is done* and is
       NEVER written by the selector (D-331, §4 [C112-B10]);
    3. picks the smallest shippable increment and freezes a declared scope;
    4. returns a `work_item` `{issue, scope, hash, branch}`, or `nil` when no
       admittable open issue remains (D-342 — milestone termination).

  ## Pinned contract this test asserts against

    - **Entry point:** `Tau.Factory.IssueSelector.select(opts :: keyword())`.
      `opts` carries:
        * `:ledger`    — `GenServer.server()` of a running `Ledger.Writer`
                         (the projection source, read-only).
        * `:milestone` — `String.t()`; the assigned milestone title.
        * `:gh_fun`    — the stubbable read-only `gh` adapter: a 1-arity fun
                         `(milestone :: String.t() -> {:ok, [issue_map]})`,
                         where `issue_map` has at least `"number"` and
                         `"title"` keys (the `--json` projection).
      The injected seam follows the codebase's canonical `*_fun` injection
      pattern (cf. `Coordinator` `:select_fun`/`:drive_fun`,
      `MergeAuthority` `build_fun`).

    - **Return:** `{issue, scope, hash, branch}` (a 4-tuple `work_item`,
      co-designed with P5c-3b) when an open, non-terminal-in-L issue exists;
      `nil` when the milestone is drained or every open issue is terminal in L.

  This file is the frozen gating-test path for PR #470. It MUST FAIL on `main`
  (module absent) and pass only once `IssueSelector` lands. It exercises the
  REAL selector against a REAL supervised Ledger — never a hand-built struct.
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.IssueSelector
  alias Tau.Factory.Ledger.Reader
  alias Tau.Factory.Ledger.Writer

  @writer Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # Start a real, supervised Ledger.Writer against an isolated temp DB; return
  # its registered name. Mirrors coordinator_recovery_test.exs's start_ledger/0.
  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique_name(:issue_sel_ledger)

    start_supervised!(
      {@writer, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  # A stubbable read-only `gh` adapter: returns the given fixed issue list for
  # ANY milestone, and records that it was called (so the test can prove the
  # selector consulted the tracker, not a hidden network call).
  defp gh_stub(issues) do
    test_pid = self()

    fn milestone ->
      send(test_pid, {:gh_called, milestone})
      {:ok, issues}
    end
  end

  # The unit_id the selector derives for a given issue. The selector must use a
  # stable, issue-derived unit_id so its L-projection lines up with the ids the
  # rest of the factory snapshots under. The conventional form across the
  # factory tests is "unit-<number>"; this helper encodes that convention so
  # the seeded terminal snapshot collides with the selector's projection.
  defp unit_id_for(issue_number), do: "unit-#{issue_number}"

  defp issue(number, title, opts \\ []) do
    %{
      "number" => number,
      "title" => title,
      "body" => Keyword.get(opts, :body, ""),
      "labels" => Keyword.get(opts, :labels, [])
    }
  end

  # ---------------------------------------------------------------------------
  # 1. Selects an open, non-terminal issue (B10).
  #
  # gh returns one open milestone issue; L is empty (no terminal units). The
  # selector MUST return a work_item {issue, scope, hash, branch} for that
  # issue — exercised through the REAL select/1, not a hand-built struct.
  # ---------------------------------------------------------------------------
  @tag :b10
  @tag :d_331
  @tag :d_342
  test "B10/D-331/D-342: select/1 returns a work_item for an open non-terminal issue" do
    ledger = start_ledger()
    milestone = "M10"

    open_issue = issue(469, "P5c-4 — IssueSelector")
    gh_fun = gh_stub([open_issue])

    result =
      IssueSelector.select(
        ledger: ledger,
        milestone: milestone,
        gh_fun: gh_fun
      )

    # The selector actually consulted the (stubbed) tracker for THIS milestone.
    assert_received {:gh_called, ^milestone}

    # Strong assertion on the pinned work_item shape: a 4-tuple
    # {issue, scope, hash, branch}, carrying the selected issue.
    assert {selected_issue, scope, hash, branch} = result,
           "expected a {issue, scope, hash, branch} work_item, got: #{inspect(result)}"

    # The work_item carries the open issue the selector picked.
    assert issue_carries_number?(selected_issue, 469),
           "work_item issue did not carry issue #469: #{inspect(selected_issue)}"

    # The remaining fields are populated (a frozen scope, a content hash, a
    # branch) — none may be nil for an admittable issue.
    refute is_nil(scope), "scope must be a frozen declared scope, not nil"
    assert is_binary(hash) and hash != "", "hash must be a non-empty string"
    assert is_binary(branch) and branch != "", "branch must be a non-empty string"
  end

  # ---------------------------------------------------------------------------
  # 2. Drops terminal-in-L issues (D-331).
  #
  # gh returns one open issue, but that issue's unit is ALREADY :merged in L
  # (seeded via the REAL durable Writer.snapshot_unit/2). The read-only
  # projection MUST drop it — so with no OTHER open issue, select/1 returns nil.
  # ---------------------------------------------------------------------------
  @tag :b10
  @tag :d_331
  test "B10/D-331: select/1 drops an issue whose unit is already terminal in L" do
    ledger = start_ledger()
    milestone = "M10"

    terminal_issue_number = 469
    open_issue = issue(terminal_issue_number, "already-merged increment")
    gh_fun = gh_stub([open_issue])

    # Seed L: the open issue's unit is already at a terminal sink (:merged),
    # via the REAL durable write op.
    unit_id = unit_id_for(terminal_issue_number)

    assert {:ok, _} =
             @writer.snapshot_unit(ledger, %{
               unit_id: unit_id,
               state: :merged,
               idempotency_key: "#{unit_id}:snapshot:merged"
             })

    result =
      IssueSelector.select(
        ledger: ledger,
        milestone: milestone,
        gh_fun: gh_fun
      )

    # The only open issue is terminal in L → it is dropped → nothing admittable.
    assert result == nil,
           "D-331 violation: an issue terminal-in-L (:merged) was NOT dropped; " <>
             "select/1 returned #{inspect(result)} instead of nil"
  end

  # ---------------------------------------------------------------------------
  # 3. `nil` on drained (D-342).
  #
  # gh returns NO open issues. select/1 MUST return nil — the milestone has
  # reached zero open issues (D-342 termination signal).
  # ---------------------------------------------------------------------------
  @tag :b10
  @tag :d_342
  test "B10/D-342: select/1 returns nil when the milestone has no open issues" do
    ledger = start_ledger()
    milestone = "M10"

    gh_fun = gh_stub([])

    result =
      IssueSelector.select(
        ledger: ledger,
        milestone: milestone,
        gh_fun: gh_fun
      )

    assert result == nil,
           "D-342 violation: a drained milestone (no open issues) did not yield " <>
             "nil; select/1 returned #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # 4. L is read-only (D-331).
  #
  # The selector projects L but MUST NEVER write it (the tracker is never a
  # second writer of L). Assert the unit-snapshot population in L is unchanged
  # across a select/1 call — including a call that selects a work_item.
  # ---------------------------------------------------------------------------
  @tag :b10
  @tag :d_331
  test "B10/D-331: select/1 never writes the Ledger (read-only projection)" do
    ledger = start_ledger()
    milestone = "M10"

    # Seed one terminal unit so L starts non-empty and the snapshot count is a
    # meaningful, observable quantity.
    seeded_unit = unit_id_for(999)

    assert {:ok, _} =
             @writer.snapshot_unit(ledger, %{
               unit_id: seeded_unit,
               state: :escalated,
               idempotency_key: "#{seeded_unit}:snapshot:escalated"
             })

    snapshots_before = Reader.latest_unit_snapshots(ledger)

    # An open, non-terminal issue → select/1 returns a work_item. Even on the
    # admit path, L MUST NOT be written.
    open_issue = issue(469, "fresh admittable increment")
    gh_fun = gh_stub([open_issue])

    _result =
      IssueSelector.select(
        ledger: ledger,
        milestone: milestone,
        gh_fun: gh_fun
      )

    snapshots_after = Reader.latest_unit_snapshots(ledger)

    assert snapshots_after == snapshots_before,
           "D-331 violation: select/1 mutated L. The selector's projection MUST " <>
             "be read-only (the tracker is never a second writer of L). " <>
             "before=#{inspect(snapshots_before)} after=#{inspect(snapshots_after)}"
  end

  # ---------------------------------------------------------------------------
  # Shape-tolerant accessor: the work_item's first element is "the issue". The
  # selector may carry it as the raw gh map, a normalised struct, or the bare
  # number; this predicate accepts any representation that preserves the issue
  # number, so the gating test pins the CONTRACT (the right issue is selected)
  # without over-constraining the issue representation P5c-3b co-designs.
  # ---------------------------------------------------------------------------
  defp issue_carries_number?(%{"number" => n}, n), do: true
  defp issue_carries_number?(%{number: n}, n), do: true
  defp issue_carries_number?(n, n) when is_integer(n), do: true
  defp issue_carries_number?(_, _), do: false
end
