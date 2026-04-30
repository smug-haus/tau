defmodule Tau.Compactor.SummarizeTailTest do
  @moduledoc """
  Compactor must preserve system-role user messages (the memory cascade)
  across compaction so `TAU.md` survives long sessions.
  """
  use ExUnit.Case, async: true

  alias Tau.Compactor.SummarizeTail
  alias Tau.Message.{Assistant, User}
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

    refute synth == prior_summary
    refute synth.metadata == prior_summary.metadata
    assert is_binary(summary_text)
  end
end
