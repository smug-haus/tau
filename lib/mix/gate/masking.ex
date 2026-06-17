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

  Returns a list of maps `%{file: String.t(), line: integer(), removed: String.t() | nil}`.
  `file` is the path from the `+++ b/` diff header. `line` is the original-file
  line number (parsed from `@@ -L,N` hunks). `removed` is the raw content of the
  `-` line (without the leading `-`).

  Note: this shim passes an empty gating-path set (the Mix CLI receives the
  gating paths separately via `mix tau.gate.masking`; path-violation detection
  with a declared set is handled by the pure module when invoked directly with
  those paths).
  """
  @spec masking_violations(String.t()) :: [
          %{file: String.t(), line: non_neg_integer(), removed: String.t() | nil}
        ]
  def masking_violations(unified_diff) when is_binary(unified_diff) do
    masking_violations(unified_diff, MapSet.new())
  end

  @doc """
  Scans `unified_diff` for masking violations, including path-based violations
  for any path in `gating_paths` (P-MK2 / INV-6 / issue #566).

  Accepts both assertion-deletion findings (P-MK1) and gating-path-edit findings
  (P-MK2). Neither finding type is filtered out — all findings are mandatory
  review items for the critic (SPEC-FACTORY-GATE §4 B6 / C207-B6).

  Returns a list of maps:
  - For assertion deletions: `%{file: path, line: line, removed: content}`.
  - For gating-path edits: `%{file: path, line: 0, removed: nil}`.
  """
  @spec masking_violations(String.t(), MapSet.t(String.t())) :: [
          %{file: String.t(), line: non_neg_integer(), removed: String.t() | nil}
        ]
  def masking_violations(unified_diff, gating_paths)
      when is_binary(unified_diff) and is_struct(gating_paths, MapSet) do
    {_status, findings} = PureMasking.scan(unified_diff, gating_paths)

    # Both :assertion_deleted and :gating_path_edited findings are surfaced —
    # no filtering by reason. All are mandatory review items for the critic
    # (SPEC-FACTORY-GATE §4 B6 / C207-B6 / INV-6 / issue #566).
    Enum.map(findings, fn f ->
      %{
        file: Map.get(f, :path),
        line: Map.get(f, :line, 0),
        removed: Map.get(f, :removed)
      }
    end)
  end
end
