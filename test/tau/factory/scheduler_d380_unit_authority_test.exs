defmodule Tau.Factory.SchedulerD380UnitAuthorityTest do
  @moduledoc """
  Gating test for issue #583 — D-380 single admission authority: the Unit FSM
  `planned` state IS the one and only caller of `Scheduler.admit`, exercised via
  the real `Unit.start_link/1` entry point (not a synthetic drive_fun).

  ## Invariant under test (SPEC-FACTORY-CORE §6, D-380)

  D-380, sub-claim 2 — **Single admission authority (D-380, [C132-B1]):** the
  **only** caller of `Scheduler.admit` per unit is the Unit FSM `planned` state.
  K MUST NOT admit on behalf of a unit.

  The existing `scheduler_self_exclusion_test.exs` (test (c)) verifies the
  Coordinator side via a synthetic `drive_fun` that bypasses the real Unit FSM.
  This file closes the remaining gap: the **Unit-side** assertion via the real
  `Unit.start_link/1` entry point.

  ## What this test asserts

  The D-380 single-authority invariant requires that `Scheduler.admit/3` and
  `admit/4` are only ever called by the Unit FSM's `planned` state. To make
  this auditable and structurally detectable, the Scheduler MUST emit a
  `[:tau, :factory, :scheduler, :admit]` telemetry event on every admission
  attempt (OTP non-negotiable §5: telemetry for perf-sensitive paths). The
  event metadata MUST include `caller_pid: from_pid` so tooling can audit
  whether the caller is a registered Unit process.

  Tests in this file:

    1. **Telemetry audit event** — `Scheduler.admit/4` fires
       `[:tau, :factory, :scheduler, :admit]` with `unit_id`, `result`
       (`admit | {:defer, _}`), and `caller_pid` in metadata.

    2. **Unit FSM is the caller** — after `Unit.start_link/1`, the telemetry
       event's `caller_pid` IS the Unit process (the only legitimate source
       of admit calls per D-380 sub-claim 2).

    3. **Real declared_scope in-flight** — after `Unit.start_link/1`,
       `Scheduler.in_flight/1` contains the unit mapped to its declared_scope
       (regression guard from prior test).

  ## Failure mode on current code

  Tests 1 and 2: `Scheduler.admit` does NOT emit any telemetry event.
  Subscribing to `[:tau, :factory, :scheduler, :admit]` and then calling
  `admit/3` or `admit/4` produces no event; the `assert_receive` fails
  with a timeout.

  Test 3: After `Unit.start_link/1`, `in_flight` DOES contain the unit
  with the real declared_scope. This test passes on current code and is
  kept as a regression guard.

  ## AC linkage

    - D-380 — all tests tagged `:d_380`
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :d_380

  alias Tau.Factory.Policy
  alias Tau.Factory.Scheduler
  alias Tau.Factory.Unit

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp scope_with_file(filename) do
    %{
      deps: [],
      files: MapSet.new([filename]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp start_scheduler(w_cap \\ 5) do
    name = unique_name(:d380_unit_sched)
    start_supervised!({Scheduler, name: name, w_cap: w_cap}, id: unique_name(:d380_sched_sup))
    name
  end

  defp attach_admit_telemetry(handler_id, test_pid) do
    :telemetry.attach(
      handler_id,
      [:tau, :factory, :scheduler, :admit],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:admit_telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # ---------------------------------------------------------------------------
  # D-380 — Scheduler.admit emits [:tau, :factory, :scheduler, :admit] telemetry
  #
  # MUST FAIL on current branch:
  #   Scheduler.admit/3 and admit/4 do NOT emit any telemetry event.
  #   No handler receives a message; assert_receive times out.
  #
  #   Fix required: Scheduler.handle_call({:admit, ...}) must call
  #   :telemetry.execute([:tau, :factory, :scheduler, :admit], measurements,
  #     %{unit_id: unit_id, result: result, caller_pid: caller_pid})
  #   where `caller_pid` is extracted from the `from` argument ({caller_pid, _tag})
  #   of handle_call/3.
  # ---------------------------------------------------------------------------

  describe "D-380 — Scheduler.admit/4 emits admit telemetry (single-authority auditability)" do
    @tag :d_380
    test "D-380: Scheduler.admit/4 fires [:tau, :factory, :scheduler, :admit] on successful admission" do
      sched = start_scheduler()
      scope = scope_with_file("lib/tau/factory/unit.ex")
      unit_id = "unit-d380-tel-#{System.unique_integer([:positive])}"
      test_pid = self()
      handler_id = "d380-admit-tel-#{System.unique_integer([:positive])}"

      attach_admit_telemetry(handler_id, test_pid)

      policy = %Policy{
        model_per_role: %{test_author: "claude-3-5-haiku-20241022"},
        retry_bound_n: 3
      }

      result = Scheduler.admit(sched, unit_id, scope, policy)
      assert result == :admit, "precondition: admit/4 must succeed on empty Scheduler"

      # D-380 telemetry: Scheduler MUST emit the admit audit event so that the
      # single-authority invariant is structurally verifiable at runtime.
      # Without this event, sub-claim 2 remains unauditable (issue #583).
      #
      # FAILS on current branch: Scheduler.handle_call({:admit, ...}) has no
      # :telemetry.execute call; the handler never receives a message; this
      # assert_receive times out after 1_000ms.
      assert_receive {:admit_telemetry, measurements, metadata},
                     1_000,
                     "D-380: Scheduler.admit/4 must emit [:tau, :factory, :scheduler, :admit] " <>
                       "telemetry after processing the admission. No event received within 1s. " <>
                       "Fix: call :telemetry.execute([:tau, :factory, :scheduler, :admit], " <>
                       "%{latency_us: ...}, %{unit_id: uid, result: result, caller_pid: pid}) " <>
                       "inside handle_call({:admit, ...})."

      assert Map.has_key?(measurements, :latency_us) or Map.has_key?(measurements, :monotonic_ms),
             "D-380: admit telemetry measurements must include a latency key. " <>
               "Got measurements=#{inspect(measurements)}"

      assert metadata[:unit_id] == unit_id,
             "D-380: admit telemetry metadata[:unit_id] must equal unit_id. " <>
               "Got metadata=#{inspect(metadata)}"

      assert metadata[:result] == :admit,
             "D-380: admit telemetry metadata[:result] must be :admit. " <>
               "Got #{inspect(metadata[:result])}"

      assert is_pid(metadata[:caller_pid]),
             "D-380: admit telemetry metadata[:caller_pid] must be the calling pid " <>
               "(D-380 sub-claim 2 — auditable authority). Got #{inspect(metadata[:caller_pid])}"
    end

    @tag :d_380
    test "D-380: Scheduler.admit/3 fires [:tau, :factory, :scheduler, :admit] on defer" do
      # Verify that deferred admissions also emit telemetry (result is {:defer, _}).
      # w_cap=0 forces every admit to defer.
      sched = start_scheduler(0)
      scope = scope_with_file("lib/audit_defer.ex")
      unit_id = "unit-d380-tel-defer-#{System.unique_integer([:positive])}"
      test_pid = self()
      handler_id = "d380-admit-defer-tel-#{System.unique_integer([:positive])}"

      attach_admit_telemetry(handler_id, test_pid)

      result = Scheduler.admit(sched, unit_id, scope)
      assert {:defer, :at_capacity} = result, "precondition: admit must defer (w_cap=0)"

      # FAILS on current branch: no telemetry emitted.
      assert_receive {:admit_telemetry, _measurements, metadata},
                     1_000,
                     "D-380: Scheduler.admit/3 must emit [:tau, :factory, :scheduler, :admit] " <>
                       "telemetry even on {:defer, _} results. No event received within 1s."

      assert {:defer, :at_capacity} = metadata[:result],
             "D-380: admit telemetry metadata[:result] must be {:defer, :at_capacity}. " <>
               "Got #{inspect(metadata[:result])}"

      assert is_pid(metadata[:caller_pid]),
             "D-380: metadata[:caller_pid] must be a pid even on defer. " <>
               "Got #{inspect(metadata[:caller_pid])}"
    end
  end

  describe "D-380 — Unit FSM planned state is the telemetry-observed admit caller (real Unit.start_link)" do
    @tag :d_380
    test "D-380: after Unit.start_link, the admit telemetry caller_pid equals the Unit process" do
      # D-380 sub-claim 2 structural check: when a real Unit is started, the
      # [:tau, :factory, :scheduler, :admit] event's caller_pid MUST be the
      # Unit process (not the Coordinator, not the test process).
      #
      # FAILS on current branch: Scheduler.admit emits no telemetry event at all.
      sched = start_scheduler()
      declared_scope = scope_with_file("lib/real_unit_caller.ex")
      unit_id = "unit-d380-caller-#{System.unique_integer([:positive])}"
      test_pid = self()

      pubsub_name = unique_name(:d380_pubsub_caller)

      start_supervised!({Phoenix.PubSub, name: pubsub_name},
        id: unique_name(:d380_ps_caller_sup)
      )

      handler_id = "d380-caller-tel-#{System.unique_integer([:positive])}"
      attach_admit_telemetry(handler_id, test_pid)

      worker_fun = fn _role ->
        {:ok, spawn(fn -> Process.sleep(500) end)}
      end

      {:ok, unit_pid} =
        Unit.start_link(
          unit_id: unit_id,
          declared_scope: declared_scope,
          hash: "abc123",
          scheduler: sched,
          report_to: test_pid,
          worker_fun: worker_fun,
          gate_fun: fn _coord -> :pass end,
          merge_fun: fn _uid, _hash -> :queued end,
          pubsub: pubsub_name
        )

      # FAILS on current branch: Scheduler.admit emits no telemetry.
      assert_receive {:admit_telemetry, _measurements, metadata},
                     2_000,
                     "D-380: after Unit.start_link, Scheduler must emit " <>
                       "[:tau, :factory, :scheduler, :admit] with caller_pid = the Unit process. " <>
                       "No event received within 2s. " <>
                       "Fix: Scheduler.handle_call({:admit,...}) must emit the telemetry event."

      # D-380 sub-claim 2: the caller_pid in the telemetry MUST be the Unit process.
      assert metadata[:caller_pid] == unit_pid,
             "D-380: the admit telemetry caller_pid must be the Unit process #{inspect(unit_pid)}. " <>
               "Got caller_pid=#{inspect(metadata[:caller_pid])}. " <>
               "A non-Unit caller_pid indicates a D-380 single-authority violation."

      assert metadata[:unit_id] == unit_id,
             "D-380: admit telemetry unit_id must match. Got metadata=#{inspect(metadata)}"
    end
  end

  describe "D-380 — regression: real declared_scope in Scheduler.in_flight after Unit.start_link" do
    @tag :d_380
    test "D-380: after Unit.start_link, in_flight contains unit with its real declared_scope (not empty scope)" do
      # Regression guard — this passed on prior code; kept to prevent backslide.
      # If this fails, D-380 sub-claim 1 (self-exclusion) or the Unit FSM's
      # call to Scheduler.admit has regressed.
      sched = start_scheduler()
      declared_scope = scope_with_file("lib/tau/factory/unit.ex")
      unit_id = "unit-d380-real-#{System.unique_integer([:positive])}"

      pubsub_name = unique_name(:d380_pubsub)
      start_supervised!({Phoenix.PubSub, name: pubsub_name}, id: unique_name(:d380_ps_sup))

      test_pid = self()

      worker_fun = fn _role ->
        {:ok,
         spawn(fn ->
           Process.sleep(500)
         end)}
      end

      {:ok, _unit_pid} =
        Unit.start_link(
          unit_id: unit_id,
          declared_scope: declared_scope,
          hash: "abc123",
          scheduler: sched,
          report_to: test_pid,
          worker_fun: worker_fun,
          gate_fun: fn _coord -> :pass end,
          merge_fun: fn _uid, _hash -> :queued end,
          pubsub: pubsub_name
        )

      Process.sleep(200)

      inflight = Scheduler.in_flight(sched)

      assert Map.has_key?(inflight, unit_id),
             "D-380: unit_id must be in Scheduler's in_flight after Unit.start_link. " <>
               "Got in_flight=#{inspect(inflight)}"

      assert Map.fetch!(inflight, unit_id) == declared_scope,
             "D-380: Scheduler.in_flight must map unit_id to the real declared_scope " <>
               "(not an empty-scope K placeholder). " <>
               "Expected #{inspect(declared_scope)}, got #{inspect(Map.fetch!(inflight, unit_id))}"
    end
  end
end
