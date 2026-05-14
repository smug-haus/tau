defmodule Tau.Message.User do
  @moduledoc "User message: a string or a list of content blocks."
  @enforce_keys [:content, :timestamp]
  defstruct [:content, :timestamp, metadata: %{}]

  @type t :: %__MODULE__{
          content: String.t() | [map()],
          timestamp: DateTime.t(),
          metadata: map()
        }

  @spec new(String.t() | [map()], keyword()) :: t()
  def new(content, opts \\ []) do
    %__MODULE__{
      content: content,
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end

defmodule Tau.Message.Assistant do
  @moduledoc """
  Assistant message: text + thinking + tool_call blocks.

  Carries provider/model metadata (`api`, `provider`, `model`) so the message
  can be replayed across providers with appropriate transformation.
  """

  @enforce_keys [:content, :timestamp]
  defstruct [
    :content,
    :timestamp,
    :api,
    :provider,
    :model,
    :response_model,
    :response_id,
    :stop_reason,
    :error_message,
    usage: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0},
    metadata: %{}
  ]

  @type stop_reason ::
          :stop | :length | :tool_use | :error | :aborted | :stop_sequence | :tool_loop_aborted

  @type t :: %__MODULE__{
          content: [map()],
          timestamp: DateTime.t(),
          api: atom() | String.t() | nil,
          provider: module() | nil,
          model: String.t() | nil,
          response_model: String.t() | nil,
          response_id: String.t() | nil,
          usage: map(),
          stop_reason: stop_reason() | nil,
          error_message: String.t() | nil,
          metadata: map()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      content: Keyword.get(opts, :content, []),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      api: opts[:api],
      provider: opts[:provider],
      model: opts[:model],
      response_model: opts[:response_model],
      response_id: opts[:response_id],
      usage: Keyword.get(opts, :usage, %{input_tokens: 0, output_tokens: 0}),
      stop_reason: opts[:stop_reason],
      error_message: opts[:error_message],
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end

defmodule Tau.Message.ToolResult do
  @moduledoc "Result of a tool call, fed back into the conversation."
  @enforce_keys [:tool_call_id, :tool_name, :content, :timestamp]
  defstruct [
    :tool_call_id,
    :tool_name,
    :content,
    :timestamp,
    details: %{},
    is_error: false
  ]

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          tool_name: String.t(),
          content: String.t() | [map()],
          details: map(),
          is_error: boolean(),
          timestamp: DateTime.t()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      tool_call_id: Keyword.fetch!(opts, :tool_call_id),
      tool_name: Keyword.fetch!(opts, :tool_name),
      content: Keyword.fetch!(opts, :content),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      details: Keyword.get(opts, :details, %{}),
      is_error: Keyword.get(opts, :is_error, false)
    }
  end
end

defmodule Tau.Message do
  @moduledoc """
  Unified message types passed between sessions and providers.

  The shape mirrors Pi's `pi-ai` types so cross-provider replay works out of
  the box. Concrete structs:

    * `Tau.Message.User`      — user input (text or content blocks)
    * `Tau.Message.Assistant` — model output (text + thinking + tool calls)
    * `Tau.Message.ToolResult` — result of a tool call, fed back to the model

  Content blocks are tagged maps; pattern-match on `:type` to dispatch.
  """

  alias Tau.Message.{Assistant, ToolResult, User}

  @type role :: :user | :assistant | :tool_result

  @type text_block :: %{type: :text, text: String.t()}
  @type image_block :: %{type: :image, data: binary(), media_type: String.t()}
  @type thinking_block :: %{type: :thinking, text: String.t(), signature: String.t() | nil}
  @type tool_call_block :: %{
          type: :tool_call,
          id: String.t(),
          name: String.t(),
          arguments: map(),
          thought_signature: String.t() | nil
        }

  @type content_block :: text_block() | image_block() | thinking_block() | tool_call_block()

  @type t :: User.t() | Assistant.t() | ToolResult.t()

  @spec role(t()) :: role()
  def role(%User{}), do: :user
  def role(%Assistant{}), do: :assistant
  def role(%ToolResult{}), do: :tool_result
end
