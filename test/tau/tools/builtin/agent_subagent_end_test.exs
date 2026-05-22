defmodule Tau.Tools.Builtin.AgentSubagentEndTest do
  @moduledoc """
  D-154 (SPEC-TUI-HEADLESS §5c): unit tests for all five terminal branches of
  `Tau.Tools.Builtin.Agent.await_child/4`.

  Each test triggers exactly one terminal branch and asserts that
  `%SE.SubagentEnd{}` arrives on the parent topic with the correct `state`.

  Branches under test:
    1. natural_end  — MessageEnd with natural stop_reason → state: :done
    2. failure_end  — MessageEnd with failure stop_reason → state: :failed
    3. SessionEnd   — child FSM terminates abnormally   → state: :failed
    4. {:DOWN, …}   — parent FSM process killed         → state: :cancelled
    5. after-timeout — await_timeout_ms fires           → state: :cancelled

  Branch 3 (`%SE.SessionEnd{}`) is the regression introduced when the
  catch-all `%{session_id: ^child_id}` was placed BEFORE `%SE.SessionEnd{}` in
  the receive block, causing SessionEnd to be consumed by the catch-all and
  the tool-task to hang until timeout (returning `:cancelled` instead of the
  correct `:failed`). This test MUST fail against the pre-fix clause order.

  Uses `async: false` because it touches global application env and PubSub.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  # ---------------------------------------------------------------------------
  # Providers
  # ---------------------------------------------------------------------------

  # Parent drives a single Agent tool call; child fixture selected by function.
  defmodule MultiRouteProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def default_model, do: "multi-route"

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
    def stream(messages, _opts, ctx) do
      parent_sid = ctx[:parent_session_id]
      this_sid = ctx[:session_id]
      has_tool_result? = Enum.any?(messages, &match?(%Tau.Message.ToolResult{}, &1))

      events =
        cond do
          this_sid == parent_sid and has_tool_result? ->
            ctx[:parent_second_fixture] || default_parent_done()

          this_sid == parent_sid ->
            ctx[:parent_first_fixture]

          true ->
            # Child: delegate to the :child_stream_fn stored in ctx, or hang.
            stream_fn = ctx[:child_stream_fn] || (&hanging_stream/0)
            stream_fn.()
        end

      {:ok, events}
    end

    defp default_parent_done do
      [
        %Event.Start{request_id: "mrp-done", model: "multi-route"},
        %Event.TextStart{block_id: "b0"},
        %Event.TextDelta{block_id: "b0", text: "parent done"},
        %Event.TextEnd{block_id: "b0"},
        %Event.Done{stop_reason: :end_turn, usage: %{}}
      ]
    end

    defp hanging_stream do
      Stream.resource(
        fn -> :ok end,
        fn :ok ->
          Process.sleep(:infinity)
          {:halt, :ok}
        end,
        fn _ -> :ok end
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp agent_tool_call_fixture(call_id, description) do
    [
      %Event.Start{request_id: "se-parent-r1", model: "multi-route"},
      %Event.ToolCallStart{tool_call_id: call_id, name: "Agent"},
      %Event.ToolCallEnd{tool_call_id: call_id, params: %{"description" => description}},
      %Event.Done{stop_reason: :tool_use, usage: %{}}
    ]
  end

  defp parent_done_fixture do
    [
      %Event.Start{request_id: "se-parent-r2", model: "multi-route"},
      %Event.TextStart{block_id: "b0"},
      %Event.TextDelta{block_id: "b0", text: "done"},
      %Event.TextEnd{block_id: "b0"},
      %Event.Done{stop_reason: :end_turn, usage: %{}}
    ]
  end

  defp child_natural_end_fixture do
    fn ->
      [
        %Event.Start{request_id: "se-child-nat", model: "multi-route"},
        %Event.TextStart{block_id: "b0"},
        %Event.TextDelta{block_id: "b0", text: "child result"},
        %Event.TextEnd{block_id: "b0"},
        %Event.Done{stop_reason: :end_turn, usage: %{}}
      ]
    end
  end

  defp child_failure_end_fixture do
    fn ->
      [
        %Event.Start{request_id: "se-child-err", model: "multi-route"},
        %Event.Error{reason: :test_failure, retryable?: false}
      ]
    end
  end

  defp hanging_child_fixture do
    fn ->
      Stream.resource(
        fn -> :ok end,
        fn :ok ->
          Process.sleep(:infinity)
          {:halt, :ok}
        end,
        fn _ -> :ok end
      )
    end
  end

  defp await_child_registered(parent_sid, timeout \\ 10_000) do
    test_pid = self()
    handler_id = "subagent-end-child-reg-#{System.unique_integer()}"

    :telemetry.attach(
      handler_id,
      [:tau, :session, :child_registered],
      fn _event, _m, meta, _ ->
        if meta.session_id == parent_sid do
          send(test_pid, {:child_registered, meta.child_id})
        end
      end,
      nil
    )

    receive do
      {:child_registered, child_id} ->
        :telemetry.detach(handler_id)
        child_id
    after
      timeout ->
        :telemetry.detach(handler_id)
        flunk("timeout waiting for child_registered telemetry")
    end
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "tau-subagent-end-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:tau, :subagent_await_timeout_ms)
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{tmp: tmp}
  end

  # ---------------------------------------------------------------------------
  # Branch 1: natural_end — MessageEnd with natural stop_reason → state: :done
  # ---------------------------------------------------------------------------
  @tag :integration
  test "branch 1 natural_end: SubagentEnd{state: :done} when child ends with :end_turn",
       %{tmp: tmp} do
    parent_sid = Tau.Session.generate_id()
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{parent_sid}")
    call_id = "se-b1-call"

    provider_ctx = %{
      parent_session_id: parent_sid,
      parent_first_fixture: agent_tool_call_fixture(call_id, "branch1"),
      parent_second_fixture: parent_done_fixture(),
      child_stream_fn: child_natural_end_fixture()
    }

    {:ok, ^parent_sid} =
      start_session_for_test(
        provider: MultiRouteProvider,
        session_id: parent_sid,
        cwd: tmp,
        metadata: %{permissions_mode: :bypass},
        provider_ctx: provider_ctx
      )

    Tau.send(parent_sid, "branch 1 test")

    assert_receive %SE.SubagentEnd{state: :done}, 10_000
  end

  # ---------------------------------------------------------------------------
  # Branch 2: failure_end — MessageEnd with failure stop_reason → state: :failed
  # ---------------------------------------------------------------------------
  @tag :integration
  test "branch 2 failure_end: SubagentEnd{state: :failed} when child MessageEnd has :error stop_reason",
       %{tmp: tmp} do
    parent_sid = Tau.Session.generate_id()
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{parent_sid}")
    call_id = "se-b2-call"

    provider_ctx = %{
      parent_session_id: parent_sid,
      parent_first_fixture: agent_tool_call_fixture(call_id, "branch2"),
      parent_second_fixture: parent_done_fixture(),
      child_stream_fn: child_failure_end_fixture()
    }

    {:ok, ^parent_sid} =
      start_session_for_test(
        provider: MultiRouteProvider,
        session_id: parent_sid,
        cwd: tmp,
        metadata: %{permissions_mode: :bypass},
        provider_ctx: provider_ctx
      )

    Tau.send(parent_sid, "branch 2 test")

    assert_receive %SE.SubagentEnd{state: :failed}, 10_000
  end

  # ---------------------------------------------------------------------------
  # Branch 3: SessionEnd — child FSM terminated → state: :failed
  #
  # This is the regression case for FIX-1. When the catch-all
  # `%{session_id: ^child_id}` was placed BEFORE `%SE.SessionEnd{}` in the
  # receive block, the SessionEnd struct (which IS a map with session_id key)
  # matched the catch-all and was silently discarded. The tool task then hung
  # until the timeout, returning SubagentEnd{state: :cancelled} instead of
  # SubagentEnd{state: :failed}. This test MUST fail against the pre-fix order.
  # ---------------------------------------------------------------------------
  @tag :integration
  test "branch 3 SessionEnd: SubagentEnd{state: :failed} when child FSM terminates (D-154 regression)",
       %{tmp: tmp} do
    # Use a very short timeout so the test fails fast if branch 3 is shadowed
    # by the catch-all (it would fall through to the :cancelled timeout branch).
    Application.put_env(:tau, :subagent_await_timeout_ms, 2_000)

    parent_sid = Tau.Session.generate_id()
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{parent_sid}")
    call_id = "se-b3-call"

    provider_ctx = %{
      parent_session_id: parent_sid,
      parent_first_fixture: agent_tool_call_fixture(call_id, "branch3"),
      parent_second_fixture: parent_done_fixture(),
      child_stream_fn: hanging_child_fixture()
    }

    {:ok, ^parent_sid} =
      start_session_for_test(
        provider: MultiRouteProvider,
        session_id: parent_sid,
        cwd: tmp,
        metadata: %{permissions_mode: :bypass},
        provider_ctx: provider_ctx
      )

    Tau.send(parent_sid, "branch 3 test")

    # Wait for the child to be registered so we have its id.
    child_id = await_child_registered(parent_sid)

    # Terminate the child FSM abnormally. This causes the child's
    # `terminate/3` to run and broadcast `%SE.SessionEnd{session_id: child_id}`.
    # In the pre-FIX-1 code, the catch-all `%{session_id: ^child_id}` would
    # swallow this struct (because all Elixir structs are maps), causing the
    # tool task to hang. Post-fix, `%SE.SessionEnd{}` matches first.
    Tau.stop(child_id)

    # Must receive :failed (not :cancelled) and within 1s (not the 2s timeout).
    assert_receive %SE.SubagentEnd{state: :failed}, 1_500
  end

  # ---------------------------------------------------------------------------
  # Branch 4: {:DOWN, parent_ref} — parent FSM process killed → state: :cancelled
  # ---------------------------------------------------------------------------
  @tag :integration
  test "branch 4 parent_down: SubagentEnd{state: :cancelled} when parent process is killed",
       %{tmp: tmp} do
    parent_sid = Tau.Session.generate_id()
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{parent_sid}")
    call_id = "se-b4-call"

    provider_ctx = %{
      parent_session_id: parent_sid,
      parent_first_fixture: agent_tool_call_fixture(call_id, "branch4"),
      parent_second_fixture: parent_done_fixture(),
      child_stream_fn: hanging_child_fixture()
    }

    {:ok, ^parent_sid} =
      start_session_for_test(
        provider: MultiRouteProvider,
        session_id: parent_sid,
        cwd: tmp,
        metadata: %{permissions_mode: :bypass},
        provider_ctx: provider_ctx
      )

    Tau.send(parent_sid, "branch 4 test")

    # Wait for the child to be registered and the tool task to start awaiting.
    _child_id = await_child_registered(parent_sid)

    # Get the parent FSM pid and kill it. The tool task monitors the parent pid
    # via `Process.monitor/1`; when it dies the {:DOWN, ^parent_ref, ...} fires.
    [{parent_pid, _}] = Registry.lookup(Tau.Sessions.Registry, parent_sid)
    Process.exit(parent_pid, :kill)

    # The tool task broadcasts SubagentEnd{state: :cancelled} on the parent topic
    # before returning. Since we subscribed to "session:#{parent_sid}", we should
    # receive it even though the parent FSM is dead (PubSub delivers to us, not
    # to the FSM).
    assert_receive %SE.SubagentEnd{state: :cancelled}, 5_000
  end

  # ---------------------------------------------------------------------------
  # Branch 5: after-timeout — await_timeout_ms fires → state: :cancelled
  # ---------------------------------------------------------------------------
  @tag :integration
  test "branch 5 timeout: SubagentEnd{state: :cancelled} when await_timeout_ms fires",
       %{tmp: tmp} do
    # Inject a short timeout so the test doesn't block for 10 minutes.
    Application.put_env(:tau, :subagent_await_timeout_ms, 300)

    parent_sid = Tau.Session.generate_id()
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{parent_sid}")
    call_id = "se-b5-call"

    provider_ctx = %{
      parent_session_id: parent_sid,
      parent_first_fixture: agent_tool_call_fixture(call_id, "branch5"),
      parent_second_fixture: parent_done_fixture(),
      child_stream_fn: hanging_child_fixture()
    }

    {:ok, ^parent_sid} =
      start_session_for_test(
        provider: MultiRouteProvider,
        session_id: parent_sid,
        cwd: tmp,
        metadata: %{permissions_mode: :bypass},
        provider_ctx: provider_ctx
      )

    Tau.send(parent_sid, "branch 5 test")

    # SubagentEnd{state: :cancelled} must arrive after ~300ms timeout fires.
    assert_receive %SE.SubagentEnd{state: :cancelled, summary: summary}, 5_000

    assert summary =~ "timed out",
           "summary should mention timeout, got: #{inspect(summary)}"
  end
end
