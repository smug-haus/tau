defmodule Mix.Tasks.Tau.Gate.AcLinkage do
  @shortdoc "Gate 5.1: verify every AC-N/D-NNN in the PR body has a gating test. Exits 1 on missing."

  @moduledoc """
  Factory-loop Gate 5.1 — AC-to-test linkage (issue #370).

  Reads the PR body and gating-test source files, then verifies that every
  `AC-N` / `D-NNN` token claimed in the body appears in at least one
  gating-test source as a test name or `@tag`.

  ## Usage

      mix tau.gate.ac_linkage PR_BODY_FILE GATING_TEST_FILE [GATING_TEST_FILE ...]

  `PR_BODY_FILE` — path to a file containing the draft-PR body text.
  `GATING_TEST_FILE` — one or more paths to gating-test `.exs` files.

  ## Exit codes

  | code | meaning |
  |------|---------|
  | 0    | every claimed AC-N/D-NNN is covered |
  | 1    | one or more tokens are missing from the gating tests |
  | 2    | usage error (wrong number of arguments) |
  """

  use Mix.Task

  alias Tau.Factory.Gate

  @impl Mix.Task
  def run(argv) do
    case argv do
      [pr_body_file | gating_files] when gating_files != [] ->
        pr_body = File.read!(pr_body_file)
        sources = Enum.map(gating_files, &File.read!/1)

        case Gate.ac_linkage(pr_body, sources) do
          :ok ->
            Mix.shell().info("tau.gate.ac_linkage: OK — all claimed AC/D-NNN tokens covered")

          {:error, missing} ->
            Mix.shell().error(
              "tau.gate.ac_linkage: FAIL — missing tokens: #{Enum.join(missing, ", ")}"
            )

            System.halt(1)
        end

      _ ->
        Mix.shell().error("usage: mix tau.gate.ac_linkage PR_BODY_FILE GATING_TEST_FILE [...]")

        System.halt(2)
    end
  end
end
