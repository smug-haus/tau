defmodule Mix.Tasks.Tau.Gate.Masking do
  @shortdoc "Gate 5.2: scan a unified diff for removed assertions and gating-path edits. Detection-only; never exits 1."

  @moduledoc """
  Factory-loop Gate 5.2 — Masking detection.

  Scans a unified diff for removed assertion lines (`assert`, `refute`,
  `assert_receive`, `assert_raise` on `-` lines) and for implementer edits
  to declared gating-test paths (P-MK2 / INV-6 / D-305). Detection-only:
  outputs any violations found for the `critic` to review but never fails CI
  by itself (always exits 0).

  ## Usage

      mix tau.gate.masking DIFF_FILE
      mix tau.gate.masking DIFF_FILE GATING_PATHS_FILE

  `DIFF_FILE` — path to a file containing a unified diff. Use `-` to read
  from stdin.

  `GATING_PATHS_FILE` — optional path to a file containing one repo-relative
  gating-test path per line (the frozen paths_g set declared for the PR).
  When supplied, any diff hunk that touches a declared gating-test path
  produces a path-violation finding (P-MK2 / D-305 / INV-6).

  ## Exit codes

  | code | meaning |
  |------|---------|
  | 0    | always (detection-only gate) |
  | 2    | usage error |

  Violations are written to stdout even when found; CI should capture and
  surface them to the `critic` for review.
  """

  use Mix.Task

  alias Mix.Gate.Masking

  @impl Mix.Task
  def run(argv) do
    case argv do
      [diff_source] ->
        diff = read_diff(diff_source)
        violations = Masking.masking_violations(diff)
        report_violations(violations)

      [diff_source, gating_paths_source] ->
        diff = read_diff(diff_source)

        gating_paths =
          gating_paths_source
          |> File.read!()
          |> String.split("\n", trim: true)
          |> MapSet.new()

        violations = Masking.masking_violations(diff, gating_paths)
        report_violations(violations)

      _ ->
        Mix.shell().error("usage: mix tau.gate.masking DIFF_FILE [GATING_PATHS_FILE]")
        System.halt(2)
    end
  end

  defp read_diff("-"), do: IO.read(:all)
  defp read_diff(path), do: File.read!(path)

  defp report_violations([]) do
    Mix.shell().info("tau.gate.masking: OK — no violations detected")
    :ok
  end

  defp report_violations(violations) do
    Mix.shell().info("tau.gate.masking: VIOLATIONS DETECTED (surfaced for critic review)")

    Enum.each(violations, fn %{file: file, line: line, removed: removed} ->
      Mix.shell().info("  #{file}:#{line}: -#{removed}")
    end)

    :ok
  end
end
