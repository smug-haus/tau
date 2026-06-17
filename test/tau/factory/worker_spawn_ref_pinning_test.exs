defmodule Tau.Factory.WorkerSpawnRefPinningTest do
  @moduledoc """
  Gating test for INV-WF-9: a worker MUST be spawned from a system-established
  ref derived from fresh `origin/main`, never from the spawning agent's feature
  branch and never from the parent repository root.

  ## Invariant

  **INV-WF-9** (SPEC-FACTORY-FLEET §4 B2, D-311):

  > A worker MUST be spawned only from a system-established ref (the Unit's
  > pinned base, derived from fresh origin/main), never from the spawning
  > agent's branch and never the parent repository root.

  The failing code path (evidence from issue #563):

  - `IssueSelector.pick_work_item/2` sets `branch = "unit-<number>"` from the
    issue number with no origin/main derivation.
  - `Supervisor.build_unit_work_item/1` sets `base_ref: branch` (the feature
    branch name, e.g. "unit-42") and `oracle_base_ref: "origin/unit-42"` (the
    feature branch's remote-tracking ref) — both are feature-branch-derived refs,
    neither is an origin/main-derived pinned ref.
  - `UnitDriver.drive/2` forwards these refs to `WorkerSupervisor.spawn/5`
    unchanged — no `origin/main` pinning is interposed.

  ## What the conformant implementation must do

  `Tau.Factory.Supervisor.to_unit_work_item/2` (the real production entry point
  that converts a 4-tuple IssueSelector work_item into the map shape
  `UnitDriver.drive/2` uses) must produce a map where:

  - `:base_ref` is pinned to a fresh-`origin/main`-derived ref
    (e.g. `"origin/main"` or a SHA resolved from it) — NOT the feature branch
    name `"unit-<n>"`.
  - `:oracle_base_ref` is also a fresh-`origin/main`-derived ref — NOT
    `"origin/unit-<n>"`.

  ## Entry point exercised

  `Tau.Factory.Supervisor.to_unit_work_item/2` — the public seam (line 321 of
  supervisor.ex) that builds the work item map the Coordinator's wrapped
  `drive_fun` passes to `UnitDriver.drive/2`, and therefore the map from which
  `WorkerSupervisor.spawn/5` receives its `base_ref` argument.

  This is the highest-level boundary at which the INV-WF-9 deviation is
  observable without exercising real git I/O (the `base_ref` is constructed
  here and forwarded unchanged downstream).

  ## Fail-before validity

  The current code sets `base_ref: branch` (= `"unit-42"`) and
  `oracle_base_ref: "origin/unit-42"`. Both assertions in the test FAIL against
  the current production code.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :inv_wf_9

  alias Tau.Factory.Supervisor, as: FactorySupervisor

  # Minimal scope map matching ConflictCheck.scope() shape (no universal_conflict).
  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # A minimal issue map as returned by IssueSelector (the "number" key is
  # what build_unit_work_item/1 uses to derive unit_id and branch).
  defp issue_map(number) do
    %{"number" => number, "title" => "Test issue #{number}", "body" => ""}
  end

  # The 4-tuple work_item shape returned by IssueSelector.pick_work_item/2.
  # branch = "unit-#{number}" (what the current production code sets).
  defp selector_work_item(number) do
    issue = issue_map(number)
    scope = empty_scope()
    hash = "abcdef#{number}"
    branch = "unit-#{number}"
    {issue, scope, hash, branch}
  end

  describe "INV-WF-9 — to_unit_work_item/2 must pin base_ref to origin/main" do
    @tag :inv_wf_9
    test "INV-WF-9: base_ref in the produced work_item is derived from origin/main, not the feature branch" do
      work_item = selector_work_item(42)
      result = FactorySupervisor.to_unit_work_item(work_item, [])

      base_ref = Map.fetch!(result, :base_ref)

      # INV-WF-9 / SPEC-FACTORY-FLEET §4 B2: base_ref MUST be derived from
      # origin/main (e.g. "origin/main" or a SHA), never the feature branch name.
      # The conformant implementation must NOT produce "unit-42" here.
      refute base_ref == "unit-42",
             "INV-WF-9 violated: base_ref is the feature branch name #{inspect(base_ref)}; " <>
               "expected an origin/main-derived ref"

      assert String.contains?(base_ref, "main") or String.match?(base_ref, ~r/\A[0-9a-f]{7,40}\z/),
             "INV-WF-9 violated: base_ref #{inspect(base_ref)} is not an origin/main-derived ref " <>
               "(must contain 'main' or be a SHA hex string)"
    end

    @tag :inv_wf_9
    test "INV-WF-9: oracle_base_ref in the produced work_item is derived from origin/main, not origin/unit-<n>" do
      work_item = selector_work_item(42)
      result = FactorySupervisor.to_unit_work_item(work_item, [])

      oracle_base_ref = Map.fetch!(result, :oracle_base_ref)

      # INV-WF-9 / SPEC-FACTORY-FLEET §4 B2: the oracle worker also MUST be
      # spawned from an origin/main-derived ref. The conformant implementation
      # must NOT produce "origin/unit-42" here.
      refute oracle_base_ref == "origin/unit-42",
             "INV-WF-9 violated: oracle_base_ref is the feature branch remote " <>
               "#{inspect(oracle_base_ref)}; expected an origin/main-derived ref"

      assert String.contains?(oracle_base_ref, "main") or
               String.match?(oracle_base_ref, ~r/\A[0-9a-f]{7,40}\z/),
             "INV-WF-9 violated: oracle_base_ref #{inspect(oracle_base_ref)} is not an " <>
               "origin/main-derived ref (must contain 'main' or be a SHA hex string)"
    end
  end
end
