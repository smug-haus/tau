defmodule Tau.Test.MultiFixtureProvider do
  @moduledoc """
  Test-only provider that serves different event streams to the parent
  session vs child (sub-agent) sessions, keyed by `ctx.session_id`.

  ## Context keys

    * `:parent_session_id` — the parent session's id. Events for the
      parent are selected based on this plus message-history inspection.
    * `:parent_first_fixture` — events returned on the parent's FIRST
      provider call (no `ToolResult` in history yet).
    * `:parent_second_fixture` — events returned on the parent's SECOND
      provider call (at least one `ToolResult` is present in history).
    * `:child_fixture` — events returned for ANY session whose id does
      not match `:parent_session_id` (i.e. child / grandchild sessions).
    * `:replay_delay_ms` — optional ms sleep between events (for cancel
      timing tests). Applied only when streaming the `:child_fixture`.

  All keys are optional; missing fixtures fall back to a minimal
  `end_turn` response so tests don't wedge.
  """

  @behaviour Tau.Provider

  alias Tau.Provider.Event

  @impl Tau.Provider
  def default_model, do: "multi-fixture"

  @impl Tau.Provider
  def capabilities,
    do: %{thinking: false, tools: true, vision: false, prompt_caching: false, parallel_tools: true}

  @impl Tau.Provider
  def stream(messages, _opts, ctx) do
    parent_sid = ctx[:parent_session_id]
    this_sid = ctx[:session_id]
    delay_ms = ctx[:replay_delay_ms] || 0

    has_tool_result? = Enum.any?(messages, &match?(%Tau.Message.ToolResult{}, &1))

    {events, apply_delay?} =
      cond do
        this_sid == parent_sid and has_tool_result? ->
          {ctx[:parent_second_fixture] || default_end_turn(), false}

        this_sid == parent_sid ->
          {ctx[:parent_first_fixture] || default_end_turn(), false}

        true ->
          {ctx[:child_fixture] || default_child_text(), true}
      end

    stream =
      if apply_delay? and delay_ms > 0 do
        Stream.map(events, fn ev ->
          Process.sleep(delay_ms)
          ev
        end)
      else
        events
      end

    {:ok, stream}
  end

  # Minimal valid end-turn response.
  defp default_end_turn do
    [
      %Event.Start{request_id: "mfp-end", model: "multi-fixture"},
      %Event.TextStart{block_id: "b0"},
      %Event.TextDelta{block_id: "b0", text: "(parent done)"},
      %Event.TextEnd{block_id: "b0"},
      %Event.Done{stop_reason: :end_turn, usage: %{}}
    ]
  end

  defp default_child_text do
    [
      %Event.Start{request_id: "mfp-child", model: "multi-fixture"},
      %Event.TextStart{block_id: "b0"},
      %Event.TextDelta{block_id: "b0", text: "(child result)"},
      %Event.TextEnd{block_id: "b0"},
      %Event.Done{stop_reason: :end_turn, usage: %{}}
    ]
  end
end
