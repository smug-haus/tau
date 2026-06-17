defmodule Tau.Factory.Merge.Train do
  @moduledoc """
  Pure train assembler and bisector (SPEC-FACTORY-MERGE §2 C2).

  ## assemble/2

  Picks a batch of `B >= 1` units from the wait-queue under the fair FIFO+aging
  policy (LIV-2 / D-341). Currently returns the full queue as the batch --
  `Merge.Queue` owns the aging priority ordering.

  ## bisect/3

  `O(log B)` culprit search on a red-tip batch (SPEC-FACTORY-MERGE §2 C2,
  D-303, INV-MAI-8). When a combined health check on a batch tip is red, M
  does not know which member is the culprit. `bisect/3` recursively halves the
  train, calling `build_fun` on each sub-train until the single culprit is
  identified.

  Returns `{:culprit, culprit_unit, survivors}` where `survivors` is the
  sub-list of train members that are NOT the culprit. The caller (M's
  `:integrating` state handler) ejects the culprit and re-queues the survivors
  for re-integration.

  Invariant: the bisect always terminates with a single culprit because the
  base case is a singleton train (`B = 1`).

  This module has no process state -- it is a pure computation module
  (OTP non-negotiable #3: MUST NOT wrap stateless logic in a GenServer).
  """

  @doc """
  Identify the culprit in a health-red train by binary search.

  ## Parameters

    - `train` -- the list of unit maps currently in the train; MUST be non-empty.
    - `build_fun` -- `(units, base) -> {:built, units, base, tip} | {:build_failed, reason}`
    - `base` -- the `origin/main` OID captured at the start of the build cycle.

  ## Return value

    - `{:culprit, culprit_unit, survivors}` where `culprit_unit` is the map of
      the unit that caused the health-red, and `survivors` is every other
      member of the original train.

  ## Complexity

  `O(log B)` calls to `build_fun` in the worst case.
  """
  @spec bisect([map()], (list(), term() -> term()), term()) ::
          {:culprit, map(), [map()]}
  def bisect([unit], _build_fun, _base) do
    # Base case: singleton train -- this unit is the culprit.
    {:culprit, unit, []}
  end

  def bisect(train, build_fun, base) when length(train) > 1 do
    mid = div(length(train), 2)
    {left, right} = Enum.split(train, mid)

    case build_fun.(left, base) do
      {:build_failed, {:health_red, _}} ->
        # Culprit is somewhere in the left half.  Recurse left; survivors from
        # the right half are all innocent.
        {:culprit, culprit, left_survivors} = bisect(left, build_fun, base)
        {:culprit, culprit, left_survivors ++ right}

      _ok ->
        # Left half is green (or at least not health-red); culprit is in the
        # right half.
        {:culprit, culprit, right_survivors} = bisect(right, build_fun, base)
        {:culprit, culprit, left ++ right_survivors}
    end
  end
end
