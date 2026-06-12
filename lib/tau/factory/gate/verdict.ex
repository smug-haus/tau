defmodule Tau.Factory.Gate.Verdict do
  @moduledoc """
  The folded output of `Tau.Factory.Gate.run/1`.

  ## Fields

  - `:status`  — `:pass` iff every half in the engine-fixed floor passed; `:fail`
                 otherwise.
  - `:halves`  — a map of `half_id => half_result` for every half that was run
                 (keyed by atom, e.g. `%{mutation: ..., critic: ..., reviewer: ...}`).
                 The fold preserves per-half provenance for the Ledger (D-335) and
                 the critic adjudication path (D-308).

  ## `fold/1`

  Accepts a list of `{half_id, result}` pairs (where `result` is `:pass`, `:fail`,
  or `{:error, reason}`). Returns a `%Verdict{}` where:
  - `status = :pass` iff every half returned `:pass`.
  - `status = :fail` if any half returned `:fail` or an error tuple.
  - `halves` maps each half id to its result.
  """

  @type half_id :: atom()
  @type half_result :: :pass | :fail | {:error, term()}

  @type t :: %__MODULE__{
          status: :pass | :fail,
          halves: %{half_id() => half_result()}
        }

  defstruct [:status, :halves]

  @doc """
  Fold a list of `{half_id, result}` pairs into a single `%Verdict{}`.

  PASS iff every result is `:pass`. Any `:fail` or error tuple folds to FAIL.
  An empty list folds to FAIL (no halves ran — vacuous, not a pass).
  """
  @spec fold([{half_id(), half_result()}]) :: t()
  def fold(half_results) when is_list(half_results) do
    halves = Map.new(half_results, fn {id, result} -> {id, result} end)

    status =
      cond do
        halves == %{} ->
          :fail

        Enum.all?(half_results, fn {_id, result} -> result == :pass end) ->
          :pass

        true ->
          :fail
      end

    %__MODULE__{status: status, halves: halves}
  end
end
