defmodule Tau.Session.LifecycleBuiltinDispatchTest do
  @moduledoc """
  D-042 dispatch tests for the lifecycle built-ins: `/reload` and `/logout`.

  Each test asserts:
  - The command dispatches via `handle_builtin_command/4`.
  - The FSM produces a SystemNotice without starting a provider turn
    (no MessageStart, no `stream/3` call).
  - The FSM stays alive in `:awaiting_user` (snapshot/1 succeeds after).

  The `/reload` postpone test additionally verifies that a `/reload` cast
  arriving while the FSM is in `:provider_streaming` is postponed and
  applied only after the turn ends (D-007 complement).
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Session.Events, as: SE

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-lifecycle-cmds-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  # Provider that records stream/3 calls and emits a minimal valid stream.
  defmodule RecordingProvider do
    @behaviour Tau.Provider

    @impl Tau.Provider
    def default_model, do: "recording-model"

    @impl Tau.Provider
    def capabilities,
      do: %{
        thinking: false,
        tools: false,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }

    @impl Tau.Provider
    def configure(opts), do: {:ok, opts}

    @impl Tau.Provider
    def stream(_messages, _opts, ctx) do
      owner = ctx[:stream_owner]
      if owner, do: send(owner, {:stream_called, self()})

      stream =
        Stream.map(
          [
            %Tau.Provider.Event.Start{request_id: "r", model: "recording-model"},
            %Tau.Provider.Event.TextStart{block_id: "b"},
            %Tau.Provider.Event.TextDelta{block_id: "b", text: "recording"},
            %Tau.Provider.Event.TextEnd{block_id: "b"},
            %Tau.Provider.Event.Done{stop_reason: :stop, usage: %{}}
          ],
          & &1
        )

      {:ok, stream}
    end
  end

  defp start_session(sid, owner) do
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: RecordingProvider,
        model: "recording-model",
        session_id: sid,
        provider_ctx: %{stream_owner: owner}
      )
  end

  # ── /reload ──────────────────────────────────────────────────────────────────

  test "D-042: /reload produces SystemNotice, zero provider stream calls, FSM alive" do
    sid = "builtin-reload-d042-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/reload")

    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    assert String.contains?(text, "Reload")

    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    assert {:ok, snap} = Tau.snapshot(sid)
    assert snap.id == sid
  end

  test "D-042: /reload telemetry fires with outcome :mutate" do
    sid = "builtin-reload-telemetry-#{System.unique_integer([:positive])}"
    owner = self()
    test_ref = make_ref()

    handler_id = "test-reload-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:tau, :session, :builtin_command],
      fn _event, _measurements, meta, _ ->
        if meta.command == "/reload" do
          send(owner, {:telemetry_fired, test_ref, meta})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    start_session(sid, owner)
    Tau.send(sid, "/reload")

    assert_receive {:telemetry_fired, ^test_ref, meta}, 2_000
    assert meta.session_id == sid
    assert meta.command == "/reload"
    assert meta.outcome == :mutate
  end

  # ── /reload postpone guarantee (D-007 complement) ────────────────────────────

  # Provider that pauses mid-stream so we can inject a /reload while streaming.
  defmodule SlowProvider do
    @behaviour Tau.Provider

    @impl Tau.Provider
    def default_model, do: "slow-model"

    @impl Tau.Provider
    def capabilities,
      do: %{
        thinking: false,
        tools: false,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }

    @impl Tau.Provider
    def configure(opts), do: {:ok, opts}

    @impl Tau.Provider
    def stream(_messages, _opts, ctx) do
      owner = ctx[:stream_owner]
      delay = ctx[:stream_delay_ms] || 200

      stream =
        Stream.map(
          [
            %Tau.Provider.Event.Start{request_id: "r", model: "slow-model"},
            %Tau.Provider.Event.TextStart{block_id: "b"},
            # Signal that streaming has started before any delay.
            :notify_started,
            %Tau.Provider.Event.TextDelta{block_id: "b", text: "slow"},
            %Tau.Provider.Event.TextEnd{block_id: "b"},
            %Tau.Provider.Event.Done{stop_reason: :stop, usage: %{}}
          ],
          fn
            :notify_started ->
              if owner, do: send(owner, {:stream_started, self()})
              Process.sleep(delay)
              # Return a benign event so the stream is valid.
              %Tau.Provider.Event.TextDelta{block_id: "b", text: ""}

            event ->
              event
          end
        )

      {:ok, stream}
    end
  end

  test "/reload cast during :provider_streaming is postponed, applied after turn" do
    sid = "builtin-reload-postpone-#{System.unique_integer([:positive])}"
    owner = self()

    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: SlowProvider,
        model: "slow-model",
        session_id: sid,
        provider_ctx: %{stream_owner: owner, stream_delay_ms: 500}
      )

    # Start a real provider turn so the FSM enters :provider_streaming.
    Tau.send(sid, "trigger a provider turn")

    # Wait until the stream has started (FSM is in :provider_streaming).
    assert_receive {:stream_started, _}, 3_000

    # Cast /reload while streaming — must be postponed.
    Tau.send(sid, "/reload")

    # The reload notice MUST NOT arrive before the MessageEnd.
    refute_receive %SE.SystemNotice{session_id: ^sid, text: "Reloaded settings and skills."},
                   100

    # Wait for the turn to complete.
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    # Now the postponed /reload should fire.
    assert_receive %SE.SystemNotice{session_id: ^sid, text: "Reloaded settings and skills."},
                   2_000

    # FSM still alive.
    assert {:ok, snap} = Tau.snapshot(sid)
    assert snap.id == sid
  end

  # ── /logout ──────────────────────────────────────────────────────────────────

  test "D-042: /logout with no provider produces error SystemNotice, no provider turn" do
    sid = "builtin-logout-noprov-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/logout")

    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    assert String.contains?(text, "Error: Provider required")

    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    assert {:ok, snap} = Tau.snapshot(sid)
    assert snap.id == sid
  end

  test "D-042: /logout with unknown provider produces error SystemNotice, no provider turn" do
    sid = "builtin-logout-unknown-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/logout notareal")

    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    assert String.contains?(text, "Error: Unknown provider: notareal")

    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    assert {:ok, _snap} = Tau.snapshot(sid)
  end

  test "D-042: /logout anthropic produces error/notice, no provider turn (Env backend read-only)" do
    sid = "builtin-logout-anthropic-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/logout anthropic")

    # Env backend returns {:error, :read_only} for delete — so we get an error notice.
    assert_receive %SE.SystemNotice{session_id: ^sid}, 2_000

    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    assert {:ok, _snap} = Tau.snapshot(sid)
  end

  test "D-042: /logout telemetry fires with outcome :error" do
    sid = "builtin-logout-telemetry-#{System.unique_integer([:positive])}"
    owner = self()
    test_ref = make_ref()

    handler_id = "test-logout-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:tau, :session, :builtin_command],
      fn _event, _measurements, meta, _ ->
        if meta.command == "/logout" do
          send(owner, {:telemetry_fired, test_ref, meta})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    start_session(sid, owner)
    # /logout with no provider → {:error, ...}
    Tau.send(sid, "/logout")

    assert_receive {:telemetry_fired, ^test_ref, meta}, 2_000
    assert meta.session_id == sid
    assert meta.command == "/logout"
    assert meta.outcome == :error
  end
end
