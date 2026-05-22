defmodule Tau.Providers.Bedrock do
  @moduledoc """
  AWS Bedrock provider.

  Streams `InvokeModelWithResponseStream` against
  `bedrock-runtime.<region>.amazonaws.com`. Wire format is the AWS binary
  event-stream framing (see `Tau.Providers.Shared.AwsEventStream`); each
  payload is a JSON object whose shape depends on the underlying model
  family (Anthropic Claude on Bedrock, Llama, Mistral, Titan, etc.).

  This implementation handles the Anthropic-on-Bedrock case (the most
  common production deployment); other model families use a similar
  structure and can be added incrementally.

  Auth uses `:aws_credentials` for the standard credential chain
  (env vars → ~/.aws → IMDS / EKS pod identity / SSO).
  """

  @behaviour Tau.Provider

  alias Tau.Message.{Assistant, ToolResult, User}
  alias Tau.Provider.ContextWindows
  alias Tau.Provider.Event
  alias Tau.Providers.Shared.{AwsEventStream, FinchStream, ToolSpec}

  @default_model "anthropic.claude-3-5-sonnet-20241022-v2:0"

  @impl Tau.Provider
  def default_model, do: @default_model

  @impl Tau.Provider
  def context_window(model), do: ContextWindows.lookup(__MODULE__, model)

  @impl Tau.Provider
  def capabilities do
    %{thinking: true, tools: true, vision: true, prompt_caching: true, parallel_tools: true}
  end

  @impl Tau.Provider
  def stream(messages, opts \\ %{}, ctx \\ %{}) do
    case credentials() do
      nil ->
        {:error, :missing_aws_credentials}

      creds ->
        est = Tau.Providers.Shared.TokenEstimate.estimate(messages)

        case Tau.Providers.RateLimiter.acquire(__MODULE__, est) do
          {:error, :rate_limit_timeout} ->
            {:error, :rate_limited}

          :ok ->
            region = region()
            model = opts[:model] || @default_model

            url =
              "https://bedrock-runtime.#{region}.amazonaws.com/model/#{model}/invoke-with-response-stream"

            body = Jason.encode!(build_payload(messages, opts))

            headers =
              sigv4_sign(
                :post,
                url,
                [{"content-type", "application/json"}],
                body,
                creds,
                region,
                "bedrock"
              )

            request = Finch.build(:post, url, headers, body)

            {:ok,
             FinchStream.run(
               request,
               &decode_aws_chunk/2,
               %{
                 aws: AwsEventStream.new(),
                 model: model,
                 started?: false,
                 provider: __MODULE__,
                 # ADR-0017: cooperative cancellation flag.
                 cancel_flag: ctx[:cancel_flag]
               },
               mode: :raw
             )}
        end
    end
  end

  defp decode_aws_chunk(chunk, partial) when is_binary(chunk) do
    {frames, aws} = AwsEventStream.feed(partial.aws, chunk)

    Enum.reduce(frames, {[], %{partial | aws: aws}}, fn frame, {acc, p} ->
      {evs, p2} = decode_frame(frame, p)
      {acc ++ evs, p2}
    end)
  end

  defp decode_frame(%{payload: payload}, partial) do
    case Jason.decode(payload) do
      {:ok, %{"bytes" => b64}} ->
        {:ok, inner_json} = Jason.decode(Base.decode64!(b64))
        decode_anthropic_event(inner_json, partial)

      _ ->
        {[], partial}
    end
  end

  defp decode_anthropic_event(%{"type" => "message_start", "message" => m}, p),
    do:
      {if(p.started?,
         do: [],
         else: [%Event.Start{request_id: m["id"] || "bed_unk", model: m["model"]}]
       ), %{p | started?: true}}

  defp decode_anthropic_event(%{"type" => "content_block_delta", "delta" => %{"text" => t}}, p),
    do: {[%Event.TextDelta{block_id: "text", text: t}], p}

  defp decode_anthropic_event(%{"type" => "message_stop"}, p),
    do: {[%Event.Done{stop_reason: :stop}], p}

  defp decode_anthropic_event(_, p), do: {[], p}

  # --- Body -----------------------------------------------------------------

  defp build_payload(messages, opts) do
    base = %{
      anthropic_version: "bedrock-2023-05-31",
      max_tokens: opts[:max_tokens] || 8192,
      messages: Enum.map(messages, &to_anthropic/1)
    }

    case ToolSpec.adapt(opts[:tools], __MODULE__) do
      nil -> base
      [] -> base
      tools -> Map.put(base, :tools, tools)
    end
  end

  defp to_anthropic(%User{content: c}) when is_binary(c), do: %{role: "user", content: c}

  defp to_anthropic(%Assistant{content: blocks}),
    do: %{
      role: "assistant",
      content:
        Enum.map(blocks, fn
          %{type: :text, text: t} ->
            %{type: "text", text: t}

          %{type: :tool_call, id: id, name: n, arguments: a} ->
            %{type: "tool_use", id: id, name: n, input: a}

          b ->
            b
        end)
    }

  defp to_anthropic(%ToolResult{tool_call_id: id, content: c, is_error: e}) do
    %{
      role: "user",
      content: [
        %{type: "tool_result", tool_use_id: id, content: render(c), is_error: e}
      ]
    }
  end

  defp render(s) when is_binary(s), do: s

  defp render(blocks) when is_list(blocks),
    do:
      Enum.map_join(blocks, "\n", fn
        %{type: :text, text: t} -> t
        _ -> ""
      end)

  # --- Auth ----------------------------------------------------------------

  defp credentials do
    cond do
      key = System.get_env("AWS_ACCESS_KEY_ID") ->
        %{
          access_key_id: key,
          secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
          session_token: System.get_env("AWS_SESSION_TOKEN")
        }

      Code.ensure_loaded?(:aws_credentials) ->
        Application.ensure_all_started(:aws_credentials)

        case :aws_credentials.get_credentials() do
          :undefined -> nil
          c -> c
        end

      true ->
        nil
    end
  end

  defp region do
    System.get_env("AWS_REGION") || System.get_env("AWS_DEFAULT_REGION") || "us-east-1"
  end

  defp sigv4_sign(method, url, headers, body, creds, region, service) do
    Tau.Providers.Shared.SigV4.sign(method, url, headers, body, creds, region, service)
  end
end
