defmodule Tau.Factory.WorkerBaseRefInvWf9Test do
  @moduledoc """
  Gating test for PR #680 — INV-WF-9: worker MUST be spawned only from a
  system-established ref derived from fresh `origin/main`.

  Closes #563. Advances INV-WF-9 / [C214-B2] (SPEC-FACTORY-FLEET §4 B2).

  ## The invariant (INV-WF-9)

  A worker MUST be spawned only from a **system-established ref** — the Unit's
  pinned base derived from a **fresh `origin/main`** — never from the spawning
  agent's branch, the parent repo root, or a ref derived from the issue number
  alone.

  ## The current DEVIATION

  `IssueSelector.pick_work_item/2` (lib/tau/factory/issue_selector.ex ~line 158)
  sets `branch = "unit-\#{number}"` from the issue number alone: no `git fetch`,
  no `origin/main` resolution. `Supervisor.build_unit_work_item/1` copies this
  directly to `base_ref: branch` (lib/tau/factory/supervisor.ex ~line 411).

  The `base_ref` that reaches the Worker is therefore `"unit-563"` — an
  issue-number-derived string, not a system-established ref.

  ## What this test asserts (the conformant contract)

  `IssueSelector.select/1` MUST accept a `:fetch_fun` seam (following the
  codebase's canonical `*_fun` injection pattern) that:

    1. Performs a `git fetch origin` (or equivalent, injected for test isolation).
    2. Resolves the current `origin/main` HEAD SHA.
    3. Uses that SHA (or a `origin/main`-rooted branch ref) as the `base_ref`
       carried in the returned work_item.

  The conformant `branch` field in the work_item is NOT `"unit-<N>"` but a ref
  established from the fetched `origin/main` — e.g. the `origin/main` SHA or a
  branch name that has been created from it via a system operation.

  ## Fail-before validity (oracle separation)

  On the current branch, `IssueSelector.select/1` ignores any `:fetch_fun` opt
  and returns `branch = "unit-<N>"` with no `origin/main` derivation. This test's
  assertion that `branch` is NOT simply `"unit-<number>"` will FAIL against the
  current code, making gate 5.3 (:mutation check) meaningful once the implementer
  ships the fix.

  ## AC / INV-WF-9 linkage (gate 5.1)
    - `@tag :inv_wf_9` on the test below — scanned by `mix tau.gate.ac_linkage`.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :inv_wf_9

  alias Tau.Factory.IssueSelector
  alias Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # Start a real, supervised Ledger.Writer against an isolated temp DB.
  # Mirrors the pattern in issue_selector_test.exs.
  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique_name(:wf9_ledger)

    start_supervised!(
      {Writer, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  # A stubbable read-only `gh` adapter: returns a fixed single-issue list.
  defp gh_stub(issues) do
    fn _milestone -> {:ok, issues} end
  end

  # A stubbable `:fetch_fun` — the seam the conformant IssueSelector MUST accept
  # to perform `git fetch origin` + `origin/main` SHA resolution in a
  # network-free, injected way. Returns a known sentinel SHA so the test can
  # assert the work_item's base_ref is derived from it rather than from the issue
  # number alone.
  #
  # The sentinel SHA is a valid 40-hex SHA that cannot collide with `"unit-<N>"`.
  @sentinel_origin_main_sha "aabbccdd11223344556677889900aabbccdd1122"

  defp fetch_fun_stub do
    test_pid = self()

    fn ->
      send(test_pid, :fetch_called)
      {:ok, @sentinel_origin_main_sha}
    end
  end

  # ---------------------------------------------------------------------------
  # INV-WF-9 — the single gating test
  #
  # Exercises the real `IssueSelector.select/1` entry point (not a hand-built
  # struct). Asserts that the `branch` field in the returned work_item is derived
  # from a system-established `origin/main` ref (the sentinel SHA returned by
  # the injected `:fetch_fun`), NOT from the issue number alone ("unit-<N>").
  # ---------------------------------------------------------------------------
  @tag :inv_wf_9
  test "INV-WF-9: IssueSelector.select/1 derives worker base_ref from a system-established origin/main ref, not the issue number alone" do
    ledger = start_ledger()
    issue_number = 563
    issue_title = "INV-WF-9 worker base ref audit"

    issue_map = %{
      "number" => issue_number,
      "title" => issue_title,
      "body" => "",
      "labels" => []
    }

    gh_fun = gh_stub([issue_map])
    fetch_fun = fetch_fun_stub()

    result =
      IssueSelector.select(
        ledger: ledger,
        milestone: "m-wf9",
        gh_fun: gh_fun,
        fetch_fun: fetch_fun
      )

    # The selector must have consulted the fetch_fun (proves origin/main was
    # resolved, not skipped).
    assert_received :fetch_called,
                    "INV-WF-9 violation: IssueSelector.select/1 did NOT call the " <>
                      "injected :fetch_fun. A system-established base_ref requires " <>
                      "a git fetch step before deriving the worker base; the current " <>
                      "code skips the fetch entirely."

    # The work_item must be a 4-tuple {issue, scope, hash, branch}.
    assert {_issue, _scope, _hash, branch} = result,
           "INV-WF-9: IssueSelector.select/1 must return a {issue, scope, hash, branch} " <>
             "work_item when an admittable issue exists. Got: #{inspect(result)}"

    # The branch (= base_ref) MUST NOT be simply "unit-<issue_number>".
    # A ref derived solely from the issue number is NOT a system-established ref
    # (INV-WF-9 / [C214-B2]). The conformant implementation uses the fetched
    # origin/main SHA (or a branch rooted from it) as the base.
    naive_issue_branch = "unit-#{issue_number}"

    refute branch == naive_issue_branch,
           "INV-WF-9 violation (DEVIATION confirmed): branch = #{inspect(branch)} is " <>
             "the naive issue-number-derived string \"#{naive_issue_branch}\". " <>
             "IssueSelector MUST derive base_ref from a fresh origin/main fetch " <>
             "([C214-B2], SPEC-FACTORY-FLEET §4 B2), not from the issue number alone. " <>
             "Fix: introduce a :fetch_fun seam, call it before pick_work_item/2, and " <>
             "thread the resolved origin/main SHA into the work_item's branch/base_ref."

    # Additionally: the conformant branch must carry evidence of the fetched
    # origin/main ref. The sentinel SHA returned by the injected fetch_fun MUST
    # appear in (or equal) the branch, confirming the system-established ref was
    # actually used.
    assert String.contains?(branch, @sentinel_origin_main_sha) or
             branch == @sentinel_origin_main_sha,
           "INV-WF-9: branch #{inspect(branch)} does not contain the system-established " <>
             "origin/main SHA #{inspect(@sentinel_origin_main_sha)} returned by the " <>
             "injected :fetch_fun. The conformant base_ref must be rooted in the fetched " <>
             "origin/main SHA, not an independently-derived string."
  end
end
