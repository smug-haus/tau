defmodule Tau.Factory.Gate.Mutation do
  @moduledoc """
  Gate 5.3 — Mutation check (pure planning + pure judgement, no I/O).

  This module provides the PURE functions only:
  - `plan/2` — produces a `%Plan{}` describing which paths to revert and to
    which ref. The engine executes the revert and the test run.
  - `judge/1` — pure predicate over an engine-parsed test report. Decides
    whether the mutation check passes (≥1 test failed on the reverted tree).

  **No I/O.** All subprocess execution, git operations, and file system access
  live in the engine (C6 `Tau.Factory.Engine.TestRun`, arriving in P2). This
  module is referentially transparent and property-testable in isolation.

  ## Spec

  SPEC-FACTORY-GATE §2 C4 / §4 B2–B3 / gate-and-toolchain.md §2.3. Properties:
  - P-MU1 (non-vacuity): `judge/1 = {:pass, _}` iff `report` has ≥1 `:failed`
    case.
  - P-MU2 (boundary = declared paths): `plan/2` records `gating_paths` as the
    keep-set; the engine reverts `tracked ∖ gating_paths` to `merge_base`.
  - P-MU3 (project-creation N/A): `judge/1` returns `{:na, :project_created}`
    when the report carries the `project_created: true` sentinel.
  - P-MU4 (purity): `plan/2` and `judge/1` are referentially transparent.

  ## Report shape

  `judge/1` accepts any map with:
  - `:cases` — a list of `%{id: test_id, status: :passed | :failed}` maps.
  - `:project_created` (optional) — `true` when the N/A sentinel applies.

  ## Plan shape

  `plan/2` returns a `%Tau.Factory.Gate.Mutation.Plan{}` struct with:
  - `:merge_base` — the merge-base git ref (string).
  - `:gating_paths` — the declared keep-set (`MapSet`).
  """

  defmodule Plan do
    @moduledoc """
    The reverted-tree plan produced by `Tau.Factory.Gate.Mutation.plan/2`.

    Fields:
    - `:merge_base` — the git ref to revert non-gating paths to.
    - `:gating_paths` — the declared gating-test paths to keep at HEAD.
    """
    @type t :: %__MODULE__{
            merge_base: String.t(),
            gating_paths: MapSet.t(String.t())
          }
    defstruct [:merge_base, :gating_paths]
  end

  @typedoc "A test case map: `%{id: String.t(), status: :passed | :failed}`."
  @type test_case :: %{id: String.t(), status: :passed | :failed}

  @typedoc """
  A test report map: `%{cases: [test_case()]}` plus optional
  `project_created: true` sentinel.
  """
  @type report :: map()

  @doc """
  Produce a reverted-tree plan for the mutation check.

  The engine will:
  1. Revert every tracked file except those in `gating_paths` to `merge_base`.
  2. Keep `gating_paths` at the test-author's committed state (HEAD).
  3. Run the gating tests and capture a structured report.
  4. Apply `judge/1` to the report.

  The boundary is path-based (INV-6): `gating_paths` is the frozen declared set,
  not derived from commit attribution. This survives a refine-cycle rebase.
  """
  @spec plan(String.t(), MapSet.t(String.t())) :: Plan.t()
  def plan(merge_base, gating_paths)
      when is_binary(merge_base) do
    %Plan{merge_base: merge_base, gating_paths: gating_paths}
  end

  @doc """
  Pure predicate over an engine-parsed test report.

  Returns:
  - `{:pass, killed_ids}` — ≥1 test failed on the reverted tree (the suite
    discriminates against absent production code; mutation check passes).
  - `{:fail, :no_test_failed}` — all tests passed (vacuous suite; INV-7
    violated).
  - `{:na, :project_created}` — the report carries the `project_created: true`
    sentinel; no pre-implementer production code existed to revert
    (SPEC-FACTORY-GATE Gate 5.3 project-creation N/A clause).
  """
  @spec judge(report()) ::
          {:pass, [String.t()]}
          | {:fail, :no_test_failed}
          | {:na, :project_created}
  def judge(%{project_created: true}) do
    {:na, :project_created}
  end

  def judge(%{cases: cases}) do
    failed = Enum.filter(cases, &(&1.status == :failed))

    case failed do
      [] -> {:fail, :no_test_failed}
      _ -> {:pass, Enum.map(failed, & &1.id)}
    end
  end
end
