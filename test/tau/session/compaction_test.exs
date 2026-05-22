defmodule Tau.Session.CompactionTest do
  @moduledoc """
  Tests for the async `/compact` built-in command and the D-016 failure counter.

  Covers:
  - AC-9, D-048, D-049, D-016, C67-B4

  Stub compactors are configured via `Application.put_env(:tau, :compactor, ...)`.
  All stubs implement `Tau.Compactor`; `should_compact?` returns `false` (so the
  sync post-turn path never fires) unless noted otherwise (D-016 cross-path tests).

  FSM is driven via `/compact` slash commands delivered through `Tau.send/3`;
  `Tau.snapshot/1` inspects FSM state; `Phoenix.PubSub` captures broadcast events.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-compact-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)
    # Use a very short timeout for compaction in tests to avoid hanging.
    Application.put_env(:tau, :compaction_timeout_ms, 5_000)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
      Application.delete_env(:tau, :compaction_timeout_ms)
      Application.delete_env(:tau, :compactor)
    end)

    :ok
  end

  # Drain all queued SystemNotice messages from the current mailbox for a session.
  # Used to assert absence of specific text without pattern-guard limitations.
  defp flush_notices(sid) do
    case Process.info(self(), :messages) do
      {:messages, msgs} ->
        msgs
        |> Enum.filter(fn
          %SE.SystemNotice{session_id: ^sid} -> true
          _ -> false
        end)
        |> Enum.map(& &1.text)

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Stub compactors
  # ---------------------------------------------------------------------------

  defmodule NeverCompactor do
    @moduledoc "should_compact? always false — the sync path never fires."
    @behaviour Tau.Compactor
    @impl Tau.Compactor
    def should_compact?(_msgs, _usage), do: false
    @impl Tau.Compactor
    def compact(_msgs, _ctx), do: {:error, "NeverCompactor.compact/2 should not be called"}
  end

  defmodule HappyCompactor do
    @moduledoc "Successful compaction. Returns a single-message list + summary."
    @behaviour Tau.Compactor
    @impl Tau.Compactor
    def should_compact?(_msgs, _usage), do: false
    @impl Tau.Compactor
    def compact(messages, _ctx) do
      summary = "Summary of #{length(messages)} messages"

      new_messages = [
        Tau.Message.User.new(
          "<conversation_summary>\n#{summary}\n</conversation_summary>",
          metadata: %{role: :compaction_summary}
        )
      ]

      {:ok, new_messages, summary}
    end
  end

  defmodule ErrorCompactor do
    @moduledoc "Always fails. Used for D-016 tests."
    @behaviour Tau.Compactor
    @impl Tau.Compactor
    def should_compact?(_msgs, _usage), do: false
    @impl Tau.Compactor
    def compact(_msgs, _ctx), do: {:error, "simulated compaction error"}
  end

  defmodule ErrorCompactorWithSync do
    @moduledoc "should_compact? always true AND compact always errors — drives D-016 sync path."
    @behaviour Tau.Compactor
    @impl Tau.Compactor
    def should_compact?(_msgs, _usage), do: true
    @impl Tau.Compactor
    def compact(_msgs, _ctx), do: {:error, "simulated compaction error"}
  end

  defmodule CrashCompactor do
    @moduledoc "compact/2 raises, so the worker process crashes (Clause 2b)."
    @behaviour Tau.Compactor
    @impl Tau.Compactor
    def should_compact?(_msgs, _usage), do: false
    @impl Tau.Compactor
    def compact(_msgs, _ctx), do: raise("CrashCompactor intentional crash")
  end

  defmodule SlowCompactor do
    @moduledoc "Blocks long enough to be cancelled or timed out."
    @behaviour Tau.Compactor
    @impl Tau.Compactor
    def should_compact?(_msgs, _usage), do: false
    @impl Tau.Compactor
    def compact(_msgs, _ctx) do
      # Block for 30s — the compaction_timeout_ms (5s in tests) will fire first.
      Process.sleep(30_000)
      {:ok, [], nil}
    end
  end

  # A provider that always produces one turn of output (for setting up messages).
  defp replay_fixture do
    [
      %Event.Start{request_id: "r", model: "replay"},
      %Event.TextStart{block_id: "b"},
      %Event.TextDelta{block_id: "b", text: "hello"},
      %Event.TextEnd{block_id: "b"},
      %Event.Done{stop_reason: :stop, usage: %{}}
    ]
  end

  defp start_compact_session(compactor) do
    Application.put_env(:tau, :compactor, compactor)
    sid = "compact-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: replay_fixture()}
      )

    # Seed one user+assistant turn so the message list is non-trivial.
    Tau.send(sid, "hello")
    assert_receive %SE.MessageEnd{session_id: ^sid}, 3_000

    sid
  end

  # ---------------------------------------------------------------------------
  # Happy-path tests
  # ---------------------------------------------------------------------------

  test "AC-9 happy path: /compact transitions to :compacting, returns to :awaiting_user" do
    sid = start_compact_session(HappyCompactor)

    Tau.send(sid, "/compact")

    # D-163: CompactionStarted fires before entering :compacting.
    assert_receive %SE.CompactionStarted{session_id: ^sid}, 3_000

    # Notice broadcast
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compacting conversation…"}, 3_000

    # Completion notice
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compaction complete."}, 5_000

    # D-164 (Clause 1 / {:ok,_,_}): CompactionFinished fires with {:ok, :compacted}.
    assert_receive %SE.CompactionFinished{session_id: ^sid, outcome: {:ok, :compacted}}, 3_000

    # Back in :awaiting_user
    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user

    # Message list compacted to a single summary message
    assert Enum.any?(snap.messages, fn
             %Tau.Message.User{metadata: %{role: :compaction_summary}} -> true
             _ -> false
           end)
  end

  test "AC-9: /compact emits [:tau, :compaction, :start] telemetry" do
    test_pid = self()
    handler_id = "compact-start-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:tau, :compaction, :start],
      fn _event, _measurements, meta, _ ->
        send(test_pid, {:telemetry_start, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    sid = start_compact_session(HappyCompactor)
    Tau.send(sid, "/compact")

    assert_receive {:telemetry_start, meta}, 3_000
    assert meta.session_id == sid
    assert meta[:async] == true
  end

  test "AC-9: [:tau, :session, :builtin_command] telemetry fires with outcome: :async_compact" do
    test_pid = self()
    handler_id = "builtin-cmd-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:tau, :session, :builtin_command],
      fn _event, _measurements, meta, _ ->
        if meta[:command] == "/compact" do
          send(test_pid, {:builtin_telemetry, meta})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    sid = start_compact_session(HappyCompactor)
    Tau.send(sid, "/compact")

    assert_receive {:builtin_telemetry, meta}, 3_000
    assert meta.outcome == :async_compact
  end

  # ---------------------------------------------------------------------------
  # D-048: postpone-and-flush
  # ---------------------------------------------------------------------------

  test "D-048: user message sent during :compacting is postponed and delivered after" do
    sid = start_compact_session(HappyCompactor)

    # Shrink the compaction timeout to ensure we can send a message while compacting.
    Application.put_env(:tau, :compaction_timeout_ms, 10_000)

    Tau.send(sid, "/compact")
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compacting conversation…"}, 3_000

    # Send a second message while compacting — it should be postponed.
    Tau.send(sid, "hello after compact")

    # After compaction completes, the postponed message is delivered.
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compaction complete."}, 6_000
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
  end

  # ---------------------------------------------------------------------------
  # D-049: worker-crash recovery (Clause 2b)
  # ---------------------------------------------------------------------------

  test "D-049: worker crash returns FSM to :awaiting_user without wedging" do
    sid = start_compact_session(CrashCompactor)
    Tau.send(sid, "/compact")

    assert_receive %SE.CompactionStarted{session_id: ^sid}, 3_000
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compacting conversation…"}, 3_000
    assert_receive %SE.SystemNotice{session_id: ^sid, text: notice}, 5_000
    assert notice =~ "crashed"

    # D-164 / S-2 (Clause 2b): CompactionFinished MUST fire on worker crash.
    # The outcome is {:error, reason} where reason is the crash reason.
    assert_receive %SE.CompactionFinished{session_id: ^sid, outcome: {:error, _reason}}, 3_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
  end

  # ---------------------------------------------------------------------------
  # D-049: race test — {ref,result} + {:DOWN,:normal} back-to-back
  # ---------------------------------------------------------------------------

  test "D-049: {ref,result} + {:DOWN,:normal} race causes NO spurious crash-recovery notice (×50)" do
    for _i <- 1..50 do
      sid = "compact-race-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      Application.put_env(:tau, :compactor, HappyCompactor)

      {:ok, ^sid} =
        start_session_for_test(
          provider: Tau.Providers.Replay,
          model: "replay",
          session_id: sid,
          provider_ctx: %{replay_fixture: replay_fixture()}
        )

      Tau.send(sid, "hello")
      assert_receive %SE.MessageEnd{session_id: ^sid}, 3_000

      Tau.send(sid, "/compact")
      assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compacting conversation…"}, 3_000
      assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compaction complete."}, 5_000

      # Assert NO "crashed" notice was broadcast — the :normal DOWN was properly
      # swallowed by Clause 2a. Drain remaining messages and check none contain
      # "crashed" (refute_receive can't use =~ in match guards).
      Process.sleep(200)
      all_notices = flush_notices(sid)
      crash_notices = Enum.filter(all_notices, &String.contains?(&1, "crashed"))

      assert crash_notices == [],
             "Spurious crash-recovery notice received: #{inspect(crash_notices)}"

      {:ok, snap} = Tau.snapshot(sid)
      assert snap.state == :awaiting_user

      Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")
    end
  end

  # ---------------------------------------------------------------------------
  # D-048: late timeout after success (Clause 4)
  # ---------------------------------------------------------------------------

  test "D-048: late {:compaction_timeout} after success does NOT crash the FSM" do
    sid = start_compact_session(HappyCompactor)
    Tau.send(sid, "/compact")
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compaction complete."}, 5_000

    # Send a late stale timeout message directly to the FSM — it must be dropped
    # by Clause 4 (no demonitor on nil, no crash).
    [{fsm_pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
    stale_pid = spawn(fn -> :ok end)
    send(fsm_pid, {:compaction_timeout, stale_pid, 5_000})
    Process.sleep(100)

    # FSM is still alive and responsive.
    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
  end

  # ---------------------------------------------------------------------------
  # C67-B4: /cancel outside :compacting does NOT crash FSM (BLOCKING-3 fix)
  # ---------------------------------------------------------------------------

  test "C67-B4: /cancel outside :compacting does NOT crash the FSM" do
    Application.put_env(:tau, :compactor, NeverCompactor)
    sid = "compact-cancel-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: replay_fixture()}
      )

    # Cancel while in :awaiting_user with compaction_task == nil — the guarded
    # demonitor must NOT crash on nil.
    :ok = Tau.cancel(sid)

    assert_receive %SE.Cancelled{session_id: ^sid}, 2_000
    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
  end

  # ---------------------------------------------------------------------------
  # D-049: timeout path (Clause 3)
  # ---------------------------------------------------------------------------

  test "D-049: compaction timeout returns FSM to :awaiting_user" do
    # Use a very short timeout so the test doesn't take 5s.
    Application.put_env(:tau, :compaction_timeout_ms, 100)
    sid = start_compact_session(SlowCompactor)

    Tau.send(sid, "/compact")
    assert_receive %SE.CompactionStarted{session_id: ^sid}, 3_000
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compacting conversation…"}, 3_000
    assert_receive %SE.SystemNotice{session_id: ^sid, text: notice}, 3_000
    assert notice =~ "timed out"

    # D-164 / S-2 (Clause 3): CompactionFinished MUST fire on timeout with {:error, :timeout}.
    assert_receive %SE.CompactionFinished{session_id: ^sid, outcome: {:error, :timeout}}, 3_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
  end

  # ---------------------------------------------------------------------------
  # D-048: stale-result drop after cancel (compaction_task=nil guard)
  # ---------------------------------------------------------------------------

  test "D-048: stale {ref,result} dropped after cancel — no FSM crash" do
    Application.put_env(:tau, :compaction_timeout_ms, 100)
    sid = start_compact_session(SlowCompactor)

    # Get FSM pid before cancel
    [{fsm_pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)

    Tau.send(sid, "/compact")
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compacting conversation…"}, 3_000

    # Cancel immediately — kills the worker, clears fields.
    :ok = Tau.cancel(sid)
    assert_receive %SE.Cancelled{session_id: ^sid}, 2_000

    # Forge a stale {ref, result} to the FSM (as if an old worker returned late).
    stale_ref = make_ref()
    send(fsm_pid, {stale_ref, {:ok, [], nil}})
    Process.sleep(100)

    # FSM must still be alive and in :awaiting_user.
    assert Process.alive?(fsm_pid)
    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
  end

  # ---------------------------------------------------------------------------
  # D-016: sync abort after 3 consecutive failures
  # ---------------------------------------------------------------------------

  test "D-016 sync abort: 3 consecutive sync errors abort the turn with :compaction_failed" do
    # Use a compactor that always fails AND always triggers (should_compact? = true).
    Application.put_env(:tau, :compactor, ErrorCompactorWithSync)

    sid = "compact-d016-sync-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: replay_fixture()}
      )

    test_pid = self()
    handler_id = "compact-exception-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:tau, :compaction, :exception],
      fn _event, _measurements, meta, _ ->
        send(test_pid, {:telemetry_exception, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Turn 1: compaction fails (failure 1)
    Tau.send(sid, "turn 1")
    assert_receive %SE.MessageEnd{session_id: ^sid}, 3_000

    # Turn 2: compaction fails (failure 2)
    Tau.send(sid, "turn 2")
    assert_receive %SE.MessageEnd{session_id: ^sid}, 3_000

    # Turn 3: compaction fails (failure 3 → abort). finalize_assistant/2
    # broadcasts two MessageEnd events: (1) the real assistant response with
    # stop_reason: :stop, then (2) the abort synthetic message with
    # stop_reason: :compaction_failed. We must receive the second one.
    Tau.send(sid, "turn 3")
    assert_receive %SE.MessageEnd{session_id: ^sid}, 3_000
    assert_receive %SE.MessageEnd{session_id: ^sid, message: abort_msg}, 3_000
    assert abort_msg.stop_reason == :compaction_failed

    assert abort_msg.content |> hd() |> Map.get(:text) =~
             "repeated or background compaction failure"

    # At least 3 exception telemetry events should have fired.
    assert_receive {:telemetry_exception, _}, 3_000
    assert_receive {:telemetry_exception, _}, 3_000
    assert_receive {:telemetry_exception, _}, 3_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
  end

  # ---------------------------------------------------------------------------
  # D-016: cross-path (1 async failure + 2 sync failures → abort on 3rd)
  # ---------------------------------------------------------------------------

  test "D-016 cross-path: 1 async failure + 2 sync failures share the counter" do
    # First trigger one async failure via /compact, then switch to the sync-error
    # compactor and do 2 sync turns — the 3rd failure (total) should abort.
    sid = "compact-d016-cross-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    Application.put_env(:tau, :compactor, ErrorCompactor)

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: replay_fixture()}
      )

    # Seed messages.
    Tau.send(sid, "seed")
    assert_receive %SE.MessageEnd{session_id: ^sid}, 3_000

    # Async failure 1: /compact with ErrorCompactor
    Tau.send(sid, "/compact")
    assert_receive %SE.CompactionStarted{session_id: ^sid}, 3_000
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compacting conversation…"}, 3_000
    assert_receive %SE.SystemNotice{session_id: ^sid, text: notice1}, 5_000
    assert notice1 =~ "failed"
    # D-164 (Clause 1 / {:error,_}): CompactionFinished fires with {:error, reason}.
    assert_receive %SE.CompactionFinished{session_id: ^sid, outcome: {:error, _}}, 3_000

    # Now switch to a compactor that also fires should_compact? = true
    Application.put_env(:tau, :compactor, ErrorCompactorWithSync)

    # Sync failure 2: provider turn, compactor fires via maybe_compact
    Tau.send(sid, "turn 2")
    assert_receive %SE.MessageEnd{session_id: ^sid}, 3_000

    # Sync failure 3: this is the 3rd consecutive failure → abort.
    # Two MessageEnds arrive: (1) the real :stop response, (2) the abort.
    Tau.send(sid, "turn 3")
    assert_receive %SE.MessageEnd{session_id: ^sid}, 3_000
    assert_receive %SE.MessageEnd{session_id: ^sid, message: abort_msg}, 3_000
    assert abort_msg.stop_reason == :compaction_failed
  end

  # ---------------------------------------------------------------------------
  # Guard: /compact error path (via FSM integration)
  # Note: Pure predicate testing (empty messages, etc.) lives in
  # test/tau/commands/builtin/compact_test.exs. These tests verify FSM-level
  # error broadcast and state preservation.
  # ---------------------------------------------------------------------------

  test "/compact broadcasts 'Error:' notice and stays in :awaiting_user on error" do
    # Force the compactor to always report nothing to compact by using a compactor
    # that won't matter — the key is that /compact.run/2 returns {:error, _}.
    # We achieve this by resetting all messages after seeding, then checking.
    # Simplest approach: test that the error path broadcasts the right event shape.
    Application.put_env(:tau, :compactor, HappyCompactor)

    # A session with messages already seeded. Send a second /compact after the
    # first one completes (so compaction_task is nil again), then check the
    # error is NOT produced (since messages ARE present).
    sid = start_compact_session(HappyCompactor)
    Tau.send(sid, "/compact")
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compaction complete."}, 5_000

    # After successful compaction the message list has only one summary message.
    # /compact again → "Nothing to compact." error.
    Tau.send(sid, "/compact")
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Error: Nothing to compact."}, 2_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
  end

  test "/compact while already compacting: FSM does not crash or wedge" do
    # Use a short timeout so the test completes quickly.
    Application.put_env(:tau, :compaction_timeout_ms, 500)
    sid = start_compact_session(SlowCompactor)

    Tau.send(sid, "/compact")
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compacting conversation…"}, 3_000

    # Second /compact while still in :compacting — it is postponed (D-048).
    # After the timeout fires the FSM returns to :awaiting_user, delivers the
    # second /compact, which should produce an error notice (nothing to compact
    # because the session was reset via cancel/timeout, or in-progress if still
    # running). Key property: FSM does NOT crash and does NOT wedge.
    Tau.send(sid, "/compact")

    # Timeout fires and returns to :awaiting_user.
    assert_receive %SE.SystemNotice{session_id: ^sid, text: notice}, 3_000
    assert notice =~ "timed out"

    # Postponed /compact is re-delivered — should produce a notice.
    # If messages are still non-trivial, it starts another async compact (with
    # SlowCompactor → triggers another timeout). If messages became trivial
    # (compacted from timeout path), it errors. Either way, another notice arrives.
    assert_receive %SE.SystemNotice{session_id: ^sid}, 3_000

    # If a second compaction was launched, wait for its timeout to fire.
    # The timeout is 500ms. After that the FSM returns to :awaiting_user.
    # We use assert_receive with a generous timeout to catch either path.
    # If the second /compact errored immediately (no new compaction), we're
    # already in :awaiting_user.
    receive do
      %SE.SystemNotice{session_id: ^sid} -> :ok
    after
      2000 -> :ok
    end

    # Ensure FSM has settled.
    Process.sleep(200)
    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
  end

  # ---------------------------------------------------------------------------
  # D-048: :swap_model busy during :compacting
  # ---------------------------------------------------------------------------

  test "D-048: swap_model returns {:error, :busy} while in :compacting state" do
    Application.put_env(:tau, :compaction_timeout_ms, 10_000)
    sid = start_compact_session(SlowCompactor)

    Tau.send(sid, "/compact")
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Compacting conversation…"}, 3_000

    # FSM is in :compacting — swap_model must return :busy.
    assert {:error, :busy} = Tau.Session.swap_model(sid, "some-model")

    # Cancel the compaction to clean up.
    :ok = Tau.cancel(sid)
    assert_receive %SE.Cancelled{session_id: ^sid}, 2_000
  end
end
