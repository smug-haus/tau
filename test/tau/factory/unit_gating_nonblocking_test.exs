defmodule Tau.Factory.UnitGatingNonblockingTest do
  @moduledoc """
  Gating test for issue #609 (INV-SAFE-CP-5 — Unit gating state MUST NOT call
  gate_fun synchronously/blocking).

  ## Invariant under test

  **INV-SAFE-CP-5** (safety — Unit-FSM, high severity):

  > U state callbacks must not block (no synchronous git/build subprocess, no
  > multi-second receive, no call held across a long activity). Every long or
  > blocking effect is pushed into a monitored peer (worker, M, gate Task) whose
  > result returns as a message or :DOWN. In particular merge_fun must return
  > promptly (:queued). Falsified if any U state callback performs a blocking
  > operation that would prevent state_timeout from firing or stall processing
  > of worker_exit/worker_stalled messages.

  The current violation (unit.ex:568): `gating(:internal, :on_enter, data)` calls
  `data.gate_fun.(coordinate)` synchronously inline and blocks the gen_statem
  callback until gate_fun returns. This prevents any other message (state_timeout,
  worker_exit, worker_stalled) from being processed while the gate runs.

  ## Test design

  The test injects a slow gate_fun (blocks for `@slow_gate_ms` ms) and advances
  the Unit to the `:gating` state via `{:work_ready, worker_id, branch, sha}`.
  Immediately after triggering the transition, the test spawns a probe process
  that calls `:sys.get_state/2` with a tight timeout of `@probe_timeout_ms` ms
  (much shorter than `@slow_gate_ms`). Three assertions:

    1. The probe MUST succeed within `@probe_timeout_ms` — the gen_statem callback
       MUST have returned promptly, NOT blocked on gate_fun.
    2. The state returned by the probe MUST be `:gating` — the FSM is still in the
       gating state, waiting for the async gate result (Task or peer message).
    3. There is NO `{:gate_result, _}` or `:pass` message in the test process's
       mailbox yet (the slow gate hasn't finished).

  Under the CURRENT code, the gen_statem callback blocks inside gate_fun for
  `@slow_gate_ms` ms. `:sys.get_state/2` sends a system message to the gen_statem,
  which queues until the current callback returns — i.e., it blocks for
  ~`@slow_gate_ms` ms too. The probe's timeout fires first, the probe returns
  `:timeout`, and assertion 1 fails (the probe did NOT succeed within the tight
  deadline). This is the correct fail-before.

  Under the CONFORMANT code, the callback spawns a Task (or sends to a peer),
  returns immediately to the gen_statem receive loop, and `:sys.get_state/2`
  responds within a few ms. Assertions 1 and 2 pass. Assertion 3 ensures we
  are testing the right moment — not after the gate has already resolved.

  ## Entry path

  The real entry path: `Tau.Factory.UnitSupervisor.start_unit/2` →
  `Tau.Factory.Unit` (gen_statem). No hand-built struct; no injected seam
  that bypasses the real FSM.

  ## INV-SAFE-CP-5 linkage (Gate 5.1)

  Every test in this file carries `@tag :inv_safe_cp_5` so the AC-linkage
  gate can verify coverage of `INV-SAFE-CP-5`.
  """

  # async: false — this test reasons about wall-clock responsiveness of a
  # gen_statem callback. Under full-suite concurrency BEAM scheduler pressure
  # can extend the tight probe deadline with false positives. Serialise to
  # eliminate scheduler starvation as a confound.
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :inv_safe_cp_5

  alias Tau.Factory.Scheduler
  alias Tau.Factory.UnitSupervisor

  # How long the injected gate_fun blocks. Must be long enough that a
  # synchronous block is observable but short enough that the test doesn't
  # time out on the subsequent success assertions.
  @slow_gate_ms 400

  # How long the `:sys.get_state/2` probe is allowed to wait. Must be much
  # shorter than @slow_gate_ms so a synchronous block trips it, but long
  # enough that scheduling jitter doesn't cause false positives.
  @probe_timeout_ms 80

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp start_scheduler(name) do
    start_supervised!({Scheduler, name: name, w_cap: 10}, id: name)
  end

  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Drive the Unit oracle state through using the legacy seam so we can focus
  # the test on the gating state behaviour.
  defp drive_oracle_done(unit_pid) do
    :timer.sleep(50)

    case :sys.get_state(unit_pid) do
      {:oracle, data} ->
        worker_pid = Map.get(data, :worker_pid)
        if is_pid(worker_pid), do: send(unit_pid, {:worker_done, worker_pid})

      _ ->
        :ok
    end

    :timer.sleep(100)
  end

  # Poll until the unit reaches target_state (or deadline elapses).
  defp wait_for_state(unit_pid, target_state, max_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + max_ms

    Stream.repeatedly(fn ->
      case :sys.get_state(unit_pid) do
        {^target_state, _data} -> :reached
        _ -> :not_yet
      end
    end)
    |> Enum.find_value(fn
      :reached ->
        true

      :not_yet ->
        if System.monotonic_time(:millisecond) < deadline do
          :timer.sleep(20)
          nil
        else
          false
        end
    end)
  end

  # ---------------------------------------------------------------------------
  # INV-SAFE-CP-5 — gating state MUST NOT block on gate_fun
  # ---------------------------------------------------------------------------

  describe "INV-SAFE-CP-5 — Unit.gating/3 must return promptly (non-blocking gate_fun)" do
    @tag :inv_safe_cp_5
    test "INV-SAFE-CP-5: gen_statem remains responsive while slow gate_fun runs — :sys.get_state returns within probe deadline" do
      test_pid = self()
      unit_id = "u-nonblocking-gate-#{System.unique_integer([:positive])}"
      sched = unique(:sched_inv_safe_cp_5)
      sup = unique(:sup_inv_safe_cp_5)
      start_scheduler(sched)
      start_supervised!({UnitSupervisor, name: sup}, id: sup)

      {:ok, worker_id_store} = Agent.start_link(fn -> nil end)
      on_exit(fn -> if Process.alive?(worker_id_store), do: Agent.stop(worker_id_store) end)

      # worker_fun: oracle via legacy 2-tuple; implementing via 3-tuple so we
      # can send {:work_ready, worker_id, branch, sha} to trigger gating.
      worker_fun = fn role ->
        worker_pid = spawn_worker()

        case role do
          :test_author ->
            # Oracle: legacy 2-tuple seam.
            {:ok, worker_pid}

          :implementer ->
            worker_id = "wid-inv-safe-cp-5-#{System.unique_integer([:positive])}"
            Agent.update(worker_id_store, fn _ -> worker_id end)
            {:ok, worker_pid, worker_id}
        end
      end

      # Slow gate_fun: blocks for @slow_gate_ms ms to make a synchronous call
      # observable. Notifies test_pid when it actually starts running so the
      # test knows the gating state has been entered.
      slow_gate_fun = fn _coord ->
        send(test_pid, :gate_started)
        # Block long enough that a synchronous call is observable.
        :timer.sleep(@slow_gate_ms)
        :pass
      end

      merge_fun = fn uid, _hash ->
        Phoenix.PubSub.broadcast(Tau.PubSub, "factory:pr:#{uid}", {:merge_result, :merged})
        :queued
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-inv-safe-cp-5-#{System.unique_integer([:positive])}",
        scheduler: sched,
        report_to: test_pid,
        pubsub: Tau.PubSub,
        worker_fun: worker_fun,
        gate_fun: slow_gate_fun,
        merge_fun: merge_fun,
        timeouts: [state_timeout_ms: 10_000]
      ]

      unit_pid = UnitSupervisor.start_unit(sup, opts)
      assert is_pid(unit_pid), "INV-SAFE-CP-5: UnitSupervisor.start_unit must return a pid"

      # Drive oracle through (legacy seam).
      drive_oracle_done(unit_pid)

      assert wait_for_state(unit_pid, :implementing),
             "INV-SAFE-CP-5: Unit must reach :implementing after oracle completes"

      worker_id = Agent.get(worker_id_store, & &1)
      refute is_nil(worker_id), "INV-SAFE-CP-5: worker_id must be set by 3-tuple worker_fun"

      # Trigger the :implementing → :gating transition.
      branch = "feat/inv-safe-cp-5-branch"
      head_sha = "sha-inv-safe-cp-5-#{System.unique_integer([:positive])}"
      send(unit_pid, {:work_ready, worker_id, branch, head_sha})

      # Wait for gate_fun to start — this confirms we are actually in the gating
      # state and the gate is running. After this, the gen_statem MUST be
      # responsive (callback already returned) if the implementation is async.
      assert_receive :gate_started,
                     3_000,
                     "INV-SAFE-CP-5: gate_fun must be invoked after {:work_ready, ...}"

      # Probe: spawn a process to call :sys.get_state with a tight timeout.
      # Under synchronous (broken) code, the gen_statem callback is still
      # executing (blocked in gate_fun's :timer.sleep), so :sys.get_state
      # blocks for the remaining ~@slow_gate_ms ms and the probe times out.
      # Under async (conformant) code, the callback has already returned and
      # :sys.get_state responds within a few ms.
      probe_result =
        Task.async(fn ->
          :sys.get_state(unit_pid, @probe_timeout_ms)
        end)
        |> Task.yield(@probe_timeout_ms + 50)

      # Assertion 1: the probe MUST succeed (not time out).
      assert probe_result != nil,
             "INV-SAFE-CP-5: :sys.get_state timed out within #{@probe_timeout_ms}ms. " <>
               "This means the gen_statem callback is still executing (blocked in gate_fun). " <>
               "Unit.gating/3 calls data.gate_fun.(coordinate) synchronously, " <>
               "which blocks the entire gen_statem mailbox for ~#{@slow_gate_ms}ms. " <>
               "The conformant implementation MUST spawn gate_fun into a Task/peer and " <>
               "return immediately so the FSM can process state_timeout, worker_exit, " <>
               "and worker_stalled messages while the gate runs."

      # Assertion 2: the state must be :gating — we're testing during gate execution,
      # not after it has resolved. If the gate already returned, this confirms the
      # timing is off (the slow sleep should prevent early resolution).
      case probe_result do
        {:ok, {state, _data}} ->
          assert state == :gating,
                 "INV-SAFE-CP-5: Unit must still be in :gating state while gate_fun is slow. " <>
                   "Got state: #{inspect(state)}. " <>
                   "If the state has already advanced to :awaiting_merge, " <>
                   "the @slow_gate_ms delay may be too short or scheduling resolved it early."

        other ->
          flunk(
            "INV-SAFE-CP-5: unexpected probe result: #{inspect(other)}. " <>
              "Expected {:ok, {:gating, _data}} within the probe deadline."
          )
      end

      # Assertion 3: no gate_result or :pass in the mailbox yet — the gate has NOT
      # finished during the probe window (confirms the timing assertion holds).
      refute_receive :pass,
                     0,
                     "INV-SAFE-CP-5: received :pass in test mailbox before expected — " <>
                       "gate resolved too quickly for the timing assertion to be meaningful."
    end
  end
end
