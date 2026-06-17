defmodule Tau.Factory.UnitInvWf13OraclePathSetTest do
  @moduledoc """
  Gating test for INV-WF-13 — oracle-phase path-set reporting.

  ## Invariant (INV-WF-13, Clause 2)

  The Unit FSM MUST enforce the oracle-separation contract's path-set
  reporting phase: the `:test_author` worker's `work_ready` signal MUST carry
  a non-empty `gating_test_paths` list, and the Unit MUST:

    1. Capture that list into `data.gating_test_paths` on the
       `oracle → implementing` transition (observable via `:sys.get_state/1`).

    2. REFUSE the `oracle → implementing` transition (and remain in `:oracle`
       or escalate) when `work_ready` arrives without a non-empty
       `gating_test_paths` — i.e., NOT silently advance to `:implementing`
       with an empty or absent path set.

  Falsified by: the Unit advancing to `:implementing` when the test_author's
  `work_ready` carries no `gating_test_paths`, which is the current behaviour
  (`oracle(:info, {:work_ready, worker_id, branch, head_sha}, data)` has no
  guard and stores no path set — unit.ex:273–287 and data map init at
  unit.ex:167–211 confirm neither the event handler nor the data map carry
  `gating_test_paths`).

  ## Entry-point contract

  The test exercises `Tau.Factory.Unit` via `Tau.Factory.UnitSupervisor.start_unit/2`
  (the real supervised entry point used by the production Coordinator). No
  hand-built structs bypass the real state-machine.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  Current code FAILS both clauses:

    * Clause 1 (capture): `data` has no `:gating_test_paths` key (data map
      initialised at unit.ex:167–211 with no such field). Post-transition
      `:sys.get_state/1` will return data without that key.

    * Clause 2 (guard): `oracle(:info, {:work_ready, worker_id, branch, head_sha}, data)`
      (unit.ex:273–287) fires unconditionally — it does not inspect
      `gating_test_paths` and advances to `:implementing` regardless.

  The "path-set present" test will fail (assertion on missing key). The
  "no path-set" test will fail (Unit advances to :implementing when it should
  not).

  ## AC / D-NNN linkage

    - INV-WF-13 — every test in this file.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :inv_wf_13

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

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
    start_supervised!({@scheduler, name: name, w_cap: 10}, id: name)
  end

  # A long-lived worker that parks until stopped — monitorable (B8).
  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Poll until the Unit is in the target state (up to max_ms milliseconds).
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
  # INV-WF-13 Clause 1 — work_ready WITH gating_test_paths: paths captured
  # ---------------------------------------------------------------------------

  describe "INV-WF-13 — oracle work_ready WITH gating_test_paths: paths captured into data" do
    @tag :inv_wf_13
    test "INV-WF-13: when test_author work_ready carries gating_test_paths, Unit captures them and reaches :implementing" do
      unit_id = "u-wf13-present-#{System.unique_integer([:positive])}"
      sched = unique(:sched_wf13_present)
      sup = unique(:sup_wf13_present)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      asserted_paths = ["test/tau/factory/some_gate_test.exs", "test/tau/factory/other_test.exs"]
      asserted_branch = "feat/wf13-test"
      asserted_head_sha = "wf13sha_#{System.unique_integer([:positive])}"

      # The 3-tuple worker_fun stores the worker_id so we can deliver work_ready.
      {:ok, worker_id_store} = Agent.start_link(fn -> nil end)
      on_exit(fn -> if Process.alive?(worker_id_store), do: Agent.stop(worker_id_store) end)

      test_pid = self()

      worker_fun = fn role ->
        worker_pid = spawn_worker()

        case role do
          :test_author ->
            # Use the 3-tuple form so we can send a targeted work_ready with paths.
            worker_id = "wid-ta-wf13-#{System.unique_integer([:positive])}"
            Agent.update(worker_id_store, fn _ -> worker_id end)
            {:ok, worker_pid, worker_id}

          :implementer ->
            # The implementer worker parks; the test does not exercise past this point.
            send(test_pid, {:implementer_spawned, worker_pid})
            {:ok, worker_pid}
        end
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "declared-hash-#{unit_id}",
        scheduler: sched,
        report_to: self(),
        worker_fun: worker_fun,
        # gate_fun is arity-1 (D-361 contract); return fail so the Unit does not
        # advance past :gating (test only observes up to :implementing).
        gate_fun: fn _coord -> {:fail, [:stop_here]} end,
        merge_fun: fn _uid, _hash -> :queued end,
        timeouts: [state_timeout_ms: 10_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      # Wait for the Unit to reach :oracle and spawn the test_author worker.
      assert wait_for_state(unit_pid, :oracle),
             "INV-WF-13: Unit must reach :oracle state after :planned"

      # Retrieve the worker_id assigned by the 3-tuple test_author worker_fun.
      worker_id = Agent.get(worker_id_store, & &1)
      refute is_nil(worker_id), "INV-WF-13: worker_id must be set by the 3-tuple worker_fun"

      # Deliver work_ready WITH gating_test_paths. The conformant implementation
      # extends the {:work_ready, worker_id, branch, head_sha} signal to carry
      # the path set: {:work_ready, worker_id, branch, head_sha, paths}
      # (or an equivalent mechanism). We use the extended 5-tuple form the
      # production worker will emit after the fix.
      send(unit_pid, {:work_ready, worker_id, asserted_branch, asserted_head_sha, asserted_paths})

      # The Unit must advance to :implementing after capturing the path set.
      assert wait_for_state(unit_pid, :implementing),
             "INV-WF-13: Unit must advance to :implementing after test_author delivers work_ready " <>
               "with a non-empty gating_test_paths. Current code either rejects the 5-tuple form " <>
               "as unexpected (oracle's work_ready clause only matches 4-tuple) or it advances " <>
               "without capturing the path set."

      # The captured path set MUST be in data.gating_test_paths after the transition.
      {_state, data_after} = :sys.get_state(unit_pid)

      assert Map.has_key?(data_after, :gating_test_paths),
             "INV-WF-13: data MUST have a :gating_test_paths key after the oracle→implementing " <>
               "transition. Current unit.ex init/1 has no :gating_test_paths field in the data map " <>
               "(unit.ex:167–211). Got data keys: #{inspect(Map.keys(data_after))}."

      assert Map.get(data_after, :gating_test_paths) == asserted_paths,
             "INV-WF-13: data.gating_test_paths MUST equal the paths carried by the test_author's " <>
               "work_ready signal. Expected: #{inspect(asserted_paths)}. " <>
               "Got: #{inspect(Map.get(data_after, :gating_test_paths))}."
    end
  end

  # ---------------------------------------------------------------------------
  # INV-WF-13 Clause 2 — work_ready WITHOUT gating_test_paths: Unit MUST NOT advance
  # ---------------------------------------------------------------------------

  describe "INV-WF-13 — oracle work_ready WITHOUT gating_test_paths: Unit MUST NOT advance to :implementing" do
    @tag :inv_wf_13
    test "INV-WF-13: when test_author work_ready carries NO gating_test_paths, Unit must not advance to :implementing" do
      unit_id = "u-wf13-absent-#{System.unique_integer([:positive])}"
      sched = unique(:sched_wf13_absent)
      sup = unique(:sup_wf13_absent)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # 3-tuple worker_fun; oracle worker emits the CURRENT (pre-fix) 4-tuple
      # work_ready form — branch + head_sha, no gating_test_paths.
      {:ok, worker_id_store} = Agent.start_link(fn -> nil end)
      on_exit(fn -> if Process.alive?(worker_id_store), do: Agent.stop(worker_id_store) end)

      test_pid = self()

      worker_fun = fn role ->
        worker_pid = spawn_worker()

        case role do
          :test_author ->
            worker_id = "wid-ta-absent-#{System.unique_integer([:positive])}"
            Agent.update(worker_id_store, fn _ -> worker_id end)
            {:ok, worker_pid, worker_id}

          :implementer ->
            # Reaching here means the Unit advanced to :implementing without a
            # path set — that is the violation INV-WF-13 Clause 2 asserts against.
            send(test_pid, {:implementer_spawned_illegally, worker_pid})
            {:ok, worker_pid}
        end
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "declared-hash-#{unit_id}",
        scheduler: sched,
        report_to: self(),
        worker_fun: worker_fun,
        gate_fun: fn _coord -> {:fail, [:stop_here]} end,
        merge_fun: fn _uid, _hash -> :queued end,
        # Short timeout so the test does not hang if the Unit is waiting.
        timeouts: [state_timeout_ms: 8_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      # Wait for :oracle.
      assert wait_for_state(unit_pid, :oracle),
             "INV-WF-13: Unit must reach :oracle state"

      worker_id = Agent.get(worker_id_store, & &1)
      refute is_nil(worker_id), "INV-WF-13: worker_id must be set"

      # Send the CURRENT 4-tuple work_ready (no gating_test_paths).
      # A conformant implementation MUST NOT advance to :implementing on this signal.
      send(unit_pid, {:work_ready, worker_id, "feat/wf13-absent", "sha_absent_test"})

      # Give the Unit time to process the event and potentially (incorrectly) advance.
      :timer.sleep(300)

      # The Unit MUST NOT have advanced to :implementing.
      current_state_result =
        case :sys.get_state(unit_pid) do
          {:implementing, _} -> :implementing
          {state, _} -> state
        end

      refute current_state_result == :implementing,
             "INV-WF-13 Clause 2 VIOLATED: the Unit advanced to :implementing after receiving " <>
               "a work_ready WITHOUT gating_test_paths. The oracle→implementing transition " <>
               "at unit.ex:273–287 fires unconditionally — it has no guard on a non-empty " <>
               "path set being present. The implementer must add a guard clause that " <>
               "rejects (or awaits) work_ready when it carries no gating_test_paths."

      # Nor must the implementer worker have been spawned (it is called in :implementing).
      refute_received {:implementer_spawned_illegally, _pid},
                      "INV-WF-13 Clause 2 VIOLATED: worker_fun(:implementer) was called, " <>
                        "meaning the Unit entered :implementing despite the absent path set. " <>
                        "This proves the oracle→implementing guard is missing."
    end
  end
end
