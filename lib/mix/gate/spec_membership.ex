defmodule Mix.Gate.SpecMembership do
  @moduledoc """
  Gate C5 — Spec-before-code mechanized (Mix shim).

  Thin shim over `Tau.Factory.Gate.SpecMembership`. Adapts the pure module's
  `{:pass, []} | {:fail, [boundary]}` output to a flat list-of-maps format
  consumed by `Mix.Tasks.Tau.Gate.SpecMembership`.

  No decision logic lives here — all checking is delegated to
  `Tau.Factory.Gate.SpecMembership.check/3`.

  ## Contract (D-322 / SPEC-FACTORY-GATE §4 C5)

  `spec_membership_violations/3 :: (diff, pr_body, source_maps) -> [violation]`

  Where each violation is `%{boundary: String.t()}` naming a SPEC source-map
  boundary path that was touched by the diff without a `SPEC-*`/`D-NNN` token
  in the PR body.

  Returns `[]` when no boundaries are violated (P-SP2 non-SPEC'd-only =>
  no violations).
  """

  alias Tau.Factory.Gate.SpecMembership, as: PureSpecMembership

  @doc """
  Returns a list of violation maps for every SPEC'd boundary touched by `diff`
  that is not referenced in `pr_body`.

  Each map has the form `%{boundary: boundary_path}` where `boundary_path` is
  the source-map path that was touched without a `SPEC-*`/`D-NNN` token in the
  PR body.

  Returns `[]` when:
  - the diff touches only non-SPEC'd paths (P-SP2); or
  - every touched SPEC'd boundary is covered by a token in `pr_body`.

  `source_maps` is a list of `{boundary_path, spec_ref}` pairs as loaded from
  the Appendix B of each `docs/spec/SPEC-*.md`.
  """
  @spec spec_membership_violations(
          String.t(),
          String.t(),
          [{String.t(), String.t()}]
        ) :: [%{boundary: String.t()}]
  def spec_membership_violations(diff, pr_body, source_maps)
      when is_binary(diff) and is_binary(pr_body) and is_list(source_maps) do
    case PureSpecMembership.check(diff, pr_body, source_maps) do
      {:pass, []} ->
        []

      {:fail, violated_boundaries} ->
        Enum.map(violated_boundaries, fn boundary -> %{boundary: boundary} end)
    end
  end
end
