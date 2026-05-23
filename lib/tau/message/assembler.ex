defmodule Tau.Message.Assembler do
  @moduledoc """
  Pure folding of `Tau.Provider.Event` streams into `Tau.Message.Assistant`.

  Holds a small accumulator: the partially-built message, plus per-block
  staging state for in-progress text/thinking/tool_call blocks. `step/2`
  takes the current state and the next event, returns the new state and
  any `{:emit, side_effect_event}` notes the FSM should broadcast on
  PubSub.

  This is the only place that reasons about block ordering / interleaving;
  the FSM and TUI just consume the resulting `%Assistant{}`.
  """

  alias Tau.Message.Assistant
  alias Tau.Provider.Event

  defstruct message: nil, blocks: %{}, order: [], started?: false, done?: false, error: nil

  @typedoc "Assembler state: in-progress `%Assistant{}`, per-block staging, and any error from the upstream stream."
  @type t :: %__MODULE__{
          message: Assistant.t() | nil,
          blocks: map(),
          order: [String.t()],
          started?: boolean(),
          done?: boolean(),
          error: term() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      message:
        Assistant.new(
          content: [],
          provider: opts[:provider],
          model: opts[:model],
          api: opts[:api]
        )
    }
  end

  @doc """
  Step the assembler with one event. Returns the new state.
  """
  @spec step(t(), Event.t()) :: t()
  def step(state, %Event.Start{model: model, request_id: rid}) do
    msg = state.message

    %{
      state
      | message: %{msg | model: model || msg.model, response_id: rid},
        started?: true
    }
  end

  def step(state, %Event.TextStart{block_id: id}) do
    block = %{type: :text, text: "", id: id, _complete?: false}
    %{state | blocks: Map.put(state.blocks, id, block), order: state.order ++ [id]}
  end

  def step(state, %Event.TextDelta{block_id: id, text: t}) do
    update_block(state, id, fn b -> %{b | text: b.text <> t} end)
  end

  def step(state, %Event.TextEnd{block_id: id}), do: finalize_block(state, id)

  def step(state, %Event.ThinkingStart{block_id: id}) do
    block = %{type: :thinking, text: "", signature: nil, id: id, _complete?: false}
    %{state | blocks: Map.put(state.blocks, id, block), order: state.order ++ [id]}
  end

  def step(state, %Event.ThinkingDelta{block_id: id, text: t}) do
    update_block(state, id, fn b -> %{b | text: b.text <> t} end)
  end

  def step(state, %Event.ThinkingEnd{block_id: id, signature: sig}) do
    state = update_block(state, id, fn b -> %{b | signature: sig} end)
    finalize_block(state, id)
  end

  def step(state, %Event.ToolCallStart{tool_call_id: id, name: name}) do
    block = %{
      type: :tool_call,
      id: id,
      name: name,
      arguments: %{},
      _args_buf: "",
      _complete?: false
    }

    %{state | blocks: Map.put(state.blocks, id, block), order: state.order ++ [id]}
  end

  def step(state, %Event.ToolCallDelta{tool_call_id: id, json_fragment: f}) do
    update_block(state, id, fn b -> %{b | _args_buf: b._args_buf <> f} end)
  end

  def step(state, %Event.ToolCallEnd{tool_call_id: id, params: p}) do
    state = update_block(state, id, fn b -> %{b | arguments: p} end)
    finalize_block(state, id)
  end

  def step(state, %Event.Done{stop_reason: r, usage: u}) do
    msg = %{state.message | stop_reason: r, usage: u, content: build_content(state)}
    %{state | message: msg, done?: true}
  end

  def step(state, %Event.Error{reason: r, retryable?: _}) do
    state = drop_incomplete_tool_calls(state)

    msg = %{
      state.message
      | stop_reason: :error,
        error_message: format_reason(r),
        content: build_content(state)
    }

    %{state | message: msg, done?: true, error: r}
  end

  def step(state, _other), do: state

  @doc "Build the public content list from the current ordered blocks."
  @spec build_content(t()) :: [map()]
  def build_content(%{order: order, blocks: blocks}) do
    order
    |> Enum.map(&Map.get(blocks, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&strip_internals/1)
  end

  defp update_block(state, id, fun) do
    case Map.get(state.blocks, id) do
      nil -> state
      b -> %{state | blocks: Map.put(state.blocks, id, fun.(b))}
    end
  end

  defp finalize_block(state, id) do
    update_block(state, id, fn b -> Map.put(b, :_complete?, true) end)
  end

  defp drop_incomplete_tool_calls(state) do
    incomplete_ids =
      state.blocks
      |> Enum.filter(fn {_id, b} -> b[:type] == :tool_call and not b[:_complete?] end)
      |> Enum.map(fn {id, _b} -> id end)

    %{
      state
      | blocks: Map.drop(state.blocks, incomplete_ids),
        order: Enum.reject(state.order, &(&1 in incomplete_ids))
    }
  end

  defp strip_internals(%{type: :tool_call} = b), do: Map.drop(b, [:_args_buf, :_complete?])
  defp strip_internals(b), do: Map.drop(b, [:id, :_complete?])

  defp format_reason({:http_status, n, %{type: type, message: msg}}) when is_binary(type),
    do: "HTTP #{n} (#{type}): #{msg}"

  defp format_reason({:http_status, n, %{body: body}}) when is_binary(body),
    do: "HTTP #{n}: #{body}"

  defp format_reason({:http_status, n, _other}), do: "HTTP #{n}"
  defp format_reason({:http_status, n}), do: "HTTP #{n}"
  defp format_reason({type, msg}) when is_binary(type), do: "#{type}: #{msg}"
  defp format_reason(other), do: inspect(other)

  # SPEC-USER-TURN / D-009: render paths that iterate
  # `msg.content` (Tau.TUI.App.on_message_end/2) silently drop a
  # message with empty content. When a stream errors before emitting
  # any TextDelta — e.g. Anthropic auth failure, network error, OAuth
  # expiry — `build_content/1` returns []. This guard synthesizes a
  # single text block carrying the error so the TUI, CLI streamer, and
  # any other consumer surface SOMETHING instead of going silent.
  #
  # This is the single source-agnostic D-009 implementation: both the
  # provider and coding-agent finalize paths route through it via
  # `finalize/3`. No path may carry a parallel copy.
  @doc """
  D-009 guarantee: ensure a finalized `%Assistant{}` has non-empty
  `content` so no render path drops it silently. Source-agnostic.
  """
  @spec ensure_visible_content(Assistant.t()) :: Assistant.t()
  def ensure_visible_content(%{content: [_ | _]} = msg), do: msg

  def ensure_visible_content(%{content: [], stop_reason: :error, error_message: em} = msg)
      when is_binary(em) and em != "" do
    %{msg | content: [%{type: :text, text: "Error: " <> em}]}
  end

  def ensure_visible_content(%{content: [], stop_reason: :error} = msg) do
    %{msg | content: [%{type: :text, text: "Error: stream ended with no content"}]}
  end

  def ensure_visible_content(%{content: []} = msg) do
    %{msg | content: [%{type: :text, text: "(empty response)"}]}
  end

  def ensure_visible_content(msg), do: msg

  @doc """
  Source-agnostic terminal fold: build the final `%Assistant{}` from a
  base message and a list of content blocks, applying the D-009
  visible-content guarantee. Both the provider and coding-agent
  finalize paths route through this.
  """
  @spec finalize(Assistant.t(), [map()], keyword()) :: Assistant.t()
  def finalize(%Assistant{} = base, blocks, opts \\ []) when is_list(blocks) do
    stop_reason = opts[:stop_reason] || base.stop_reason

    %{base | content: blocks, stop_reason: stop_reason}
    |> ensure_visible_content()
  end

  @doc "Has the stream finished (cleanly or with an error)?"
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{done?: d}), do: d

  @doc "Get the assembled `%Assistant{}` (only meaningful after `done?/1`)."
  @spec assistant(t()) :: Assistant.t()
  def assistant(%__MODULE__{message: msg} = s),
    do: finalize(msg, build_content(s), stop_reason: msg.stop_reason)
end
