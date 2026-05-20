defmodule Tau.Compactor.SummarizeTailTest do
  @moduledoc """
  Compactor must preserve system-role user messages (the memory cascade)
  across compaction so `TAU.md` survives long sessions.
  """
  use ExUnit.Case, async: true

  alias Tau.Compactor.SummarizeTail
  alias Tau.Message.{Assistant, ToolResult, User}
  alias Tau.Provider.Event

  defmodule StubProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_messages, _opts, _ctx) do
      {:ok,
       [%Event.TextDelta{block_id: "b", text: "summary text"}, %Event.Done{stop_reason: :stop}]}
    end

    @impl true
    def capabilities do
      %{thinking: false, tools: false, vision: false, prompt_caching: false, parallel_tools: false}
    end

    @impl true
    def default_model, do: "stub"
  end

  test "system-tagged messages survive compaction at the head of the list" do
    pinned =
      User.new("Always reply in haiku.",
        metadata: %{role: :system, source: :memory, path: "TAU.md"}
      )

    conv =
      for i <- 1..10 do
        if rem(i, 2) == 0 do
          Assistant.new(content: [%{type: :text, text: "assistant ##{i}"}])
        else
          User.new("user ##{i}")
        end
      end

    assert {:ok, compacted, summary_text} =
             SummarizeTail.compact([pinned | conv], %{provider: StubProvider})

    assert [^pinned, %User{content: "<conversation_summary>" <> _} = synth | tail] = compacted
    refute pinned in tail
    refute synth in tail

    # The third tuple element is the raw summary text (#57); the
    # synth message wraps it in <conversation_summary>...</conversation_summary>.
    assert is_binary(summary_text)
    assert summary_text != ""
    assert synth.content =~ summary_text

    # 60% of 10 = 6 oldest dropped; 4 newest preserved.
    assert length(tail) == 4
    assert List.last(tail).content == [%{type: :text, text: "assistant #10"}]
  end

  test "no system messages still produces a valid summary + recent split" do
    conv =
      for i <- 1..5 do
        User.new("turn #{i}")
      end

    assert {:ok, [%User{content: "<conversation_summary>" <> _} | recent], summary_text} =
             SummarizeTail.compact(conv, %{provider: StubProvider})

    assert is_binary(summary_text)
    refute Enum.any?(recent, &match?(%User{metadata: %{role: :system}}, &1))
  end

  test "compact/2 on an empty list returns {:ok, [], nil} without a synthetic summary" do
    assert {:ok, [], nil} = SummarizeTail.compact([], %{provider: StubProvider})
  end

  test "compact/2 on a list of only pinned system messages preserves them; summary nil" do
    pinned =
      User.new("Always reply in haiku.",
        metadata: %{role: :system, source: :memory, path: "TAU.md"}
      )

    skill =
      User.new("# Skill: foo\n\nbody",
        metadata: %{role: :system, source: :skill, name: "foo", path: "skill.md"}
      )

    assert {:ok, [^pinned, ^skill], nil} =
             SummarizeTail.compact([pinned, skill], %{provider: StubProvider})
  end

  test "should_compact?/2 on an empty list returns false regardless of usage" do
    refute SummarizeTail.should_compact?([], %{})
    refute SummarizeTail.should_compact?([], %{input_tokens: 1_000_000})
  end

  # D-062 / #310 — split boundary MUST NOT orphan tool_results
  #
  # Build a conversation whose pure 60%-length split lands between an
  # %Assistant{} with a tool_use block and the corresponding %ToolResult{}.
  # After compact/2 the preserved (recent) portion must:
  #   1. Not begin with a %ToolResult{}.
  #   2. For every %ToolResult{tool_call_id: id} in the recent portion, have
  #      a %Assistant{} in the recent portion whose content includes a block
  #      with type :tool_call and the matching id.
  test "split boundary is realigned to avoid orphan tool_results (D-062 / #310)" do
    # We need a conversation of N messages where ceil(0.6*N) falls mid tool-round.
    # Use 5 messages:
    #   0: user turn A
    #   1: assistant turn A (no tools)
    #   2: assistant turn B — carries a tool_use block
    #   3: tool_result for turn B  ← would be "recent[0]" at a 3/2 split
    #   4: user turn C
    #
    # 60% of 5 = 3 → Enum.split(conv, 3) puts messages 0..2 in old,
    # messages 3..4 in recent.  Without the fix, recent[0] is a ToolResult.

    tool_call_id = "call_abc123"

    assistant_with_tool =
      Assistant.new(
        content: [%{type: :tool_call, id: tool_call_id, name: "Bash", params: %{"cmd" => "ls"}}],
        stop_reason: :tool_use
      )

    tool_result =
      ToolResult.new(
        tool_call_id: tool_call_id,
        tool_name: "Bash",
        content: "file1\nfile2"
      )

    conv = [
      User.new("user turn A"),
      Assistant.new(content: [%{type: :text, text: "plain reply"}]),
      assistant_with_tool,
      tool_result,
      User.new("user turn C")
    ]

    # Sanity: pure 60% split WOULD put tool_result first in recent.
    cutoff = max(div(length(conv) * 6, 10), 1)
    assert cutoff == 3
    {_old_raw, [first_recent_raw | _]} = Enum.split(conv, cutoff)
    assert match?(%ToolResult{}, first_recent_raw)

    # After compact/2 the boundary must be repaired.
    assert {:ok, [%User{} = synth | recent], _summary} =
             SummarizeTail.compact(conv, %{provider: StubProvider})

    assert synth.content =~ "<conversation_summary>"

    # Assertion 1: recent does NOT start with a ToolResult.
    refute match?(%ToolResult{}, hd(recent)),
           "expected recent portion to not begin with a ToolResult, got: #{inspect(hd(recent))}"

    # Assertion 2: every ToolResult in recent has a matching Assistant in recent.
    tool_results_in_recent = Enum.filter(recent, &match?(%ToolResult{}, &1))

    for %ToolResult{tool_call_id: id} <- tool_results_in_recent do
      has_matching_assistant =
        Enum.any?(recent, fn
          %Assistant{content: blocks} ->
            Enum.any?(blocks, fn
              %{type: :tool_call, id: ^id} -> true
              _ -> false
            end)

          _ ->
            false
        end)

      assert has_matching_assistant,
             "no Assistant with tool_use id=#{id} found in recent: #{inspect(recent)}"
    end
  end

  test "split at an already-clean boundary is unaffected by realignment (D-062)" do
    # Build a conversation where the 60% cut lands cleanly between a ToolResult
    # and the next User message — realignment should be a no-op.
    #
    # 10 messages; 60% = 6:
    #   0: user A
    #   1: assistant A (tool_use)
    #   2: tool_result A
    #   3: user B
    #   4: assistant B (plain)
    #   5: user C          ← last of old
    #   6: assistant C (tool_use)
    #   7: tool_result C
    #   8: user D
    #   9: assistant D (plain)

    make_tool_round = fn id ->
      [
        Assistant.new(content: [%{type: :tool_call, id: id, name: "Read", params: %{}}]),
        ToolResult.new(tool_call_id: id, tool_name: "Read", content: "ok")
      ]
    end

    conv =
      [User.new("A")] ++
        make_tool_round.("id1") ++
        [User.new("B"), Assistant.new(content: [%{type: :text, text: "reply B"}]), User.new("C")] ++
        make_tool_round.("id2") ++
        [User.new("D"), Assistant.new(content: [%{type: :text, text: "reply D"}])]

    assert length(conv) == 10

    assert {:ok, [%User{} = synth | recent], _} =
             SummarizeTail.compact(conv, %{provider: StubProvider})

    assert synth.content =~ "<conversation_summary>"
    refute match?(%ToolResult{}, hd(recent))

    tool_results_in_recent = Enum.filter(recent, &match?(%ToolResult{}, &1))

    for %ToolResult{tool_call_id: id} <- tool_results_in_recent do
      assert Enum.any?(recent, fn
               %Assistant{content: blocks} ->
                 Enum.any?(blocks, &match?(%{type: :tool_call, id: ^id}, &1))

               _ ->
                 false
             end),
             "orphan tool_result id=#{id}"
    end
  end

  test "compaction_summary messages survive a subsequent compaction (ADR-0007)" do
    prior_summary =
      User.new(
        "<conversation_summary>\nrun 1 summary\n</conversation_summary>",
        metadata: %{role: :compaction_summary}
      )

    conv = for i <- 1..6, do: User.new("after-summary turn #{i}")

    assert {:ok, [^prior_summary, %User{content: "<conversation_summary>" <> _} = synth | _],
            summary_text} =
             SummarizeTail.compact([prior_summary | conv], %{provider: StubProvider})

    # synth is a NEW summary message — different content (it summarised
    # the post-prior-summary conv), but carrying the same
    # :compaction_summary marker so it'll also survive the next round.
    refute synth == prior_summary
    refute synth.content == prior_summary.content
    assert synth.metadata == %{role: :compaction_summary}
    assert is_binary(summary_text)
  end
end
