defmodule Tau.Factory.CodingAgentShimHeartbeatTest do
  @moduledoc """
  Gating test for PR #504 (#487 — A1: wire real Tau.CodingAgent substrate as the
  worker agent). Advances AC-14, D-366 (SPEC-FACTORY-FLEET §4 B4-A1, §6).

  Written BEFORE production code exists (oracle-separation, factory-loop §4b).
  These tests MUST FAIL against the current branch because:
    - `Tau.Factory.CodingAgentShim` does not exist yet.
    - Calling `Tau.Factory.CodingAgentShim.write/2` will raise
      `UndefinedFunctionError`.

  ## The contract under test (D-366)

  SPEC-FACTORY-FLEET §4 B4-A1 and §6 D-366:

    * The shim emits a `{:packet,4}` heartbeat frame derived from CONSUMED
      CodingAgent stream events (`AssistantText`, `ToolUse`, `ToolResult`,
      `FileEdit`), rate-limited to at most one per `heartbeat_interval`.
    * A wedged agent emitting NO stream events stops pulsing heartbeats.
    * A self-clock timer that fires regardless of stream activity is NOT
      sufficient (V12 finding against the current worker heartbeat).
    * `□( emits_heartbeat(t) ⇒ ∃ stream_event consumed in (t−interval, t] )`.

  ## Pinned heartbeat frame wire format

  A heartbeat frame is a `{:packet,4}`-framed JSON object on the shim's stdout:

      {"type":"heartbeat"}

  The Worker decodes this via its existing `decode_event/1` path and treats it
  as a liveness pulse (forwarding `{:worker_heartbeat, worker_id}` to `report_to`
  when a `heartbeat_interval` is configured — same as the existing self-clock path
  in `handle_info(:heartbeat, state)` but now event-driven).

  ## Test strategy

  We use the Replay adapter with configurable per-event delays to control timing:

  1. **Active stream test**: events arriving faster than `heartbeat_interval`
     → the Worker receives at least one `{:worker_heartbeat, worker_id}` message
     within the run window.

  2. **Gap test (the discriminating assertion)**: a Replay fixture with a gap
     longer than `heartbeat_interval` between two event batches → the Worker
     receives NO heartbeat during the gap window. After the gap events resume,
     heartbeats resume. A self-clock timer would fire during the gap (the
     counter-example D-366 forbids).

  Because the shim is an executable separate from the Worker process, the
  heartbeat frames arrive as `{:data, frame}` on the Worker's Port. The Worker
  forwards each decoded heartbeat to `report_to` as `{:worker_heartbeat, worker_id}`.

  ## AC linkage
    - AC-14 / D-366 — all tests below.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :ac_14
  @moduletag :d_366

  alias Tau.CodingAgent.Event

  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # heartbeat_interval used in tests (ms). Small enough for fast tests but
  # large enough to distinguish event-driven from clock-driven.
  @hb_interval_ms 200

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

  defp mk_tmp(tag) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "tau_#{tag}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    tmp_dir
  end

  defp start_fleet(tag) do
    n = System.unique_integer([:positive])
    registry_name = :"hb_reg_#{tag}_#{n}"
    sup_name = :"hb_sup_#{tag}_#{n}"

    {:ok, _reg} =
      start_supervised({@worker_registry, name: registry_name}, id: :"reg_#{n}")

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"sup_#{n}"
      )

    {sup, registry_name}
  end

  # A fixture with several events, each separated by a short delay.
  # The shim is instructed to use per-event delay_ms so the events arrive
  # spread over time, making heartbeat emission observable.
  defp active_stream_fixture do
    [
      %Event.Start{agent: :replay, version: "0.0.0", pid: nil},
      %Event.AssistantText{text: "step 1", turn: 0},
      %Event.AssistantText{text: "step 2", turn: 0},
      %Event.ToolUse{id: "t1", name: "Bash", input: %{"command" => "echo hi"}},
      %Event.ToolResult{tool_use_id: "t1", content: "hi", is_error: false},
      %Event.AssistantText{text: "step 3", turn: 0},
      %Event.Cost{tokens: %{}, usd: 0.0, duration_ms: 0},
      %Event.Done{exit_status: 0, final_message: nil}
    ]
  end

  # ---------------------------------------------------------------------------
  # D-366 test 1: active stream produces at least one heartbeat
  #
  # Full contract: the shim emits {:packet,4} heartbeat frames derived from
  # CONSUMED stream events (AssistantText, ToolUse, ToolResult, FileEdit);
  # the Worker forwards {:worker_heartbeat, worker_id} to report_to for each.
  # ---------------------------------------------------------------------------

  describe "D-366 heartbeat source" do
    @tag :ac_14
    @tag :d_366
    test "D-366: active stream events produce heartbeat frames forwarded as {:worker_heartbeat, worker_id}" do
      tmp_dir = mk_tmp("shim_hb_active")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      n = System.unique_integer([:positive])
      shim_bin = Path.join(tmp_dir, "shim_hb_#{n}")

      # D-366: UndefinedFunctionError on current branch — correct fail-before state.
      # The shim must accept :heartbeat_interval_ms and :replay_delay_ms so tests
      # can control the timing relationship between events and heartbeat emission.
      shim_bin =
        Tau.Factory.CodingAgentShim.write(shim_bin,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture: active_stream_fixture(),
          branch: "feat/hb-active-#{n}",
          workspace_backend: Tau.CodingAgent.Workspace.Cwd,
          heartbeat_interval_ms: @hb_interval_ms,
          # Events arrive slightly faster than hb_interval so at least one
          # heartbeat fires during the stream.
          replay_delay_ms: div(@hb_interval_ms, 3)
        )

      {sup, registry_name} = start_fleet(:shim_hb_active)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "hb active brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name,
          heartbeat_interval: @hb_interval_ms
        )

      # D-366: at least one heartbeat must arrive BEFORE the run completes.
      assert_receive {:worker_heartbeat, ^worker_id},
                     5_000,
                     "D-366: the shim must emit a {:packet,4} heartbeat frame derived from " <>
                       "consumed stream events; the Worker forwards {:worker_heartbeat, worker_id}. " <>
                       "Fails on current branch: Tau.Factory.CodingAgentShim is undefined."

      # Wait for the run to finish.
      assert_receive msg
                     when elem(msg, 0) in [:work_ready, :worker_exit] and
                            elem(msg, 1) == worker_id,
                     10_000,
                     "D-366: run must complete after heartbeats"
    end

    # D-366 test 2: gap in stream stops heartbeats (the discriminating assertion)
    #
    # Full contract: during a gap longer than heartbeat_interval between stream
    # events, the shim emits NO heartbeat (a self-clock timer would fire here —
    # that is the V12 bug D-366 closes). After the gap, events resume and
    # heartbeats resume.
    @tag :ac_14
    @tag :d_366
    test "D-366: gap in stream stops heartbeat emission (self-clock timer fails this)" do
      tmp_dir = mk_tmp("shim_hb_gap")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      # A fixture where the first batch of events is followed by a long silence
      # (represented as a high replay_delay_ms on the Done event), then the Done
      # arrives. During the silence window no heartbeat should fire.
      #
      # We model this by using two fixture variants passed to the shim:
      #  - early_events: arrive quickly (produce heartbeats)
      #  - gap + Done: done arrives after 3× hb_interval (no events → no heartbeat)
      #
      # The shim accepts :replay_fixture_phases — a list of {events, delay_ms}
      # pairs applied in order, so the test can widen the gap independently.
      gap_ms = @hb_interval_ms * 3

      early_events = [
        %Event.Start{agent: :replay, version: "0.0.0", pid: nil},
        %Event.AssistantText{text: "pre-gap step", turn: 0}
      ]

      late_events = [
        %Event.Cost{tokens: %{}, usd: 0.0, duration_ms: 0},
        %Event.Done{exit_status: 0, final_message: nil}
      ]

      n = System.unique_integer([:positive])
      shim_bin = Path.join(tmp_dir, "shim_hb_gap_#{n}")

      # D-366: UndefinedFunctionError on current branch — correct fail-before state.
      shim_bin =
        Tau.Factory.CodingAgentShim.write(shim_bin,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture_phases: [
            {early_events, div(@hb_interval_ms, 4)},
            {late_events, 0}
          ],
          gap_before_phase_ms: [0, gap_ms],
          branch: "feat/hb-gap-#{n}",
          workspace_backend: Tau.CodingAgent.Workspace.Cwd,
          heartbeat_interval_ms: @hb_interval_ms
        )

      {sup, registry_name} = start_fleet(:shim_hb_gap)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "hb gap brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name,
          heartbeat_interval: @hb_interval_ms
        )

      # Drain any heartbeats from the early-event phase.
      # The discriminating check is: DURING the gap window, no heartbeat fires.

      # Wait for the early-phase heartbeat(s) to arrive.
      assert_receive {:worker_heartbeat, ^worker_id},
                     5_000,
                     "D-366 precondition: at least one heartbeat expected in the pre-gap phase"

      # Record the time the last heartbeat before the gap arrived.
      last_hb_time = System.monotonic_time(:millisecond)

      # During the gap window (gap_ms wide) NO heartbeat should arrive.
      # A self-clock timer firing every @hb_interval_ms would produce one here.
      refute_receive {:worker_heartbeat, ^worker_id},
                     gap_ms,
                     "D-366: NO heartbeat must fire during the stream gap (gap=#{gap_ms}ms > " <>
                       "hb_interval=#{@hb_interval_ms}ms). A self-clock timer fires here regardless " <>
                       "of agent progress — that is the V12 bug D-366 closes. " <>
                       "Fails on current branch: Tau.Factory.CodingAgentShim is undefined."

      gap_duration = System.monotonic_time(:millisecond) - last_hb_time

      assert gap_duration >= @hb_interval_ms,
             "D-366: gap assertion window too short (#{gap_duration}ms < #{@hb_interval_ms}ms)"

      # Wait for the run to complete (late events arrive after the gap, resuming heartbeats).
      assert_receive msg
                     when elem(msg, 0) in [:work_ready, :worker_exit] and
                            elem(msg, 1) == worker_id,
                     10_000,
                     "D-366: run must complete after the gap+late-events phase"
    end
  end
end
