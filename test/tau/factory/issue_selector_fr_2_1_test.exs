defmodule Tau.Factory.IssueSelectorFr21Test do
  @moduledoc """
  Gating test for FR-2.1 — dependency conjunct of the work-selection invariant.

  Issue #648. Branch wave/scheduler-conformance.

  ## What FR-2.1 requires

  FR-2.1 (docs/arch/02-requirements/R-list.md): "Work is selected as the
  **smallest shippable increment** that respects declared dependencies and any
  stated priority order; a missing prerequisite is **filed as an issue**, never
  silently created as code."

  The audit verdict (issue #648) is PARTIAL: the elaborator correctly parses
  `blocked-by: #N` into `"unit-N"` dep strings, and `ConflictCheck` correctly
  blocks a candidate whose dep is IN-FLIGHT (in F).  However, the dep conjunct
  is NOT enforced at the `IssueSelector.select/1` boundary for these two cases:

    1. **Open-but-not-yet-started prerequisite**: issue A declares
       `blocked-by: #B`; issue B is still open in the tracker (returned by
       `gh_fun`) but not in F and not terminal in L.  The selector currently
       returns A as admittable work — it should skip A (either return B first,
       or return nil when A is the only remaining issue and B is still open).

    2. **Escalated (terminal-failed) prerequisite**: issue A declares
       `blocked-by: #B`; issue B's unit is `:escalated` in the Ledger.
       A dep on an escalated unit can never be satisfied.  The selector
       currently returns A as admittable work — it should skip A (or return nil)
       because the prerequisite will never merge.

  ## Entry point under test

  `Tau.Factory.IssueSelector.select/1` — the real user-facing `select_fun`
  called by the Coordinator loop (K). All tests inject a stub `:gh_fun` (no
  network) and a real supervised `Ledger.Writer` (no hand-built struct).

  ## Tag

  Every test carries `@tag :fr_2_1` so the AC-to-test linkage gate finds FR-2.1
  coverage.
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.IssueSelector
  alias Tau.Factory.Ledger.Writer

  @writer Writer

  # ---------------------------------------------------------------------------
  # Helpers (mirrors issue_selector_test.exs conventions)
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique_name(:fr21_ledger)

    start_supervised!(
      {@writer, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  defp gh_stub(issues) do
    test_pid = self()

    fn milestone ->
      send(test_pid, {:gh_called, milestone})
      {:ok, issues}
    end
  end

  defp issue(number, title, opts \\ []) do
    %{
      "number" => number,
      "title" => title,
      "body" => Keyword.get(opts, :body, ""),
      "labels" => Keyword.get(opts, :labels, [])
    }
  end

  defp unit_id_for(issue_number), do: "unit-#{issue_number}"

  # ---------------------------------------------------------------------------
  # Test 1 — open-but-not-yet-started prerequisite (FR-2.1 conjunct 2).
  #
  # Issue A (number 200) declares `blocked-by: #100` in its body.
  # Issue B (number 100) is open in the tracker (returned by gh_fun) and is
  # NOT terminal in L (fresh ledger, no snapshots for unit-100).
  #
  # FR-2.1 requires the selector to respect declared dependencies: A MUST NOT
  # be selected while B is still open.  If B (the prerequisite) is admittable
  # it should be returned instead; if neither A nor B is admittable the result
  # is nil.  The invariant is: the selected work_item MUST NOT be A while B
  # remains open and unsatisfied.
  # ---------------------------------------------------------------------------
  @tag :fr_2_1
  test "FR-2.1: select/1 does not select an issue whose declared dep is still open in the tracker" do
    ledger = start_ledger()
    milestone = "M-FR21"

    # Issue A depends on issue B (open prerequisite).
    issue_b = issue(100, "Prerequisite B — must land first")
    issue_a = issue(200, "Blocked A", body: "blocked-by: #100\nSome work here.")

    # Both issues are open in the tracker; B is the prerequisite of A.
    # L has no terminal snapshots — unit-100 is NOT terminal.
    gh_fun = gh_stub([issue_a, issue_b])

    result =
      IssueSelector.select(
        ledger: ledger,
        milestone: milestone,
        gh_fun: gh_fun
      )

    # FR-2.1 violation: selected A (number 200) while its dep B (number 100) is
    # still open.  The selector MUST NOT return A here.
    refute match?({%{"number" => 200}, _, _, _}, result),
           "FR-2.1 violated: selected issue #200 whose dep #100 is still open. " <>
             "Declared dependencies must be respected at the IssueSelector boundary. " <>
             "select/1 returned: #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # Test 2 — all remaining issues are blocked by an open prerequisite (FR-2.1).
  #
  # Only issue A (number 201) exists in the milestone; it declares
  # `blocked-by: #101`.  Issue 101 is NOT in the tracker (it lives in a
  # different milestone or is otherwise unlisted), so no admittable prerequisite
  # is available.  The selector MUST return nil — there is no smallest shippable
  # increment when every remaining issue has an unsatisfied dep.
  # ---------------------------------------------------------------------------
  @tag :fr_2_1
  test "FR-2.1: select/1 returns nil when the only remaining issue has an unsatisfied open dep" do
    ledger = start_ledger()
    milestone = "M-FR21-nil"

    # Only issue A; its dep (#101) is not in the tracker (not returned by gh_fun).
    issue_a = issue(201, "Blocked A — lone remaining", body: "blocked-by: #101")
    gh_fun = gh_stub([issue_a])

    result =
      IssueSelector.select(
        ledger: ledger,
        milestone: milestone,
        gh_fun: gh_fun
      )

    assert result == nil,
           "FR-2.1 violated: selected issue #201 whose dep #101 is unsatisfied. " <>
             "The selector MUST return nil when no admittable shippable increment exists. " <>
             "select/1 returned: #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # Test 3 — escalated (terminal-failed) prerequisite is not a satisfied dep
  # (FR-2.1 conjunct 2).
  #
  # Issue A (number 202) declares `blocked-by: #102`.  Issue B (unit-102) is
  # :escalated in the Ledger — it failed terminally and will never merge.  A dep
  # on an escalated unit can never be satisfied; the selector MUST NOT return A.
  #
  # Note: unit-102 is NOT returned by gh_fun (it is terminal-in-L, so the
  # selector drops it from consideration on the terminal-rejection path).  Only
  # issue A is in the admittable set.  The correct behaviour is nil — A must not
  # proceed when its prerequisite escalated.
  # ---------------------------------------------------------------------------
  @tag :fr_2_1
  test "FR-2.1: select/1 does not select an issue whose dep is escalated (terminal-failed)" do
    ledger = start_ledger()
    milestone = "M-FR21-esc"

    # Seed L: unit-102 is escalated (terminal failure — will never merge).
    escalated_uid = unit_id_for(102)

    assert {:ok, _} =
             @writer.snapshot_unit(ledger, %{
               unit_id: escalated_uid,
               state: :escalated,
               idempotency_key: "#{escalated_uid}:snapshot:escalated"
             })

    # Issue A depends on issue 102 (which is now escalated in L).
    # gh_fun does NOT return issue 102 (it is terminal-in-L; selector rejects it
    # anyway), only issue A.
    issue_a = issue(202, "Blocked A — dep escalated", body: "blocked-by: #102\nSome work.")
    gh_fun = gh_stub([issue_a])

    result =
      IssueSelector.select(
        ledger: ledger,
        milestone: milestone,
        gh_fun: gh_fun
      )

    assert result == nil,
           "FR-2.1 violated: selected issue #202 whose dep unit-102 is escalated " <>
             "(terminal-failed, will never merge). An escalated dep is never satisfied; " <>
             "the selector MUST NOT return A. select/1 returned: #{inspect(result)}"
  end
end
