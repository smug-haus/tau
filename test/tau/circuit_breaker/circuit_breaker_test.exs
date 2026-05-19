defmodule Tau.CircuitBreakerTest do
  @moduledoc """
  Tests for `Tau.CircuitBreaker` façade (SPEC-CIRCUIT-BREAKER PR3).

  Covers:
  - AC-5: After `failure_threshold` failures, subsequent calls return
    `{:error, :circuit_open}` without invoking the thunk.
  - AC-6: After `cooldown_ms`, `call/3` admits exactly one probe; if the probe
    fails, subsequent calls are again `:circuit_open`.
  - AC-3b / D-043: All-breakers-open chain terminates in exactly N invocations.
  - Telemetry: `:check`, `:open`, and `:transition` events are emitted.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Tau.CircuitBreaker
  alias Tau.CircuitBreaker.State
  alias Tau.CircuitBreaker.Store

  @table Store.table()

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    case Process.whereis(Store) do
      nil -> {:ok, _pid} = start_supervised(Store)
      _pid -> :ok
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp failing_thunk, do: fn -> {:error, :provider_down} end
  defp ok_thunk, do: fn -> {:ok, :response} end

  defp thunk_counter do
    counter = :counters.new(1, [])

    thunk = fn ->
      :counters.add(counter, 1, 1)
      {:error, :provider_down}
    end

    {counter, thunk}
  end

  defp count_calls(counter), do: :counters.get(counter, 1)

  # Force `failure_threshold` failures to open the breaker.
  defp open_breaker(provider, threshold) do
    for _ <- 1..threshold do
      CircuitBreaker.call(provider, [failure_threshold: threshold], failing_thunk())
    end
  end

  # Force the ETS row into :half_open state by directly writing it, using the
  # opened_at_ms = 0 so that State.check sees cooldown elapsed. Then call
  # Store.transition to simulate the check+transition the façade would do.
  defp seed_half_open(provider) do
    # Insert an :open row with opened_at_ms = 0 (well in the past).
    :ets.insert(@table, {provider, :open, 5, 0, 0, 0})

    # Transition to :half_open explicitly (simulating cooldown elapsed).
    half_open = %State{
      state: :half_open,
      failure_count: 5,
      success_count: 0,
      opened_at_ms: 0,
      probe_slot: 0
    }

    1 = Store.transition(provider, :open, half_open)
  end

  # ---------------------------------------------------------------------------
  # AC-5: Thunk not called when breaker is :open
  # ---------------------------------------------------------------------------

  test "AC-5 — after failure_threshold failures, subsequent calls return {:error, :circuit_open} without calling thunk" do
    provider = :ac5_provider

    {counter, counting_thunk} = thunk_counter()

    threshold = 3

    for _ <- 1..threshold do
      result = CircuitBreaker.call(provider, [failure_threshold: threshold], counting_thunk)
      assert result == {:error, :provider_down}
    end

    assert count_calls(counter) == threshold,
           "thunk should have been called exactly threshold times"

    # Now the breaker should be :open
    assert Store.state_for(provider) == :open

    # Subsequent calls must not invoke the thunk
    result1 = CircuitBreaker.call(provider, [failure_threshold: threshold], counting_thunk)
    result2 = CircuitBreaker.call(provider, [failure_threshold: threshold], counting_thunk)

    assert result1 == {:error, :circuit_open}
    assert result2 == {:error, :circuit_open}
    assert count_calls(counter) == threshold, "thunk must not be called when breaker is :open"
  end

  # ---------------------------------------------------------------------------
  # AC-6: Half-open probe admission and re-open on probe failure
  # ---------------------------------------------------------------------------

  test "AC-6 — after cooldown, exactly one probe is admitted; probe failure re-opens the breaker" do
    provider = :ac6_provider
    {counter, counting_thunk} = thunk_counter()

    # Seed directly into :half_open with probe_slot = 0
    Store.ensure_row(provider)
    seed_half_open(provider)

    # First call: probe admitted, thunk runs, fails → re-opens
    result = CircuitBreaker.call(provider, [], counting_thunk)
    assert result == {:error, :provider_down}
    assert count_calls(counter) == 1

    # Breaker should be :open again
    assert Store.state_for(provider) == :open

    # Further calls: circuit is open, thunk not called
    result2 = CircuitBreaker.call(provider, [], counting_thunk)
    assert result2 == {:error, :circuit_open}
    assert count_calls(counter) == 1, "thunk must not be called after re-open"
  end

  test "AC-6 — probe success closes the breaker" do
    provider = :ac6_success_provider
    Store.ensure_row(provider)
    seed_half_open(provider)

    result = CircuitBreaker.call(provider, [], ok_thunk())
    assert result == {:ok, :response}

    assert Store.state_for(provider) == :closed
  end

  # ---------------------------------------------------------------------------
  # AC-6 — second concurrent probe is rejected (D-030 enforcement at façade level)
  # ---------------------------------------------------------------------------

  test "AC-6 — second probe_admitted? call is rejected → {:error, :circuit_open}" do
    provider = :ac6_concurrent_provider
    Store.ensure_row(provider)
    seed_half_open(provider)

    # Manually claim the probe slot
    assert Store.probe_admitted?(provider) == true
    # Now the slot is taken; a second call through the façade must be rejected
    # We simulate by directly calling probe_admitted? again
    assert Store.probe_admitted?(provider) == false

    # And a call through the façade with probe_slot already taken returns :circuit_open
    # Seed a fresh half_open row for the façade call
    provider2 = :ac6_concurrent_provider2
    Store.ensure_row(provider2)
    seed_half_open(provider2)

    # Claim the slot before the façade call
    assert Store.probe_admitted?(provider2) == true

    # Now façade sees :half_open but probe_admitted? returns false
    result = CircuitBreaker.call(provider2, [], ok_thunk())
    assert result == {:error, :circuit_open}
  end

  # ---------------------------------------------------------------------------
  # D-043: All-open chain terminates in exactly N invocations
  # ---------------------------------------------------------------------------

  @tag :property
  property "D-043 — all-open chain terminates in exactly N call/3 invocations" do
    check all(
            providers <- list_of(atom(:alphanumeric), min_length: 1, max_length: 10),
            max_runs: 50
          ) do
      :ets.delete_all_objects(@table)

      # Deduplicate providers (list_of may produce duplicates)
      providers = Enum.uniq(providers)
      n = length(providers)

      # Seed all providers as :open
      for p <- providers do
        :ets.insert(@table, {p, :open, 5, 0, System.monotonic_time(:millisecond), 0})
      end

      counter = :counters.new(1, [])

      tracking_thunk = fn ->
        :counters.add(counter, 1, 1)
        {:error, :provider_down}
      end

      results =
        Enum.map(providers, fn p ->
          CircuitBreaker.call(p, [], tracking_thunk)
        end)

      # Every result must be :circuit_open
      assert Enum.all?(results, &(&1 == {:error, :circuit_open})),
             "All results must be {:error, :circuit_open}"

      # The thunk must never have been called
      assert :counters.get(counter, 1) == 0,
             "Thunk must not be invoked when all breakers are :open (D-043)"

      # Invocation count equals list length — no retries or loops
      assert length(results) == n
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry: :check event is emitted
  # ---------------------------------------------------------------------------

  test "telemetry :check event is emitted on each call" do
    provider = :telemetry_check_provider
    test_pid = self()
    handler_id = {__MODULE__, :check, make_ref()}

    :telemetry.attach(
      handler_id,
      [:tau, :circuit_breaker, :check],
      fn [:tau, :circuit_breaker, :check], _meas, meta, _cfg ->
        send(test_pid, {:telemetry, :check, meta})
      end,
      nil
    )

    CircuitBreaker.call(provider, [], ok_thunk())

    :telemetry.detach(handler_id)

    assert_receive {:telemetry, :check, %{provider: ^provider}}, 500
  end

  # ---------------------------------------------------------------------------
  # Telemetry: :open event is emitted on short-circuit
  # ---------------------------------------------------------------------------

  test "telemetry :open event is emitted when call is short-circuited" do
    provider = :telemetry_open_provider
    open_breaker(provider, 5)

    test_pid = self()
    handler_id = {__MODULE__, :open, make_ref()}

    :telemetry.attach(
      handler_id,
      [:tau, :circuit_breaker, :open],
      fn [:tau, :circuit_breaker, :open], _meas, meta, _cfg ->
        send(test_pid, {:telemetry, :open, meta})
      end,
      nil
    )

    CircuitBreaker.call(provider, [], ok_thunk())

    :telemetry.detach(handler_id)

    assert_receive {:telemetry, :open, %{provider: ^provider}}, 500
  end

  # ---------------------------------------------------------------------------
  # Telemetry: :transition event is emitted on state change
  # ---------------------------------------------------------------------------

  test "telemetry :transition event is emitted when breaker opens" do
    provider = :telemetry_transition_provider
    test_pid = self()
    handler_id = {__MODULE__, :transition, make_ref()}

    :telemetry.attach(
      handler_id,
      [:tau, :circuit_breaker, :transition],
      fn [:tau, :circuit_breaker, :transition], _meas, meta, _cfg ->
        send(test_pid, {:telemetry, :transition, meta})
      end,
      nil
    )

    open_breaker(provider, 5)

    :telemetry.detach(handler_id)

    assert_receive {:telemetry, :transition, %{from: :closed, to: :open, provider: ^provider}}, 500
  end

  # ---------------------------------------------------------------------------
  # C56-B1 / C60-B1: atomic counter increments — no lost updates under concurrency
  # ---------------------------------------------------------------------------

  @tag :property
  property "C56-B1 — concurrent failures on :closed breaker produce exact failure_count" do
    check all(n <- integer(2..20), max_runs: 20) do
      provider = :"concurrent_failure_#{n}_#{System.unique_integer([:positive])}"
      :ets.delete_all_objects(@table)
      Store.ensure_row(provider)

      # Use a threshold high enough that the breaker stays :closed throughout
      # (we want to count increments, not transitions).
      threshold = n + 1
      opts = [failure_threshold: threshold]

      # Real barrier: spawn N processes; each blocks on :go before executing.
      # Once all N are ready (each sends :ready), coordinator broadcasts :go
      # so all N race to CircuitBreaker.call/3 simultaneously.
      parent = self()

      pids =
        for _ <- 1..n do
          spawn(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> :ok
            end

            CircuitBreaker.call(provider, opts, fn -> {:error, :concurrent_failure} end)
            send(parent, :done)
          end)
        end

      # Wait until all N processes are ready at the barrier.
      for _ <- 1..n, do: assert_receive({:ready, _pid}, 5_000)

      # Release all N simultaneously.
      for pid <- pids, do: send(pid, :go)

      # Wait for all to complete.
      for _ <- pids, do: assert_receive(:done, 5_000)

      # Each of the N calls must have bumped failure_count exactly once.
      # The row stays :closed (threshold = n+1) so no transition clobbers counters.
      [{_key, _state, final_count, _sc, _oat, _ps}] = :ets.lookup(@table, provider)

      assert final_count == n,
             "Expected failure_count == #{n}, got #{final_count} — lost update detected"
    end
  end

  @tag :property
  property "F1 fix — concurrent failures crossing :open threshold preserve exact failure_count" do
    check all(n <- integer(2..10), max_runs: 20) do
      provider = :"concurrent_open_#{n}_#{System.unique_integer([:positive])}"
      :ets.delete_all_objects(@table)
      Store.ensure_row(provider)

      # Set threshold == n so the nth failure triggers the :closed → :open transition.
      # If select_replace overwrites counter columns, the transition write races
      # with concurrent update_counter bumps and loses increments.
      threshold = n
      opts = [failure_threshold: threshold]

      parent = self()

      pids =
        for _ <- 1..n do
          spawn(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> :ok
            end

            CircuitBreaker.call(provider, opts, fn -> {:error, :concurrent_failure} end)
            send(parent, :done)
          end)
        end

      for _ <- 1..n, do: assert_receive({:ready, _pid}, 5_000)
      for pid <- pids, do: send(pid, :go)
      for _ <- pids, do: assert_receive(:done, 5_000)

      [{_key, final_state, final_count, _sc, _oat, _ps}] = :ets.lookup(@table, provider)

      # Breaker must have opened (threshold reached).
      assert final_state == :open,
             "Expected breaker to be :open, got #{final_state}"

      # failure_count must be >= threshold — no bump was lost at the transition.
      assert final_count >= threshold,
             "Expected failure_count >= #{threshold}, got #{final_count} — lost update at transition"
    end
  end

  # ---------------------------------------------------------------------------
  # :closed + success resets failure_count
  # ---------------------------------------------------------------------------

  test "success in :closed state resets failure_count" do
    provider = :closed_success_provider
    Store.ensure_row(provider)

    # Accumulate some failures (below threshold)
    CircuitBreaker.call(provider, [failure_threshold: 5], failing_thunk())
    CircuitBreaker.call(provider, [failure_threshold: 5], failing_thunk())

    assert Store.state_for(provider) == :closed

    # A success should reset failure_count
    CircuitBreaker.call(provider, [], ok_thunk())

    # Breaker remains closed
    assert Store.state_for(provider) == :closed

    # Now needs threshold failures to open again
    for _ <- 1..5 do
      CircuitBreaker.call(provider, [failure_threshold: 5], failing_thunk())
    end

    assert Store.state_for(provider) == :open
  end

  # ---------------------------------------------------------------------------
  # Full error term is preserved (C65-B3)
  # ---------------------------------------------------------------------------

  test "C65-B3 — full error term from thunk is returned unchanged" do
    provider = :c65_provider
    rich_error = {:error, %{code: 503, body: "service unavailable"}}
    result = CircuitBreaker.call(provider, [], fn -> rich_error end)
    assert result == rich_error
  end
end
