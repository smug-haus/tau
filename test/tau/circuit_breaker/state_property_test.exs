defmodule Tau.CircuitBreaker.StatePropertyTest do
  @moduledoc """
  Properties that pin `Tau.CircuitBreaker.State` (SPEC-CIRCUIT-BREAKER §4 B4).

  Enforces D-029: for any `%State{}` and any `now_ms`, `check/2` returns
  exactly one of `:closed`, `:open`, `:half_open`; all functions are total.

  Invariants tested:

  * `check/2` always returns one of the three valid state atoms.
  * N consecutive failures in `:closed` state cause transition to `:open`
    once the failure count reaches `failure_threshold`.
  * A success in `:closed` state resets `failure_count` to 0.
  * `record_failure/2` on an `:open` breaker is a no-op.
  * `record_success/2` on an `:half_open` breaker with `success_threshold = 1`
    immediately closes it.
  * `record_failure/2` on a `:half_open` breaker transitions to `:open`.
  * `check/2` never returns `:half_open` before `cooldown_ms` has elapsed.
  * State is always one of `:closed`, `:open`, `:half_open`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.CircuitBreaker.State

  @moduletag :property

  @valid_states [:closed, :open, :half_open]

  # Default cooldown used by State.check/2
  @default_cooldown_ms 30_000

  defp now_ms_gen, do: StreamData.integer(0..10_000_000)
  defp threshold_gen, do: StreamData.integer(1..20)
  defp count_gen, do: StreamData.integer(0..50)

  defp closed_state_gen do
    StreamData.bind(count_gen(), fn fc ->
      StreamData.constant(%State{state: :closed, failure_count: fc, success_count: 0})
    end)
  end

  defp open_state_gen do
    StreamData.bind(
      StreamData.tuple({now_ms_gen(), count_gen()}),
      fn {opened_at, fc} ->
        StreamData.constant(%State{
          state: :open,
          failure_count: fc,
          success_count: 0,
          opened_at_ms: opened_at
        })
      end
    )
  end

  defp half_open_state_gen do
    StreamData.bind(count_gen(), fn sc ->
      StreamData.constant(%State{state: :half_open, success_count: sc, failure_count: 0})
    end)
  end

  defp any_state_gen do
    StreamData.one_of([closed_state_gen(), open_state_gen(), half_open_state_gen()])
  end

  property "check/2 always returns a valid state atom (D-029)" do
    check all(
            s <- any_state_gen(),
            now_ms <- now_ms_gen()
          ) do
      result = State.check(s, now_ms)
      assert result in @valid_states
    end
  end

  property "state field is always one of the three valid atoms after record_failure/2" do
    check all(
            s <- any_state_gen(),
            now_ms <- now_ms_gen(),
            threshold <- threshold_gen()
          ) do
      s2 = State.record_failure(s, failure_threshold: threshold, now_ms: now_ms)
      assert s2.state in @valid_states
    end
  end

  property "state field is always one of the three valid atoms after record_success/2" do
    check all(
            s <- any_state_gen(),
            threshold <- threshold_gen()
          ) do
      s2 = State.record_success(s, success_threshold: threshold)
      assert s2.state in @valid_states
    end
  end

  property "N consecutive failures in :closed cause transition to :open at threshold" do
    check all(
            threshold <- threshold_gen(),
            now_ms <- now_ms_gen()
          ) do
      opts = [failure_threshold: threshold, now_ms: now_ms]

      final_state =
        Enum.reduce(1..threshold, %State{}, fn _, acc -> State.record_failure(acc, opts) end)

      assert final_state.state == :open
    end
  end

  property "fewer than threshold failures leave breaker :closed" do
    check all(
            threshold <- StreamData.integer(2..20),
            n <- StreamData.integer(1..(threshold - 1)),
            now_ms <- now_ms_gen()
          ) do
      opts = [failure_threshold: threshold, now_ms: now_ms]
      final_state = Enum.reduce(1..n, %State{}, fn _, acc -> State.record_failure(acc, opts) end)
      assert final_state.state == :closed
      assert final_state.failure_count == n
    end
  end

  property "record_success/2 in :closed resets failure_count to 0" do
    check all(s <- closed_state_gen()) do
      s2 = State.record_success(s)
      assert s2.state == :closed
      assert s2.failure_count == 0
    end
  end

  property "record_failure/2 on :open state is a no-op" do
    check all(
            s <- open_state_gen(),
            now_ms <- now_ms_gen(),
            threshold <- threshold_gen()
          ) do
      s2 = State.record_failure(s, failure_threshold: threshold, now_ms: now_ms)
      assert s2 == s
    end
  end

  property "record_success/2 on :half_open with success_threshold=1 closes the breaker" do
    check all(s <- half_open_state_gen()) do
      s2 = State.record_success(s, success_threshold: 1)
      assert s2.state == :closed
      assert s2.failure_count == 0
      assert s2.success_count == 0
    end
  end

  property "record_failure/2 on :half_open transitions back to :open" do
    check all(
            s <- half_open_state_gen(),
            now_ms <- now_ms_gen()
          ) do
      s2 = State.record_failure(s, now_ms: now_ms)
      assert s2.state == :open
      assert s2.opened_at_ms == now_ms
    end
  end

  property "check/2 never returns :half_open before cooldown_ms has elapsed" do
    check all(
            opened_at_ms <- now_ms_gen(),
            # delta strictly less than the default cooldown threshold
            delta <- StreamData.integer(0..(@default_cooldown_ms - 1))
          ) do
      now_ms = opened_at_ms + delta
      s = %State{state: :open, opened_at_ms: opened_at_ms}
      result = State.check(s, now_ms)
      # Should still be :open (default cooldown not elapsed)
      assert result == :open
    end
  end

  property "check/2 returns :half_open once default cooldown_ms has elapsed" do
    check all(
            opened_at_ms <- StreamData.integer(0..5_000_000),
            extra <- StreamData.integer(0..10_000)
          ) do
      now_ms = opened_at_ms + @default_cooldown_ms + extra
      s = %State{state: :open, opened_at_ms: opened_at_ms}
      result = State.check(s, now_ms)
      assert result == :half_open
    end
  end
end
