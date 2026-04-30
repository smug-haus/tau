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

  @optional_callbacks [configure: 1]

  @doc "Look up the configured default provider."
  @spec default() :: module()
  def default, do: Application.get_env(:tau, :default_provider, Tau.Providers.Anthropic)
end
