defmodule Tau.Provider.Event do
  @moduledoc """
  Normalised event types yielded by `Tau.Provider.stream/3`.

  Provider modules translate each native streaming format (Anthropic SSE,
  OpenAI Responses SSE, Gemini SSE, Bedrock binary event-stream) into this
  union. The session FSM only consumes events from this module — providers
  never raise on user/network input; errors flow as `%Error{}` items.

  Consumers pattern-match on the struct module:

      for event <- stream do
        case event do
          %Tau.Provider.Event.TextDelta{text: t} -> IO.write(t)
          %Tau.Provider.Event.Done{stop_reason: r} -> ...
        end
      end
  """

  defmodule Start do
    @moduledoc "Stream has started. Carries the request id and the negotiated model."
    @enforce_keys [:request_id, :model]
    defstruct [:request_id, :model]
    @type t :: %__MODULE__{request_id: String.t(), model: String.t()}
  end

  defmodule TextStart do
    @moduledoc "A new text content block has begun."
    @enforce_keys [:block_id]
    defstruct [:block_id]
    @type t :: %__MODULE__{block_id: String.t()}
  end

  defmodule TextDelta do
    @moduledoc "Incremental text appended to the currently-open text block."
    @enforce_keys [:block_id, :text]
    defstruct [:block_id, :text]
    @type t :: %__MODULE__{block_id: String.t(), text: String.t()}
  end

  defmodule TextEnd do
    @moduledoc "The current text block is complete."
    @enforce_keys [:block_id]
    defstruct [:block_id]
    @type t :: %__MODULE__{block_id: String.t()}
  end

  defmodule ThinkingStart do
    @moduledoc "A new thinking (reasoning) block has begun."
    @enforce_keys [:block_id]
    defstruct [:block_id]
    @type t :: %__MODULE__{block_id: String.t()}
  end

  defmodule ThinkingDelta do
    @moduledoc "Incremental reasoning text."
    @enforce_keys [:block_id, :text]
    defstruct [:block_id, :text]
    @type t :: %__MODULE__{block_id: String.t(), text: String.t()}
  end

  defmodule ThinkingEnd do
    @moduledoc "Thinking block complete; carries the (opaque) signature for replay."
    @enforce_keys [:block_id]
    defstruct [:block_id, :signature]
    @type t :: %__MODULE__{block_id: String.t(), signature: String.t() | nil}
  end

  defmodule ToolCallStart do
    @moduledoc "A tool call is being emitted; arguments stream in via deltas."
    @enforce_keys [:tool_call_id, :name]
    defstruct [:tool_call_id, :name]
    @type t :: %__MODULE__{tool_call_id: String.t(), name: String.t()}
  end

  defmodule ToolCallDelta do
    @moduledoc "Partial JSON fragment for the in-progress tool call's arguments."
    @enforce_keys [:tool_call_id, :json_fragment]
    defstruct [:tool_call_id, :json_fragment]
    @type t :: %__MODULE__{tool_call_id: String.t(), json_fragment: String.t()}
  end

  defmodule ToolCallEnd do
    @moduledoc "Tool call complete; `params` is the parsed JSON arguments map."
    @enforce_keys [:tool_call_id, :params]
    defstruct [:tool_call_id, :params]
    @type t :: %__MODULE__{tool_call_id: String.t(), params: map()}
  end

  defmodule Done do
    @moduledoc "Stream finished cleanly. `stop_reason` is the normalised reason."
    @enforce_keys [:stop_reason]
    defstruct [:stop_reason, usage: %{}]
    @type t :: %__MODULE__{stop_reason: atom(), usage: map()}
  end

  defmodule Error do
    @moduledoc """
    Stream failed. `retryable?` is set when the failure is transient
    (rate limit, network blip, 5xx). Hard errors (auth, schema validation)
    set it to `false`.
    """
    @enforce_keys [:reason]
    defstruct [:reason, retryable?: false]
    @type t :: %__MODULE__{reason: term(), retryable?: boolean()}
  end

  @type t ::
          Start.t()
          | TextStart.t()
          | TextDelta.t()
          | TextEnd.t()
          | ThinkingStart.t()
          | ThinkingDelta.t()
          | ThinkingEnd.t()
          | ToolCallStart.t()
          | ToolCallDelta.t()
          | ToolCallEnd.t()
          | Done.t()
          | Error.t()
end
