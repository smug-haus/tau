defmodule Tau.Providers.Gemini do
  @moduledoc """
  Google Gemini provider.

  Streams `streamGenerateContent?alt=sse`. Wire format is SSE with each
  event's `data` being a Gemini `GenerateContentResponse` JSON object.

  Gemini's tool model uses `functionCall` blocks; `parts` is the rough
  equivalent of OpenAI's `tool_calls`.
  """

  @behaviour Tau.Provider

  alias Tau.Message.{Assistant, ToolResult, User}
  alias Tau.Provider.Event
  alias Tau.Providers.Shared.FinchStream

  @api_url "https://generativelanguage.googleapis.com"
  @default_model "gemini-2.0-flash"

  @impl Tau.Provider
  def default_model, do: @default_model

  @impl Tau.Provider
  def capabilities do
    %{thinking: true, tools: true, vision: true, prompt_caching: true, parallel_tools: true}
  end

  @impl Tau.Provider
  def stream(messages, opts \\ %{}, _ctx \\ %{}) do
    case api_key() do
      nil ->
        {:error, :missing_api_key}

      key ->
        model = opts[:model] || @default_model
        body = build_body(messages, opts)

        request =
          Finch.build(
            :post,
            "#{base_url()}/v1beta/models/#{model}:streamGenerateContent?alt=sse&key=#{key}",
            [{"content-type", "application/json"}, {"accept", "text/event-stream"}],
            Jason.encode!(body)
          )

        {:ok, FinchStream.run(request, &decode/2, %{model: model, started?: false})}
    end
  end

  @doc false
  def decode(%{data: ""}, partial), do: {[], partial}

  def decode(%{data: data}, partial) do
    case Jason.decode(data) do
      {:ok, json} -> decode_chunk(json, partial)
      _ -> {[], partial}
    end
  end

  defp decode_chunk(json, partial) do
    {start_evts, partial} =
      if not partial.started? do
        {[%Event.Start{request_id: "gemini_unk", model: partial.model}],
         %{partial | started?: true}}
      else
        {[], partial}
      end

    parts =
      get_in(json, ["candidates", Access.at(0), "content", "parts"]) || []

    text_evts =
      parts
      |> Enum.filter(&Map.has_key?(&1, "text"))
      |> Enum.map(&%Event.TextDelta{block_id: "text", text: &1["text"]})

    tool_evts =
      parts
      |> Enum.filter(&Map.has_key?(&1, "functionCall"))
      |> Enum.flat_map(fn %{"functionCall" => fc} ->
        id = fc["name"] <> "_call"

        [
          %Event.ToolCallStart{tool_call_id: id, name: fc["name"]},
          %Event.ToolCallEnd{tool_call_id: id, params: fc["args"] || %{}}
        ]
      end)

    finish =
      case get_in(json, ["candidates", Access.at(0), "finishReason"]) do
        "STOP" -> [%Event.Done{stop_reason: :stop}]
        "MAX_TOKENS" -> [%Event.Done{stop_reason: :length}]
        nil -> []
        _ -> []
      end

    {start_evts ++ text_evts ++ tool_evts ++ finish, partial}
  end

  defp build_body(messages, opts) do
    body = %{
      contents: Enum.map(messages, &to_gemini/1)
    }

    case opts[:tools] do
      nil -> body
      [] -> body
      tools -> Map.put(body, :tools, [%{functionDeclarations: tools}])
    end
  end

  defp to_gemini(%User{content: c}) when is_binary(c),
    do: %{role: "user", parts: [%{text: c}]}

  defp to_gemini(%User{content: blocks}),
    do: %{role: "user", parts: Enum.map(blocks, &block_to_part/1)}

  defp to_gemini(%Assistant{content: blocks}) do
    parts =
      Enum.map(blocks, fn
        %{type: :text, text: t} -> %{text: t}
        %{type: :tool_call, name: n, arguments: a} -> %{functionCall: %{name: n, args: a}}
        b -> block_to_part(b)
      end)

    %{role: "model", parts: parts}
  end

  defp to_gemini(%ToolResult{tool_name: n, content: c}) do
    %{role: "user", parts: [%{functionResponse: %{name: n, response: %{result: render_tr(c)}}}]}
  end

  defp render_tr(s) when is_binary(s), do: s

  defp render_tr(blocks) when is_list(blocks),
    do:
      Enum.map_join(blocks, "\n", fn
        %{type: :text, text: t} -> t
        _ -> ""
      end)

  defp block_to_part(%{type: :text, text: t}), do: %{text: t}

  defp block_to_part(%{type: :image, data: d, media_type: mt}),
    do: %{inlineData: %{mimeType: mt, data: Base.encode64(d)}}

  defp block_to_part(other), do: other

  defp api_key do
    Application.get_env(:tau, __MODULE__, [])[:api_key] ||
      System.get_env("GOOGLE_API_KEY") || System.get_env("GEMINI_API_KEY")
  end

  defp base_url do
    Application.get_env(:tau, __MODULE__, [])[:base_url] ||
      System.get_env("GOOGLE_API_BASE_URL") || @api_url
  end
end
