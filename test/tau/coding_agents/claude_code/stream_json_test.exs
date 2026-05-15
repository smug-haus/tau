defmodule Tau.CodingAgents.ClaudeCode.StreamJsonTest do
  @moduledoc """
  Unit tests for the stream-json line decoder.

  Covers D-031 (each known stream-json line maps to a normalised
  Event) and D-035 (malformed lines never raise; they emit a
  recoverable `%Event.Error{}`).
  """

  use ExUnit.Case, async: true

  alias Tau.CodingAgent.Event
  alias Tau.CodingAgents.ClaudeCode.StreamJson

  describe "system events" do
    test "system/init becomes %Start{agent: :claude_code, version: <claude_code_version>}" do
      line =
        ~s({"type":"system","subtype":"init","session_id":"s1","model":"claude-sonnet-4-6","claude_code_version":"2.1.142"})

      {[ev], state} = StreamJson.decode_line(line, StreamJson.new())

      assert %Event.Start{agent: :claude_code, version: "2.1.142"} = ev
      assert state.last_session_id == "s1"
    end

    test "system/hook_* subtypes are silently ignored" do
      line = ~s({"type":"system","subtype":"hook_started","hook_id":"x"})
      assert {[], _state} = StreamJson.decode_line(line, StreamJson.new())
    end

    test "rate_limit_event is silently ignored" do
      line = ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}})
      assert {[], _state} = StreamJson.decode_line(line, StreamJson.new())
    end
  end

  describe "assistant content" do
    test "text block becomes %AssistantText{} with incrementing turn" do
      l1 =
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}})

      l2 =
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"world"}]}})

      {[%Event.AssistantText{text: "hello", turn: 0}], s1} =
        StreamJson.decode_line(l1, StreamJson.new())

      {[%Event.AssistantText{text: "world", turn: 1}], _s2} = StreamJson.decode_line(l2, s1)
    end

    test "tool_use block becomes %ToolUse{}" do
      line =
        ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01","name":"Read","input":{"path":"a.md"}}]}})

      {[ev], _state} = StreamJson.decode_line(line, StreamJson.new())

      assert %Event.ToolUse{id: "toolu_01", name: "Read", input: %{"path" => "a.md"}} = ev
    end

    test "mixed text + tool_use blocks in one line yield both events in order" do
      line =
        ~s({"type":"assistant","message":{"content":[) <>
          ~s({"type":"text","text":"reading"},) <>
          ~s({"type":"tool_use","id":"t1","name":"Read","input":{}}) <>
          ~s(]}})

      {events, _state} = StreamJson.decode_line(line, StreamJson.new())

      assert [%Event.AssistantText{text: "reading"}, %Event.ToolUse{id: "t1"}] = events
    end

    test "unknown assistant content block is dropped" do
      line =
        ~s({"type":"assistant","message":{"content":[{"type":"future_block","stuff":1}]}})

      assert {[], _state} = StreamJson.decode_line(line, StreamJson.new())
    end
  end

  describe "user / tool_result" do
    test "tool_result with string content" do
      line =
        ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok","is_error":false}]}})

      {[ev], _} = StreamJson.decode_line(line, StreamJson.new())

      assert %Event.ToolResult{tool_use_id: "t1", content: "ok", is_error: false} = ev
    end

    test "tool_result with structured content list is flattened to text" do
      line =
        ~s({"type":"user","message":{"content":[) <>
          ~s({"type":"tool_result","tool_use_id":"t1","content":[) <>
          ~s({"type":"text","text":"line 1"},{"type":"text","text":"line 2"}) <>
          ~s(],"is_error":false}]}})

      {[ev], _} = StreamJson.decode_line(line, StreamJson.new())

      assert ev.content == "line 1\nline 2"
    end

    test "tool_result with is_error: true is surfaced" do
      line =
        ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"boom","is_error":true}]}})

      {[ev], _} = StreamJson.decode_line(line, StreamJson.new())
      assert ev.is_error == true
    end
  end

  describe "result events" do
    test "result/success emits %Cost{} then %Done{exit_status: 0}" do
      line =
        ~s({"type":"result","subtype":"success","duration_ms":1500,"result":"Done.","total_cost_usd":0.005,"usage":{"input_tokens":50,"output_tokens":20},"session_id":"s1"})

      {events, _} = StreamJson.decode_line(line, StreamJson.new())

      assert [
               %Event.Cost{
                 tokens: %{"input_tokens" => 50, "output_tokens" => 20},
                 usd: 0.005,
                 duration_ms: 1500
               },
               %Event.Done{exit_status: 0, final_message: "Done."}
             ] = events
    end

    test "result/error_max_turns produces non-recoverable %Error{}" do
      line =
        ~s({"type":"result","subtype":"error_max_turns","is_error":true,"result":"max turns reached","session_id":"s2"})

      {[ev], _} = StreamJson.decode_line(line, StreamJson.new())

      assert %Event.Error{recoverable: false} = ev
      assert match?({:error_max_turns, _}, ev.reason)
    end

    test "result/error_during_execution with auth wording tags :auth_failed" do
      line =
        ~s({"type":"result","subtype":"error_during_execution","is_error":true,"result":"Please run `/login` first.","session_id":"s3"})

      {[ev], _} = StreamJson.decode_line(line, StreamJson.new())

      assert %Event.Error{recoverable: false, reason: {:auth_failed, _msg}} = ev
    end
  end

  describe "malformed input (D-035 — never raise)" do
    test "invalid JSON yields a recoverable parse_error event" do
      {[ev], _} = StreamJson.decode_line("not json\n", StreamJson.new())
      assert %Event.Error{recoverable: true, reason: {:parse_error, _}} = ev
    end

    test "JSON array (non-object) yields a recoverable malformed_event" do
      {[ev], _} = StreamJson.decode_line(~s([1,2,3]), StreamJson.new())
      assert %Event.Error{recoverable: true, reason: {:malformed_event, _}} = ev
    end

    test "object without a type field yields a recoverable malformed_event" do
      {[ev], _} = StreamJson.decode_line(~s({"no":"type"}), StreamJson.new())
      assert %Event.Error{recoverable: true, reason: {:malformed_event, _}} = ev
    end

    test "empty line yields no events" do
      assert {[], _} = StreamJson.decode_line("", StreamJson.new())
      assert {[], _} = StreamJson.decode_line("\n", StreamJson.new())
    end

    test "unknown top-level type is silently dropped" do
      assert {[], _} = StreamJson.decode_line(~s({"type":"future_thing"}), StreamJson.new())
    end
  end

  describe "classify_failure/2 (AC-6)" do
    test "exit 127 → :not_found" do
      assert {:not_found, _} = StreamJson.classify_failure(127, "")
    end

    test "login wording → :auth_failed" do
      assert {:auth_failed, _} = StreamJson.classify_failure(1, "Please run /login")
    end

    test "non-zero with no recognised wording → :nonzero_exit" do
      assert {:nonzero_exit, _} = StreamJson.classify_failure(2, "boom")
    end

    test "zero exit with unknown text → :unknown" do
      assert {:unknown, _} = StreamJson.classify_failure(0, "huh")
    end
  end
end
