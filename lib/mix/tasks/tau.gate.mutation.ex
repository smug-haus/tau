defmodule Mix.Tasks.Tau.Gate.Mutation do
  @shortdoc "Gate 5.3: mutation check — verifies ≥1 gating test fails against the pre-implementer tree."

  @moduledoc """
  Factory-loop Gate 5.3 — Mutation check.

  Keeps the declared gating-test paths at HEAD, reverts every other path
  to `base_ref` (the pre-implementer commit), runs the gating tests, and
  exits 0 when ≥1 test fails (the suite is discriminating) or exits 1 when
  all tests pass (the suite is vacuous — the gating tests do not bind to
  the implementation change).

  ## Usage

      mix tau.gate.mutation BASE_REF GATING_TEST_FILE [GATING_TEST_FILE ...]

  `BASE_REF` — a git ref (SHA, branch, or tag) representing the
  pre-implementer state (the test-author's commit, before the implementer
  added production code).

  `GATING_TEST_FILE` — one or more paths to gating-test files (relative to
  the repo root).

  ## Exit codes

  | code | meaning |
  |------|---------|
  | 0    | ≥1 gating test failed against the reverted tree (discriminating); OR N/A (project-creation PR — no pre-implementer code to mutate) |
  | 1    | all gating tests passed against the reverted tree (vacuous suite) |
  | 2    | usage error |
  | 3    | test runner crashed — gate could not evaluate (compile error or process crash) |
  """

  use Mix.Task

  alias Tau.Factory.Gate

  @impl Mix.Task
  def run(argv) do
    case argv do
      [base_ref | gating_files] when gating_files != [] ->
        case Gate.mutation_check(gating_files, base_ref) do
          :ok ->
            Mix.shell().info(
              "tau.gate.mutation: OK — ≥1 gating test failed against reverted tree (suite is discriminating)"
            )

          :not_applicable ->
            Mix.shell().info(
              "tau.gate.mutation: N/A — project-creation PR; no pre-implementer production code to mutate"
            )

          {:error, :all_passed} ->
            Mix.shell().error(
              "tau.gate.mutation: FAIL — all gating tests passed against the reverted tree (vacuous suite)"
            )

            System.halt(1)

          {:error, {:runner_crashed, detail}} ->
            Mix.shell().error(
              "tau.gate.mutation: ERROR — test runner crashed before producing a summary " <>
                "(compile error or process crash — gate could not evaluate); detail: #{detail}"
            )

            System.halt(3)
        end

      _ ->
        Mix.shell().error("usage: mix tau.gate.mutation BASE_REF GATING_TEST_FILE [...]")

        System.halt(2)
    end
  end
end
