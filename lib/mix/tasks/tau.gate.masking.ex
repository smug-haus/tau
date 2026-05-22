defmodule Mix.Tasks.Tau.Gate.Masking do
  @shortdoc "Gate 5.2: scan a unified diff for removed assertions. Detection-only; never exits 1."

  @moduledoc """
  Factory-loop Gate 5.2 — Masking detection (issue #370).

  Scans a unified diff for removed assertion lines (`assert`, `refute`,
  `assert_receive`, `assert_raise` on `-` lines). Detection-only: outputs
  any violations found for the `critic` to review but never fails CI by
  itself (always exits 0).

  ## Usage

      mix tau.gate.masking DIFF_FILE

  `DIFF_FILE` — path to a file containing a unified diff. Use `-` to read
  from stdin.

  ## Exit codes

  | code | meaning |
  |------|---------|
  | 0    | always (detection-only gate) |
  | 2    | usage error |

  Violations are written to stdout even when found; CI should capture and
  surface them to the `critic` for review.
  """

  use Mix.Task

  alias Tau.Factory.Gate

  @impl Mix.Task
  def run(argv) do
    case argv do
      [diff_source] ->
        diff =
          if diff_source == "-" do
            IO.read(:all)
          else
            File.read!(diff_source)
          end

        violations = Gate.masking_violations(diff)

        if violations == [] do
          Mix.shell().info("tau.gate.masking: OK — no removed assertions detected")
        else
          Mix.shell().info("tau.gate.masking: VIOLATIONS DETECTED (surfaced for critic review)")

          Enum.each(violations, fn %{file: file, line: line, removed: removed} ->
            Mix.shell().info("  #{file}:#{line}: -#{removed}")
          end)
        end

        :ok

      _ ->
        Mix.shell().error("usage: mix tau.gate.masking DIFF_FILE")
        System.halt(2)
    end
  end
end
