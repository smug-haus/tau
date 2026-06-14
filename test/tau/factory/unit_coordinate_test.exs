defmodule Tau.Factory.UnitCoordinateTest do
  @moduledoc """
  Gating tests for PR #503 (C1 — thread the worker's actual head_sha as the
  unit coordinate). Advances D-361, D-362, D-363 (SPEC-FACTORY-CORE §6, §4 B6/B7/B8).

  ## What is being enforced

  ### D-362 — Capture-on-work_ready (SPEC-FACTORY-CORE §6, §4 B8)

  When the Unit's `implementing` or `oracle` state receives
  `{:work_ready, ^worker_id, branch, head_sha}` from the current worker (3-tuple
  seam), it MUST capture `branch` and `head_sha` into `data`:

      %{data | branch: branch, head_sha: head_sha}

  Observable via `:sys.get_state/1` after the transition completes.

  ### D-361 — Coordinate identity: gate/merge key on captured head_sha (§6, §4 B6/B7)

  When `data.head_sha` is non-`nil` (captured from `work_ready`), BOTH the
  gate seam and the merge seam MUST use `data.head_sha` as the coordinate —
  NOT the pre-declared `work_item.hash`. The merge spy's received `hash`
  argument is the observable signal for the merge seam (B6).

  ### D-363 — Total back-compat: legacy 2-tuple seam falls through to declared hash (§6)

  With the legacy 2-tuple `worker_fun` (no `worker_id`, completion via
  `{:worker_done, ^worker_pid}`), `data.head_sha` stays `nil` and the merge seam
  falls back to the declared `work_item.hash` unchanged. Additionally, the
  implementation MUST initialise the `:head_sha` key in data (with value `nil`) so
  that `Map.has_key?(data, :head_sha)` is true even when no capture has occurred.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  The current branch (`feat/486-head-sha-coordinate`) has NOT yet implemented
  the capture/threading:

  - `oracle/3` and `implementing/3` use `_branch` / `_head_sha` (discarded).
  - `awaiting_merge` calls `data.merge_fun.(data.unit_id, data.hash)` — always
    the pre-declared hash, never the captured one.
  - The `data` map initialised in `init/1` has NO `:head_sha` or `:branch` key.

  As a result:

  - D-362 test: `:sys.get_state` after work_ready finds `data` has no `:head_sha`
    key → `Map.get(data, :head_sha, :key_missing)` returns `:key_missing`, not the
    asserted `head_sha` string → assertion fails.
  - D-361 test: spy `merge_fun` receives the declared `"declared-hash-XXX"`, not
    the asserted `"agent-sha-YYY"` → assertion fails.
  - D-363 test: `Map.has_key?(data, :head_sha)` is `false` (key absent from the
    current data map) → assertion fails.

  ## D-NNN linkage
    - D-361 — `test "D-361: ..."`
    - D-362 — `test "D-362: ..."`
    - D-363 — `test "D-363: ..."`
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :d_361
  @moduletag :d_362
  @moduletag :d_363

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

  # Drive the Unit from :planned through :oracle by delivering {:worker_done, pid}
  # (legacy seam) for the oracle role, leaving it in :implementing with the
  # 3-tuple worker running.
  #
  # For the 3-tuple seam under test we deliver the oracle worker via legacy
  # {:worker_done, pid} (oracle only uses legacy for test simplicity), then the
  # implementing worker is spawned via the 3-tuple worker_fun and we send
  # {:work_ready, worker_id, branch, head_sha} directly.
  defp advance_oracle_to_implementing_via_legacy(unit_pid) do
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

  # Poll until the unit is in the target state (up to max_ms milliseconds).
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
  # D-362 — Capture-on-work_ready: Unit captures branch/head_sha into data
  # ---------------------------------------------------------------------------

  describe "D-362 — Unit captures branch and head_sha from work_ready into data" do
    @tag :d_362
    test "D-362: after {:work_ready, worker_id, branch, head_sha}, data.head_sha and data.branch are set" do
      unit_id = "u-capture-#{System.unique_integer([:positive])}"
      sched = unique(:sched_d362)
      sup = unique(:sup_d362)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      asserted_branch = "feat/test-branch-d362"
      asserted_head_sha = "d362sha_#{System.unique_integer([:positive])}"

      # The 3-tuple worker_fun stores the worker_id so we can send work_ready.
      {:ok, worker_id_store} = Agent.start_link(fn -> nil end)
      on_exit(fn -> if Process.alive?(worker_id_store), do: Agent.stop(worker_id_store) end)

      worker_fun = fn role ->
        worker_pid = spawn_worker()

        case role do
          :test_author ->
            # oracle uses legacy seam; worker_id not stored for oracle
            {:ok, worker_pid}

          :implementer ->
            worker_id = "wid-#{System.unique_integer([:positive])}"
            Agent.update(worker_id_store, fn _ -> worker_id end)
            {:ok, worker_pid, worker_id}
        end
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "declared-hash-#{unit_id}",
        scheduler: sched,
        report_to: self(),
        worker_fun: worker_fun,
        gate_fun: fn -> {:fail, [:stop_here]} end,
        merge_fun: fn _uid, _hash -> :queued end,
        timeouts: [state_timeout_ms: 5_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      # Drive oracle through (legacy {:worker_done}).
      advance_oracle_to_implementing_via_legacy(unit_pid)

      # Wait for implementing state, then send work_ready with the asserted coordinate.
      assert wait_for_state(unit_pid, :implementing),
             "D-362: Unit must reach :implementing after oracle completes"

      worker_id = Agent.get(worker_id_store, & &1)
      refute is_nil(worker_id), "D-362: worker_id must be set by the 3-tuple worker_fun"

      send(unit_pid, {:work_ready, worker_id, asserted_branch, asserted_head_sha})

      # Wait for gating (work_ready → gating transition).
      :timer.sleep(150)

      # Read the FSM data AFTER the transition. In :gating, we capture gate_fun's
      # immediate fail result and bounce back to implementing, but we need to observe
      # the data AS SOON AS possible. Use :sys.get_state regardless of current state —
      # the captured data should persist through gating into the next implementing entry.
      {_state, data} = :sys.get_state(unit_pid)

      assert Map.get(data, :head_sha, :key_missing) == asserted_head_sha,
             "D-362: after {:work_ready, worker_id, branch, head_sha}, data.head_sha " <>
               "must equal the asserted head_sha. Got: #{inspect(Map.get(data, :head_sha, :key_missing))}. " <>
               "Current code discards head_sha in work_ready handlers (uses _head_sha); " <>
               "the capture `%{data | head_sha: head_sha}` is not yet implemented."

      assert Map.get(data, :branch, :key_missing) == asserted_branch,
             "D-362: after {:work_ready, worker_id, branch, head_sha}, data.branch " <>
               "must equal the asserted branch. Got: #{inspect(Map.get(data, :branch, :key_missing))}. " <>
               "Current code discards branch in work_ready handlers (uses _branch)."
    end
  end

  # ---------------------------------------------------------------------------
  # D-361 — Gate/merge coordinate is the captured head_sha, not the declared hash
  # ---------------------------------------------------------------------------

  describe "D-361 — merge_fun receives captured head_sha as the coordinate, not the declared hash" do
    @tag :d_361
    test "D-361: when captured head_sha != declared hash, merge_fun receives captured head_sha" do
      test_pid = self()
      unit_id = "u-coordinate-#{System.unique_integer([:positive])}"
      sched = unique(:sched_d361)
      sup = unique(:sup_d361)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # Declared hash and agent-asserted head_sha are deliberately different.
      declared_hash = "declared-hash-d361-#{System.unique_integer([:positive])}"
      agent_head_sha = "agent-sha-d361-#{System.unique_integer([:positive])}"
      agent_branch = "feat/branch-d361"

      assert declared_hash != agent_head_sha,
             "Test setup: declared_hash and agent_head_sha must differ to make D-361 observable"

      {:ok, worker_id_store} = Agent.start_link(fn -> nil end)
      on_exit(fn -> if Process.alive?(worker_id_store), do: Agent.stop(worker_id_store) end)

      worker_fun = fn role ->
        worker_pid = spawn_worker()

        case role do
          :test_author ->
            {:ok, worker_pid}

          :implementer ->
            worker_id = "wid-d361-#{System.unique_integer([:positive])}"
            Agent.update(worker_id_store, fn _ -> worker_id end)
            {:ok, worker_pid, worker_id}
        end
      end

      # merge_fun spy: captures the hash it receives and broadcasts :merged so the
      # Unit can reach terminal :merged.
      merge_fun = fn uid, received_hash ->
        send(test_pid, {:merge_called, uid, received_hash})
        :ok = Phoenix.PubSub.broadcast(Tau.PubSub, "factory:pr:#{uid}", {:merge_result, :merged})
        :queued
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: declared_hash,
        scheduler: sched,
        report_to: self(),
        pubsub: Tau.PubSub,
        worker_fun: worker_fun,
        gate_fun: fn -> :pass end,
        merge_fun: merge_fun,
        timeouts: [state_timeout_ms: 5_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      # Drive oracle through (legacy {:worker_done}).
      advance_oracle_to_implementing_via_legacy(unit_pid)

      assert wait_for_state(unit_pid, :implementing),
             "D-361: Unit must reach :implementing"

      worker_id = Agent.get(worker_id_store, & &1)
      refute is_nil(worker_id), "D-361: worker_id must be set by 3-tuple worker_fun"

      # Deliver work_ready with the agent-asserted coordinate (differs from declared hash).
      send(unit_pid, {:work_ready, worker_id, agent_branch, agent_head_sha})

      # merge_fun will be called in awaiting_merge; we capture the hash it receives.
      assert_receive {:merge_called, ^unit_id, received_hash},
                     5_000,
                     "D-361: merge_fun must be called after gate :pass"

      assert received_hash == agent_head_sha,
             "D-361: merge_fun must receive the captured head_sha (\"#{agent_head_sha}\"), " <>
               "NOT the pre-declared work_item.hash (\"#{declared_hash}\"). " <>
               "Got: #{inspect(received_hash)}. " <>
               "Current code calls merge_fun(data.unit_id, data.hash) which is always the " <>
               "pre-declared hash — the captured coordinate is not yet threaded to merge_fun."
    end
  end

  # ---------------------------------------------------------------------------
  # D-363 — Back-compat: legacy 2-tuple seam stays on declared hash; head_sha nil
  # ---------------------------------------------------------------------------

  describe "D-363 — legacy 2-tuple worker_fun: head_sha stays nil, merge receives declared hash" do
    @tag :d_363
    test "D-363: with legacy {:worker_done, pid} seam, data.head_sha is nil and merge gets declared hash" do
      test_pid = self()
      unit_id = "u-backcompat-#{System.unique_integer([:positive])}"
      sched = unique(:sched_d363)
      sup = unique(:sup_d363)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      declared_hash = "declared-hash-d363-#{System.unique_integer([:positive])}"

      # Legacy 2-tuple worker_fun: no worker_id, no work_ready, completed via
      # {:worker_done, worker_pid}. The Unit should NOT capture any head_sha.
      worker_fun = fn _role -> {:ok, spawn_worker()} end

      merge_fun = fn uid, received_hash ->
        send(test_pid, {:merge_called, uid, received_hash})
        :ok = Phoenix.PubSub.broadcast(Tau.PubSub, "factory:pr:#{uid}", {:merge_result, :merged})
        :queued
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: declared_hash,
        scheduler: sched,
        report_to: self(),
        pubsub: Tau.PubSub,
        worker_fun: worker_fun,
        gate_fun: fn -> :pass end,
        merge_fun: merge_fun,
        timeouts: [state_timeout_ms: 5_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      # Drive oracle via legacy {:worker_done}.
      :timer.sleep(50)

      case :sys.get_state(unit_pid) do
        {:oracle, data} ->
          worker_pid = Map.get(data, :worker_pid)
          if is_pid(worker_pid), do: send(unit_pid, {:worker_done, worker_pid})

        _ ->
          :ok
      end

      :timer.sleep(100)

      assert wait_for_state(unit_pid, :implementing),
             "D-363: Unit must reach :implementing via legacy oracle path"

      # Drive implementing via legacy {:worker_done}.
      :timer.sleep(50)

      case :sys.get_state(unit_pid) do
        {:implementing, data} ->
          worker_pid = Map.get(data, :worker_pid)
          if is_pid(worker_pid), do: send(unit_pid, {:worker_done, worker_pid})

        _ ->
          :ok
      end

      # After implementing completes via legacy seam, check FSM data for :head_sha key.
      # The implementation MUST initialise data.head_sha = nil so that Map.has_key?
      # returns true even when no capture has occurred. Current code has NO :head_sha
      # key in data at all, so this assertion FAILS now and will PASS after D-363 lands.
      :timer.sleep(100)
      {_state, data_after} = :sys.get_state(unit_pid)

      assert Map.has_key?(data_after, :head_sha),
             "D-363: data MUST have a :head_sha key (initialised to nil) even when the " <>
               "legacy 2-tuple seam is used and no capture has occurred. " <>
               "Current code's data map has no :head_sha key at all. " <>
               "Got data keys: #{inspect(Map.keys(data_after))}."

      assert Map.get(data_after, :head_sha) == nil,
             "D-363: data.head_sha MUST be nil when the legacy 2-tuple seam is used " <>
               "(no work_ready, no capture). " <>
               "Got: #{inspect(Map.get(data_after, :head_sha))}."

      # Wait for merge_fun to be called and verify it receives the declared hash.
      assert_receive {:merge_called, ^unit_id, received_hash},
                     5_000,
                     "D-363: merge_fun must be called after gate :pass"

      assert received_hash == declared_hash,
             "D-363: with legacy 2-tuple seam (head_sha = nil), merge_fun MUST receive " <>
               "the declared work_item.hash (\"#{declared_hash}\"), not nil and not something else. " <>
               "Got: #{inspect(received_hash)}."
    end
  end
end
