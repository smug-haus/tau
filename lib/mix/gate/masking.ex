defmodule Mix.Gate.Masking do
  @moduledoc """
  Gate 5.2 — Masking detection (Mix shim).

  Thin shim over `Tau.Factory.Gate.Masking`. Adapts the pure module's
  `{:clean | :flagged, findings}` output to the legacy list-of-maps format
  consumed by `Mix.Tasks.Tau.Gate.Masking`.

  No decision logic lives here — all scanning is delegated to
  `Tau.Factory.Gate.Masking.scan/2`.
  """

  alias Tau.Factory.Gate.Masking, as: PureMasking

  @doc """
  Scans `unified_diff` for removed assertion lines.

  Returns a list of maps `%{file: String.t(), line: integer(), removed: String.t()}`.
  `file` is the path from the `+++ b/` diff header. `line` is the original-file
  line number (parsed from `@@ -L,N` hunks). `removed` is the raw content of the
  `-` line (without the leading `-`).

  Note: this shim passes an empty gating-path set (the Mix CLI receives the
  gating paths separately via `mix tau.gate.masking`; path-violation detection
  with a declared set is handled by the pure module when invoked directly with
  those paths).
  """
  @spec masking_violations(String.t()) :: [
          %{file: String.t(), line: integer(), removed: String.t()}
        ]
  def masking_violations(unified_diff) when is_binary(unified_diff) do
    {_status, findings} = PureMasking.scan(unified_diff, MapSet.new())

    # Adapt: filter to assertion-deletion findings and map to the legacy shape.
    findings
    |> Enum.filter(&(Map.get(&1, :reason) == :assertion_deleted))
    |> Enum.map(fn f ->
      %{
        file: Map.get(f, :path),
        line: Map.get(f, :line, 0),
        removed: Map.get(f, :removed, "")
      }
    end)
  end
end
