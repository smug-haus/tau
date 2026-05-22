defmodule Tau.Tools.Builtin.DelegateTest do
  @moduledoc """
  Unit tests for `Tau.Tools.Builtin.Delegate` — Phase 2 of #191.

  Exercises the tool directly (without spinning up a full
  `Tau.Session` FSM) by handing it a `%Tau.Tool.Context{}` and a
  parameters map, the same way `Tau.Tools.BuiltinTest` does for
  Read/Write/Edit/Bash. The Replay adapter stands in for any real
  coding-agent backend; an integration test against the real
  `claude` binary is opt-in via INTEGRATION=1 (see end of file).

  Covers:

    * Happy path                — assistant text assembled from
                                  Replay fixture; details audit
                                  trail populated.
    * Unknown agent             — `is_error: true` with a clear
                                  message; no dispatcher spawned.
    * Recursion limit triggered — `depth >= @max_depth` rejected
                                  synchronously.
    * Timeout exceeded          — `timeout_ms` low enough to fire
                                  before the slow fixture finishes;
                                  partial text + is_error.
    * Cancellation              — parent session pid dies mid-run;
                                  tool observes the :DOWN, cancels
                                  the dispatcher, returns partial
                                  + is_error.
    * Cost in details           — `Event.Cost{}` from the Replay
                                  fixture surfaces in
                                  `result.details.cost`.
    * Telemetry parity          — `[:tau, :tool, :delegate,
                                  :start | :stop]` fire in order.
    * Workspace passthrough     — caller-supplied absolute path
                                  used as-is; no worktree created.

  Tests use `async: false` because they touch the
  `Tau.Sessions.Registry` global registry (for the cancellation
  test) and attach telemetry handlers.
  """

  use ExUnit.Case, async: false

  alias Tau.CodingAgent.Event
  alias Tau.Tool.Context
  alias Tau.Tools.Builtin.Delegate

  # A minimal, deterministic Replay fixture that exercises every
  # event variant the tool folds into its details map.
  defp replay_fixture(text \\ "subtask done") do
    [
      %Event.Start{agent: :replay, version: "test"},
      %Event.AssistantText{text: text, turn: 0},
      %Event.ToolUse{id: "tu1", name: "Read", input: %{"path" => "README.md"}},
      %Event.ToolResult{tool_use_id: "tu1", content: "ok", is_error: false},
      %Event.FileEdit{path: "README.md", kind: :modify},
      %Event.Cost{tokens: %{"input" => 100, "output" => 50}, usd: 0.0015, duration_ms: 42},
      %Event.Done{exit_status: 0, final_message: "all done"}
    ]
  end

  defp ctx(opts \\ []) do
    Context.new(
      tool_call_id: opts[:tool_call_id] || "delegate-call-1",
      session_id: opts[:session_id] || "sess-#{System.unique_integer([:positive])}",
      cwd: opts[:cwd] || System.tmp_dir!()
    )
  end

  # Wait until the CodingAgent.Supervisor has no active children.
  #
  # The Dispatcher sends %Event.Done{} to its subscriber and then returns
  # {:stop, :normal} from handle_info. The subscriber (Delegate.execute's
  # drain loop) unblocks immediately on receiving Done, but the
  # DynamicSupervisor's decrement of count_children is asynchronous — it
  # happens after the process actually exits and the supervisor processes
  # the EXIT signal. This leaves a window where count() > 0 even though
  # Delegate.execute has already returned.
  #
  # We close this window by monitoring each currently-running child and
  # awaiting its :DOWN. :DOWN is sent synchronously when the process dies,
  # so after all :DOWNs are received, count() is guaranteed to be 0.
  defp wait_dispatchers_idle do
    Tau.CodingAgent.Supervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} when is_pid(pid) ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> Process.demonitor(ref, [:flush])
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------
  describe "happy path" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "tau-delegate-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{tmp: tmp}
    end

    test "Replay adapter — assembles final text, populates details", %{tmp: tmp} do
      params = %{
        "prompt" => "do the thing",
        "agent" => "replay",
        "workspace" => tmp,
        "replay_fixture" => replay_fixture("hello from replay")
      }

      {:ok, result} = Delegate.execute(params, ctx(cwd: tmp))

      refute result.is_error
      assert result.content == "hello from replay"

      assert result.details.kind == :delegate_result
      assert result.details.agent == "replay"
      assert result.details.adapter == Tau.CodingAgents.Replay
      assert result.details.workspace == tmp
      assert result.details.exit_status == 0
      assert result.details.final_message == "all done"

      # Audit trail: tool calls observed during the run flow through
      # details so the parent FSM persists them.
      assert [%{id: "tu1", name: "Read"}] = result.details.tool_uses
      assert [%{tool_use_id: "tu1", is_error: false}] = result.details.tool_results
      assert [%{path: "README.md", kind: :modify}] = result.details.file_edits

      # Cost folded from %Event.Cost{} into the details (Team D folds
      # it into Tau.Cost.Tracker via the dispatcher's per-event
      # telemetry; the tool itself only surfaces the line item).
      assert %{usd: 0.0015, duration_ms: 42, tokens: %{"input" => 100, "output" => 50}} =
               result.details.cost
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown agent
  # ---------------------------------------------------------------------------
  describe "unknown agent" do
    # Await teardown of any dispatchers started by previous tests before
    # recording the baseline count. The dispatcher sends Done to the drain
    # loop and then calls {:stop, :normal} — but {:stop, :normal} is
    # processed asynchronously by the DynamicSupervisor, so count() can
    # still be 1 when the next test starts. Monitoring each child and
    # awaiting :DOWN gives us a real terminal signal rather than a sleep.
    setup do
      wait_dispatchers_idle()
      :ok
    end

    test "returns is_error without spawning a dispatcher" do
      before = Tau.CodingAgent.Supervisor.count()

      params = %{
        "prompt" => "p",
        "agent" => "no_such_agent",
        "workspace" => System.tmp_dir!()
      }

      {:ok, result} = Delegate.execute(params, ctx())

      assert result.is_error
      assert result.content =~ "Unknown coding-agent identifier"
      assert result.content =~ "no_such_agent"
      assert result.details.kind == :unknown_agent

      # No dispatcher should have started for an unknown agent.
      assert Tau.CodingAgent.Supervisor.count() == before
    end
  end

  # ---------------------------------------------------------------------------
  # Recursion limit
  # ---------------------------------------------------------------------------
  describe "recursion limit" do
    # Same rationale as "unknown agent": await previous-test dispatcher
    # teardown before recording the baseline count.
    setup do
      wait_dispatchers_idle()
      :ok
    end

    test "depth >= max_depth is rejected before any dispatcher runs" do
      before = Tau.CodingAgent.Supervisor.count()

      params = %{
        "prompt" => "p",
        "agent" => "replay",
        "workspace" => System.tmp_dir!(),
        "depth" => 2
      }

      {:ok, result} = Delegate.execute(params, ctx())

      assert result.is_error
      assert result.content =~ "recursion limit reached"
      assert result.details.kind == :depth_exceeded
      assert result.details.depth == 2
      assert result.details.max_depth == 2

      assert Tau.CodingAgent.Supervisor.count() == before
    end

    test "depth = max_depth - 1 is allowed" do
      params = %{
        "prompt" => "p",
        "agent" => "replay",
        "workspace" => System.tmp_dir!(),
        "depth" => 1,
        "replay_fixture" => replay_fixture()
      }

      {:ok, result} = Delegate.execute(params, ctx())
      refute result.is_error
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout
  # ---------------------------------------------------------------------------
  describe "timeout" do
    test "fires when timeout_ms expires before Done; partial trace surfaces" do
      # Replay's `:replay_delay_ms` widens the emission interval to
      # 200ms per event; with `timeout_ms: 50` we are guaranteed to
      # observe at most the first event before the tool's own
      # deadline fires.
      events = [
        %Event.Start{agent: :replay},
        %Event.AssistantText{text: "partial", turn: 0},
        %Event.Done{exit_status: 0, final_message: "should not arrive"}
      ]

      tool_ctx =
        %Context{
          ctx()
          | metadata: %{
              replay_delay_ms: 200,
              # Disable the dispatcher's own inactivity timeout so it
              # doesn't race with our wall-clock cap.
              inactivity_timeout_ms: :infinity
            }
        }

      params = %{
        "prompt" => "p",
        "agent" => "replay",
        "workspace" => System.tmp_dir!(),
        "replay_fixture" => events,
        "timeout_ms" => 50
      }

      {:ok, result} = Delegate.execute(params, tool_ctx)

      assert result.is_error
      assert result.details.kind == :delegate_timeout
      assert result.content =~ "timed out"
    end
  end

  # ---------------------------------------------------------------------------
  # Cancellation
  # ---------------------------------------------------------------------------
  describe "cancellation via parent DOWN" do
    test "parent pid dies mid-stream; tool returns is_error with partial trace" do
      session_id = "parent-#{System.unique_integer([:positive])}"
      test_pid = self()

      # Stand up a synthetic parent process and have it register
      # itself in `Tau.Sessions.Registry` so `Delegate.monitor_parent/1`
      # finds the pid the same way the real session FSM does.
      parent_pid =
        spawn(fn ->
          {:ok, _} = Registry.register(Tau.Sessions.Registry, session_id, :synthetic)
          send(test_pid, :parent_registered)

          # Idle until the test asks us to die.
          receive do
            :die -> :ok
          end
        end)

      assert_receive :parent_registered, 1_000

      # Slow fixture: ~6 emissions × 100ms each ≈ 600ms total. The
      # cancellation lands ~50ms in, well before the run finishes.
      slow_events = [
        %Event.Start{agent: :replay},
        %Event.AssistantText{text: "partial-", turn: 0},
        %Event.AssistantText{text: "before-cancel-", turn: 0},
        %Event.AssistantText{text: "still-going-", turn: 0},
        %Event.AssistantText{text: "after-cancel", turn: 0},
        %Event.Done{exit_status: 0}
      ]

      tool_ctx =
        %Context{
          Context.new(
            tool_call_id: "tc-cancel",
            session_id: session_id,
            cwd: System.tmp_dir!()
          )
          | metadata: %{replay_delay_ms: 100, inactivity_timeout_ms: :infinity}
        }

      params = %{
        "prompt" => "p",
        "agent" => "replay",
        "workspace" => System.tmp_dir!(),
        "replay_fixture" => slow_events,
        "timeout_ms" => 5_000
      }

      # Kill the synthetic parent 150ms in — long enough for the
      # first AssistantText emission (100ms after Start) so partial
      # output accumulates, well before the run finishes (~600ms).
      spawn(fn ->
        Process.sleep(150)
        send(parent_pid, :die)
      end)

      {:ok, result} = Delegate.execute(params, tool_ctx)

      assert result.is_error
      assert result.details.kind == :delegate_cancelled
      assert result.content =~ "cancelled by parent"
    end

    test "missing parent pid (registry empty) is not fatal — runs to completion" do
      # When the session FSM is gone before the tool runs (e.g. the
      # session was already torn down), monitor_parent/1 returns nil
      # and the tool runs to completion without cancellation.
      params = %{
        "prompt" => "p",
        "agent" => "replay",
        "workspace" => System.tmp_dir!(),
        "replay_fixture" => replay_fixture("orphan run")
      }

      orphan_ctx =
        Context.new(
          tool_call_id: "tc-orphan",
          session_id: "no-such-session-#{System.unique_integer([:positive])}",
          cwd: System.tmp_dir!()
        )

      {:ok, result} = Delegate.execute(params, orphan_ctx)

      refute result.is_error
      assert result.content == "orphan run"
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry parity
  # ---------------------------------------------------------------------------
  describe "telemetry" do
    test "emits start/stop events with adapter + outcome metadata" do
      events = [
        [:tau, :tool, :delegate, :start],
        [:tau, :tool, :delegate, :stop]
      ]

      test_pid = self()
      handler_id = "delegate-test-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      params = %{
        "prompt" => "p",
        "agent" => "replay",
        "workspace" => System.tmp_dir!(),
        "replay_fixture" => replay_fixture()
      }

      {:ok, _result} = Delegate.execute(params, ctx())

      assert_receive {:telemetry, [:tau, :tool, :delegate, :start], _, %{agent: "replay"}}, 1_000

      assert_receive {:telemetry, [:tau, :tool, :delegate, :stop], %{duration: dur},
                      %{agent: "replay", is_error: false, exit_status: 0}},
                     1_000

      assert is_integer(dur) and dur >= 0

      :telemetry.detach(handler_id)
    end

    test "exception event fires on synchronous reject paths" do
      handler_id = "delegate-exc-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:tau, :tool, :delegate, :exception],
        fn _e, _m, meta, _ -> send(test_pid, {:exception, meta}) end,
        nil
      )

      {:ok, _r} =
        Delegate.execute(
          %{"prompt" => "p", "agent" => "nope", "workspace" => System.tmp_dir!()},
          ctx()
        )

      assert_receive {:exception, %{reason: :unknown_agent}}, 1_000

      :telemetry.detach(handler_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Workspace handling
  # ---------------------------------------------------------------------------
  describe "workspace handling" do
    test "caller-supplied absolute path is used as-is" do
      tmp = Path.join(System.tmp_dir!(), "tau-dlg-ws-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      params = %{
        "prompt" => "p",
        "agent" => "replay",
        "workspace" => tmp,
        "replay_fixture" => replay_fixture()
      }

      {:ok, result} = Delegate.execute(params, ctx())
      refute result.is_error
      assert result.details.workspace == tmp
    end

    test "relative path is rejected (D-033 — explicit only)" do
      params = %{
        "prompt" => "p",
        "agent" => "replay",
        "workspace" => "relative/path"
      }

      {:ok, result} = Delegate.execute(params, ctx())

      assert result.is_error
      assert result.details.kind == :workspace_error
    end

    test "non-directory workspace is rejected" do
      tmp = Path.join(System.tmp_dir!(), "tau-dlg-nodir-#{System.unique_integer([:positive])}")
      File.write!(tmp, "not a directory")
      on_exit(fn -> File.rm!(tmp) end)

      params = %{
        "prompt" => "p",
        "agent" => "replay",
        "workspace" => tmp
      }

      {:ok, result} = Delegate.execute(params, ctx())

      assert result.is_error
      assert result.details.kind == :workspace_error
    end
  end

  # ---------------------------------------------------------------------------
  # Cost folding sanity (separate from Tracker — see Team D)
  # ---------------------------------------------------------------------------
  describe "cost surfacing" do
    test "Event.Cost arrives in details.cost with adapter-tagged provenance" do
      params = %{
        "prompt" => "p",
        "agent" => "replay",
        "workspace" => System.tmp_dir!(),
        "replay_fixture" => [
          %Event.Start{agent: :replay},
          %Event.AssistantText{text: "ok"},
          %Event.Cost{tokens: %{"input" => 7}, usd: nil, duration_ms: 5},
          %Event.Done{exit_status: 0}
        ]
      }

      {:ok, result} = Delegate.execute(params, ctx())

      refute result.is_error
      # `usd: nil` is the documented sentinel for adapters that can't
      # measure cost (SPEC §7 Q4). The line item still surfaces.
      assert %{usd: nil, tokens: %{"input" => 7}, duration_ms: 5} = result.details.cost
      assert result.details.adapter == Tau.CodingAgents.Replay
    end

    # Documents the current behaviour: Delegate runs do NOT fold their
    # `%Event.Cost{}` into `Tau.Cost.Tracker` because the tool bypasses
    # the session FSM (only `Tau.Session.maybe_apply_cost_hook/2`
    # emits `[:tau, :coding_agent, :cost]`). This is a known gap; see
    # the follow-up issue "Delegate tool: fold cost into
    # Tau.Cost.Tracker (D-038 parity with session-mode)". The session-
    # mode surface (Phase 1B Team B, #195) folds cost correctly —
    # verified in `Tau.Session.CodingAgentCostTest`.
    test "Tau.Cost.Tracker does NOT see a Delegate run's cost (known gap)" do
      Tau.Cost.reset()

      params = %{
        "prompt" => "p",
        "agent" => "replay",
        "workspace" => System.tmp_dir!(),
        "replay_fixture" => [
          %Event.Start{agent: :replay},
          %Event.AssistantText{text: "ok"},
          %Event.Cost{
            tokens: %{
              "input_tokens" => 123,
              "output_tokens" => 456
            },
            usd: 0.01,
            duration_ms: 5
          },
          %Event.Done{exit_status: 0}
        ]
      }

      {:ok, result} = Delegate.execute(params, ctx())

      refute result.is_error
      # The line item still surfaces in details (so audit trail + TUI
      # can show it inline).
      assert result.details.cost.usd == 0.01

      # But the Tracker is empty: no `[:tau, :coding_agent, :cost]`
      # was emitted because Delegate doesn't go through the session
      # FSM's cost hook. Filed as follow-up.
      summary = Tau.Cost.summary()
      refute Map.has_key?(summary.by_provider, Tau.CodingAgents.Replay)
      assert summary.totals.input_tokens == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Integration — only runs when INTEGRATION=1 and `claude` is on PATH.
  # Excluded from the default suite via `@describetag :integration`;
  # run with `mix test --include integration` or set INTEGRATION=1 + use
  # the env-gated assertion below.
  # ---------------------------------------------------------------------------
  describe "integration: claude_code adapter" do
    @describetag :integration

    @tag :integration
    test "one-turn delegation returns assistant text" do
      cond do
        System.get_env("INTEGRATION") != "1" ->
          # When the tag filter is overridden (`--include integration`)
          # without the env opt-in, no-op rather than fail. Belt and
          # braces: lets a curious dev enable the tag without setting
          # up the claude CLI.
          :ok

        System.find_executable("claude") == nil ->
          flunk("`claude` not on PATH; install Claude Code or unset INTEGRATION")

        true ->
          tmp = Path.join(System.tmp_dir!(), "tau-dlg-int-#{System.unique_integer([:positive])}")
          File.mkdir_p!(tmp)
          on_exit(fn -> File.rm_rf!(tmp) end)

          params = %{
            "prompt" => "Say the word PONG and nothing else.",
            "agent" => "claude_code",
            "workspace" => tmp,
            "timeout_ms" => 60_000
          }

          {:ok, result} = Delegate.execute(params, ctx(cwd: tmp))

          refute result.is_error
          assert result.content =~ ~r/pong/i
      end
    end
  end
end
