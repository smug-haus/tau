defmodule Tau.Test.BlockingTool do
  @moduledoc """
  Test-only `Tau.Tool` whose `execute/2` blocks until the test process
  signals `:continue`.

  ## Race-free AC-8 / D-079 pattern

  The classic steering-queue race:

      test process                    dispatcher process
      ────────────                    ──────────────────
      ToolStart received
      Tau.steer(sid, text)            tool.execute/2 running…
      (steer MAY OR MAY NOT be         {:tool_done} sent to FSM
       queued before tool_done hits)

  With BlockingTool, `execute/2` sends `{:blocking_tool_executing, self()}`
  to the registered notify process, then blocks until the test sends
  `:blocking_tool_continue` directly to the executor process.

  The test can therefore:

    1. Receive `{:blocking_tool_executing, executor_pid}` — tool is blocked.
    2. Call `Tau.steer/2`.
    3. Call `Tau.snapshot/1` and assert the steer IS in the steering queue.
    4. Call `BlockingTool.release(executor_pid)` — unblocks the tool.
    5. Await `%SE.ToolEnd{}` — by construction, the steer was queued BEFORE
       `{:tool_done}` was sent to the FSM mailbox.

  This eliminates the race entirely: the steering message is provably in the
  queue when the tool round completes, so D-079's drain fires with the steer
  present.

  ## Setup (in test or setup block)

      prior_builtins = Application.get_env(:tau, :builtin_tools, [])
      Application.put_env(:tau, :builtin_tools, [BlockingTool | prior_builtins])
      Process.register(self(), BlockingTool.notify_name())

      on_exit(fn ->
        Application.put_env(:tau, :builtin_tools, prior_builtins)
        try do
          Process.unregister(BlockingTool.notify_name())
        rescue
          ArgumentError -> :ok
        end
      end)

  Tests using this module must run `async: false` (or ensure the notify name
  is not contended across concurrent tests).
  """

  @behaviour Tau.Tool

  @notify_name :tau_blocking_tool_notify

  @doc "The atom under which the test process must be registered."
  @spec notify_name() :: atom()
  def notify_name, do: @notify_name

  @impl true
  def name, do: "blocking_test_tool"

  @impl true
  def description, do: "Test tool that blocks until released (test-only)"

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def streams_updates?, do: false

  @impl true
  def execute(_args, _ctx) do
    # Runs in the tool dispatcher process. Notify the test that execution
    # is in progress, including our pid so the test can unblock us.
    case Process.whereis(@notify_name) do
      nil ->
        # No test registered — proceed immediately (safe degradation).
        :ok

      test_pid ->
        send(test_pid, {:blocking_tool_executing, self()})

        receive do
          :blocking_tool_continue -> :ok
        after
          15_000 ->
            # Timeout: proceed to avoid hanging the suite.
            :ok
        end
    end

    {:ok, "blocking-tool-result"}
  end

  @doc """
  Unblocks the executor process captured from `:blocking_tool_executing`.

  Call this from the test process after confirming the steering message
  is in the session's steering queue.
  """
  @spec release(pid()) :: :ok
  def release(executor_pid) when is_pid(executor_pid) do
    send(executor_pid, :blocking_tool_continue)
    :ok
  end
end
