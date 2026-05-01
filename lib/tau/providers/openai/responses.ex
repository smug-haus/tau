defmodule Tau.Providers.OpenAI.Responses do
  @moduledoc """
  OpenAI Responses API (`/v1/responses`) — newer, structured-output-friendly
  endpoint that supports the o1/o3-style reasoning models with explicit
  `reasoning.effort` knobs.

  Streaming wire format: SSE; events are typed (`response.created`,
  `response.output_text.delta`, `response.completed`, etc.).
  """

  @behaviour Tau.Provider

  alias Tau.Message.{Assistant, ToolResult, User}
  alias Tau.Provider.Event
  alias Tau.Providers.Shared.{FinchStream, ToolSpec}

  @api_url "https://api.openai.com"
  @default_model "gpt-4o-mini"

  @impl Tau.Provider
  def default_model, do: @default_model

  @impl Tau.Provider
  def capabilities do
    %{thinking: true, tools: true, vision: true, prompt_caching: false, parallel_tools: true}
  end

  @impl Tau.Provider
  def stream(messages, opts \\ %{}, _ctx \\ %{}) do
    case api_key() do
      nil ->
        {:error, :missing_api_key}

      key ->
        est = Tau.Providers.Shared.TokenEstimate.estimate(messages)

        case Tau.Providers.RateLimiter.acquire(__MODULE__, est) do
          {:error, :rate_limit_timeout} ->
            {:error, :rate_limited}

          :ok ->
            body = build_body(messages, opts)

            request =
              Finch.build(
                :post,
                base_url() <> "/v1/responses",
                headers(key),
                Jason.encode!(body)
              )

            {:ok,
             FinchStream.run(
               request,
               &decode/2,
               %{model: nil, started?: false, provider: __MODULE__}
             )}
        end
    end
  end

  @doc false
  def decode(%{event: "response.created", data: data}, partial) do
    case Jason.decode(data) do
      {:ok, %{"response" => %{"model" => m}}} ->
        {[%Event.Start{request_id: "openai_resp", model: m}], %{partial | model: m, started?: true}}

      _ ->
        {[], partial}
    end
  end

  def decode(%{event: "response.output_text.delta", data: data}, partial) do
    case Jason.decode(data) do
      {:ok, %{"delta" => d}} -> {[%Event.TextDelta{block_id: "text", text: d}], partial}
      _ -> {[], partial}
    end
  end

  def decode(%{event: "response.completed"}, partial),
    do: {[%Event.Done{stop_reason: :stop}], partial}

  def decode(%{event: "response.failed", data: data}, partial) do
    {[%Event.Error{reason: data, retryable?: true}], partial}
  end

  def decode(_, partial), do: {[], partial}

  defp build_body(messages, opts) do
    body = %{
      model: opts[:model] || @default_model,
      stream: true,
      input: Enum.map(messages, &to_input/1)
    }

    body
    |> maybe_put(:temperature, opts[:temperature])
    |> maybe_put(:max_output_tokens, opts[:max_tokens])
    |> maybe_put(:reasoning, reasoning(opts[:reasoning]))
    |> maybe_put(:tools, ToolSpec.adapt(opts[:tools], __MODULE__))
  end

  defp reasoning(nil), do: nil

  defp reasoning(level) when level in [:minimal, :low, :medium, :high, :xhigh],
    do: %{effort: to_string(level)}

  defp to_input(%User{content: c}) when is_binary(c),
    do: %{role: "user", content: [%{type: "input_text", text: c}]}

  defp to_input(%Assistant{content: blocks}) do
    text =
      Enum.find_value(blocks, fn
        %{type: :text, text: t} -> t
        _ -> nil
      end) || ""

    %{role: "assistant", content: [%{type: "output_text", text: text}]}
  end

  defp to_input(%ToolResult{tool_call_id: id, content: c}) do
    %{role: "tool", tool_call_id: id, content: [%{type: "input_text", text: render(c)}]}
  end

  defp render(s) when is_binary(s), do: s

  defp render(blocks) when is_list(blocks),
    do:
      Enum.map_join(blocks, "\n", fn
        %{type: :text, text: t} -> t
        _ -> ""
      end)

  defp maybe_put(map, _, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp api_key do
    Application.get_env(:tau, __MODULE__, [])[:api_key] ||
      Application.get_env(:tau, Tau.Providers.OpenAI, [])[:api_key] ||
      System.get_env("OPENAI_API_KEY")
  end

  defp base_url do
    Application.get_env(:tau, __MODULE__, [])[:base_url] ||
      System.get_env("OPENAI_BASE_URL") ||
      @api_url
  end

  defp headers(key) do
    [
      {"authorization", "Bearer #{key}"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end
end
