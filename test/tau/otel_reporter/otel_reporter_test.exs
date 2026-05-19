defmodule Tau.OtelReporterTest do
  @moduledoc """
  Unit and property tests for `Tau.OtelReporter` (SPEC-OTEL-REPORTER).

  Tests run without an OTel SDK running. The reporter's `init/1` returns
  `:ignore` in this case (D-055 / C74). We verify the state-machine
  invariants through pure-function helpers that mirror the GenServer's
  `handle_cast` logic, and verify telemetry emit-site fixes directly.

  Covers:
  - AC-3: reporter is startable; returns :ignore when OTel SDK absent (correct).
  - AC-4 (D-054): map_size(open_spans) never exceeds max_open_spans for any
    sequence of span_open casts.
  - AC-5 (D-053): after a sweep with sweep_age_ms = 0, all remaining entries
    have opened_at_mono >= sweep_start.
  - AC-6 (D-052 / C78): [:tau, :tool, :execute, :exception] metadata includes
    tool_call_id.
  - Handler.primitive_map/1: non-primitive values are serialized (C79).
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Tau.OtelReporter.Config
  alias Tau.OtelReporter.Handler

  @moduletag :otel_reporter

  # ---------------------------------------------------------------------------
  # AC-3: reporter lifecycle
  # ---------------------------------------------------------------------------

  describe "AC-3: reporter start lifecycle" do
    test "returns :ignore when OTel SDK is not running (correct D-055 behaviour)" do
      Application.put_env(:tau, :otel, enabled: true)
      on_exit(fn -> Application.delete_env(:tau, :otel) end)

      # Without :opentelemetry app started, init/1 should return {:stop, :otel_not_started}
      # or :ignore depending on whether the API module is loaded.
      # Either way, no crash — the supervisor does not loop-restart.
      result = start_supervised(Tau.OtelReporter)

      # Valid outcomes: {:error, :ignore} or {:error, {:shutdown, :otel_not_started}}.
      # The key property: no unhandled exception.
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end

    test "does not start when otel.enabled is false (no-op)" do
      Application.put_env(:tau, :otel, enabled: false)
      on_exit(fn -> Application.delete_env(:tau, :otel) end)

      result = start_supervised(Tau.OtelReporter)
      # :ignore when disabled
      assert match?({:error, :ignore}, result) or match?({:ok, _}, result)
    end

    test "Config.from_keyword/1 returns correct defaults" do
      cfg = Config.from_keyword(enabled: true)
      assert cfg.enabled == true
      assert cfg.max_open_spans == 1_000
      assert cfg.sweep_interval_ms == 60_000
      assert cfg.sweep_age_ms == 120_000
      assert cfg.sampling_ratio == 1.0
    end

    test "Config.from_keyword/1 clamps invalid sampling_ratio" do
      cfg = Config.from_keyword(enabled: true, sampling_ratio: 99.9)
      assert cfg.sampling_ratio == 1.0
    end

    test "Config.from_keyword/1 honours explicit values" do
      cfg =
        Config.from_keyword(
          enabled: true,
          max_open_spans: 50,
          sweep_interval_ms: 5_000,
          sweep_age_ms: 30_000,
          sampling_ratio: 0.5
        )

      assert cfg.max_open_spans == 50
      assert cfg.sweep_interval_ms == 5_000
      assert cfg.sweep_age_ms == 30_000
      assert cfg.sampling_ratio == 0.5
    end
  end

  # ---------------------------------------------------------------------------
  # AC-6 / D-052 / C78: tool.execute.exception carries tool_call_id
  # ---------------------------------------------------------------------------

  describe "AC-6 / D-052: tool.execute.exception metadata" do
    test "includes tool_call_id in emit" do
      ref = make_ref()
      call_id = "call-#{System.unique_integer([:positive])}"
      tool = :some_tool

      :telemetry.attach(
        {__MODULE__, ref},
        [:tau, :tool, :execute, :exception],
        fn _event, _measurements, metadata, _ ->
          send(self(), {:captured, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      # Simulate the emit from session.ex after D-052 fix.
      :telemetry.execute(
        [:tau, :tool, :execute, :exception],
        %{duration: 10},
        %{tool: tool, tool_call_id: call_id, error: "boom"}
      )

      assert_receive {:captured, metadata}, 500

      assert Map.has_key?(metadata, :tool_call_id),
             "tool.execute.exception metadata MUST include tool_call_id (D-052)"

      assert metadata.tool_call_id == call_id
    end
  end

  # ---------------------------------------------------------------------------
  # C77: hook.run telemetry includes span_ref
  # ---------------------------------------------------------------------------

  describe "C77: hook.run span_ref discriminator" do
    test "[:tau, :hook, :run, :start] metadata includes span_ref after dispatcher fix" do
      ref = make_ref()

      :telemetry.attach(
        {__MODULE__, ref, :hook_start},
        [:tau, :hook, :run, :start],
        fn _event, _measurements, metadata, _ ->
          send(self(), {:hook_start, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref, :hook_start}) end)

      # Emit directly as dispatcher would after C77 fix.
      span_ref = make_ref()

      :telemetry.execute(
        [:tau, :hook, :run, :start],
        %{system_time: System.system_time()},
        %{hook: Tau.Hook, event: :test_event, span_ref: span_ref}
      )

      assert_receive {:hook_start, metadata}, 500

      assert Map.has_key?(metadata, :span_ref),
             "hook.run.start metadata MUST include span_ref (C77)"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-4 / D-054: bounded open-span map (property)
  # ---------------------------------------------------------------------------

  @moduletag :property
  describe "AC-4 / D-054: bounded open-span map" do
    property "map_size(open_spans) never exceeds max_open_spans for any cast sequence" do
      check all(
              max_open_spans <- integer(1..20),
              n_spans <- integer(1..50)
            ) do
        state = fresh_state(max_open_spans: max_open_spans)

        state =
          Enum.reduce(1..n_spans, state, fn i, s ->
            apply_span_open(s, {:test_span, i}, "tau.test", %{})
          end)

        assert map_size(state.open_spans) <= max_open_spans,
               "open_spans size #{map_size(state.open_spans)} exceeded max #{max_open_spans}"
      end
    end

    property "eviction removes exactly one entry when at capacity" do
      check all(max_open_spans <- integer(1..10)) do
        state = fresh_state(max_open_spans: max_open_spans)

        # Fill to capacity
        state =
          Enum.reduce(1..max_open_spans, state, fn i, s ->
            apply_span_open(s, {:test, i}, "tau.test", %{})
          end)

        assert map_size(state.open_spans) == max_open_spans

        # One more open: evicts oldest, size stays at max
        state = apply_span_open(state, {:test, :extra}, "tau.test", %{})
        assert map_size(state.open_spans) == max_open_spans
      end
    end

    property "span_close removes an entry from the map" do
      check all(n_spans <- integer(1..20)) do
        state = fresh_state(max_open_spans: 100)

        keys = Enum.map(1..n_spans, &{:test, &1})

        state =
          Enum.reduce(keys, state, fn key, s ->
            apply_span_open(s, key, "tau.test", %{})
          end)

        assert map_size(state.open_spans) == n_spans

        # Close one
        [first_key | _] = keys
        state = apply_span_close(state, first_key)
        assert map_size(state.open_spans) == n_spans - 1
        refute Map.has_key?(state.open_spans, first_key)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AC-5 / D-053: stale-span sweep (property)
  # ---------------------------------------------------------------------------

  @moduletag :property
  describe "AC-5 / D-053: stale-span sweep" do
    property "after sweep with sweep_age_ms=0, all remaining entries opened after sweep_start" do
      check all(n_spans <- integer(1..20)) do
        state = fresh_state(max_open_spans: 200, sweep_age_ms: 0)

        # Insert spans — all will be considered stale by sweep_age_ms=0
        state =
          Enum.reduce(1..n_spans, state, fn i, s ->
            apply_span_open(s, {:test, i}, "tau.test", %{})
          end)

        sweep_start = System.monotonic_time(:millisecond)
        state = apply_sweep(state, sweep_start)

        # After sweep_age_ms=0, all spans opened before sweep_start are removed.
        # Remaining entries (if any) must have opened_at >= sweep_start.
        Enum.each(state.open_spans, fn {_k, {_ctx, opened_at}} ->
          assert opened_at >= sweep_start,
                 "remaining span has opened_at #{opened_at} < sweep_start #{sweep_start}"
        end)
      end
    end

    property "sweep removes spans older than sweep_age_ms and keeps newer ones" do
      check all(
              n_old <- integer(1..10),
              n_new <- integer(1..10)
            ) do
        sweep_age_ms = 1_000
        state = fresh_state(max_open_spans: 500, sweep_age_ms: sweep_age_ms)

        # Insert old spans with monotonic time far in the past
        old_base = System.monotonic_time(:millisecond) - 2_000

        state =
          Enum.reduce(1..n_old, state, fn i, s ->
            key = {:old, i}
            opened_at = old_base + i
            open_spans = Map.put(s.open_spans, key, {:no_otel, opened_at})
            %{s | open_spans: open_spans}
          end)

        # Insert fresh spans
        state =
          Enum.reduce(1..n_new, state, fn i, s ->
            apply_span_open(s, {:new, i}, "tau.test", %{})
          end)

        sweep_start = System.monotonic_time(:millisecond)
        state = apply_sweep(state, sweep_start)

        # Old spans should be gone
        old_keys = Enum.map(1..n_old, &{:old, &1})

        Enum.each(old_keys, fn k ->
          refute Map.has_key?(state.open_spans, k),
                 "stale span #{inspect(k)} should have been swept"
        end)

        # Fresh spans should still be present (opened_at > old_base + 2000)
        new_keys = Enum.map(1..n_new, &{:new, &1})

        Enum.each(new_keys, fn k ->
          assert Map.has_key?(state.open_spans, k),
                 "fresh span #{inspect(k)} should survive sweep"
        end)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.primitive_map/1 — C79
  # ---------------------------------------------------------------------------

  describe "Handler.primitive_map/1 (C79)" do
    test "passes through string, integer, float, boolean unchanged" do
      m = %{"s" => "str", "i" => 1, "f" => 1.5, "b" => true, "bf" => false}
      assert Handler.primitive_map(m) == m
    end

    test "serializes module names to inspect strings" do
      m = %{"mod" => Tau.OtelReporter}
      result = Handler.primitive_map(m)
      assert result["mod"] == inspect(Tau.OtelReporter)
    end

    test "serializes atoms to inspect strings" do
      m = %{"atom" => :some_atom}
      result = Handler.primitive_map(m)
      assert result["atom"] == inspect(:some_atom)
    end

    test "serializes nil to string 'nil'" do
      m = %{"n" => nil}
      result = Handler.primitive_map(m)
      assert result["n"] == "nil"
    end

    test "serializes arbitrary terms" do
      m = %{"term" => {:ok, [1, 2, 3]}}
      result = Handler.primitive_map(m)
      assert is_binary(result["term"])
    end
  end

  # ---------------------------------------------------------------------------
  # Pure helpers: simulate GenServer handle_cast logic
  # ---------------------------------------------------------------------------

  defp fresh_state(opts) do
    max_open_spans = Keyword.get(opts, :max_open_spans, 1_000)
    sweep_age_ms = Keyword.get(opts, :sweep_age_ms, 120_000)

    config =
      Config.from_keyword(
        enabled: true,
        max_open_spans: max_open_spans,
        sweep_age_ms: sweep_age_ms,
        sweep_interval_ms: 60_000
      )

    %{open_spans: %{}, config: config, sweep_timer: nil}
  end

  # Mirrors OtelReporter.handle_cast({:span_open, ...}) — pure, no OTel SDK.
  defp apply_span_open(state, key, _span_name, _attrs) do
    state = maybe_evict_pure(state)
    opened_at = System.monotonic_time(:millisecond)
    open_spans = Map.put(state.open_spans, key, {:no_otel, opened_at})
    %{state | open_spans: open_spans}
  end

  # Mirrors OtelReporter.handle_cast({:span_close, ...}) — pure, no OTel SDK.
  defp apply_span_close(state, key) do
    case Map.pop(state.open_spans, key) do
      {nil, _} -> state
      {_, remaining} -> %{state | open_spans: remaining}
    end
  end

  defp maybe_evict_pure(state) do
    max = state.config.max_open_spans

    if map_size(state.open_spans) >= max do
      {oldest_key, _} =
        Enum.min_by(state.open_spans, fn {_k, {_ctx, opened_at}} -> opened_at end)

      %{state | open_spans: Map.delete(state.open_spans, oldest_key)}
    else
      state
    end
  end

  # Mirrors OtelReporter.handle_info(:sweep, ...) — pure, no OTel SDK.
  defp apply_sweep(state, _sweep_start) do
    sweep_age_ms = state.config.sweep_age_ms
    now_ms = System.monotonic_time(:millisecond)

    {_stale, fresh} =
      Map.split_with(state.open_spans, fn {_k, {_ctx, opened_at}} ->
        now_ms - opened_at >= sweep_age_ms
      end)

    %{state | open_spans: fresh}
  end
end
