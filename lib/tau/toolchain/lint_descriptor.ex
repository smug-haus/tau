defmodule Tau.Toolchain.LintDescriptor do
  @moduledoc """
  Declarative lint/compile/typecheck recipe returned by `Tau.Factory.Toolchain`
  adapters.

  The descriptor is data only — it names the ordered steps the engine runs
  sequentially via the exit-status judge (SPEC-FACTORY-GATE §4 B4, §5.2 HR-6).
  A non-zero exit code from any step is a lint-half FAIL.

  Fields:

    * `steps` — ordered list of step maps, each containing:
        - `:argv`   — the command + arguments as a list of strings.
        - `:report` — the judgment format; `:exit_status` means a non-zero exit
                      code is the failure signal.
  """

  @enforce_keys [:steps]

  defstruct [:steps]

  @type step :: %{required(:argv) => [String.t()], required(:report) => atom()}

  @type t :: %__MODULE__{
          steps: [step()]
        }
end
