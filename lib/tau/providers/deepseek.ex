defmodule Tau.Providers.DeepSeek do
  @moduledoc """
  DeepSeek Chat Completions API (`https://api.deepseek.com/v1/chat/completions`).

  Uses the same OpenAI-compatible wire format as `Tau.Providers.OpenAI.Chat`.
  Wire-level helpers live in `Tau.Providers.Shared.OpenAIChatWire`.

  ## DeepSeek-R1 thinking

  DeepSeek-R1 and compatible models emit chain-of-thought via the non-standard
  `delta.reasoning` field on the OpenAI-compatible SSE stream.
  `OpenAIChatWire.decode/2` already handles this field — no bespoke decode path
  is needed here.

  ## Configuration

  Priority order for API key resolution:

  1. `config :tau, Tau.Providers.DeepSeek, api_key: "ds-..."` (application env)
  2. `Tau.Settings.Vault.resolve({:vault, "DEEPSEEK_API_KEY"})`
  3. `System.get_env("DEEPSEEK_API_KEY")`

  Base URL override (for proxies or local forks):

  1. `config :tau, Tau.Providers.DeepSeek, base_url: "https://..."`
  2. `System.get_env("DEEPSEEK_BASE_URL")`
  3. `https://api.deepseek.com` (upstream default)
  """

  @behaviour Tau.Provider

  alias Tau.Providers.RateLimiter
  alias Tau.Providers.Shared.{FinchStream, OpenAIChatWire, TokenEstimate}

  @api_url "https://api.deepseek.com"
  @default_model "deepseek-chat"

  @impl Tau.Provider
  def default_model, do: @default_model

  @impl Tau.Provider
  def capabilities do
    %{
      thinking: true,
      tools: true,
      vision: false,
      prompt_caching: true,
      parallel_tools: true
    }
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
      vault_key() ||
      System.get_env("DEEPSEEK_API_KEY")
  end

  defp vault_key do
    if Code.ensure_loaded?(Tau.Settings.Vault) do
      Tau.Settings.Vault.resolve({:vault, "DEEPSEEK_API_KEY"})
    end
  end

  defp base_url do
    Application.get_env(:tau, __MODULE__, [])[:base_url] ||
      System.get_env("DEEPSEEK_BASE_URL") ||
      @api_url
  end
end
