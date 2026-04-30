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

    assert {:ok, compacted} = SummarizeTail.compact([pinned | conv], %{provider: StubProvider})

    assert [^pinned, %User{content: "<conversation_summary>" <> _} = synth | tail] = compacted
    refute pinned in tail
    refute synth in tail

    # 60% of 10 = 6 oldest dropped; 4 newest preserved.
    assert length(tail) == 4
    assert List.last(tail).content == [%{type: :text, text: "assistant #10"}]
  end

  test "no system messages still produces a valid summary + recent split" do
    conv =
      for i <- 1..5 do
        User.new("turn #{i}")
      end

    assert {:ok, [%User{content: "<conversation_summary>" <> _} | recent]} =
             SummarizeTail.compact(conv, %{provider: StubProvider})

    refute Enum.any?(recent, &match?(%User{metadata: %{role: :system}}, &1))
  end
end
