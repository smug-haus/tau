defmodule Tau.Toolchain.TestDescriptor do
  @moduledoc """
  Declarative test invocation recipe returned by `Tau.Factory.Toolchain` adapters.

  The descriptor is data only — it names the argv, env, the machine-readable
  report format, and the artifact path. The engine (not the adapter) runs the
  subprocess, captures the artifact, and judges the result (HR-3,
  SPEC-FACTORY-GATE §4 B4).

  Fields:

    * `argv`     — the command + arguments to run, as a list of strings.
    * `env`      — environment variables to set for the subprocess.
    * `report`   — the machine-readable report format the engine will parse
                   (`:junit | :tap`). The engine selects a trusted parser by
                   this tag; the adapter never supplies a parser.
    * `artifact` — relative path (from the workspace root) where the
                   subprocess writes its report artifact. The engine reads and
                   parses this file; the descriptor only names the path.
  """

  @enforce_keys [:argv, :env, :report, :artifact]

  defstruct [:argv, :env, :report, :artifact]

  @type report_format :: :junit | :tap

  @type t :: %__MODULE__{
          argv: [String.t()],
          env: %{String.t() => String.t()},
          report: report_format(),
          artifact: String.t()
        }
end
