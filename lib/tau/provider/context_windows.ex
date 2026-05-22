defmodule Tau.Provider.ContextWindows do
  @moduledoc """
  Single lookup table of context-window sizes keyed by `{provider, model}`.

  D-161 (SPEC-TUI-HEADLESS §5d): all provider/model context-window sizes live
  in ONE file, not five per-adapter maps. This is the authoritative source for
  the `context_window/1` optional callback dispatched in `Tau.Provider`.

  Returns `nil` for unknown pairs — callers fall back to the compactor's
  `:compaction_threshold_tokens` application env and render as `~NN%`.

  Coding-agent adapters are NOT listed here; they return `nil` (window
  opaque to Tau).

  Sources (as of 2026-05):
    - Anthropic: https://docs.anthropic.com/en/docs/about-claude/models
    - OpenAI: https://platform.openai.com/docs/models
    - Gemini: https://ai.google.dev/gemini-api/docs/models/gemini
    - Bedrock: same as underlying Anthropic / Mistral models
    - Mistral: https://docs.mistral.ai/getting-started/models/
    - Groq: https://console.groq.com/docs/models
    - DeepSeek: https://platform.deepseek.com/api-docs/
    - Azure OpenAI: same as upstream OpenAI
  """

  @type provider :: module()
  @type model :: String.t()

  # ---------------------------------------------------------------------------
  # Lookup table: {provider_module, model_string} => context_window_tokens
  # ---------------------------------------------------------------------------

  # credo:disable-for-next-line Credo.Check.Design.AliasUsage
  @table %{
    # --- Anthropic -----------------------------------------------------------
    {Tau.Providers.Anthropic, "claude-3-5-haiku-20241022"} => 200_000,
    {Tau.Providers.Anthropic, "claude-3-5-sonnet-20241022"} => 200_000,
    {Tau.Providers.Anthropic, "claude-3-7-sonnet-20250219"} => 200_000,
    {Tau.Providers.Anthropic, "claude-opus-4-7"} => 200_000,
    {Tau.Providers.Anthropic, "claude-opus-4"} => 200_000,
    {Tau.Providers.Anthropic, "claude-sonnet-4-5"} => 200_000,
    {Tau.Providers.Anthropic, "claude-sonnet-4-6"} => 200_000,
    {Tau.Providers.Anthropic, "claude-3-opus-20240229"} => 200_000,
    {Tau.Providers.Anthropic, "claude-3-haiku-20240307"} => 200_000,
    # --- Gemini --------------------------------------------------------------
    {Tau.Providers.Gemini, "gemini-2.0-flash"} => 1_048_576,
    {Tau.Providers.Gemini, "gemini-2.0-flash-lite"} => 1_048_576,
    {Tau.Providers.Gemini, "gemini-1.5-flash"} => 1_048_576,
    {Tau.Providers.Gemini, "gemini-1.5-flash-8b"} => 1_048_576,
    {Tau.Providers.Gemini, "gemini-1.5-pro"} => 2_097_152,
    {Tau.Providers.Gemini, "gemini-2.5-flash-preview-05-20"} => 1_048_576,
    {Tau.Providers.Gemini, "gemini-2.5-pro-preview-05-06"} => 1_048_576,
    # --- Bedrock (Anthropic models) ------------------------------------------
    {Tau.Providers.Bedrock, "anthropic.claude-3-5-sonnet-20241022-v2:0"} => 200_000,
    {Tau.Providers.Bedrock, "anthropic.claude-3-5-haiku-20241022-v1:0"} => 200_000,
    {Tau.Providers.Bedrock, "anthropic.claude-3-opus-20240229-v1:0"} => 200_000,
    {Tau.Providers.Bedrock, "anthropic.claude-3-haiku-20240307-v1:0"} => 200_000,
    # --- Mistral -------------------------------------------------------------
    {Tau.Providers.Mistral, "mistral-large-latest"} => 131_072,
    {Tau.Providers.Mistral, "mistral-medium-latest"} => 131_072,
    {Tau.Providers.Mistral, "mistral-small-latest"} => 131_072,
    {Tau.Providers.Mistral, "codestral-latest"} => 262_144,
    {Tau.Providers.Mistral, "open-mistral-nemo"} => 131_072,
    # --- Groq ----------------------------------------------------------------
    {Tau.Providers.Groq, "llama-3.3-70b-versatile"} => 131_072,
    {Tau.Providers.Groq, "llama-3.1-70b-versatile"} => 131_072,
    {Tau.Providers.Groq, "llama3-70b-8192"} => 8_192,
    {Tau.Providers.Groq, "mixtral-8x7b-32768"} => 32_768,
    {Tau.Providers.Groq, "gemma2-9b-it"} => 8_192,
    # --- DeepSeek ------------------------------------------------------------
    {Tau.Providers.DeepSeek, "deepseek-chat"} => 65_536,
    {Tau.Providers.DeepSeek, "deepseek-reasoner"} => 65_536,
    # --- OpenAI (responses + chat) -------------------------------------------
    {Tau.Providers.OpenAI.Responses, "gpt-4o"} => 128_000,
    {Tau.Providers.OpenAI.Responses, "gpt-4o-mini"} => 128_000,
    {Tau.Providers.OpenAI.Responses, "gpt-4-turbo"} => 128_000,
    {Tau.Providers.OpenAI.Responses, "o1"} => 200_000,
    {Tau.Providers.OpenAI.Responses, "o1-mini"} => 128_000,
    {Tau.Providers.OpenAI.Responses, "o3"} => 200_000,
    {Tau.Providers.OpenAI.Responses, "o3-mini"} => 200_000,
    {Tau.Providers.OpenAI.Responses, "o4-mini"} => 200_000,
    {Tau.Providers.OpenAI.Chat, "gpt-4o"} => 128_000,
    {Tau.Providers.OpenAI.Chat, "gpt-4o-mini"} => 128_000,
    {Tau.Providers.OpenAI.Chat, "gpt-4-turbo"} => 128_000,
    {Tau.Providers.OpenAI.Chat, "o1"} => 200_000,
    {Tau.Providers.OpenAI.Chat, "o1-mini"} => 128_000,
    # --- Azure OpenAI --------------------------------------------------------
    {Tau.Providers.AzureOpenAI, "gpt-4o"} => 128_000,
    {Tau.Providers.AzureOpenAI, "gpt-4o-mini"} => 128_000,
    {Tau.Providers.AzureOpenAI, "gpt-4-turbo"} => 128_000
  }

  @doc """
  Look up the context-window size for a `{provider, model}` pair.

  Returns the window in tokens or `nil` when the pair is not in the table.
  Callers that receive `nil` SHOULD fall back to
  `Application.get_env(:tau, :compaction_threshold_tokens, 120_000)` and
  render the percentage as approximate (`~NN%`).
  """
  @spec lookup(provider(), model()) :: pos_integer() | nil
  def lookup(provider, model) when is_atom(provider) and is_binary(model) do
    Map.get(@table, {provider, model})
  end
end
