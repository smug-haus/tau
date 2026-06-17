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

  Cancellation is cooperative (ADR-0017). When the caller threads a
  `:cancel_flag` (a `:counters` reference) through `ctx`, the
  streaming engine checks it at every chunk boundary; a non-zero
  counter aborts the stream cleanly, releasing the upstream socket
  and emitting a final `%Tau.Provider.Event.Error{reason: :cancelled}`.
  Providers that don't honour the flag continue to work — the
  session falls back to a brutal kill of the streaming task after
  a 250ms grace period.
  """

  @type messages :: [Tau.Message.t()]

  @typedoc "Per-call options passed to `stream/3`."
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

  @typedoc "Per-call context: cancellation flag, pid, request id, session id."
  @type ctx :: %{
          optional(:cancel_flag) => :counters.counters_ref(),
          optional(:cancel_pid) => pid(),
          optional(:request_id) => String.t(),
          optional(:session_id) => String.t()
        }

  @typedoc "Static capability flags declared by an adapter."
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

  @doc """
  Declares the prompt-caching policy *intent* for a turn (SPEC-PROMPT-CACHING B1).

  Optional callback. Dispatch is via `function_exported?/3` at the call site;
  an adapter that does not implement it is treated as `:none` (caching
  disabled for that adapter).

  Return values:

    * `:explicit`  — the adapter SHOULD emit cache markers inside its own
      `build_body/3` (Family A: Anthropic, Bedrock-Claude). The adapter owns
      marker placement; this callback is only the policy switch.
    * `:automatic` — the adapter relies on provider-side automatic prefix
      caching (Families B and C). No body changes, but the adapter MUST honour
      the canonical request ordering (SPEC-PROMPT-CACHING §4).
    * `:none`      — caching disabled for this turn. Default when the callback
      is absent.

  This is the only behaviour callback for prompt caching. Cache-usage
  normalisation is NOT a callback — it is each adapter's own
  `merge_usage`-side responsibility (SPEC-PROMPT-CACHING B3).
  """
  @callback cache_regions(messages :: [Tau.Message.t()], opts :: map()) ::
              :explicit | :automatic | :none

  @doc """
  Returns the total context-window size in tokens for `model` (D-160 /
  SPEC-TUI-HEADLESS §5d).

  Optional callback. Dispatch is via `function_exported?/3` at the call
  site; an adapter that does not implement it returns `nil` and the status
  bar falls back to the compactor's `:compaction_threshold_tokens` config
  key, rendering the percentage as approximate (`~NN%`).

  Coding-agent adapters MUST return `nil` — the underlying subprocess's
  context window is opaque to Tau.

  Return values:
    * `pos_integer()` — total context window in tokens for this model.
    * `nil`           — window unknown for this model (triggers fallback).
  """
  @callback context_window(model :: String.t()) :: pos_integer() | nil

  # capabilities/0 and default_model/0 are optional: test stubs may omit them.
  @optional_callbacks [
    configure: 1,
    chat: 3,
    cache_regions: 2,
    context_window: 1,
    capabilities: 0,
    default_model: 0
  ]

  alias Tau.Factory.Egress

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
    with {:ok, stream} <- Egress.call(provider, %{messages: messages, opts: opts}, ctx) do
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
