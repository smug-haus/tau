defmodule Tau.Provider do
  @moduledoc """
  Behaviour for LLM provider backends.

  Implementations:

    * `Tau.Providers.Anthropic`         — Anthropic Messages API
    * `Tau.Providers.OpenAI.Responses`  — OpenAI `/v1/responses`
    * `Tau.Providers.OpenAI.Chat`       — OpenAI `/v1/chat/completions`
    * `Tau.Providers.Gemini`            — Google Gemini `streamGenerateContent`
    * `Tau.Providers.Bedrock`           — AWS Bedrock `InvokeModelWithResponseStream`
    * `Tau.Providers.Replay`            — test-only, replays a JSONL fixture

  ## Contract

  `stream/3` returns `{:ok, Enumerable.t()}` whose elements are
  `Tau.Provider.Event` structs. **It MUST NOT raise** for user/network
  errors; failures arrive in-stream as `%Tau.Provider.Event.Error{}`.

  Hard configuration errors (missing API key, malformed model id) may be
  returned synchronously as `{:error, reason}` from `stream/3` itself.

  Cancellation is cooperative: the caller passes an MFA or pid in `ctx`
  that will be `Process.exit/2`'d (or otherwise signalled) to abort
  in-flight work.
  """

  @type messages :: [Tau.Message.t()]

  @type stream_opts :: %{
          optional(:model) => String.t(),
          optional(:max_tokens) => pos_integer(),
          optional(:temperature) => float(),
          optional(:reasoning) => :minimal | :low | :medium | :high | :xhigh,
          optional(:thinking_budget) => non_neg_integer(),
          optional(:cache_retention) => :none | :short | :long,
          optional(:tools) => [map()],
          optional(:tool_choice) => :auto | :any | :none | {:tool, String.t()},
          optional(:system) => String.t() | [map()],
          optional(:stop_sequences) => [String.t()],
          optional(:metadata) => map()
        }

  @type ctx :: %{
          optional(:cancel_pid) => pid(),
          optional(:request_id) => String.t(),
          optional(:session_id) => String.t()
        }

  @type capabilities :: %{
          thinking: boolean(),
          tools: boolean(),
          vision: boolean(),
          prompt_caching: boolean(),
          parallel_tools: boolean()
        }

  @callback stream(messages(), stream_opts(), ctx()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @callback capabilities() :: capabilities()

  @callback default_model() :: String.t()

  @callback configure(map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Non-streaming convenience: drains `stream/3` and returns the
  assembled `%Tau.Message.Assistant{}`. Optional override for
  providers with a native non-SSE endpoint (e.g. private deployments
  that prefer a single request/response). Callers that want to stay
  provider-agnostic should call `Tau.Provider.chat/4` instead, which
  dispatches to this callback if defined and falls back to a default
  drain otherwise.
  """
  @callback chat(messages(), stream_opts(), ctx()) ::
              {:ok, Tau.Message.Assistant.t()} | {:error, term()}

  @optional_callbacks [configure: 1, chat: 3]

  @doc "Look up the configured default provider."
  @spec default() :: module()
  def default, do: Application.get_env(:tau, :default_provider, Tau.Providers.Anthropic)

  @doc """
  Provider-agnostic non-streaming entry point.

  If `provider` exports `chat/3`, delegates. Otherwise drains
  `provider.stream/3` through `Tau.Message.Assembler` and returns
  the final assistant message.

  Error surface (default-impl):

    * Synchronous `{:error, reason}` from `stream/3` surfaces
      unchanged — these are configuration errors (missing API
      key, malformed model id) that the caller should fix.
    * An in-stream `%Tau.Provider.Event.Error{}` produces
      `{:error, reason}` carrying the original event's reason.
      Streaming callers see partial content and a synthetic
      `%Assistant{stop_reason: :error}`; non-streaming callers
      get a clean tagged tuple instead.

  Provider overrides are free to choose their own error semantics
  (e.g. retrying internally before returning).
  """
  @spec chat(module(), messages(), stream_opts(), ctx()) ::
          {:ok, Tau.Message.Assistant.t()} | {:error, term()}
  def chat(provider, messages, opts \\ %{}, ctx \\ %{}) do
    if function_exported?(provider, :chat, 3) do
      provider.chat(messages, opts, ctx)
    else
      drain_stream(provider, messages, opts, ctx)
    end
  end

  defp drain_stream(provider, messages, opts, ctx) do
    with {:ok, stream} <- provider.stream(messages, opts, ctx) do
      assembler =
        Enum.reduce(
          stream,
          Tau.Message.Assembler.new(provider: provider, model: opts[:model]),
          fn ev, acc -> Tau.Message.Assembler.step(acc, ev) end
        )

      case assembler do
        %{error: nil} = a -> {:ok, Tau.Message.Assembler.assistant(a)}
        %{error: reason} -> {:error, reason}
      end
    end
  end
end
