defmodule Tau.Providers.Mistral do
  @moduledoc """
  Mistral Chat Completions API (`https://api.mistral.ai/v1/chat/completions`).

  Uses the same OpenAI-compatible wire format as `Tau.Providers.OpenAI.Chat`.
  Wire-level helpers live in `Tau.Providers.Shared.OpenAIChatWire`.

  ## Configuration

  Priority order for API key resolution:

  1. `config :tau, Tau.Providers.Mistral, api_key: "..."` (application env)
  2. `Tau.Settings.Vault.resolve({:vault, "MISTRAL_API_KEY"})`
  3. `System.get_env("MISTRAL_API_KEY")`

  Base URL override (for proxies or local forks):

  1. `config :tau, Tau.Providers.Mistral, base_url: "https://..."`
  2. `System.get_env("MISTRAL_BASE_URL")`
  3. `https://api.mistral.ai/v1` (upstream default)
  """

  @behaviour Tau.Provider

  alias Tau.Provider.ContextWindows
  alias Tau.Providers.RateLimiter
  alias Tau.Providers.Shared.{FinchStream, OpenAIChatWire, TokenEstimate}

  @api_url "https://api.mistral.ai/v1"
  @default_model "mistral-large-latest"

  @impl Tau.Provider
  def default_model, do: @default_model

  @impl Tau.Provider
  def context_window(model), do: ContextWindows.lookup(__MODULE__, model)

  @impl Tau.Provider
  def capabilities do
    %{
      thinking: false,
      tools: true,
      vision: false,
      prompt_caching: false,
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
                base_url() <> "/chat/completions",
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
                 cancel_flag: ctx[:cancel_flag]
               }
             )}
        end
    end
  end

  defp api_key do
    Application.get_env(:tau, __MODULE__, [])[:api_key] ||
      vault_key() ||
      System.get_env("MISTRAL_API_KEY")
  end

  defp vault_key do
    if Code.ensure_loaded?(Tau.Settings.Vault) do
      Tau.Settings.Vault.resolve({:vault, "MISTRAL_API_KEY"})
    end
  end

  defp base_url do
    Application.get_env(:tau, __MODULE__, [])[:base_url] ||
      System.get_env("MISTRAL_BASE_URL") ||
      @api_url
  end
end
