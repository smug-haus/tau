defmodule Tau.CircuitBreaker.StorePropertyTest do
  @moduledoc """
  Property tests for `Tau.CircuitBreaker.Store` (SPEC-CIRCUIT-BREAKER PR2).

  Covers:
  - D-030: Probe admission is exclusive under concurrency — exactly one of N
    concurrent callers is admitted for a `:half_open` breaker.
  - D-044: Row layout is positional and fixed; transitions preserve all fields.
  - Transition CAS semantics: a stale `current_state` guard returns 0 (no-op);
    a matching guard returns 1.
  - `ensure_row/1` is idempotent; `state_for/1` defaults to `:closed` (C64-B1).
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Tau.CircuitBreaker.State
  alias Tau.CircuitBreaker.Store

  @table Store.table()

  @moduletag :property

  # ---------------------------------------------------------------------------
  # Setup: start Store if not already running; reset table between tests.
  # ---------------------------------------------------------------------------

  setup do
    case Process.whereis(Store) do
      nil ->
        {:ok, _pid} = start_supervised(Store)

      _pid ->
        :ok
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  # ---------------------------------------------------------------------------
  # D-030: Probe admission exclusivity under concurrency
  # ---------------------------------------------------------------------------

  property "D-030 — exactly one of N concurrent probe_admitted? calls succeeds" do
    check all(
            n <- integer(2..20),
            provider <- atom(:alphanumeric),
            max_runs: 50
          ) do
      :ets.delete_all_objects(@table)

      # Seed a half_open row with probe_slot = 0
      :ets.insert(@table, {provider, :half_open, 3, 0, 0, 0})

      parent = self()

      # Spawn N processes that all race probe_admitted?/1 simultaneously
      pids =
        for _ <- 1..n do
          spawn(fn ->
            # Synchronise: wait for :go signal
            receive do
              :go ->
                result = Store.probe_admitted?(provider)
                send(parent, {:result, result})
            end
          end)
        end

      # Fire them all at once
      Enum.each(pids, &send(&1, :go))

      results =
        for _ <- 1..n do
          receive do
            {:result, r} -> r
          after
            5_000 -> flunk("timed out waiting for probe result")
          end
        end

      admitted_count = Enum.count(results, & &1)
      rejected_count = Enum.count(results, &(!&1))

      assert admitted_count == 1,
             "Expected exactly 1 admitted probe, got #{admitted_count} (n=#{n})"

      assert rejected_count == n - 1,
             "Expected #{n - 1} rejected probes, got #{rejected_count}"
    end
  end

  # ---------------------------------------------------------------------------
  # Transition CAS semantics
  # ---------------------------------------------------------------------------

  property "transition/3 with matching current_state returns 1 and updates row" do
    check all(
            provider <- atom(:alphanumeric),
            max_runs: 50
          ) do
      :ets.delete_all_objects(@table)
      Store.ensure_row(provider)

      assert Store.state_for(provider) == :closed

      new_state = %State{
        state: :open,
        failure_count: 5,
        success_count: 0,
        opened_at_ms: 1_000_000,
        probe_slot: 0
      }

      result = Store.transition(provider, :closed, new_state)
      assert result == 1, "Expected CAS to succeed (return 1)"
      assert Store.state_for(provider) == :open
    end
  end

  property "transition/3 with stale current_state returns 0 (no-op)" do
    check all(
            provider <- atom(:alphanumeric),
            max_runs: 50
          ) do
      :ets.delete_all_objects(@table)
      Store.ensure_row(provider)

      # Row is :closed; pass :open as the "current" state — a stale guard
      new_state = %State{
        state: :half_open,
        failure_count: 0,
        success_count: 0,
        opened_at_ms: 0,
        probe_slot: 0
      }

      result = Store.transition(provider, :open, new_state)
      assert result == 0, "Expected stale CAS to fail (return 0)"
      # Row must be unchanged
      assert Store.state_for(provider) == :closed
    end
  end

  # ---------------------------------------------------------------------------
  # ensure_row/1 idempotency
  # ---------------------------------------------------------------------------

  property "ensure_row/1 is idempotent — repeated calls do not reset existing state" do
    check all(
            provider <- atom(:alphanumeric),
            max_runs: 50
          ) do
      :ets.delete_all_objects(@table)

      # First call: inserts default row
      Store.ensure_row(provider)
      assert Store.state_for(provider) == :closed

      # Transition to :open
      new_state = %State{
        state: :open,
        failure_count: 5,
        success_count: 0,
        opened_at_ms: 1_000,
        probe_slot: 0
      }

      assert Store.transition(provider, :closed, new_state) == 1

      # Second ensure_row call must not overwrite the :open row
      Store.ensure_row(provider)
      assert Store.state_for(provider) == :open
    end
  end

  # ---------------------------------------------------------------------------
  # state_for/1 defaults to :closed for unknown providers (C64-B1)
  # ---------------------------------------------------------------------------

  property "state_for/1 returns :closed for providers with no row (C64-B1)" do
    check all(
            provider <- atom(:alphanumeric),
            max_runs: 50
          ) do
      :ets.delete_all_objects(@table)
      assert Store.state_for(provider) == :closed
    end
  end

  # ---------------------------------------------------------------------------
  # D-044: Field positions are stable across transitions
  # ---------------------------------------------------------------------------

  property "D-044 — transition writes state columns; counter columns preserved from ETS" do
    check all(
            provider <- atom(:alphanumeric),
            pre_fc <- integer(0..20),
            pre_sc <- integer(0..5),
            oat <- integer(0..1_000_000),
            max_runs: 50
          ) do
      :ets.delete_all_objects(@table)
      Store.ensure_row(provider)

      # Seed counters via atomic bumps so ETS holds known values.
      for _ <- 1..pre_fc//1, do: Store.bump_failure_count(provider)
      for _ <- 1..pre_sc//1, do: Store.bump_success_count(provider)

      new_state = %State{
        state: :open,
        # counter fields in new_state are intentionally different — must be ignored
        failure_count: 999,
        success_count: 999,
        opened_at_ms: oat,
        probe_slot: 0
      }

      assert Store.transition(provider, :closed, new_state) == 1

      # Read raw row and assert field positions match D-044.
      [{row_key, row_state, row_fc, row_sc, row_oat, row_probe_slot}] =
        :ets.lookup(@table, provider)

      assert row_key == provider
      assert row_state == :open
      # Counter columns are PRESERVED from ETS, not taken from new_state.
      assert row_fc == pre_fc, "failure_count must be preserved from ETS, not overwritten"
      assert row_sc == pre_sc, "success_count must be preserved from ETS, not overwritten"
      assert row_oat == oat
      assert row_probe_slot == 0
    end
  end

  # ---------------------------------------------------------------------------
  # probe_slot resets correctly after transition to :half_open
  # ---------------------------------------------------------------------------

  property "probe_slot is 0 after transition to :half_open; first admission wins, second rejected" do
    check all(
            provider <- atom(:alphanumeric),
            max_runs: 30
          ) do
      :ets.delete_all_objects(@table)
      Store.ensure_row(provider)

      # Transition to :open
      open_state = %State{
        state: :open,
        failure_count: 5,
        success_count: 0,
        opened_at_ms: 0,
        probe_slot: 0
      }

      assert Store.transition(provider, :closed, open_state) == 1

      # Transition to :half_open (simulating cooldown elapsed)
      half_open_state = %State{
        state: :half_open,
        failure_count: 5,
        success_count: 0,
        opened_at_ms: 0,
        probe_slot: 0
      }

      assert Store.transition(provider, :open, half_open_state) == 1

      # probe_slot should be 0; first admission wins
      assert Store.probe_admitted?(provider) == true
      # Second call should be rejected
      assert Store.probe_admitted?(provider) == false
    end
  end
end
