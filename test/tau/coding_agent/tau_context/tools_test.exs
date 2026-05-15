defmodule Tau.CodingAgent.TauContext.ToolsTest do
  @moduledoc """
  Exercises each of the four tau-side tools.

  Goals:

    * `catalog/0` returns 4 tool entries with valid JSON-Schema
      input.
    * `tau_session_status` gracefully reports `available: false`
      when no session id is bound, and structured success when
      a real session is available.
    * `tau_memory_query` returns `available: true` against this
      repo's TAU.md cascade, and gracefully degrades when given
      a directory with no memory files.
    * `tau_memory_write` returns `available: false` (no
      writable layer in tau today).
    * `tau_delegate` enforces max_depth and rejects empty
      prompt.

  D-035: every public function returns a tagged tuple; no test
  expects a raise.
  """

  # `async: false` because the live-session test (`returns structured success
  # when a real session is reachable`) uses the real Sessions supervisor +
  # Persistence layer, both of which read shared Application env. The pure
  # tool tests are unaffected; concurrency here was never load-bearing.
  use ExUnit.Case, async: false

  alias Tau.CodingAgent.TauContext.Tools

  defp decode!(json), do: Jason.decode!(json)

  describe "catalog/0" do
    test "returns exactly the 4 expected tools" do
      catalog = Tools.catalog()
      assert length(catalog) == 4

      names = Enum.map(catalog, & &1["name"])

      assert "tau_session_status" in names
      assert "tau_memory_query" in names
      assert "tau_memory_write" in names
      assert "tau_delegate" in names
    end

    test "each tool has a description and an inputSchema object" do
      for tool <- Tools.catalog() do
        assert is_binary(tool["description"])
        assert byte_size(tool["description"]) > 10
        assert is_map(tool["inputSchema"])
        assert tool["inputSchema"]["type"] == "object"
      end
    end
  end

  describe "call/3 — tau_session_status" do
    test "available: false when no session id is bound" do
      state = %{session_id: nil, cwd: nil, max_depth: 2}
      assert {:ok, json} = Tools.call("tau_session_status", %{}, state)
      decoded = decode!(json)
      assert decoded["available"] == false
      assert is_binary(decoded["reason"])
    end

    test "available: false (not_found) when session id has no live process" do
      state = %{session_id: "does-not-exist-xyz", cwd: nil, max_depth: 2}
      assert {:ok, json} = Tools.call("tau_session_status", %{}, state)
      decoded = decode!(json)
      assert decoded["available"] == false
      assert decoded["session_id"] == "does-not-exist-xyz"
    end

    test "returns structured success when a real session is reachable" do
      session_id = start_real_session!()
      state = %{session_id: session_id, cwd: System.tmp_dir!(), max_depth: 2}

      assert {:ok, json} = Tools.call("tau_session_status", %{}, state)
      decoded = decode!(json)
      assert decoded["available"] == true
      assert decoded["session_id"] == session_id
      assert is_binary(decoded["state"])
      assert is_integer(decoded["message_count"])
    end
  end

  describe "call/3 — tau_memory_query" do
    test "available: true (empty results OK) against an empty cwd" do
      empty = Path.join(System.tmp_dir!(), "tau-mem-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)

      state = %{session_id: nil, cwd: empty, max_depth: 2}

      assert {:ok, json} = Tools.call("tau_memory_query", %{"query" => "anything"}, state)
      decoded = decode!(json)
      # Loader still returns ~/.tau/TAU.md if present so we don't
      # require an empty results list; just confirm structure.
      assert decoded["available"] == true
      assert decoded["query"] == "anything"
      assert is_list(decoded["results"])

      File.rm_rf!(empty)
    end

    test "missing 'query' arg returns a JSON-RPC -32602 error" do
      state = %{session_id: nil, cwd: nil, max_depth: 2}
      assert {:error, %{code: -32_602}} = Tools.call("tau_memory_query", %{}, state)
    end
  end

  describe "call/3 — tau_memory_write" do
    test "always returns available: false (no writable layer)" do
      state = %{session_id: nil, cwd: nil, max_depth: 2}

      assert {:ok, json} =
               Tools.call(
                 "tau_memory_write",
                 %{"kind" => "note", "key" => "k", "body" => "hello"},
                 state
               )

      decoded = decode!(json)
      assert decoded["available"] == false
      assert decoded["kind"] == "note"
      assert decoded["key"] == "k"
      assert decoded["body_size"] == 5
    end

    test "missing args returns -32602" do
      state = %{session_id: nil, cwd: nil, max_depth: 2}
      assert {:error, %{code: -32_602}} = Tools.call("tau_memory_write", %{}, state)
    end
  end

  describe "call/3 — tau_delegate" do
    test "empty prompt is rejected with -32602" do
      state = %{session_id: nil, cwd: nil, max_depth: 2}
      assert {:error, %{code: -32_602}} = Tools.call("tau_delegate", %{"prompt" => ""}, state)
    end

    test "max_depth reached returns available: false, depth recorded" do
      state = %{session_id: nil, cwd: nil, max_depth: 2}

      assert {:ok, json} =
               Tools.call("tau_delegate", %{"prompt" => "go", "depth" => 2}, state)

      decoded = decode!(json)
      assert decoded["available"] == false
      assert decoded["reason"] =~ "max delegation depth"
      assert decoded["depth"] == 2
      assert decoded["max_depth"] == 2
    end

    test "under-depth returns available: false with would_delegate" do
      # available: false because the underlying delegation queue
      # isn't wired in Phase 1B Team C — but the SHAPE confirms
      # the agent gets a structured plan rather than a hard error.
      state = %{session_id: nil, cwd: nil, max_depth: 2}

      assert {:ok, json} =
               Tools.call(
                 "tau_delegate",
                 %{"prompt" => "do thing", "agent" => "claude_code", "depth" => 0},
                 state
               )

      decoded = decode!(json)
      assert decoded["available"] == false
      assert decoded["would_delegate"]["agent"] == "claude_code"
      assert decoded["would_delegate"]["depth"] == 1
    end

    test "non-integer depth coerces to default" do
      state = %{session_id: nil, cwd: nil, max_depth: 2}

      assert {:ok, json} =
               Tools.call("tau_delegate", %{"prompt" => "x", "depth" => "bad"}, state)

      decoded = decode!(json)
      # 0 < 2 so it proceeds to would_delegate.
      assert decoded["would_delegate"]["depth"] == 1
    end
  end

  describe "call/3 — unknown tool" do
    test "returns -32601 method-not-found" do
      state = %{session_id: nil, cwd: nil, max_depth: 2}
      assert {:error, %{code: -32_601}} = Tools.call("tau_does_not_exist", %{}, state)
    end
  end

  # ── helpers ───────────────────────────────────────────────────

  defp start_real_session! do
    {:ok, id} =
      Tau.Test.SessionHelper.start_session_for_test(
        provider: Tau.Providers.Replay,
        cwd: System.tmp_dir!()
      )

    id
  end
end
