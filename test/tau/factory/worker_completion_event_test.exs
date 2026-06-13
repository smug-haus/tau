defmodule Tau.Factory.WorkerCompletionEventTest do
  @moduledoc """
  Gating test for PR #468 (P5c-3a — implement D-326: Worker `work_ready`
  completion event → Unit `implementing → gating` trigger).

  Closes #467. Advances AC-13 (SPEC-FACTORY-FLEET §4 B4, D-326) and the cited
  Unit-trigger contract (SPEC-FACTORY-CORE §4 B8).

  Written BEFORE production code exists (oracle-separation phase, factory-loop
  §4b). These tests MUST FAIL against current `main`:

    * `Tau.Factory.Worker.handle_info({port, {:data, _}}, …)` currently IGNORES
      agent Port output ("future: forward to Unit FSM") — so NO `work_ready` is
      ever forwarded to `report_to`.
    * `Tau.Factory.Unit` consumes the `{:worker_done, worker_pid}` placeholder,
      NOT `work_ready(worker_id, branch, head_sha)` — so it never gates on
      `work_ready` and never discards a stale-worker `work_ready`.

  A compile/timeout/assertion failure here is the correct fail-before state; it
  is NOT to be resolved by writing production code.

  ## The contract under test (D-326 / AC-13)

  SPEC-FACTORY-FLEET §4 B4 (the agent Port) and §4 B1 + D-326 (lines 269-279,
  318-337, 494-514); SPEC-FACTORY-CORE §4 B8 (lines 378-391):

    * A normally-completing agent emits an in-band `work_ready(branch, head_sha)`
      frame over its `{:packet,4}` Port BEFORE it exits.
    * The **Worker** decodes that frame and is the SOLE forwarder of
      `work_ready(worker_id, branch, head_sha)` to its owning Unit (`report_to`),
      keyed by `worker_id` — the single-writer discipline that mirrors the
      independent monitor's sole ownership of `worker_exit`.
    * `work_ready` is the ONLY trigger of U's `implementing → gating` edge.
    * `{:exit_status, 0}` with NO prior `work_ready` is fail-closed: surfaced as
      `worker_exit(worker_id, :no_work_product)`, a semantic non-completion routed
      to U's retry ladder, NEVER gated.
    * U tags the CURRENT `worker_id` and DISCARDS `work_ready` from a superseded
      worker.

  ## PINNED shapes (oracle-declared; see "SPEC gap" in the PR report)

  The §4 contracts name the events and their payloads but DO NOT pin (a) the
  exact wire encoding inside the `{:packet,4}` frame, (b) the exact Worker→Unit
  message tuple, nor (c) how the Unit's `worker_fun` seam surfaces a `worker_id`.
  Pending the §3 amendment, this oracle pins defensible, SPEC-consistent shapes
  the implementer MUST conform to (or the test-author corrects on amendment):

  ### Wire frame (agent → Worker, decoded by `handle_info({port,{:data,_}},…)`)
  A `{:packet,4}` frame whose payload is a JSON object (the shell-writable,
  stream-json-consistent encoding; `Jason.decode/1`):

      {"type":"work_ready","branch":"<branch>","head_sha":"<sha>"}

  With `{:packet, 4}` the BEAM strips the 4-byte big-endian length header, so the
  Worker's `{:data, payload}` carries exactly the JSON bytes. The dummy agent
  below writes the 4-byte BE length prefix itself, then the JSON, then exits 0.

  ### Worker → Unit (`report_to`) message — the SUCCESS counterpart of
  `{:worker_exit, worker_id, reason}`:

      {:work_ready, worker_id :: String.t(), branch :: String.t(), head_sha :: String.t()}

  ### Fail-closed exit-0-without-work_ready — reuses the death-cert channel:

      {:worker_exit, worker_id :: String.t(), :no_work_product}

  ### Unit consumes `work_ready` keyed by `worker_id`
  The Unit, on entering `implementing`, holds the CURRENT worker's `worker_id`
  (test-observable via `:sys.get_state/1` under `data.worker_id`). It transitions
  `implementing → gating` on `{:work_ready, ^worker_id, _branch, _sha}` and
  IGNORES `{:work_ready, other_id, _, _}` (stale-worker discard, B8).

  ## AC linkage
    - AC-13 / D-326 — every test below.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :ac_13
  @moduletag :d_326

  # Runtime module references — file compiles even when the D-326 wiring is
  # absent. @mod.fun form (Credo strict), never apply/2,3.
  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor
  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Hermetic git repo (mirrors worker_test.exs idiom)
  # ---------------------------------------------------------------------------

  defp setup_git_repo(tmp_dir) do
    repo_dir = Path.join(tmp_dir, "repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_dir)

    git = fn args ->
      System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    end

    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])

    File.write!(Path.join(repo_dir, "README"), "initial\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial commit"])
    {sha, 0} = git.(["rev-parse", "HEAD"])

    %{repo_dir: repo_dir, base_ref: String.trim(sha)}
  end

  # An agent_bin that emits ONE `{:packet,4}`-framed JSON `work_ready` frame and
  # then exits 0. Writes the 4-byte big-endian length prefix itself (the framing
  # the Worker's `{:packet,4}` Port strips on receive), so the Worker observes a
  # single `{:data, json}` frame BEFORE the `{:exit_status, 0}`.
  #
  # The branch/head_sha are interpolated so the test can assert the EXACT payload
  # the Worker forwards (non-vacuous: the forwarded values must round-trip).
  defp work_ready_agent_bin(tmp_dir, branch, head_sha, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "work_ready_agent#{suffix}")

    json = ~s({"type":"work_ready","branch":"#{branch}","head_sha":"#{head_sha}"})
    len = byte_size(json)

    # 4-byte big-endian length as octal \NNN escapes for printf.
    b0 = Bitwise.band(Bitwise.bsr(len, 24), 0xFF)
    b1 = Bitwise.band(Bitwise.bsr(len, 16), 0xFF)
    b2 = Bitwise.band(Bitwise.bsr(len, 8), 0xFF)
    b3 = Bitwise.band(len, 0xFF)

    oct = fn b -> "\\" <> (b |> Integer.to_string(8) |> String.pad_leading(3, "0")) end
    len_prefix = oct.(b0) <> oct.(b1) <> oct.(b2) <> oct.(b3)

    File.write!(bin_path, """
    #!/bin/sh
    # Write the 4-byte BE length prefix, then the JSON payload, then exit 0.
    printf '#{len_prefix}'
    printf '%s' '#{json}'
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  # An agent_bin that exits 0 WITHOUT ever emitting a work_ready frame.
  defp silent_exit0_agent_bin(tmp_dir, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "silent_agent#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp start_fleet(tag) do
    n = System.unique_integer([:positive])
    registry_name = :"#{tag}_registry_#{n}"
    sup_name = :"#{tag}_sup_#{n}"

    {:ok, _reg} =
      start_supervised({@worker_registry, name: registry_name}, id: :"reg_#{n}")

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"sup_#{n}"
      )

    {sup, registry_name}
  end

  defp mk_tmp(tag) do
    tmp_dir = Path.join(System.tmp_dir!(), "tau_#{tag}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    tmp_dir
  end

  # ---------------------------------------------------------------------------
  # Oracle 1 — Worker FORWARDS work_ready on the in-band frame (keyed by worker_id)
  # ---------------------------------------------------------------------------

  describe "AC-13 / D-326 — Worker forwards work_ready on the in-band frame" do
    @tag :ac_13
    @tag :d_326
    test "AC-13/D-326: Worker decodes the in-band work_ready frame and forwards exactly one {:work_ready, worker_id, branch, head_sha} to report_to" do
      tmp_dir = mk_tmp("wr_forward")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/agent-branch"
      head_sha = String.duplicate("ab12cd34", 5)
      agent_bin = work_ready_agent_bin(tmp_dir, branch, head_sha)

      {sup, registry_name} = start_fleet(:wr_forward)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          report_to: report_to,
          registry: registry_name
        )

      assert is_binary(worker_id),
             "AC-13: spawn/5 must return {:ok, worker_id}; got #{inspect(worker_id)}"

      # The Worker must forward the success event keyed by the REAL worker_id,
      # carrying the EXACT branch/head_sha the agent asserted in-band (D-326).
      assert_receive {:work_ready, ^worker_id, ^branch, ^head_sha},
                     5_000,
                     "AC-13/D-326: Worker must forward {:work_ready, worker_id, branch, head_sha} " <>
                       "to report_to on decoding the in-band work_ready frame. " <>
                       "On current main the Worker IGNORES Port {:data,_} (no forward)."

      # SINGLE-writer discipline (D-326): exactly ONE work_ready, and the clean
      # exit-0 that followed it must NOT also surface as a separate completion or
      # a :no_work_product (the work_ready was seen).
      refute_received {:work_ready, ^worker_id, _b, _h},
                      "AC-13/D-326: the Worker is the SOLE forwarder — exactly one work_ready per worker"

      refute_received {:worker_exit, ^worker_id, :no_work_product},
                      "AC-13/D-326: a worker that emitted work_ready must NOT also surface :no_work_product"
    end
  end

  # ---------------------------------------------------------------------------
  # Oracle 2 — Unit GATES on work_ready (not bare exit)
  # ---------------------------------------------------------------------------

  describe "AC-13 / D-326 — Unit transitions implementing → gating on work_ready" do
    @tag :ac_13
    @tag :d_326
    test "AC-13/D-326: a real Unit in implementing gates ON {:work_ready, worker_id, _, _}, NOT on a bare worker exit" do
      test_pid = self()
      n = System.unique_integer([:positive])
      unit_id = "u-wr-#{n}"
      scheduler_name = :"sched_wr_#{n}"
      sup_name = :"unitsup_wr_#{n}"

      start_supervised!({@scheduler, name: scheduler_name, w_cap: 10}, id: scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # The Unit's worker_fun must surface a worker_id (D-326 keys events by it).
      # Pinned seam: worker_fun.(role) -> {:ok, worker_pid, worker_id}; the Unit
      # stores worker_id under data.worker_id (test-observable).
      worker_id = "w-#{n}"
      worker_pid = spawn(fn -> receive do: (:stop -> :ok) end)

      # gate_fun records that the gate WAS reached — the discriminating signal
      # that the Unit gated on work_ready rather than ignoring it.
      gate_fun = fn ->
        send(test_pid, {:gate_called, unit_id})
        {:fail, [:stop_here]}
      end

      opts = [
        unit_id: unit_id,
        declared_scope: %{
          deps: [],
          files: MapSet.new(),
          codepoints: MapSet.new(),
          specs: MapSet.new(),
          resources: MapSet.new()
        },
        hash: "hash-#{unit_id}",
        scheduler: scheduler_name,
        report_to: test_pid,
        worker_fun: fn _role -> {:ok, worker_pid, worker_id} end,
        gate_fun: gate_fun,
        merge_fun: fn _uid, _hash -> :queued end,
        timeouts: [state_timeout_ms: 5_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      # Advance oracle → implementing. The oracle worker also completes via
      # work_ready (D-326 is the sole completion trigger in BOTH oracle and
      # implementing per §5). Drive each phase by delivering work_ready keyed by
      # the CURRENT worker_id the FSM is waiting on.
      drive_work_ready(unit_pid, worker_id)
      :timer.sleep(50)
      drive_work_ready(unit_pid, worker_id)

      # The gate must have been called — i.e. the Unit reached :gating BECAUSE of
      # work_ready (not a bare exit, which the Unit must not treat as completion).
      assert_receive {:gate_called, ^unit_id},
                     5_000,
                     "AC-13/D-326: the Unit must transition implementing → gating ON work_ready. " <>
                       "On current main the Unit consumes {:worker_done, pid}, not " <>
                       "{:work_ready, worker_id, _, _}, so the gate is never reached this way."
    end
  end

  # Deliver {:work_ready, worker_id, branch, head_sha} to the Unit for whichever
  # waiting state (oracle | implementing) it is currently in, keyed by the
  # CURRENT worker_id (D-326 / B8). The Unit MUST expose data.worker_id.
  defp drive_work_ready(unit_pid, expected_worker_id) do
    :timer.sleep(50)

    case :sys.get_state(unit_pid) do
      {state, data} when state in [:oracle, :implementing] ->
        wid = Map.get(data, :worker_id, expected_worker_id)
        send(unit_pid, {:work_ready, wid, "feat/x", "deadbeef"})

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Oracle 3 — Fail-closed: exit-0 WITHOUT work_ready → :no_work_product, no gate
  # ---------------------------------------------------------------------------

  describe "AC-13 / D-326 — exit-0 without work_ready is fail-closed (:no_work_product)" do
    @tag :ac_13
    @tag :d_326
    test "AC-13/D-326: a Worker whose agent exits 0 WITHOUT work_ready yields worker_exit(:no_work_product), NOT a completion" do
      tmp_dir = mk_tmp("wr_noproduct")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      agent_bin = silent_exit0_agent_bin(tmp_dir)
      {sup, registry_name} = start_fleet(:wr_noproduct)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          report_to: report_to,
          registry: registry_name
        )

      # Fail-closed: a clean exit with NO work_ready is a semantic non-completion.
      assert_receive {:worker_exit, ^worker_id, :no_work_product},
                     5_000,
                     "AC-13/D-326: exit-0 without a prior work_ready MUST surface " <>
                       "{:worker_exit, worker_id, :no_work_product}. On current main the " <>
                       "monitor reports {:worker_exit, worker_id, :normal} — a clean exit is " <>
                       "wrongly treated as benign completion, not fail-closed."

      # It must NEVER surface as a success.
      refute_received {:work_ready, ^worker_id, _b, _h},
                      "AC-13/D-326: a silent exit-0 worker must NOT forge a work_ready completion"
    end

    @tag :ac_13
    @tag :d_326
    test "AC-13/D-326: a Unit does NOT gate on a worker that produced no work_ready (clean exit ≠ completion)" do
      test_pid = self()
      n = System.unique_integer([:positive])
      unit_id = "u-noprod-#{n}"
      scheduler_name = :"sched_noprod_#{n}"
      sup_name = :"unitsup_noprod_#{n}"

      start_supervised!({@scheduler, name: scheduler_name, w_cap: 10}, id: scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      worker_id = "w-noprod-#{n}"
      worker_pid = spawn(fn -> receive do: (:stop -> :ok) end)

      gate_fun = fn ->
        send(test_pid, {:gate_called, unit_id})
        :pass
      end

      opts = [
        unit_id: unit_id,
        declared_scope: %{
          deps: [],
          files: MapSet.new(),
          codepoints: MapSet.new(),
          specs: MapSet.new(),
          resources: MapSet.new()
        },
        hash: "hash-#{unit_id}",
        scheduler: scheduler_name,
        report_to: test_pid,
        worker_fun: fn _role -> {:ok, worker_pid, worker_id} end,
        gate_fun: gate_fun,
        merge_fun: fn _uid, _hash -> :queued end,
        timeouts: [state_timeout_ms: 5_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      # Advance oracle → implementing via work_ready.
      drive_work_ready(unit_pid, worker_id)
      :timer.sleep(50)

      # Now deliver the FAIL-CLOSED exit (no_work_product) for the current worker
      # while the Unit is in implementing. This must NOT drive the gating edge —
      # a clean exit without work_ready is a non-completion, routed to the retry
      # ladder, NEVER gated (D-326 / B8).
      case :sys.get_state(unit_pid) do
        {:implementing, data} ->
          wid = Map.get(data, :worker_id, worker_id)
          send(unit_pid, {:worker_exit, wid, :no_work_product})

        {state, _data} ->
          flunk(
            "AC-13/D-326: Unit must be in :implementing after work_ready; was #{inspect(state)}. " <>
              "On current main the Unit does not consume work_ready, so it never reaches " <>
              "implementing this way."
          )
      end

      # The gate must NOT have been called as a result of the no_work_product exit.
      refute_receive {:gate_called, ^unit_id},
                     1_000,
                     "AC-13/D-326: a :no_work_product exit must NOT trigger implementing → gating " <>
                       "(clean exit is never completion)."
    end
  end

  # ---------------------------------------------------------------------------
  # Oracle 4 — Stale-worker work_ready is discarded
  # ---------------------------------------------------------------------------

  describe "AC-13 / D-326 — stale-worker work_ready is discarded" do
    @tag :ac_13
    @tag :d_326
    test "AC-13/D-326: a work_ready carrying a worker_id that is NOT the Unit's current worker is discarded (Unit does not gate)" do
      test_pid = self()
      n = System.unique_integer([:positive])
      unit_id = "u-stale-#{n}"
      scheduler_name = :"sched_stale_#{n}"
      sup_name = :"unitsup_stale_#{n}"

      start_supervised!({@scheduler, name: scheduler_name, w_cap: 10}, id: scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      current_worker_id = "w-current-#{n}"
      worker_pid = spawn(fn -> receive do: (:stop -> :ok) end)

      gate_fun = fn ->
        send(test_pid, {:gate_called, unit_id})
        :pass
      end

      opts = [
        unit_id: unit_id,
        declared_scope: %{
          deps: [],
          files: MapSet.new(),
          codepoints: MapSet.new(),
          specs: MapSet.new(),
          resources: MapSet.new()
        },
        hash: "hash-#{unit_id}",
        scheduler: scheduler_name,
        report_to: test_pid,
        worker_fun: fn _role -> {:ok, worker_pid, current_worker_id} end,
        gate_fun: gate_fun,
        merge_fun: fn _uid, _hash -> :queued end,
        timeouts: [state_timeout_ms: 5_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      # Advance oracle → implementing via a CURRENT-worker work_ready.
      drive_work_ready(unit_pid, current_worker_id)
      :timer.sleep(50)

      # Confirm we are in implementing with the current worker.
      assert {:implementing, _data} = :sys.get_state(unit_pid),
             "AC-13/D-326: Unit must be in :implementing before the stale-event test"

      # Deliver a work_ready for a SUPERSEDED worker_id — must be discarded (B8).
      stale_worker_id = "w-stale-#{n}"
      send(unit_pid, {:work_ready, stale_worker_id, "feat/stale", "cafebabe"})

      # The stale event must NOT drive the gating edge.
      refute_receive {:gate_called, ^unit_id},
                     1_000,
                     "AC-13/D-326: a work_ready from a superseded worker_id MUST be discarded; " <>
                       "the Unit must not transition implementing → gating on it."

      # And the Unit must still be in :implementing, awaiting its current worker.
      assert {:implementing, _data} = :sys.get_state(unit_pid),
             "AC-13/D-326: after a discarded stale work_ready, the Unit stays in :implementing"
    end
  end
end
