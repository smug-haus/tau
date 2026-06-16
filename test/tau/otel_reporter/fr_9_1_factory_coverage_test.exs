defmodule Tau.OtelReporter.FR91FactoryCoverageTest do
  @moduledoc """
  Gating test for issue #664 — FR-9.1: factory telemetry events MUST be
  subscribed and exported by `Tau.OtelReporter`.

  The finding: `build_event_list/1` in `lib/tau/otel_reporter.ex` subscribes
  to ZERO `[:tau, :factory, ...]` events, so gate.ex's paired
  `[:tau, :factory, :gate, :run, :start]` / `[:tau, :factory, :gate, :run, :stop]`
  events (and worker/unit events) are never exported as OTel spans.

  This test exercises the real entry point — `Tau.OtelReporter.Handler.handle_event/4`
  — and asserts that factory gate events produce a `:span_open` cast to the
  reporter. The assertion currently FAILS because:

  1. `Handler` has no clause for `[:tau, :factory, :gate, :run, ...]`; the
     catch-all `do_handle/4` fires and returns `:ok` with no cast.
  2. `build_event_list/1` does not include `[:tau, :factory, :gate, :run, :start]`
     (or any `[:tau, :factory, ...]` event), so even if a handler clause existed
     the reporter would never be attached to those events.

  Both defects must be fixed for this test to pass:

  - `build_event_list/1` must include `[:tau, :factory, :gate, :run, :start]` and
    `[:tau, :factory, :gate, :run, :stop]`.
  - `Handler.handle_event/4` must have clauses for those events that cast
    `{:span_open, key, span_name, attrs}` and `{:span_close, key, duration, outcome}`
    to the reporter (matching the paired-span contract of NFR-OBS-COVERAGE).

  Invariant: FR-9.1 (issue #664). Boundary: `Tau.OtelReporter.Handler.handle_event/4`.
  """

  use ExUnit.Case, async: true

  alias Tau.OtelReporter.Handler

  @moduletag :fr_9_1

  # ---------------------------------------------------------------------------
  # FR-9.1: Handler emits paired span_open / span_close for factory.gate.run
  # ---------------------------------------------------------------------------

  describe "FR-9.1: factory gate run telemetry exported as OTel span" do
    @tag :fr_9_1
    test "Handler casts span_open when receiving [:tau, :factory, :gate, :run, :start]" do
      # Exercise the real Handler entry point.
      # config is %{reporter: pid} — matches the live attach_handlers/1 config shape.
      reporter = self()
      config = %{reporter: reporter}

      unit = "unit-#{System.unique_integer([:positive])}"

      Handler.handle_event(
        [:tau, :factory, :gate, :run, :start],
        %{system_time: System.system_time()},
        %{unit: unit, hash: "abc123", run: 1},
        config
      )

      # The Handler MUST cast {:span_open, key, span_name, attrs} to the reporter.
      # GenServer.cast/2 delivers {:"$gen_cast", msg} to the target process.
      gen_cast = :"$gen_cast"

      assert_receive {^gen_cast, {:span_open, _key, span_name, attrs}},
                     300,
                     "Handler MUST cast :span_open for [:tau, :factory, :gate, :run, :start] " <>
                       "(FR-9.1 — factory gate events must be exported as OTel spans)"

      assert is_binary(span_name),
             "span_name must be a string, got: #{inspect(span_name)}"

      assert is_map(attrs),
             "attrs must be a map, got: #{inspect(attrs)}"
    end

    @tag :fr_9_1
    test "Handler casts span_close when receiving [:tau, :factory, :gate, :run, :stop]" do
      reporter = self()
      config = %{reporter: reporter}

      unit = "unit-#{System.unique_integer([:positive])}"
      gen_cast = :"$gen_cast"

      # First open a span.
      Handler.handle_event(
        [:tau, :factory, :gate, :run, :start],
        %{system_time: System.system_time()},
        %{unit: unit, hash: "abc123", run: 1},
        config
      )

      # Drain the span_open cast (may or may not arrive depending on fix state).
      receive do
        {^gen_cast, {:span_open, _, _, _}} -> :ok
      after
        50 -> :ok
      end

      Handler.handle_event(
        [:tau, :factory, :gate, :run, :stop],
        %{duration: 100_000},
        %{unit: unit, hash: "abc123", run: 1, status: :pass},
        config
      )

      assert_receive {^gen_cast, {:span_close, _key, _duration, _outcome}},
                     300,
                     "Handler MUST cast :span_close for [:tau, :factory, :gate, :run, :stop] " <>
                       "(FR-9.1 — factory gate events must be exported as OTel spans)"
    end

    @tag :fr_9_1
    test "start and stop share the same span key — paired-span invariant (FR-9.1)" do
      # The span key produced by :start MUST equal the key consumed by :stop so
      # that the span map in OtelReporter correctly correlates them.
      reporter = self()
      config = %{reporter: reporter}

      unit = "unit-#{System.unique_integer([:positive])}"
      gen_cast = :"$gen_cast"

      Handler.handle_event(
        [:tau, :factory, :gate, :run, :start],
        %{system_time: System.system_time()},
        %{unit: unit, hash: "abc123", run: 1},
        config
      )

      open_key =
        receive do
          {^gen_cast, {:span_open, key, _span_name, _attrs}} -> key
        after
          300 ->
            flunk("Expected :span_open cast for [:tau, :factory, :gate, :run, :start] (FR-9.1)")
        end

      Handler.handle_event(
        [:tau, :factory, :gate, :run, :stop],
        %{duration: 50_000},
        %{unit: unit, hash: "abc123", run: 1, status: :pass},
        config
      )

      close_key =
        receive do
          {^gen_cast, {:span_close, key, _duration, _outcome}} -> key
        after
          300 ->
            flunk("Expected :span_close cast for [:tau, :factory, :gate, :run, :stop] (FR-9.1)")
        end

      assert open_key == close_key,
             "span key from :start and :stop MUST match for paired-span correlation (FR-9.1); " <>
               "open_key=#{inspect(open_key)} close_key=#{inspect(close_key)}"
    end
  end
end
