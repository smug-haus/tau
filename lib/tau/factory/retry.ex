defmodule Tau.Factory.Retry do
  @moduledoc """
  Pure retry-ladder for per-PR outcome decisions (SPEC-FACTORY-CORE §4, D-318).

  Implements the bounded refine → pivot → exhausted ladder from
  `factory-loop.md` §Outcomes and the `retry-strategy` skill.

  Constants (D-318):

    N_REFINE = 3  — maximum refine steps before pivot
    N_PIVOT  = 1  — maximum pivot attempts before exhausted

  Total non-terminal steps ≤ N_REFINE + N_PIVOT = 4.
  """

  @n_refine 3
  @n_pivot 1

  @doc "Maximum refine steps before pivot (D-318)."
  @spec n_refine() :: non_neg_integer()
  def n_refine, do: @n_refine

  @doc "Maximum pivot attempts before exhausted (D-318)."
  @spec n_pivot() :: non_neg_integer()
  def n_pivot, do: @n_pivot

  @doc """
  Returns the next ladder decision given an outcome and the current counters.

  The ladder (D-318):

    refine_count < N_REFINE                          → {:refine, refine_count}
    refine_count >= N_REFINE, pivot_count < N_PIVOT  → :pivot
    refine_count >= N_REFINE, pivot_count >= N_PIVOT → :exhausted

  The decision is independent of `outcome` — the caller decides whether the
  outcome warrants progression. All outcomes (`:gate_fail`, `:gate_pass`,
  `{:error, _}`) apply the same counter-based ladder, so the function is
  total and bounded regardless of the outcome sequence.
  """
  @spec next(term(), non_neg_integer(), non_neg_integer()) ::
          {:refine, non_neg_integer()} | :pivot | :exhausted
  def next(_outcome, refine_count, pivot_count)
      when refine_count >= @n_refine and pivot_count >= @n_pivot do
    :exhausted
  end

  def next(_outcome, refine_count, _pivot_count) when refine_count >= @n_refine do
    :pivot
  end

  def next(_outcome, refine_count, _pivot_count) do
    {:refine, refine_count}
  end
end
