defmodule Tau.Providers.AnthropicCachePolicyTest do
  @moduledoc """
  SPEC-PROMPT-CACHING D-063 / D-064 / D-065 + AC-1 / AC-3 / AC-5.

  Exercises the request-side prompt-caching machinery of
  `Tau.Providers.Anthropic` directly — `cache_regions/2`,
  `build_body/3` marker injection, `OrderingCheck.validate!/1`, and
  `merge_usage/2` usage normalisation — without driving a network
  stream. AC-2 (the response-side B3 round-trip through a real
  decode path) lives in `anthropic_cache_cassette_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Tau.Message.{Assistant, ToolResult, User}
  alias Tau.Providers.Anthropic
  alias Tau.Providers.Shared.OrderingCheck

  # --- fixture builders ------------------------------------------------------

  defp sys(text), do: User.new(text, metadata: %{role: :system})
  defp user(text), do: User.new(text)

  defp assistant(text) do
    Assistant.new(content: [%{type: :text, text: text}], stop_reason: :stop)
  end

  defp tool_result(id, text) do
    ToolResult.new(tool_call_id: id, tool_name: "t", content: text)
  end

  defp compaction(text), do: User.new(text, metadata: %{role: :compaction_summary})

  defp tool(name) do
    %{name: name, description: "desc-#{name}", parameters: %{"type" => "object"}}
  end

  # Count cache_control markers anywhere in the assembled body.
  defp marker_count(body) do
    sys_n = count_in(body[:system])
    tools_n = count_in(body[:tools])
    msg_n = body.messages |> Enum.map(& &1[:content]) |> Enum.map(&count_in/1) |> Enum.sum()
    sys_n + tools_n + msg_n
  end

  defp count_in(nil), do: 0
  defp count_in(s) when is_binary(s), do: 0

  defp count_in(list) when is_list(list) do
    Enum.count(list, fn
      %{cache_control: %{type: "ephemeral"}} -> true
      _ -> false
    end)
  end

  defp count_in(_), do: 0

  # --- D-063 — cache region policy switch ------------------------------------

  describe "D-063 cache_regions/2 policy switch" do
    test "returns :explicit for a non-empty session" do
      assert Anthropic.cache_regions([user("hi")], %{}) == :explicit
    end

    test "returns :none when opts[:caching] == false" do
      assert Anthropic.cache_regions([user("hi")], %{caching: false}) == :none
    end

    test "returns :none for an empty session" do
      assert Anthropic.cache_regions([], %{}) == :none
    end

    test ":none skips all marker injection in build_body/3" do
      {sys_blocks, rest} = split([sys("S"), user("u1"), assistant("a1"), user("u2")])
      body = Anthropic.build_body(sys_blocks, rest, %{caching: false, tools: [tool("a")]})
      assert marker_count(body) == 0
    end

    test ":explicit injects markers in build_body/3" do
      {sys_blocks, rest} = split([sys("S"), user("u1"), assistant("a1"), user("u2")])
      body = Anthropic.build_body(sys_blocks, rest, %{tools: [tool("a")]})
      assert marker_count(body) > 0
    end
  end

  # --- D-064 / AC-1 — marker placement ---------------------------------------

  describe "D-064 / AC-1 marker placement" do
    test "case 1: full conversation places A on last system block, B on last tool, C on compaction summary" do
      messages = [
        sys("system one"),
        sys("system two"),
        user("old user"),
        assistant("old assistant"),
        compaction("compaction summary"),
        user("fresh input")
      ]

      {sys_blocks, rest} = split(messages)
      body = Anthropic.build_body(sys_blocks, rest, %{tools: [tool("a"), tool("b")]})

      # Marker A — last system text block.
      assert List.last(body[:system])[:cache_control] == %{type: "ephemeral"}
      refute hd(body[:system])[:cache_control]

      # Marker B — last tool spec.
      assert List.last(body[:tools])[:cache_control] == %{type: "ephemeral"}
      refute hd(body[:tools])[:cache_control]

      # Marker C — last content block of the compaction-summary message.
      summary_wire =
        Enum.find(body.messages, &(&1[:content] |> wire_text() == "compaction summary"))

      assert summary_wire
      assert summary_wire.content |> List.last() |> Map.get(:cache_control) == %{type: "ephemeral"}

      # Fresh input is NOT marked.
      fresh = List.last(body.messages)
      assert count_in(fresh[:content]) == 0

      assert marker_count(body) == 3
    end

    test "case 2: first turn with only a user input places A,B and skips C" do
      {sys_blocks, rest} = split([sys("S"), user("only input")])
      body = Anthropic.build_body(sys_blocks, rest, %{tools: [tool("a")]})

      assert count_in(body[:system]) == 1
      assert count_in(body[:tools]) == 1
      # No stable boundary -> marker C skipped.
      assert body.messages |> Enum.map(& &1[:content]) |> Enum.map(&count_in/1) |> Enum.sum() == 0
      assert marker_count(body) == 2
    end

    test "case 3: empty system + empty tools skips A,B and places C" do
      messages = [user("u1"), assistant("a1"), user("u2")]
      {sys_blocks, rest} = split(messages)
      body = Anthropic.build_body(sys_blocks, rest, %{})

      assert is_nil(body[:system])
      assert is_nil(body[:tools])
      # Marker C lands on the assistant message (second-to-last stable boundary).
      assert marker_count(body) == 1
    end

    test "post-compaction: marker C goes to the compaction summary, not a later assistant" do
      messages = [
        user("u1"),
        assistant("a1"),
        compaction("the summary"),
        assistant("a2"),
        user("fresh")
      ]

      {sys_blocks, rest} = split(messages)
      body = Anthropic.build_body(sys_blocks, rest, %{})

      summary_wire = Enum.find(body.messages, &(wire_text(&1[:content]) == "the summary"))
      assert summary_wire.content |> List.last() |> Map.get(:cache_control) == %{type: "ephemeral"}
      assert marker_count(body) == 1
    end

    test "multi-summary: latest-list-position compaction summary wins (D-064 tiebreaker)" do
      messages = [
        compaction("older summary"),
        user("u1"),
        assistant("a1"),
        compaction("newer summary"),
        user("fresh")
      ]

      {sys_blocks, rest} = split(messages)
      body = Anthropic.build_body(sys_blocks, rest, %{})

      newer = Enum.find(body.messages, &(wire_text(&1[:content]) == "newer summary"))
      older = Enum.find(body.messages, &(wire_text(&1[:content]) == "older summary"))

      assert newer.content |> List.last() |> Map.get(:cache_control) == %{type: "ephemeral"}
      assert count_in(older[:content]) == 0
      assert marker_count(body) == 1
    end

    test "tool-loop: marker C goes to the second-to-last assistant/tool-result message" do
      # A tool loop in progress: the freshest input is a tool_result;
      # build_body is called to request the next assistant turn.
      messages = [
        user("u1"),
        assistant("a1"),
        assistant("a2-with-toolcall"),
        tool_result("call-1", "tool output")
      ]

      {sys_blocks, rest} = split(messages)
      body = Anthropic.build_body(sys_blocks, rest, %{})

      # assistant/tool-result candidates: a1, a2, tool_result. The
      # tool_result is the freshest input; marker C lands on the
      # second-to-last candidate — a2.
      a2_wire = Enum.find(body.messages, &(wire_text(&1[:content]) == "a2-with-toolcall"))
      assert a2_wire.content |> List.last() |> Map.get(:cache_control) == %{type: "ephemeral"}

      # The fresh tool_result is NOT marked.
      tr_wire = Enum.find(body.messages, &(wire_text(&1[:content]) == "tool output"))
      assert count_in(tr_wire[:content]) == 0
      assert marker_count(body) == 1
    end

    test "empty system block-array is skipped (marker A absent)" do
      {sys_blocks, rest} = split([user("u1"), assistant("a1"), user("u2")])
      assert is_nil(sys_blocks)
      body = Anthropic.build_body(sys_blocks, rest, %{tools: [tool("a")]})
      assert count_in(body[:system]) == 0
    end
  end

  # --- D-064 — pure function / determinism -----------------------------------

  describe "D-064 marker derivation is a pure function" do
    test "byte-identical body for the same input across two invocations 1.5s apart" do
      messages = [
        sys("S"),
        user("u1"),
        assistant("a1"),
        compaction("summary"),
        user("fresh")
      ]

      {sys_blocks, rest} = split(messages)
      opts = %{tools: [tool("a"), tool("b")], model: "claude-opus-4-7"}

      body_a = Anthropic.build_body(sys_blocks, rest, opts)
      Process.sleep(1500)
      body_b = Anthropic.build_body(sys_blocks, rest, opts)

      assert Jason.encode!(body_a) == Jason.encode!(body_b)
    end

    test "two-turn stability: prefix up to and including marker C is byte-identical" do
      base = [
        sys("S"),
        user("u1"),
        assistant("a1"),
        compaction("summary"),
        user("turn-N input")
      ]

      turn_n1 =
        base ++ [assistant("a2"), user("turn-N+1 input")]

      {sys_n, rest_n} = split(base)
      {sys_n1, rest_n1} = split(turn_n1)
      opts = %{tools: [tool("a")]}

      body_n = Anthropic.build_body(sys_n, rest_n, opts)
      body_n1 = Anthropic.build_body(sys_n1, rest_n1, opts)

      # System and tools are stable across turns.
      assert body_n[:system] == body_n1[:system]
      assert body_n[:tools] == body_n1[:tools]

      # The compaction-summary message (marker C) is byte-identical, and
      # so is everything before it.
      idx_n = Enum.find_index(body_n.messages, &(wire_text(&1[:content]) == "summary"))
      idx_n1 = Enum.find_index(body_n1.messages, &(wire_text(&1[:content]) == "summary"))

      prefix_n = Enum.take(body_n.messages, idx_n + 1)
      prefix_n1 = Enum.take(body_n1.messages, idx_n1 + 1)
      assert prefix_n == prefix_n1
    end
  end

  # --- AC-5 — 4-breakpoint cap regression guard ------------------------------

  describe "AC-5 marker cap" do
    test "a shape with 5+ candidate positions still emits exactly 3 markers" do
      messages = [
        sys("s1"),
        sys("s2"),
        sys("s3"),
        user("u1"),
        compaction("summary one"),
        assistant("a1"),
        tool_result("c1", "tr1"),
        compaction("summary two"),
        assistant("a2"),
        tool_result("c2", "tr2"),
        assistant("a3"),
        user("fresh input")
      ]

      {sys_blocks, rest} = split(messages)

      tools = Enum.map(["t1", "t2", "t3", "t4", "t5"], &tool/1)
      body = Anthropic.build_body(sys_blocks, rest, %{tools: tools})

      assert marker_count(body) == 3, "expected exactly 3 markers, got #{marker_count(body)}"

      # Marker C lands on the LATEST compaction summary (D-064 tiebreaker).
      newer = Enum.find(body.messages, &(wire_text(&1[:content]) == "summary two"))
      assert newer.content |> List.last() |> Map.get(:cache_control) == %{type: "ephemeral"}
    end
  end

  # --- AC-3 — canonical ordering enforced ------------------------------------

  describe "AC-3 OrderingCheck.validate!/1" do
    test "build_body/3 produces an ordering-compliant body" do
      {sys_blocks, rest} = split([sys("S"), user("u1"), assistant("a1"), user("u2")])
      body = Anthropic.build_body(sys_blocks, rest, %{tools: [tool("a")]})

      assert OrderingCheck.validate!(%{
               system: body[:system],
               tools: body[:tools],
               messages: body.messages
             }) == :ok
    end

    test "an ordering-compliant body (user input last) returns :ok" do
      body = %{
        system: [%{type: "text", text: "S"}],
        tools: [%{name: "t"}],
        messages: [
          %{role: "assistant", content: "a"},
          %{role: "user", content: "fresh"}
        ]
      }

      assert OrderingCheck.validate!(body) == :ok
    end

    test "a violation (non-user message after the last user message) raises" do
      body = %{
        system: nil,
        tools: nil,
        messages: [
          %{role: "user", content: "fresh"},
          %{role: "assistant", content: "trailing"}
        ]
      }

      assert_raise ArgumentError, fn -> OrderingCheck.validate!(body) end
    end

    test "missing :system / :tools / :messages keys raise" do
      assert_raise ArgumentError, fn -> OrderingCheck.validate!(%{messages: []}) end
      assert_raise ArgumentError, fn -> OrderingCheck.validate!(%{system: nil, tools: nil}) end
    end

    test "ill-typed fields raise" do
      assert_raise ArgumentError, fn ->
        OrderingCheck.validate!(%{system: 42, tools: nil, messages: []})
      end

      assert_raise ArgumentError, fn ->
        OrderingCheck.validate!(%{system: nil, tools: "nope", messages: []})
      end

      assert_raise ArgumentError, fn ->
        OrderingCheck.validate!(%{system: nil, tools: nil, messages: "nope"})
      end
    end

    @tag :property
    test "property: a user-last messages list always validates, a trailing non-user always raises" do
      for n <- 0..6 do
        history =
          Enum.map(0..n, fn i ->
            %{role: Enum.random(["assistant", "user"]), content: "m#{i}"}
          end)

        compliant = %{
          system: nil,
          tools: nil,
          messages: history ++ [%{role: "user", content: "fresh"}]
        }

        assert OrderingCheck.validate!(compliant) == :ok

        violating = %{
          system: nil,
          tools: nil,
          messages:
            history ++ [%{role: "user", content: "fresh"}, %{role: "assistant", content: "x"}]
        }

        assert_raise ArgumentError, fn -> OrderingCheck.validate!(violating) end
      end
    end
  end

  # --- D-065 — usage normalisation -------------------------------------------

  describe "D-065 merge_usage/2 canonical key normalisation" do
    test "(a) no cache activity -> cache_read: 0, cache_write: 0" do
      start_u = %{"input_tokens" => 100}
      delta_u = %{"output_tokens" => 50}
      usage = Anthropic.merge_usage(start_u, delta_u)

      assert usage.input_tokens == 100
      assert usage.output_tokens == 50
      assert usage.cache_read == 0
      assert usage.cache_write == 0
      assert usage.cache_breakdown == %{}
    end

    test "(b) write-only 5m -> cache_write > 0, cache_read: 0" do
      start_u = %{
        "input_tokens" => 10,
        "cache_creation_input_tokens" => 2048,
        "cache_read_input_tokens" => 0,
        "cache_creation" => %{
          "ephemeral_5m_input_tokens" => 2048,
          "ephemeral_1h_input_tokens" => 0
        }
      }

      usage = Anthropic.merge_usage(start_u, %{"output_tokens" => 5})

      assert usage.cache_write == 2048
      assert usage.cache_read == 0
      assert usage.cache_breakdown.ephemeral_5m == 2048
    end

    test "(c) mixed write+read -> both > 0, breakdown 5m > 0" do
      start_u = %{
        "input_tokens" => 30,
        "cache_creation_input_tokens" => 512,
        "cache_read_input_tokens" => 4096,
        "cache_creation" => %{
          "ephemeral_5m_input_tokens" => 512,
          "ephemeral_1h_input_tokens" => 0
        }
      }

      usage = Anthropic.merge_usage(start_u, %{"output_tokens" => 12})

      assert usage.cache_write == 512
      assert usage.cache_read == 4096
      assert usage.cache_breakdown.ephemeral_5m == 512
    end

    test "(d) server-promoted 1h -> ephemeral_1h in breakdown AND summed into cache_write" do
      # `cache_creation_input_tokens` is Anthropic's total of both tiers.
      start_u = %{
        "input_tokens" => 20,
        "cache_creation_input_tokens" => 3000,
        "cache_read_input_tokens" => 0,
        "cache_creation" => %{
          "ephemeral_5m_input_tokens" => 1000,
          "ephemeral_1h_input_tokens" => 2000
        }
      }

      usage = Anthropic.merge_usage(start_u, %{"output_tokens" => 7})

      assert usage.cache_breakdown.ephemeral_1h == 2000
      assert usage.cache_breakdown.ephemeral_5m == 1000
      # The 1h tokens are already inside the cache_write total.
      assert usage.cache_write == 3000
    end

    test "emits no Anthropic-wire key names" do
      usage = Anthropic.merge_usage(%{"input_tokens" => 1}, %{"output_tokens" => 1})
      refute Map.has_key?(usage, :cache_creation_input_tokens)
      refute Map.has_key?(usage, :cache_read_input_tokens)
      assert Map.has_key?(usage, :cache_read)
      assert Map.has_key?(usage, :cache_write)
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Mirror of Anthropic.split_system/1, which is private. Splits a
  # message list into the system block-array and the rest.
  defp split(messages) do
    {sys, rest} =
      Enum.split_with(messages, fn
        %User{metadata: %{role: :system}} -> true
        _ -> false
      end)

    blocks =
      sys
      |> Enum.map(fn %User{content: c} -> if is_binary(c), do: c, else: "" end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&%{type: "text", text: &1})

    case blocks do
      [] -> {nil, rest}
      list -> {list, rest}
    end
  end

  # Extract the joined text of a wire message's content (string or
  # block-array) for fixture lookup.
  defp wire_text(content) when is_binary(content), do: content

  defp wire_text(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "", fn
      %{type: "text", text: t} -> t
      %{type: "tool_result", content: c} when is_binary(c) -> c
      _ -> ""
    end)
  end

  defp wire_text(_), do: ""
end
