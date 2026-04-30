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
    block = %{type: :text, text: "", id: id}
    %{state | blocks: Map.put(state.blocks, id, block), order: state.order ++ [id]}
  end

  def step(state, %Event.TextDelta{block_id: id, text: t}) do
    update_block(state, id, fn b -> %{b | text: b.text <> t} end)
  end

  def step(state, %Event.TextEnd{block_id: id}), do: finalize_block(state, id)

  def step(state, %Event.ThinkingStart{block_id: id}) do
    block = %{type: :thinking, text: "", signature: nil, id: id}
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
    block = %{type: :tool_call, id: id, name: name, arguments: %{}, _args_buf: ""}
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

  defp finalize_block(state, _id), do: state

  defp strip_internals(%{type: :tool_call} = b), do: Map.drop(b, [:_args_buf])
  defp strip_internals(b), do: Map.drop(b, [:id])

  defp format_reason({:http_status, n}), do: "HTTP #{n}"
  defp format_reason({type, msg}) when is_binary(type), do: "#{type}: #{msg}"
  defp format_reason(other), do: inspect(other)

  @doc "Has the stream finished (cleanly or with an error)?"
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{done?: d}), do: d

  @doc "Get the assembled `%Assistant{}` (only meaningful after `done?/1`)."
  @spec assistant(t()) :: Assistant.t()
  def assistant(%__MODULE__{message: msg, error: nil} = s) do
    %{msg | content: build_content(s)}
  end

  def assistant(%__MODULE__{message: msg} = s) do
    %{msg | content: build_content(s)}
  end
end
