defmodule Tau.Factory.D352WorkerPairingTest do
  @moduledoc """
  Gating test for issue #667 — D-352: paired-span key invariant for
  [:tau, :factory, :worker, :start] / [:tau, :factory, :worker, :exit].

  D-352 (SPEC-FACTORY-GOV §5 / SPEC-OTEL-REPORTER §4 B1):
  Every user-visible factory event MUST produce a paired OTel span.
  "Paired" means the span_open and span_close casts share the SAME
  correlation key — so the OtelReporter can correlate the two halves.

  The invariant is exercised at `Tau.OtelReporter.Handler.handle_event/4`
  (the B1 boundary): for the worker family, the Handler MUST:

  1. Cast `{:span_open, {:factory_worker, worker_id}, span_name, attrs}`
     for `[:tau, :factory, :worker, :start]`.
  2. Cast `{:span_close, {:factory_worker, worker_id}, duration, outcome}`
     for `[:tau, :factory, :worker, :exit]` — the SAME key, not a
     different one.
  3. Map outcome correctly: reason == :normal → :ok; any other reason → :error.

  The existing `telemetry_coverage_test.exs` tests only assert that SOME
  span message is emitted for worker.exit.  This test asserts the FULL
  conformant behaviour:
  - The key in span_close MUST match the key in span_open (same worker_id).
  - The outcome MUST correctly reflect the exit reason.

  If Handler.handle_event/4 has no clause for [:tau, :factory, :worker, :exit]
  (the pre-implementation state), no cast is produced and both tests fail.

  Invariant: D-352 (issue #667). Boundary: Tau.OtelReporter.Handler.handle_event/4.
  """

  use ExUnit.Case, async: true

  alias Tau.OtelReporter.Handler

  @moduletag :d_352

  # ---------------------------------------------------------------------------
  # D-352: worker.start → span_open with {:factory_worker, worker_id} key
  # ---------------------------------------------------------------------------

  describe "D-352: worker.start span_open key invariant" do
    @tag :d_352
    test "Handler casts span_open with {:factory_worker, worker_id} key for worker.start" do
      worker_id = "worker-#{System.unique_integer([:positive])}"
      unit_id = "unit-#{System.unique_integer([:positive])}"

      reporter = self()
      config = %{reporter: reporter}
      gen_cast = :"$gen_cast"

      Handler.handle_event(
        [:tau, :factory, :worker, :start],
        %{system_time: System.system_time()},
        %{worker_id: worker_id, unit_id: unit_id, agent_mode: :claude_code},
        config
      )

      assert_receive {^gen_cast, {:span_open, key, span_name, attrs}},
                     300,
                     "Handler MUST cast :span_open for [:tau, :factory, :worker, :start] " <>
                       "(D-352 — worker start must be observable)"

      assert key == {:factory_worker, worker_id},
             "span_open key MUST be {:factory_worker, worker_id} for pairing with worker.exit; " <>
               "expected {:factory_worker, #{inspect(worker_id)}} got: #{inspect(key)}"

      assert is_binary(span_name),
             "span_name must be a binary, got: #{inspect(span_name)}"

      assert is_map(attrs),
             "attrs must be a map, got: #{inspect(attrs)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-352: worker.exit → span_close with {:factory_worker, worker_id} key
  # paired with the span_open key from worker.start (same worker_id)
  # ---------------------------------------------------------------------------

  describe "D-352: worker.exit span_close key invariant" do
    @tag :d_352
    test "Handler casts span_close with {:factory_worker, worker_id} key for worker.exit (normal)" do
      worker_id = "worker-#{System.unique_integer([:positive])}"
      unit_id = "unit-#{System.unique_integer([:positive])}"

      reporter = self()
      config = %{reporter: reporter}
      gen_cast = :"$gen_cast"

      Handler.handle_event(
        [:tau, :factory, :worker, :exit],
        %{duration: 500_000},
        %{worker_id: worker_id, unit_id: unit_id, reason: :normal},
        config
      )

      assert_receive {^gen_cast, {:span_close, key, _duration, outcome}},
                     300,
                     "Handler MUST cast :span_close for [:tau, :factory, :worker, :exit] " <>
                       "(D-352 — worker exit must be observable)"

      assert key == {:factory_worker, worker_id},
             "span_close key MUST be {:factory_worker, worker_id} to correlate with " <>
               "the worker.start span_open; expected {:factory_worker, #{inspect(worker_id)}} " <>
               "got: #{inspect(key)}"

      assert outcome == :ok,
             "Normal exit (reason: :normal) MUST produce outcome :ok; got: #{inspect(outcome)}"
    end

    @tag :d_352
    test "Handler casts span_close with outcome :error for abnormal worker.exit" do
      # Non-normal exit reason must map to :error so the OTel backend
      # records the failure correctly (D-352 — full conformant outcome mapping).
      worker_id = "worker-#{System.unique_integer([:positive])}"

      reporter = self()
      config = %{reporter: reporter}
      gen_cast = :"$gen_cast"

      Handler.handle_event(
        [:tau, :factory, :worker, :exit],
        %{duration: 100_000},
        %{worker_id: worker_id, unit_id: "u1", reason: :killed},
        config
      )

      assert_receive {^gen_cast, {:span_close, key, _duration, outcome}},
                     300,
                     "Handler MUST cast :span_close for [:tau, :factory, :worker, :exit] " <>
                       "with reason :killed (D-352)"

      assert key == {:factory_worker, worker_id},
             "span_close key must be {:factory_worker, worker_id}; got: #{inspect(key)}"

      assert outcome == :error,
             "Abnormal exit (reason: :killed) MUST produce outcome :error; got: #{inspect(outcome)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-352: pairing invariant — start and exit share the same span key
  # ---------------------------------------------------------------------------

  describe "D-352: worker.start / worker.exit share the same span key" do
    @tag :d_352
    test "span_open key from worker.start matches span_close key from worker.exit" do
      # The OtelReporter correlates spans by key. The Handler MUST use the
      # SAME key for worker.start (span_open) and worker.exit (span_close) so
      # the reporter can close the right span.  No key match → open span leaks
      # until the stale-sweep (D-053), silently masking the lifecycle.
      worker_id = "worker-#{System.unique_integer([:positive])}"
      unit_id = "unit-#{System.unique_integer([:positive])}"

      reporter = self()
      config = %{reporter: reporter}
      gen_cast = :"$gen_cast"

      Handler.handle_event(
        [:tau, :factory, :worker, :start],
        %{system_time: System.system_time()},
        %{worker_id: worker_id, unit_id: unit_id, agent_mode: :claude_code},
        config
      )

      open_key =
        receive do
          {^gen_cast, {:span_open, key, _span_name, _attrs}} -> key
        after
          300 ->
            flunk(
              "Expected :span_open cast for [:tau, :factory, :worker, :start] (D-352); " <>
                "Handler must have a clause for this event"
            )
        end

      Handler.handle_event(
        [:tau, :factory, :worker, :exit],
        %{duration: 200_000},
        %{worker_id: worker_id, unit_id: unit_id, reason: :normal},
        config
      )

      close_key =
        receive do
          {^gen_cast, {:span_close, key, _duration, _outcome}} -> key
        after
          300 ->
            flunk(
              "Expected :span_close cast for [:tau, :factory, :worker, :exit] (D-352); " <>
                "Handler must have a clause for this event"
            )
        end

      assert open_key == close_key,
             "D-352 pairing invariant violated: " <>
               "span_open key (#{inspect(open_key)}) != span_close key (#{inspect(close_key)}); " <>
               "the OtelReporter cannot correlate these spans — worker lifecycle span leaks"
    end
  end
end
