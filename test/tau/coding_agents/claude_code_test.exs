defmodule Tau.CodingAgents.ClaudeCodeTest do
  @moduledoc """
  Contract tests for `Tau.CodingAgents.ClaudeCode`. Mirrors
  `Tau.CodingAgentTest` (the Replay contract) so adapter parity is
  enforced at the test level.

  Covers SPEC-CODING-AGENT.md AC-1 (shared contract), AC-6
  (auth-failure surface), D-031 (normalised event stream),
  D-033 (explicit workspace), D-035 (no raise across boundary),
  D-036 (no credential injection — exercised by the `claude_code_source`
  injection path which never reads `~/.claude/credentials.json`).

  All spawn-paths are exercised via the `ctx[:claude_code_source]`
  test injection so the suite does NOT depend on the `claude` CLI
  being installed.
  """

  use ExUnit.Case, async: true

  alias Tau.CodingAgent
  alias Tau.CodingAgent.Event
  alias Tau.CodingAgents.ClaudeCode

  @fixture_dir Path.join([File.cwd!(), "test", "fixtures"])
  @fix_success Path.join(@fixture_dir, "claude_code_success.jsonl")
  @fix_tool_use Path.join(@fixture_dir, "claude_code_tool_use.jsonl")
  @fix_auth_error Path.join(@fixture_dir, "claude_code_auth_error.jsonl")

  describe "capabilities/0" do
    test "returns a fully-populated map" do
      caps = ClaudeCode.capabilities()

      assert is_map(caps)

      for key <- [
            :streaming,
            :tool_restriction,
            :mcp_client,
            :session_resume,
            :cost_reporting,
            :workspace_isolation
          ] do
        assert Map.has_key?(caps, key), "missing capability key: #{inspect(key)}"
      end

      assert caps.workspace_isolation in [:cwd, :worktree, :either]
      assert caps.streaming == true
      assert caps.mcp_client == true
      assert caps.session_resume == true
      assert caps.cost_reporting == true
    end
  end

  describe "configure/1" do
    test "echoes the input map" do
      assert {:ok, %{foo: 1}} = ClaudeCode.configure(%{foo: 1})
    end
  end

  describe "start/2 — workspace validation (D-033)" do
    test "returns :workspace_missing when no workspace field" do
      assert {:error, :workspace_missing} = ClaudeCode.start(%{prompt: "p"}, %{})
    end

    test "returns :workspace_missing on empty workspace string" do
      assert {:error, :workspace_missing} =
               ClaudeCode.start(%{prompt: "p", workspace: ""}, %{})
    end

    test "returns {:workspace_invalid, path} when workspace is not a directory" do
      bogus = "/nonexistent/path/that/should/not/exist/#{System.unique_integer([:positive])}"

      assert {:error, {:workspace_invalid, ^bogus}} =
               ClaudeCode.start(%{prompt: "p", workspace: bogus}, %{})
    end

    test "accepts an existing directory" do
      ctx = %{claude_code_source: {:fixture, @fix_success}}
      assert {:ok, _stream} = ClaudeCode.start(default_task(), ctx)
    end
  end

  describe "start/2 — fixture replay" do
    test "happy path: Start → AssistantText → Cost → Done(exit_status: 0)" do
      ctx = %{claude_code_source: {:fixture, @fix_success}}
      {:ok, stream} = ClaudeCode.start(default_task(), ctx)
      events = Enum.to_list(stream)

      assert match?(%Event.Start{agent: :claude_code, version: "2.1.142"}, List.first(events))

      assert Enum.any?(events, &match?(%Event.AssistantText{}, &1))
      assert Enum.any?(events, &match?(%Event.Cost{usd: 0.0015}, &1))
      assert match?(%Event.Done{exit_status: 0, final_message: "Done."}, List.last(events))
    end

    test "tool_use fixture surfaces ToolUse and ToolResult" do
      ctx = %{claude_code_source: {:fixture, @fix_tool_use}}
      {:ok, stream} = ClaudeCode.start(default_task(), ctx)
      events = Enum.to_list(stream)

      assert Enum.any?(events, fn
               %Event.ToolUse{name: "Read", id: "toolu_01abc"} -> true
               _ -> false
             end)

      assert Enum.any?(events, fn
               %Event.ToolResult{tool_use_id: "toolu_01abc", is_error: false} -> true
               _ -> false
             end)

      assert match?(%Event.Done{exit_status: 0}, List.last(events))
    end

    test "auth-error fixture surfaces a non-recoverable :auth_failed error (AC-6)" do
      ctx = %{claude_code_source: {:fixture, @fix_auth_error}}
      {:ok, stream} = ClaudeCode.start(default_task(), ctx)
      events = Enum.to_list(stream)

      assert Enum.any?(events, fn
               %Event.Error{recoverable: false, reason: {:auth_failed, msg}} ->
                 String.contains?(msg, "/login")

               _ ->
                 false
             end)
    end

    test "in-memory line list passes through unmodified" do
      lines = [
        ~s({"type":"system","subtype":"init","session_id":"x","claude_code_version":"2.1.142"}),
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}),
        ~s({"type":"result","subtype":"success","duration_ms":1,"result":"k","total_cost_usd":0.0,"usage":{}})
      ]

      ctx = %{claude_code_source: {:lines, lines}}
      {:ok, stream} = ClaudeCode.start(default_task(), ctx)
      events = Enum.to_list(stream)

      assert match?(%Event.Start{}, List.first(events))
      assert match?(%Event.Done{exit_status: 0}, List.last(events))
    end

    test "malformed line is folded into a recoverable Error and stream continues (D-035)" do
      lines = [
        ~s({"type":"system","subtype":"init","session_id":"x","claude_code_version":"2.1.142"}),
        "not json at all",
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"still here"}]}}),
        ~s({"type":"result","subtype":"success","duration_ms":1,"result":"ok","total_cost_usd":0.0,"usage":{}})
      ]

      ctx = %{claude_code_source: {:lines, lines}}
      {:ok, stream} = ClaudeCode.start(default_task(), ctx)
      events = Enum.to_list(stream)

      assert Enum.any?(events, &match?(%Event.Error{recoverable: true}, &1))
      assert Enum.any?(events, &match?(%Event.AssistantText{text: "still here"}, &1))
      assert match?(%Event.Done{}, List.last(events))
    end
  end

  describe "event order (D-031)" do
    test "fixture emits Start → … → Done with no event after Done" do
      ctx = %{claude_code_source: {:fixture, @fix_tool_use}}
      {:ok, stream} = ClaudeCode.start(default_task(), ctx)
      events = Enum.to_list(stream)

      assert match?(%Event.Start{}, List.first(events))
      done_index = Enum.find_index(events, &match?(%Event.Done{}, &1))
      assert done_index == length(events) - 1
    end
  end

  describe "cancel via cancel_flag" do
    test "halts emission and surfaces a cancelled Error event" do
      flag = :counters.new(1, [])
      :counters.add(flag, 1, 1)

      lines = [
        ~s({"type":"system","subtype":"init","session_id":"x","claude_code_version":"2.1.142"}),
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}),
        ~s({"type":"result","subtype":"success","duration_ms":1,"result":"ok","total_cost_usd":0.0,"usage":{}})
      ]

      ctx = %{claude_code_source: {:lines, lines}, cancel_flag: flag}
      {:ok, stream} = ClaudeCode.start(default_task(), ctx)
      out = Enum.to_list(stream)

      assert [%Event.Error{reason: :cancelled, recoverable: false}] = out
    end
  end

  describe "CodingAgent.run/4 convenience" do
    test "drains the stream to {:ok, %{events, done}}" do
      ctx = %{claude_code_source: {:fixture, @fix_success}}

      {:ok, %{events: events, done: done}} =
        CodingAgent.run(ClaudeCode, default_task(), ctx)

      assert match?(%Event.Done{exit_status: 0}, done)
      assert Enum.any?(events, &match?(%Event.Start{}, &1))
    end

    test "surfaces synchronous {:error, _} from start/2 unchanged" do
      assert {:error, :workspace_missing} = CodingAgent.run(ClaudeCode, %{prompt: "p"}, %{})
    end

    test "in-stream non-recoverable error returns {:error, reason}" do
      ctx = %{claude_code_source: {:fixture, @fix_auth_error}}
      assert {:error, {:auth_failed, _}} = CodingAgent.run(ClaudeCode, default_task(), ctx)
    end
  end

  describe "argv builder" do
    alias Tau.CodingAgents.ClaudeCode.Argv

    test "minimal task → -p prompt --output-format stream-json --verbose" do
      argv = Argv.build(%{prompt: "hi", workspace: "/tmp"})
      assert argv == ["-p", "hi", "--output-format", "stream-json", "--verbose"]
    end

    test "resume_id appends --resume" do
      argv = Argv.build(%{prompt: "hi", workspace: "/tmp", resume_id: "abc"})
      assert Enum.slice(argv, -2, 2) == ["--resume", "abc"]
    end

    test "empty resume_id does not append --resume" do
      argv = Argv.build(%{prompt: "hi", workspace: "/tmp", resume_id: ""})
      refute "--resume" in argv
    end

    test "mcp_config_path opt appends --mcp-config" do
      argv = Argv.build(%{prompt: "hi", workspace: "/tmp"}, mcp_config_path: "/tmp/mcp.json")
      assert Enum.slice(argv, -2, 2) == ["--mcp-config", "/tmp/mcp.json"]
    end

    test "allowed_tools list joins with commas" do
      argv =
        Argv.build(%{prompt: "hi", workspace: "/tmp", allowed_tools: ["Read", "Edit", "Bash"]})

      assert Enum.slice(argv, -2, 2) == ["--allowed-tools", "Read,Edit,Bash"]
    end

    test "allowed_tools :all omits the flag" do
      argv = Argv.build(%{prompt: "hi", workspace: "/tmp", allowed_tools: :all})
      refute "--allowed-tools" in argv
    end
  end

  describe "external integration (opt-in via INTEGRATION=1)" do
    # Skipped by default via `test_helper.exs` exclude list. Run with:
    #   INTEGRATION=1 mix test --only external
    # Requires `claude` on PATH and a logged-in account
    # (`claude /login`).
    @tag :external
    test "spawns real `claude` and round-trips a one-turn prompt" do
      assert System.find_executable("claude"),
             "the :external test requires `claude` on PATH"

      task = %{prompt: "say hi", workspace: System.tmp_dir!()}
      {:ok, stream} = ClaudeCode.start(task, %{inactivity_timeout_ms: 60_000})
      events = Enum.to_list(stream)

      assert Enum.any?(events, &match?(%Event.Start{}, &1)),
             "expected at least one %Start{} event, got: #{inspect(events)}"

      assert match?(%Event.Done{}, List.last(events)),
             "expected last event to be %Done{}, got: #{inspect(List.last(events))}"

      # D-031: nothing follows the first %Done{}.
      done_index = Enum.find_index(events, &match?(%Event.Done{}, &1))
      assert done_index == length(events) - 1, "events after %Done{}: #{inspect(events)}"

      # BLOCKER-3 regression guard: stderr is no longer merged into the
      # JSON stream, so no banner-line parse errors should appear.
      refute Enum.any?(events, fn
               %Event.Error{recoverable: true, reason: {:parse_error, _}} -> true
               _ -> false
             end),
             "stderr leaked into the event stream as parse errors: #{inspect(events)}"
    end
  end

  # ── helpers ─────────────────────────────────────────────────────

  defp default_task do
    # Use a real, existing directory so D-033 validation passes.
    # The fixture (or :lines list) is what actually drives event
    # emission via the `:claude_code_source` ctx injection.
    %{prompt: "test prompt", workspace: System.tmp_dir!()}
  end
end
