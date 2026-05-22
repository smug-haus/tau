defmodule Tau.Providers.OpenAI.Chat do
  @moduledoc """
  OpenAI Chat Completions API (`/v1/chat/completions`) — also covers
  Groq, DeepSeek, Together, Ollama, llama.cpp, vLLM, and any other
  OpenAI-compatible endpoint via the `:base_url` config.

  Streaming wire format: SSE with `data: {...}\\n\\n` framing; final
  event is `data: [DONE]`.

  Wire-level helpers (body construction, SSE decoding, headers) live in
  `Tau.Providers.Shared.OpenAIChatWire` so that future OpenAI-compatible
  providers can reuse them without duplication.
  """

  @behaviour Tau.Provider

  alias Tau.Providers.RateLimiter
  alias Tau.Providers.Shared.{FinchStream, OpenAIChatWire, TokenEstimate}

  @api_url "https://api.openai.com"
  @default_model "gpt-4o-mini"

  @impl Tau.Provider
  def default_model, do: @default_model

  @impl Tau.Provider
  def context_window(model), do: Tau.Provider.ContextWindows.lookup(__MODULE__, model)

  @impl Tau.Provider
  def capabilities do
    %{thinking: false, tools: true, vision: true, prompt_caching: false, parallel_tools: true}
  end

  @impl Tau.Provider
  def stream(messages, opts \\ %{}, ctx \\ %{}) do
    case api_key() do
      nil ->
        {:error, :missing_api_key}

      key ->
        est = TokenEstimate.estimate(messages)

        case RateLimiter.acquire(__MODULE__, est) do
          {:error, :rate_limit_timeout} ->
            {:error, :rate_limited}

          :ok ->
            body = OpenAIChatWire.build_body(messages, opts, __MODULE__, @default_model)

            request =
              Finch.build(
                :post,
                base_url() <> "/v1/chat/completions",
                OpenAIChatWire.headers(key),
                Jason.encode!(body)
              )

            {:ok,
             FinchStream.run(
               request,
               &OpenAIChatWire.decode/2,
               %{
                 tool_calls: %{},
                 model: nil,
                 provider: __MODULE__,
                 # ADR-0017: cooperative cancellation flag.
                 cancel_flag: ctx[:cancel_flag]
               }
             )}
        end
    end
  end

  defp api_key do
    Application.get_env(:tau, __MODULE__, [])[:api_key] ||
      Application.get_env(:tau, Tau.Providers.OpenAI, [])[:api_key] ||
      System.get_env("OPENAI_API_KEY")
  end

  defp base_url do
    Application.get_env(:tau, __MODULE__, [])[:base_url] ||
      Application.get_env(:tau, Tau.Providers.OpenAI, [])[:base_url] ||
      System.get_env("OPENAI_BASE_URL") ||
      @api_url
  end
end
