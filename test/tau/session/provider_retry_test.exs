defmodule Tau.Session.ProviderRetryTest do
  @moduledoc """
  Single-provider mid-stream-error retry (D-061 / #303).

  Verifies that `Tau.Session` recovers from a
  `%Tau.Provider.Event.Error{retryable?: true}` even when
  `fallback_chain_remaining == []` — the common single-provider case
  that previously killed the turn instantly on the first transient
  Mint timeout against Anthropic.
  """

  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Session.Events, as: SE
  alias Tau.Provider.Event.{Done, Error, Start}

  defmodule FlakyProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(messages, _opts, ctx) do
      # Count how many provider calls have happened so far in this
      # turn by counting how many `:provider_call_observed` notices
      # the caller already received. We use the FSM's view: each
      # call to `stream/3` is a fresh provider attempt, so we use
      # the ctx-provided test_pid to bump a counter held by the
      # caller. Simpler: thread an `:agent` pid in ctx that holds
      # the call count.
      attempt = increment_attempt(ctx[:counter])

      script = Map.get(ctx, :script, [])
      n_user_msgs = Enum.count(messages, &match?(%Tau.Message.User{}, &1))

      events =
        case Enum.at(script, attempt - 1) do
          {:error, reason} ->
            [
              %Start{request_id: "flaky-#{attempt}", model: "flaky"},
              %Error{reason: reason, retryable?: true}
            ]

          {:non_retryable, reason} ->
            [
              %Start{request_id: "flaky-#{attempt}", model: "flaky"},
              %Error{reason: reason, retryable?: false}
            ]

          {:done, stop_reason} ->
            [
              %Start{request_id: "flaky-#{attempt}", model: "flaky"},
              %Done{stop_reason: stop_reason, usage: %{}}
            ]

          # Out-of-script: emit a clean Done so the test ends.
          nil ->
            [
              %Start{request_id: "flaky-#{attempt}-eos-#{n_user_msgs}", model: "flaky"},
              %Done{stop_reason: :stop, usage: %{}}
            ]
        end

      {:ok, events}
    end

    @impl true
    def capabilities,
      do: %{
        thinking: false,
        tools: false,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }

    @impl true
    def default_model, do: "flaky"

    defp increment_attempt(nil), do: 1

    defp increment_attempt(counter) do
      # :counters.new/2 returns an opaque `{:atomics, ref}`-tagged
      # tuple; pattern-matching `is_reference/1` does NOT hold. Pass
      # the opaque value through to `:counters` directly.
      n = :counters.get(counter, 1) + 1
      :counters.put(counter, 1, n)
      n
    end
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "tau-provider-retry-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  test "retries twice then succeeds; reaches :awaiting_user without :error" do
    sid = "retry-pos-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    test_pid = self()
    handler_id = "retry-pos-tel-#{sid}"

    :telemetry.attach(
      handler_id,
      [:tau, :session, :provider_retry],
      fn _ev, m, meta, _ -> send(test_pid, {:retry_telemetry, m, meta}) end,
      nil
    )

    counter = :counters.new(1, [])

    try do
      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          provider: FlakyProvider,
          model: "flaky",
          provider_retry_max: 3,
          # Use a tiny base so the test completes quickly. The
          # backoff is 50, 100, 200ms — total under 400ms even at
          # full exhaustion.
          provider_retry_base_delay_ms: 50,
          provider_ctx: %{
            counter: counter,
            script: [
              {:error, :timeout},
              {:error, :timeout},
              {:done, :stop}
            ]
          }
        )

      :ok = Tau.send(sid, "go")

      # Two retry-telemetry events expected (counts 1 then 2). The
      # third provider call succeeds with Done{:stop}.
      assert_receive {:retry_telemetry, %{count: 1, delay_ms: 50},
                      %{session_id: ^sid, provider: FlakyProvider, reason: :timeout, max: 3}},
                     2_000

      assert_receive {:retry_telemetry, %{count: 2, delay_ms: 100},
                      %{session_id: ^sid, provider: FlakyProvider, reason: :timeout, max: 3}},
                     2_000

      # Final MessageEnd should carry a non-:error stop_reason.
      assert_receive %SE.MessageEnd{
                       session_id: ^sid,
                       message: %Tau.Message.Assistant{stop_reason: stop_reason}
                     },
                     5_000

      refute stop_reason == :error

      # SystemNotice broadcast for each retry naming the provider
      # and the count.
      assert_received %SE.SystemNotice{session_id: ^sid, text: notice1}
      assert notice1 =~ "FlakyProvider"
      assert notice1 =~ "retrying"
      assert notice1 =~ "1/3"

      assert_received %SE.SystemNotice{session_id: ^sid, text: notice2}
      assert notice2 =~ "retrying"
      assert notice2 =~ "2/3"

      # FSM is back in :awaiting_user with retry counter reset.
      {:ok, snap} = Tau.snapshot(sid)
      assert snap.state == :awaiting_user
      assert snap.provider_retry_state == %{count: 0}
    after
      :telemetry.detach(handler_id)
      Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")
    end
  end

  test "exhausts retry budget then surfaces :error stop_reason" do
    sid = "retry-exh-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    test_pid = self()
    handler_id = "retry-exh-tel-#{sid}"

    :telemetry.attach(
      handler_id,
      [:tau, :session, :provider_retry],
      fn _ev, m, meta, _ -> send(test_pid, {:retry_telemetry, m, meta}) end,
      nil
    )

    counter = :counters.new(1, [])

    try do
      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          provider: FlakyProvider,
          model: "flaky",
          provider_retry_max: 3,
          provider_retry_base_delay_ms: 20,
          provider_ctx: %{
            counter: counter,
            # Four retryable errors. With max=3, the 4th attempt
            # (after 3 retries) MUST surface as terminal :error.
            script: [
              {:error, :timeout},
              {:error, :timeout},
              {:error, :timeout},
              {:error, :timeout}
            ]
          }
        )

      :ok = Tau.send(sid, "go")

      # Three retry-telemetry events (counts 1, 2, 3). No fourth.
      assert_receive {:retry_telemetry, %{count: 1}, %{provider: FlakyProvider}}, 2_000
      assert_receive {:retry_telemetry, %{count: 2}, %{provider: FlakyProvider}}, 2_000
      assert_receive {:retry_telemetry, %{count: 3}, %{provider: FlakyProvider}}, 2_000

      # Final MessageEnd has :error stop_reason.
      assert_receive %SE.MessageEnd{
                       session_id: ^sid,
                       message: %Tau.Message.Assistant{stop_reason: :error}
                     },
                     5_000

      # No fourth retry telemetry — the 4th retryable error fell
      # through to the terminal-error path.
      refute_receive {:retry_telemetry, %{count: 4}, _}, 200

      {:ok, snap} = Tau.snapshot(sid)
      assert snap.state == :awaiting_user
      # Counter was reset on return to :awaiting_user via the
      # tool_iterations: 0 reset sites covered by finalize_assistant.
      assert snap.provider_retry_state == %{count: 0}
    after
      :telemetry.detach(handler_id)
      Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")
    end
  end

  test "non-retryable error surfaces :error immediately with no retry telemetry" do
    sid = "retry-nonr-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    test_pid = self()
    handler_id = "retry-nonr-tel-#{sid}"

    :telemetry.attach(
      handler_id,
      [:tau, :session, :provider_retry],
      fn _ev, m, meta, _ -> send(test_pid, {:retry_telemetry, m, meta}) end,
      nil
    )

    counter = :counters.new(1, [])

    try do
      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          provider: FlakyProvider,
          model: "flaky",
          provider_retry_max: 3,
          provider_retry_base_delay_ms: 20,
          provider_ctx: %{
            counter: counter,
            script: [
              {:non_retryable, :bad_input}
            ]
          }
        )

      :ok = Tau.send(sid, "go")

      assert_receive %SE.MessageEnd{
                       session_id: ^sid,
                       message: %Tau.Message.Assistant{stop_reason: :error}
                     },
                     5_000

      refute_received {:retry_telemetry, _, _}

      {:ok, snap} = Tau.snapshot(sid)
      assert snap.state == :awaiting_user
      assert snap.provider_retry_state == %{count: 0}
    after
      :telemetry.detach(handler_id)
      Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")
    end
  end
end
