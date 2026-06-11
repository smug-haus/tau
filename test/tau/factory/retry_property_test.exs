defmodule Tau.Factory.RetryPropertyTest do
  @moduledoc """
  StreamData property suite for `Tau.Factory.Retry` (SPEC-FACTORY-CORE §4,
  §6 D-318, AC-5).

  Pinned interface:

    `next(outcome, refine_count, pivot_count) ::
       {:refine, non_neg_integer()} | :pivot | :exhausted`

  Pinned constants (D-318 / retry-strategy):

    N_REFINE = 3   (maximum refines before pivot)
    N_PIVOT  = 1   (maximum pivot attempts before exhausted)

  Total attempts ≤ N_REFINE + N_PIVOT before :exhausted is mandatory.

  Properties:

  * Bounded: no outcome sequence drives the ladder beyond N_REFINE + N_PIVOT
    non-terminal steps before :exhausted.
  * Ordered: refines (up to N_REFINE) precede the pivot; pivot precedes
    :exhausted.
  * Terminal: once :exhausted is returned, there is no state to continue from
    (the function with maxed counts returns :exhausted regardless of outcome).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  @retry_mod Tau.Factory.Retry

  # Pinned bounds from SPEC-FACTORY-CORE D-318 + retry-strategy skill.
  @n_refine 3
  @n_pivot 1

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp outcome_gen do
    StreamData.one_of([
      StreamData.constant(:gate_fail),
      StreamData.constant(:gate_pass),
      StreamData.map(StreamData.string(:alphanumeric, min_length: 1), &{:error, &1})
    ])
  end

  # Generates a list of outcomes to drive the ladder through.
  defp outcome_seq_gen do
    StreamData.list_of(outcome_gen(), min_length: 1, max_length: @n_refine + @n_pivot + 3)
  end

  # ---------------------------------------------------------------------------
  # Fold helper
  # ---------------------------------------------------------------------------

  # Drives the ladder through a sequence of outcomes, threading {refine_count,
  # pivot_count}. Returns the list of decisions and the step count of the first
  # :exhausted (or nil if never reached).
  defp run_ladder(outcomes) do
    Enum.reduce_while(outcomes, {0, 0, []}, fn outcome, {rc, pc, acc} ->
      decision = @retry_mod.next(outcome, rc, pc)

      case decision do
        {:refine, k} ->
          {:cont, {k + 1, pc, [{:refine, k} | acc]}}

        :pivot ->
          {:cont, {rc, pc + 1, [:pivot | acc]}}

        :exhausted ->
          {:halt, {rc, pc, [:exhausted | acc]}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  @tag :ac_5
  @tag :d_318
  property "bounded: no sequence yields more than N_REFINE + N_PIVOT non-terminal steps before :exhausted (AC-5 / D-318)" do
    check all(outcomes <- outcome_seq_gen()) do
      {_rc, _pc, decisions} = run_ladder(outcomes)
      decisions_rev = Enum.reverse(decisions)

      non_terminal_count =
        Enum.count(decisions_rev, fn d ->
          match?({:refine, _}, d) or d == :pivot
        end)

      assert non_terminal_count <= @n_refine + @n_pivot,
             "Ladder exceeded bound: #{non_terminal_count} non-terminal steps " <>
               "(max #{@n_refine + @n_pivot}). Decisions: #{inspect(decisions_rev)}"
    end
  end

  @tag :ac_5
  @tag :d_318
  property "ordered: all {:refine, _} decisions precede any :pivot decision (AC-5 / D-318)" do
    check all(outcomes <- outcome_seq_gen()) do
      {_rc, _pc, decisions} = run_ladder(outcomes)
      decisions_rev = Enum.reverse(decisions)

      pivot_idx = Enum.find_index(decisions_rev, &(&1 == :pivot))

      refine_after_pivot_count =
        if pivot_idx do
          decisions_rev
          |> Enum.drop(pivot_idx + 1)
          |> Enum.count(&match?({:refine, _}, &1))
        else
          0
        end

      assert refine_after_pivot_count == 0,
             "Found {:refine, _} after :pivot. Decisions: #{inspect(decisions_rev)}"
    end
  end

  @tag :ac_5
  @tag :d_318
  property "ordered: :pivot precedes :exhausted (AC-5 / D-318)" do
    check all(outcomes <- outcome_seq_gen()) do
      {_rc, _pc, decisions} = run_ladder(outcomes)
      decisions_rev = Enum.reverse(decisions)

      exhausted_idx = Enum.find_index(decisions_rev, &(&1 == :exhausted))

      pivot_after_exhausted =
        if exhausted_idx do
          decisions_rev
          |> Enum.drop(exhausted_idx + 1)
          |> Enum.any?(&(&1 == :pivot))
        else
          false
        end

      refute pivot_after_exhausted,
             "Found :pivot after :exhausted. Decisions: #{inspect(decisions_rev)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Example-based: terminal boundary conditions
  # ---------------------------------------------------------------------------

  @tag :ac_5
  @tag :d_318
  test "next/3 with refine_count < N_REFINE returns {:refine, k} (AC-5 / D-318)" do
    for k <- 0..(@n_refine - 1) do
      result = @retry_mod.next(:gate_fail, k, 0)

      assert match?({:refine, _}, result),
             "Expected {:refine, _} at refine_count=#{k}, got #{inspect(result)}"
    end
  end

  @tag :ac_5
  @tag :d_318
  test "next/3 with refine_count >= N_REFINE and pivot_count < N_PIVOT returns :pivot (AC-5 / D-318)" do
    result = @retry_mod.next(:gate_fail, @n_refine, 0)

    assert result == :pivot,
           "Expected :pivot at refine_count=#{@n_refine}, pivot_count=0, got #{inspect(result)}"
  end

  @tag :ac_5
  @tag :d_318
  test "next/3 with refine_count >= N_REFINE and pivot_count >= N_PIVOT returns :exhausted (AC-5 / D-318)" do
    result = @retry_mod.next(:gate_fail, @n_refine, @n_pivot)

    assert result == :exhausted,
           "Expected :exhausted at refine_count=#{@n_refine}, pivot_count=#{@n_pivot}, got #{inspect(result)}"
  end

  @tag :ac_5
  @tag :d_318
  test "next/3 returns :exhausted for any outcome when both counts are at ceiling (AC-5 / D-318)" do
    for outcome <- [:gate_fail, :gate_pass, {:error, "test"}] do
      result = @retry_mod.next(outcome, @n_refine, @n_pivot)

      assert result == :exhausted,
             "Expected :exhausted for outcome=#{inspect(outcome)}, got #{inspect(result)}"
    end
  end
end
