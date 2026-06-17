defmodule Tau.Factory.Lineage do
  @moduledoc """
  Audit lineage record for a merged PR unit (D-353 / NFR-AUDIT).

  Every merge must be fully traceable along the chain:

      main_commit → gate_verdicts → gating_test_paths → claims(AC/D-NNN) → specs → issues

  with **no null edge**. The `%Lineage{}` row is written in the same transaction
  as the merge record (WAL before the merge ack), so an audit can never observe a
  merge without its lineage.

  See `SPEC-FACTORY-GOV §4 B10 / §6 D-353`.
  """

  @enforce_keys [
    :main_commit,
    :unit_id,
    :gate_verdicts,
    :gating_test_paths,
    :claims,
    :specs,
    :issues
  ]

  defstruct [
    :main_commit,
    :unit_id,
    :gate_verdicts,
    :gating_test_paths,
    :claims,
    :specs,
    :issues
  ]

  @type verdict :: %{
          half: :critic | :reviewer | :mutation,
          verdict: :pass | :fail,
          diff_hash: String.t()
        }

  @type t :: %__MODULE__{
          main_commit: String.t(),
          unit_id: String.t(),
          gate_verdicts: [verdict()],
          gating_test_paths: [String.t()],
          claims: [String.t()],
          specs: [String.t()],
          issues: [String.t()]
        }
end
