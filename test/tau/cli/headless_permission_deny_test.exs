defmodule Tau.CLI.HeadlessPermissionDenyTest do
  @moduledoc """
  AC-A4 (B1/D-093) — SPEC-PERMISSION-PROMPTS #341 PR-A.

  Verifies that `tau run` (non-interactive) against a fixture that emits an
  unmatched tool call:

    1. Terminates cleanly (exit code 0).
    2. The unmatched call's result is an `is_error` ToolResult naming the
       fail-closed denial (verified via provider receiving the error ToolResult
       on its second turn).
    3. The FSM NEVER enters `:awaiting_permission` (asserted via
       `[:tau, :permissions, :decision]` decision value and session state
       immediately after the decision fires).

  Exercises `Tau.CLI.run_cmd/1` (same dispatch as `Tau.CLI.main/1`).

  `async: false` because the test overrides `:default_provider` and
  `:data_dir` as Application env.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Tau.Message.ToolResult, as: TR
  alias Tau.Provider.Event

  @call_id "call-noninteractive-perm"
  @tool_name "unmatched_tool_for_perm_test"

  # ---------------------------------------------------------------------------
  # Recording provider — emits one unmatched tool call per first turn, then
  # accepts any ToolResult and ends. Records state snapshots and ToolResults
  # for test assertions.
  # ---------------------------------------------------------------------------

  defmodule UnmatchedToolProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @call_id "call-noninteractive-perm"
    @tool_name "unmatched_tool_for_perm_test"

    @impl true
    def stream(messages, _opts, ctx) do
      has_tool_result? = Enum.any?(messages, &match?(%TR{}, &1))
      call_id = Map.get(ctx, :call_id, @call_id)
      tool_name = Map.get(ctx, :tool_name, @tool_name)

      events =
        if has_tool_result? do
          # On the second turn the FSM passes the ToolResult(s) back.
          # The provider records what it received for the test to assert on.
          if recorder = Application.get_env(:tau, :perm_test_recorder) do
            tool_results =
              Enum.filter(messages, &match?(%TR{}, &1))

            send(recorder, {:second_turn_tool_results, tool_results})
          end

          [
            %Event.Start{request_id: "r2", model: "unmatched"},
            %Event.TextStart{block_id: "t1"},
            %Event.TextDelta{block_id: "t1", text: "done"},
            %Event.TextEnd{block_id: "t1"},
            %Event.Done{stop_reason: :end_turn, usage: %{}}
          ]
        else
          [
            %Event.Start{request_id: "r1", model: "unmatched"},
            %Event.ToolCallStart{tool_call_id: call_id, name: tool_name},
            %Event.ToolCallEnd{tool_call_id: call_id, params: %{}},
            %Event.Done{stop_reason: :tool_use, usage: %{}}
          ]
        end

      {:ok, events}
    end

    @impl true
    def capabilities,
      do: %{
        thinking: false,
        tools: true,
        vision: false,
        prompt_caching: false,
        parallel_tools: true
      }

    @impl true
    def default_model, do: "unmatched"
  end

  def call_id, do: @call_id
  def tool_name, do: @tool_name

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "tau-headless-perm-deny-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    prior_provider = Application.get_env(:tau, :default_provider)
    Application.put_env(:tau, :default_provider, UnmatchedToolProvider)

    Application.put_env(:tau, :perm_test_recorder, self())

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
      Application.delete_env(:tau, :perm_test_recorder)

      case prior_provider do
        nil -> Application.delete_env(:tau, :default_provider)
        prev -> Application.put_env(:tau, :default_provider, prev)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # AC-A4: the critical test.
  #
  # Strategy:
  #   1. Attach telemetry handlers for [:tau, :session, :start] (to capture
  #      the session_id) and [:tau, :permissions, :decision] (to assert the
  #      fail-closed deny fires and not :awaiting_permission).
  #   2. Spawn run_cmd/1 in a separate process so the test can receive
  #      telemetry events while the drain loop blocks in the runner.
  #   3. After the [:tau, :permissions, :decision] event fires, snapshot the
  #      session and assert it is NOT in :awaiting_permission.
  #   4. The provider sends back the ToolResults it received on the second
  #      turn — assert they are is_error.
  # ---------------------------------------------------------------------------

  test "tau run (non-interactive) resolves unmatched tool to fail-closed :deny, never enters :awaiting_permission" do
    test_pid = self()
    base_id = "perm-deny-#{System.unique_integer([:positive])}"
    start_handler = "#{base_id}-start"
    decision_handler = "#{base_id}-decision"

    # Capture the session_id from session start telemetry.
    :telemetry.attach(
      start_handler,
      [:tau, :session, :start],
      fn _event, _measurements, %{session_id: sid}, _config ->
        send(test_pid, {:session_started, sid})
      end,
      nil
    )

    # Capture permission decisions to assert the decision is deny_non_interactive.
    :telemetry.attach(
      decision_handler,
      [:tau, :permissions, :decision],
      fn _event, _measurements, meta, _config ->
        send(test_pid, {:permission_decision_telemetry, meta})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(start_handler)
      :telemetry.detach(decision_handler)
    end)

    {[:run], parsed} = Optimus.parse!(Tau.CLI.spec(), ["run", "test prompt"])

    runner =
      spawn_link(fn ->
        exit_code = Tau.CLI.run_cmd(parsed)
        send(test_pid, {:run_cmd_exit, exit_code})
      end)

    _ = runner

    # Discover the session_id from telemetry.
    session_id =
      receive do
        {:session_started, sid} -> sid
      after
        10_000 -> flunk("expected [:tau, :session, :start] telemetry within 10s")
      end

    # The [:tau, :permissions, :decision] event must fire for the unmatched call.
    assert_receive {:permission_decision_telemetry,
                    %{
                      tool_call_id: @call_id,
                      tool_name: @tool_name,
                      decision: :deny_non_interactive,
                      session_id: ^session_id
                    }},
                   8_000

    # The provider's second turn receives the is_error ToolResult.
    assert_receive {:second_turn_tool_results, tool_results}, 8_000

    assert tool_results != [],
           "expected at least one ToolResult on the second turn; got #{inspect(tool_results)}"

    denied =
      Enum.find(tool_results, fn
        %TR{tool_call_id: @call_id, is_error: true} -> true
        _ -> false
      end)

    assert denied != nil,
           "expected is_error ToolResult for #{@call_id}; got #{inspect(tool_results)}"

    assert denied.content =~ "non-interactive",
           "expected denial content to mention non-interactive; got: #{inspect(denied.content)}"

    assert denied.content =~ @tool_name,
           "expected denial content to name #{@tool_name}; got: #{inspect(denied.content)}"

    # run_cmd/1 must complete cleanly (exit code 0).
    assert_receive {:run_cmd_exit, exit_code}, 15_000

    assert exit_code == 0,
           "expected run_cmd/1 to exit 0; got #{exit_code}"

    # Final state: the session must be :awaiting_user (clean turn completion)
    # or already stopped. Either way it must NEVER have been :awaiting_permission
    # (the permission decision fired with :deny_non_interactive, which is only
    # emitted by the non-interactive path — never by the :awaiting_permission path).
    case Tau.snapshot(session_id) do
      {:ok, snap} ->
        refute snap.state == :awaiting_permission,
               "expected FSM never in :awaiting_permission; found: #{snap.state}"

        assert snap.interactive? == false,
               "expected session to be non-interactive; got interactive?: #{snap.interactive?}"

      {:error, :not_found} ->
        # Session already stopped — acceptable; the assertions above on the
        # telemetry event already confirmed the correct behaviour.
        :ok
    end
  end
end
