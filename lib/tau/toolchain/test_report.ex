defmodule Tau.Toolchain.TestReport do
  @moduledoc """
  Engine-produced test report parsed from a subprocess artifact (JUnit XML,
  TAP, or similar).

  This struct is produced exclusively by `Tau.Toolchain.ReportParser.parse/2`
  and returned by `Tau.Factory.Engine.TestRun.execute/2`. The adapter (toolchain
  descriptor) never writes or fabricates this struct — HR-3, SPEC-FACTORY-GATE
  §4 B5.

  ## Fields

    * `cases` — ordered list of `%{id: String.t(), status: :passed | :failed |
      :skipped}` maps. The `id` is stable across identical artifact inputs and
      is used by the mutation cross-check to bind reverted-run failures to
      real-run passes (D-306).
  """

  @enforce_keys [:cases]

  defstruct [:cases]

  @typedoc "A single test case in a report."
  @type test_case :: %{
          required(:id) => String.t(),
          required(:status) => :passed | :failed | :skipped
        }

  @typedoc "An engine-produced test report."
  @type t :: %__MODULE__{
          cases: [test_case()]
        }
end
