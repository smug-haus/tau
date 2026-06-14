defmodule Tau.Factory.UnitMergeResultTest do
  @moduledoc """
  Gating test for PR #477 — the **consume half** of the D-356 merge-result
  delivery contract (SPEC-FACTORY-CORE §4 B6 / §6 D-356; arch
  `control-plane.md` §3.2.2).

  ## What this enforces (SPEC-FACTORY-CORE §6 D-356, §4 B6)

  When a `Tau.Factory.Unit` enters `awaiting_merge` and the D-355 reconcile
  returns `:none`, it MUST:

    1. `Phoenix.PubSub.subscribe(Tau.PubSub, "factory:pr:\#{unit_id}")` — and only
       AFTER that returns `:ok`;
    2. invoke `merge_fun` (→ `request_merge`).

  Because Phoenix.PubSub is at-most-once with no replay, the subscribe-before-
  request ordering is LOAD-BEARING: a `{:merge_result, _}` broadcast that fires
  BEFORE (or concurrently with) the request must STILL reach U — the
  subscription provably exists at every possible publish instant. U then
  consumes `{:merge_result, :merged}` (→ terminal `:merged`) / `{:merge_result,
  :rejected}` (→ re-gate, INV-2) DIRECTLY off its mailbox (no driver bridge),
  and UNSUBSCRIBES on EVERY exit from `awaiting_merge` (→ merged, → gating on
  :rejected, → escalated on state_timeout). A late or duplicate broadcast after
  unsubscribe is dropped harmlessly (no subscriber).

  ## Fail-before validity (oracle separation, factory-loop §4b)

  On THIS branch the Unit's `awaiting_merge(:internal, :on_enter, …)` :none
  branch calls `merge_fun` WITHOUT first subscribing to `"factory:pr:\#{id}"`,
  and there is no `:pubsub` opt nor any unsubscribe. A `{:merge_result, _}`
  broadcast on the topic is therefore DROPPED (the Unit is not a subscriber), so
  U never reaches its merged/rejected transition — it sits until `state_timeout`
  and escalates. Every assertion that the broadcast drives U to terminal/re-gate
  therefore FAILS against the current code. A test that passed against the
  current code would be vacuous.

  This file starts a REAL `Tau.Factory.Unit` (via `UnitSupervisor.start_unit/2`)
  with a `:pubsub` opt and a `merge_fun` that BROADCASTS the result to
  `"factory:pr:\#{unit_id}"` — exercising the real subscription path, not a direct
  `send` to the unit pid.

  ## D-NNN linkage
    - D-356 — every test in this file.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :d_356

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Helpers (mirror merge_outcome_durability_test.exs drive idiom)
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

  defp start_scheduler(name), do: start_supervised!({@scheduler, name: name, w_cap: 10}, id: name)

  # A trivial live worker pid that simply parks; the Unit only needs a monitorable
  # pid plus a {:worker_done, pid} trigger to advance oracle → implementing → gating.
  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp pr_topic(unit_id), do: "factory:pr:#{unit_id}"

  # Drive a Unit forward oracle → implementing → gating(:pass) → awaiting_merge by
  # delivering {:worker_done, pid} for the oracle and implementing workers
  # (mirrors merge_outcome_durability_test.exs).
  defp drive_to_awaiting_merge(unit_pid) do
    deliver_worker_done(unit_pid)
    :timer.sleep(50)
    deliver_worker_done(unit_pid)
    :timer.sleep(100)
  end

  defp deliver_worker_done(unit_pid) do
    :timer.sleep(50)

    case :sys.get_state(unit_pid) do
      {state, data} when state in [:oracle, :implementing] ->
        worker_pid = Map.get(data, :worker_pid)
        if is_pid(worker_pid), do: send(unit_pid, {:worker_done, worker_pid})

      _ ->
        :ok
    end
  end

  defp base_unit_opts(unit_id, merge_fun, gate_fun) do
    [
      unit_id: unit_id,
      declared_scope: empty_scope(),
      hash: "hash-#{unit_id}",
      scheduler: unique(:sched_placeholder),
      report_to: self(),
      pubsub: Tau.PubSub,
      worker_fun: fn _role -> {:ok, spawn_worker()} end,
      gate_fun: gate_fun,
      merge_fun: merge_fun,
      timeouts: [state_timeout_ms: 4_000]
    ]
  end

  # ---------------------------------------------------------------------------
  # D-356 consume — normal timing: merge_fun broadcasts :merged AFTER returning
  # :queued. U (subscribed on entry) receives it off the topic and reaches
  # terminal :merged with NO state_timeout escalation.
  # ---------------------------------------------------------------------------

  describe "D-356 — Unit consumes {:merge_result, :merged} from the per-PR topic (normal timing)" do
    @tag :d_356
    test "D-356: a topic broadcast after request drives U to terminal :merged, no escalation" do
      test_pid = self()
      unit_id = "u-consume-merged-#{System.unique_integer([:positive])}"

      sched = unique(:sched_consume_merged)
      sup = unique(:sup_consume_merged)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # merge_fun broadcasts the result to the per-PR topic AFTER the (notional)
      # request, then returns :queued. This is the authoritative async-delivery
      # path (D-356), NOT a direct send to the unit pid.
      merge_fun = fn uid, _hash ->
        :ok = Phoenix.PubSub.broadcast(Tau.PubSub, pr_topic(uid), {:merge_result, :merged})
        send(test_pid, {:merge_requested, uid})
        :queued
      end

      opts =
        base_unit_opts(unit_id, merge_fun, fn _coord -> :pass end)
        |> Keyword.put(:scheduler, sched)

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      drive_to_awaiting_merge(unit_pid)

      assert_receive {:merge_requested, ^unit_id},
                     5_000,
                     "D-356: Unit must reach awaiting_merge and invoke merge_fun"

      assert_receive {:unit_terminal, ^unit_id, :merged, _provenance},
                     5_000,
                     "D-356: a {:merge_result, :merged} broadcast on #{pr_topic(unit_id)} must " <>
                       "reach U (subscribed on awaiting_merge entry) and drive it to terminal " <>
                       ":merged. Not receiving it means U never subscribed — the at-most-once " <>
                       "broadcast was dropped and U will sit until state_timeout."

      # An escalation would arrive as :escalated, never as :merged above; assert
      # explicitly that no spurious escalation followed.
      refute_received {:unit_terminal, ^unit_id, :escalated, _}
    end
  end

  # ---------------------------------------------------------------------------
  # D-356 consume — WORST-CASE TIMING: merge_fun broadcasts the result BEFORE it
  # returns :queued (the publish races the subscription). The subscribe-before-
  # request ordering must make U STILL receive it. This is the load-bearing case.
  # ---------------------------------------------------------------------------

  describe "D-356 — subscribe-before-request closes the race (worst-case timing)" do
    @tag :d_356
    test "D-356: a broadcast emitted from inside merge_fun (before :queued) still reaches U" do
      test_pid = self()
      unit_id = "u-consume-race-#{System.unique_integer([:positive])}"

      sched = unique(:sched_consume_race)
      sup = unique(:sup_consume_race)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # The broadcast fires as the FIRST action inside merge_fun, before :queued
      # is returned — modelling the at-most-once publish racing U's subscription.
      # If U subscribed strictly BEFORE invoking merge_fun (D-356 ordering), the
      # subscription exists at this instant and the broadcast is delivered. If U
      # subscribed after (or not at all), the broadcast is lost.
      merge_fun = fn uid, _hash ->
        :ok = Phoenix.PubSub.broadcast(Tau.PubSub, pr_topic(uid), {:merge_result, :merged})
        send(test_pid, {:merge_requested, uid})
        :queued
      end

      opts =
        base_unit_opts(unit_id, merge_fun, fn _coord -> :pass end)
        |> Keyword.put(:scheduler, sched)

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      drive_to_awaiting_merge(unit_pid)

      assert_receive {:merge_requested, ^unit_id}, 5_000

      assert_receive {:unit_terminal, ^unit_id, :merged, _provenance},
                     5_000,
                     "D-356 (load-bearing): a result broadcast BEFORE merge_fun returns must " <>
                       "still reach U. U MUST subscribe to #{pr_topic(unit_id)} BEFORE invoking " <>
                       "merge_fun (subscribe-before-request). If U requested before subscribing, " <>
                       "this at-most-once broadcast is lost and U escalates on state_timeout."
    end
  end

  # ---------------------------------------------------------------------------
  # D-356 unsubscribe-on-exit — after reaching terminal :merged (leaving
  # awaiting_merge), U holds NO subscription to the topic: a LATE broadcast from a
  # second process is dropped and U does NOT act on it (stays :merged).
  # ---------------------------------------------------------------------------

  describe "D-356 — Unit unsubscribes from the per-PR topic on leaving awaiting_merge" do
    @tag :d_356
    test "D-356: a late broadcast after :merged is ignored — U holds no subscription post-exit" do
      test_pid = self()
      unit_id = "u-unsub-merged-#{System.unique_integer([:positive])}"

      sched = unique(:sched_unsub_merged)
      sup = unique(:sup_unsub_merged)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      merge_fun = fn uid, _hash ->
        :ok = Phoenix.PubSub.broadcast(Tau.PubSub, pr_topic(uid), {:merge_result, :merged})
        send(test_pid, {:merge_requested, uid})
        :queued
      end

      opts =
        base_unit_opts(unit_id, merge_fun, fn _coord -> :pass end)
        |> Keyword.put(:scheduler, sched)

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      drive_to_awaiting_merge(unit_pid)

      assert_receive {:unit_terminal, ^unit_id, :merged, _provenance},
                     5_000,
                     "D-356: U must reach terminal :merged via the topic broadcast"

      # U is now in the terminal :merged sink, having LEFT awaiting_merge — and
      # MUST have unsubscribed from the topic on that exit. A SECOND process now
      # broadcasts a late {:merge_result, :rejected}. If U were still subscribed
      # it would receive it; but :merged is a quiescent sink that would log it as
      # unexpected — the load-bearing assertion is that U remains in :merged (the
      # late delivery cannot move it, because there is no subscription).
      spawn(fn ->
        Phoenix.PubSub.broadcast(Tau.PubSub, pr_topic(unit_id), {:merge_result, :rejected})
      end)

      :timer.sleep(200)

      {state, _data} = :sys.get_state(unit_pid)

      assert state == :merged,
             "D-356: after leaving awaiting_merge, U must hold NO subscription to " <>
               "#{pr_topic(unit_id)}. A late {:merge_result, :rejected} broadcast must be " <>
               "dropped (no subscriber). U remained in #{inspect(state)}, not :merged — a sign " <>
               "the subscription survived the exit and the late delivery was acted on."

      refute_received {:unit_terminal, ^unit_id, :rejected, _}
    end

    @tag :d_356
    test "D-356: a {:merge_result, :rejected} broadcast drives U back to gating (re-gate, INV-2)" do
      test_pid = self()
      unit_id = "u-rejected-regate-#{System.unique_integer([:positive])}"

      sched = unique(:sched_rejected_regate)
      sup = unique(:sup_rejected_regate)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # merge_fun broadcasts :rejected on the FIRST awaiting_merge entry, then
      # :merged on every subsequent entry, so the unit re-gates once then settles.
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

      merge_fun = fn uid, _hash ->
        n = Agent.get_and_update(calls, fn c -> {c, c + 1} end)
        outcome = if n == 0, do: :rejected, else: :merged
        :ok = Phoenix.PubSub.broadcast(Tau.PubSub, pr_topic(uid), {:merge_result, outcome})
        send(test_pid, {:merge_requested, uid, outcome})
        :queued
      end

      opts =
        base_unit_opts(unit_id, merge_fun, fn _coord -> :pass end)
        |> Keyword.put(:scheduler, sched)

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      drive_to_awaiting_merge(unit_pid)

      # First awaiting_merge entry → :rejected broadcast → U re-gates (INV-2).
      assert_receive {:merge_requested, ^unit_id, :rejected},
                     5_000,
                     "D-356: U must reach awaiting_merge and invoke merge_fun the first time"

      # The :rejected broadcast must route U BACK to gating (re-gate), which —
      # with gate_fun :pass — loops to awaiting_merge again and re-subscribes,
      # this time consuming :merged. Observing the SECOND merge_fun call proves U
      # consumed the :rejected from the topic and re-gated.
      assert_receive {:merge_requested, ^unit_id, :merged},
                     6_000,
                     "D-356: a {:merge_result, :rejected} broadcast on #{pr_topic(unit_id)} must " <>
                       "drive U back to :gating (re-gate, INV-2) — observed as a SECOND merge_fun " <>
                       "invocation after re-entering awaiting_merge. If U never subscribed, the " <>
                       ":rejected was dropped and no re-gate occurred."

      assert_receive {:unit_terminal, ^unit_id, :merged, _provenance},
                     6_000,
                     "D-356: after the re-gate cycle the second-entry :merged broadcast drives U " <>
                       "to terminal :merged"
    end
  end
end
