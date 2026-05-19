defmodule Tau.Session.CircuitBreakerIntegrationTest do
  @moduledoc """
  AC-7 (SPEC-CIRCUIT-BREAKER §7): integration with `Tau.Session` provider dispatch.

  A session turn against an open circuit breaker MUST surface a visible error
  event to the TUI — specifically a `%Events.MessageEnd{}` whose `%Assistant{}`
  has `stop_reason: :error` and a non-empty `:text` content block containing
  "Error" (mirroring the D-009 / SPEC-USER-TURN [C12]/[C19] contract).

  The error MUST NOT be silently dropped, and the FSM MUST return to
  `:awaiting_user` so the user can act (switch providers or wait for cooldown).
  """

  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.CircuitBreaker
  alias Tau.CircuitBreaker.Store
  alias Tau.Session.Events, as: SE

  @table Store.table()
  @failure_threshold 5

  # ---------------------------------------------------------------------------
  # Test-only provider module (never actually called when breaker is open)
  # ---------------------------------------------------------------------------

  defmodule CBTestProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    # The breaker short-circuits before this is invoked when `:open`; returning
    # {:error, :should_not_be_called} makes an accidental call obvious in test output.
    def stream(_messages, _opts, _ctx), do: {:error, :should_not_be_called}

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
    def default_model, do: "cb-test"
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    # Ensure Store is running; it may already be started by the application.
    case Process.whereis(Store) do
      nil -> {:ok, _pid} = start_supervised(Store)
      _pid -> :ok
    end

    # Clear all breaker state so each test starts with closed breakers.
    :ets.delete_all_objects(@table)

    tmp = Path.join(System.tmp_dir!(), "tau-cb-int-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      :ets.delete_all_objects(@table)
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Drive @failure_threshold failures through the façade to open the breaker for
  # a given provider. Using the real façade ensures the ETS row is correctly
  # written as the production code would write it.
  defp open_breaker(provider) do
    for _ <- 1..@failure_threshold do
      CircuitBreaker.call(provider, [failure_threshold: @failure_threshold], fn ->
        {:error, :forced_failure}
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  test "AC-7: open breaker surfaces a visible error MessageEnd to the TUI" do
    # Pre-open the breaker for CBTestProvider.
    open_breaker(CBTestProvider)
    assert Store.state_for(CBTestProvider) == :open

    sid = "cb-int-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        session_id: sid,
        provider: CBTestProvider,
        model: "cb-test"
      )

    Tau.send(sid, "trigger circuit breaker")

    assert_receive %SE.MessageEnd{message: msg}, 3_000

    assert msg.stop_reason == :error,
           "Assistant.stop_reason must be :error when breaker is open; got #{inspect(msg.stop_reason)}"

    assert is_list(msg.content) and msg.content != [],
           "Assistant.content MUST be non-empty (D-009 / AC-7); got #{inspect(msg.content)}"

    text_blocks = Enum.filter(msg.content, &match?(%{type: :text}, &1))

    assert text_blocks != [],
           "At least one :text content block is required for TUI render paths"

    assert Enum.any?(text_blocks, fn %{text: t} -> String.contains?(t, "Error") end),
           "Text block must contain 'Error' so the error is visible to the user"

    # The :circuit_open atom should NOT be surfaced raw — a human-readable
    # message is expected (see describe_provider_error/1).
    refute Enum.any?(text_blocks, fn %{text: t} -> t =~ ":circuit_open" end),
           "Raw :circuit_open atom must not leak into the user-visible message"
  end

  test "AC-7: FSM returns to :awaiting_user after open-breaker short-circuit" do
    open_breaker(CBTestProvider)
    assert Store.state_for(CBTestProvider) == :open

    sid = "cb-int-state-#{System.unique_integer([:positive])}"

    {:ok, ^sid} =
      start_session_for_test(
        session_id: sid,
        provider: CBTestProvider,
        model: "cb-test"
      )

    Tau.send(sid, "trigger circuit breaker")
    # Allow the event to be processed.
    Process.sleep(300)

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user,
           "Session must return to :awaiting_user after circuit-open short-circuit"
  end

  test "AC-7: CBTestProvider.stream/3 is not invoked when breaker is open" do
    # Subscribe to the session PubSub to detect any :should_not_be_called error.
    open_breaker(CBTestProvider)
    assert Store.state_for(CBTestProvider) == :open

    sid = "cb-int-noinvoke-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        session_id: sid,
        provider: CBTestProvider,
        model: "cb-test"
      )

    Tau.send(sid, "trigger circuit breaker")

    assert_receive %SE.MessageEnd{message: msg}, 3_000

    # If stream/3 was invoked, it would return {:error, :should_not_be_called},
    # which would produce a different error_message than the circuit-open message.
    # Confirm the error_message is the breaker-specific string, not the provider's.
    assert msg.stop_reason == :error
    assert msg.error_message =~ "circuit breaker",
           "Error message should mention circuit breaker, got: #{inspect(msg.error_message)}"
  end
end
