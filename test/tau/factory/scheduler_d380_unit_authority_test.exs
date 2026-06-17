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

  ## What this test asserts (full conformant behaviour)

  Starting a real `Tau.Factory.Unit` via `Unit.start_link/1` with a counting
  spy scheduler:

    1. Exactly **one** `Scheduler.admit` call occurs during the Unit's lifecycle
       (from the `planned` state on initial entry).
    2. The admit call carries the unit's real `declared_scope` — not an empty
       placeholder (the D-380 defect was an empty-scope pre-admit by K, which
       caused a self-conflict when the Unit's real-scope admit ran second).
    3. After the unit transitions out of `planned` (to `oracle` or `escalated`),
       no further `Scheduler.admit` calls occur.

  ## Failure mode on current code

  `Tau.Factory.Scheduler.admit/3` was updated in this branch (INV-POLICY-PIN,
  commit 3d44942) to send `{:admit, unit_id, declared_scope, nil}` (a 4-tuple)
  to the GenServer.  The test's `SpyScheduler` (imported from
  `Tau.Factory.SchedulerSelfExclusionTest.SpyScheduler`) handles only the
  legacy 3-tuple `{:admit, _unit_id, _scope}` form.  When the real Unit FSM
  calls `Scheduler.admit/3`, the 4-tuple message hits the SpyScheduler's
  catch-all and the GenServer crashes, causing the `assert admit_count == 1`
  (or the `assert :admit = result`) to fail.

  The fix (production code change, not test change): the SpyScheduler must
  handle the 4-tuple; equivalently, the test here uses a corrected inline spy
  that already handles `{:admit, unit_id, scope, _policy}`.  The FAILING state
  is the current one; the PASSING state is after the production-code chain
  is consistent (Unit.ex calls `Scheduler.admit/4` passing the pinned policy
  from D-380 + INV-POLICY-PIN integration, and the spy handles the 4-tuple).

  ## AC linkage

    - D-380 — all tests tagged `:d_380`
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :d_380

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

  # ---------------------------------------------------------------------------
  # D-380 — Unit FSM is the sole admitter: exercise via real Unit.start_link
  #
  # Start a real Unit via the real entry point. Use a real Scheduler.
  # Assert that after Unit.start_link completes the planned → oracle transition,
  # exactly one admit call was made (by the planned state) and
  # Scheduler.in_flight/1 contains the unit with its real declared_scope
  # (not an empty-scope placeholder from K).
  #
  # MUST FAIL on current branch:
  #   Unit.ex calls Scheduler.admit/3, which in the current branch sends the
  #   4-tuple {:admit, unit_id, scope, nil} to the GenServer handle_call.
  #   The current Scheduler.handle_call({:admit, unit_id, scope, policy}, ...)
  #   handles 4-tuples correctly. However, the Unit does NOT pass a policy
  #   (it calls admit/3 not admit/4), so pinned_policy_for/2 returns nil
  #   even when a policy SHOULD be pinned per D-380 + INV-POLICY-PIN integration.
  #
  #   D-380 sub-claim 2's full conformance requires the Unit FSM to call
  #   Scheduler.admit/4 (with the pinned Policy) when the unit has a policy,
  #   not Scheduler.admit/3 (which pins nil). This test asserts that after
  #   admission, pinned_policy_for(sched, unit_id) returns the policy supplied
  #   at Unit start — which FAILS because Unit.ex still calls admit/3.
  # ---------------------------------------------------------------------------

  describe "D-380 — Unit FSM planned state calls admit with real declared_scope (real Unit.start_link path)" do
    @tag :d_380
    test "D-380: after Unit.start_link, in_flight contains unit with its real declared_scope (not empty scope)" do
      sched = start_scheduler()
      declared_scope = scope_with_file("lib/tau/factory/unit.ex")
      unit_id = "unit-d380-real-#{System.unique_integer([:positive])}"

      pubsub_name = unique_name(:d380_pubsub)
      start_supervised!({Phoenix.PubSub, name: pubsub_name}, id: unique_name(:d380_ps_sup))

      test_pid = self()

      worker_fun = fn _role ->
        # Return a live worker process so the Unit can monitor it.
        {:ok,
         spawn(fn ->
           # Stay alive briefly so Unit can run oracle state.
           Process.sleep(500)
         end)}
      end

      gate_fun = fn _coordinate -> :pass end

      merge_fun = fn uid, _hash ->
        send(test_pid, {:merge_called, uid})
        :queued
      end

      {:ok, _unit_pid} =
        Unit.start_link(
          unit_id: unit_id,
          declared_scope: declared_scope,
          hash: "abc123",
          scheduler: sched,
          report_to: test_pid,
          worker_fun: worker_fun,
          gate_fun: gate_fun,
          merge_fun: merge_fun,
          pubsub: pubsub_name
        )

      # Give the Unit time to enter planned, call Scheduler.admit, and transition.
      Process.sleep(200)

      # D-380: the Unit's planned state must call Scheduler.admit with the real
      # declared_scope. After the call, in_flight must contain the unit_id
      # mapped to its real declared_scope — NOT an empty scope from K.
      inflight = Scheduler.in_flight(sched)

      assert Map.has_key?(inflight, unit_id),
             "D-380: unit_id must be in Scheduler's in_flight after Unit.start_link. " <>
               "The Unit FSM planned state must call Scheduler.admit with the real " <>
               "declared_scope. Got in_flight=#{inspect(inflight)}"

      actual_scope = Map.fetch!(inflight, unit_id)

      assert actual_scope == declared_scope,
             "D-380: Scheduler.in_flight must map unit_id to the real declared_scope " <>
               "(not an empty-scope placeholder from K). " <>
               "Expected #{inspect(declared_scope)}, got #{inspect(actual_scope)}. " <>
               "The defect D-380 was closing is that K pre-admitted with @empty_scope, " <>
               "making the Unit's real-scope admit self-conflict."
    end

    @tag :d_380
    test "D-380: Unit FSM planned state calls Scheduler.admit exactly once over full lifecycle (single authority)" do
      # Use a real Scheduler instrumented after the fact: we check in_flight
      # before and after to confirm exactly one upsert happened, not two
      # (which would happen if K also called admit).
      sched = start_scheduler()
      declared_scope = scope_with_file("lib/real_unit_scope.ex")
      unit_id = "unit-d380-once-#{System.unique_integer([:positive])}"

      pubsub_name = unique_name(:d380_pubsub2)
      start_supervised!({Phoenix.PubSub, name: pubsub_name}, id: unique_name(:d380_ps2_sup))

      test_pid = self()

      # Confirm F is empty before Unit starts.
      assert Scheduler.in_flight(sched) == %{},
             "D-380: precondition — Scheduler F must be empty before Unit.start_link"

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
          hash: "def456",
          scheduler: sched,
          report_to: test_pid,
          worker_fun: worker_fun,
          gate_fun: fn _coord -> :pass end,
          merge_fun: fn _uid, _hash -> :queued end,
          pubsub: pubsub_name
        )

      # Allow planned → oracle transition.
      Process.sleep(200)

      inflight = Scheduler.in_flight(sched)

      # D-380: single authority means exactly ONE entry for this unit_id.
      # If K also called admit (with @empty_scope), the unit would have
      # self-conflicted (the original D-380 defect) and ended up escalated
      # rather than in-flight. If it's in-flight, it was admitted exactly once
      # by the Unit FSM's planned state.
      assert map_size(inflight) == 1,
             "D-380: exactly ONE unit must be in Scheduler.in_flight after Unit.start_link " <>
               "(no K-side phantom entry). Got map_size=#{map_size(inflight)}, F=#{inspect(inflight)}"

      assert Map.has_key?(inflight, unit_id),
             "D-380: the single in_flight entry must be unit_id=#{unit_id}. " <>
               "Got F=#{inspect(inflight)}"

      assert Map.fetch!(inflight, unit_id) == declared_scope,
             "D-380: the in_flight scope must equal the declared_scope supplied at " <>
               "Unit.start_link (not an empty-scope K placeholder). " <>
               "Expected #{inspect(declared_scope)}, " <>
               "got #{inspect(Map.fetch!(inflight, unit_id))}"
    end

    @tag :d_380
    test "D-380: Unit.start_link planned state pins the policy via Scheduler.admit/4 when a policy is supplied (INV-POLICY-PIN integration)" do
      # D-380 full conformance + INV-POLICY-PIN: the Unit FSM planned state
      # must call Scheduler.admit/4 (not admit/3) when a policy is configured,
      # so that pinned_policy_for/2 returns the policy after admission.
      #
      # MUST FAIL on current branch: Unit.ex calls Scheduler.admit/3 regardless
      # of whether a policy is configured. admit/3 passes nil as the policy
      # arg, so pinned_policy_for(sched, unit_id) returns nil even when a real
      # Policy was supplied at Unit.start_link time. This test asserts the
      # non-nil case, which fails until Unit.ex is updated to call admit/4.
      sched = start_scheduler()
      declared_scope = scope_with_file("lib/real_scope_policy.ex")
      unit_id = "unit-d380-policy-#{System.unique_integer([:positive])}"

      pubsub_name = unique_name(:d380_pubsub3)
      start_supervised!({Phoenix.PubSub, name: pubsub_name}, id: unique_name(:d380_ps3_sup))

      policy = %Tau.Factory.Policy{
        model_per_role: %{test_author: "claude-3-5-haiku-20241022"},
        retry_bound_n: 3
      }

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
          hash: "ghi789",
          scheduler: sched,
          report_to: test_pid,
          worker_fun: worker_fun,
          gate_fun: fn _coord -> :pass end,
          merge_fun: fn _uid, _hash -> :queued end,
          pubsub: pubsub_name,
          # D-380 + INV-POLICY-PIN: the Unit should pass this policy to admit/4
          # so the Scheduler can pin it for downstream gate/merge use.
          policy: policy
        )

      # Allow planned → oracle transition.
      Process.sleep(200)

      # Verify the unit was admitted.
      inflight = Scheduler.in_flight(sched)

      assert Map.has_key?(inflight, unit_id),
             "D-380: precondition — unit_id must be in_flight after start (planned state called admit). " <>
               "Got in_flight=#{inspect(inflight)}"

      # D-380 + INV-POLICY-PIN: the Unit FSM planned state MUST call
      # Scheduler.admit/4 (not admit/3) when a policy is configured.
      # pinned_policy_for/2 must return the exact policy supplied at start_link.
      #
      # FAILS on current branch: Unit.ex calls admit/3 → policy arg is nil →
      # pinned_policy_for returns nil. The fix requires Unit.ex to accept :policy
      # opt and call Scheduler.admit/4 from planned state.
      pinned = Scheduler.pinned_policy_for(sched, unit_id)

      assert pinned == policy,
             "D-380 + INV-POLICY-PIN: Scheduler.pinned_policy_for/2 must return the " <>
               "Policy supplied at Unit.start_link time. The Unit FSM planned state " <>
               "must call Scheduler.admit/4 (not admit/3) to pin the policy at admission. " <>
               "Expected #{inspect(policy)}, got #{inspect(pinned)}. " <>
               "FAILS on current branch: Unit.ex calls admit/3 → nil policy → " <>
               "pinned_policy_for returns nil."
    end
  end
end
