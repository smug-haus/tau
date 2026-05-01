defmodule Tau.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages API client.

  Streams `POST /v1/messages?stream=true` (SSE). Uses the shared
  `Tau.Providers.Shared.FinchStream` engine and parses Anthropic's
  content-block events into normalised `Tau.Provider.Event` structs.

  ## Configuration

  Auth precedence (per call → settings → app env → vault):

      :api_key in opts
      Application.get_env(:tau, Tau.Providers.Anthropic)[:api_key]
      Tau.Settings.Vault.resolve({:vault, "ANTHROPIC_API_KEY"})

  The vault tail of the chain dispatches through the configured
  `Tau.Settings.Vault` backend (defaults to the `Env` passthrough,
  which preserves today's `System.get_env("ANTHROPIC_API_KEY")`
  behaviour). See ADR-0016.

  An `:api_key` value of the form `{:vault, name}` is resolved
  through the vault before being sent.

  Optional `:base_url` override for staging or self-hosted relays.

  ## Streaming

  Stateless — no GenServer. Concurrent streams share the
  `Tau.Providers.Finch` pool. Errors arrive in-stream as
  `%Tau.Provider.Event.Error{}`. Only invalid configuration (missing API
  key) returns `{:error, _}` synchronously.
  """

  @behaviour Tau.Provider

  alias Tau.Message.{Assistant, ToolResult, User}
  alias Tau.Provider.Event
  alias Tau.Providers.Shared.{FinchStream, ToolSpec}

  @api_url "https://api.anthropic.com"
  @api_version "2023-06-01"
  @beta_headers "prompt-caching-2024-07-31,extended-cache-ttl-2025-04-11"
  @default_model "claude-opus-4-7"
  @default_max_tokens 8192

  @impl Tau.Provider
  def default_model, do: @default_model

  @impl Tau.Provider
  def capabilities do
    %{
      thinking: true,
      tools: true,
      vision: true,
      prompt_caching: true,
      parallel_tools: true
    }
  end

  @impl Tau.Provider
  def stream(messages, opts \\ %{}, ctx \\ %{}) do
    case api_key(opts) do
      nil ->
        {:error, :missing_api_key}

      key ->
        est = Tau.Providers.Shared.TokenEstimate.estimate(messages)

        case Tau.Providers.RateLimiter.acquire(__MODULE__, est) do
          {:error, :rate_limit_timeout} ->
            {:error, :rate_limited}

          :ok ->
            {system, user_messages} = split_system(messages)
            body = build_body(system, user_messages, opts)

            request =
              Finch.build(
                :post,
                "#{base_url()}/v1/messages",
                headers(key),
                Jason.encode!(body)
              )

            {:ok,
             FinchStream.run(
               request,
               &decode/2,
               %{
                 partial: %{},
                 started?: false,
                 model: nil,
                 provider: __MODULE__,
                 # ADR-0017: cooperative cancellation flag.
                 cancel_flag: ctx[:cancel_flag]
               }
             )}
        end
    end
  end

  # --- SSE event decoding (called by FinchStream) ---------------------------

  @doc false
  def decode(%{event: nil, data: ""}, partial), do: {[], partial}

  def decode(%{data: data} = evt, partial) do
    case Jason.decode(data) do
      {:ok, json} -> dispatch(evt[:event] || json["type"], json, partial)
      {:error, _} -> {[], partial}
    end
  end

  defp dispatch("message_start", %{"message" => msg}, partial) do
    model = msg["model"]

    start_evts =
      if not partial.started? and not is_nil(model) do
        [%Event.Start{request_id: msg["id"] || "anth_unknown", model: model}]
      else
        []
      end

    {start_evts,
     %{
       partial
       | started?: partial.started? or not is_nil(model),
         model: model || partial.model,
         partial: Map.put(partial.partial, :usage, msg["usage"] || %{})
     }}
  end

  defp dispatch("content_block_start", %{"index" => idx, "content_block" => cb}, partial) do
    case cb["type"] do
      "text" ->
        block_id = "anth_text_#{idx}"
        p = put_in(partial.partial[idx], %{kind: :text, id: block_id})
        {[%Event.TextStart{block_id: block_id}], p}

      "thinking" ->
        block_id = "anth_think_#{idx}"
        p = put_in(partial.partial[idx], %{kind: :thinking, id: block_id})
        {[%Event.ThinkingStart{block_id: block_id}], p}

      "tool_use" ->
        tool_id = cb["id"]
        name = cb["name"]
        p = put_in(partial.partial[idx], %{kind: :tool_use, id: tool_id, name: name, args: ""})
        {[%Event.ToolCallStart{tool_call_id: tool_id, name: name}], p}

      _ ->
        {[], partial}
    end
  end

  defp dispatch("content_block_delta", %{"index" => idx, "delta" => d}, partial) do
    case Map.get(partial.partial, idx) do
      %{kind: :text, id: id} ->
        {[%Event.TextDelta{block_id: id, text: d["text"] || ""}], partial}

      %{kind: :thinking, id: id} ->
        text = d["thinking"] || d["text"] || ""
        {[%Event.ThinkingDelta{block_id: id, text: text}], partial}

      %{kind: :tool_use, id: id} = tu ->
        frag = d["partial_json"] || ""
        p = put_in(partial.partial[idx], %{tu | args: tu.args <> frag})
        {[%Event.ToolCallDelta{tool_call_id: id, json_fragment: frag}], p}

      _ ->
        {[], partial}
    end
  end

  defp dispatch("content_block_stop", %{"index" => idx}, partial) do
    case Map.get(partial.partial, idx) do
      %{kind: :text, id: id} ->
        p = %{partial | partial: Map.delete(partial.partial, idx)}
        {[%Event.TextEnd{block_id: id}], p}

      %{kind: :thinking, id: id} ->
        p = %{partial | partial: Map.delete(partial.partial, idx)}
        {[%Event.ThinkingEnd{block_id: id, signature: nil}], p}

      %{kind: :tool_use, id: id, args: args} ->
        params =
          case Jason.decode(args) do
            {:ok, m} when is_map(m) -> m
            _ -> %{}
          end

        p = %{partial | partial: Map.delete(partial.partial, idx)}
        {[%Event.ToolCallEnd{tool_call_id: id, params: params}], p}

      _ ->
        {[], partial}
    end
  end

  defp dispatch("message_delta", %{"delta" => d, "usage" => u}, partial) do
    stop_reason = normalise_stop(d["stop_reason"])
    usage = merge_usage(Map.get(partial.partial, :usage, %{}), u)
    {[%Event.Done{stop_reason: stop_reason, usage: usage}], partial}
  end

  defp dispatch("message_stop", _data, partial), do: {[], partial}
  defp dispatch("ping", _data, partial), do: {[], partial}

  defp dispatch("error", %{"error" => err}, partial) do
    reason = {err["type"] || "error", err["message"] || ""}
    retryable? = err["type"] in ["overloaded_error", "api_error", "rate_limit_error"]
    {[%Event.Error{reason: reason, retryable?: retryable?}], partial}
  end

  defp dispatch(_unknown, _data, partial), do: {[], partial}

  defp normalise_stop("end_turn"), do: :stop
  defp normalise_stop("max_tokens"), do: :length
  defp normalise_stop("tool_use"), do: :tool_use
  defp normalise_stop("stop_sequence"), do: :stop_sequence
  defp normalise_stop(nil), do: :stop
  defp normalise_stop(_), do: :stop

  defp merge_usage(start_u, delta_u) do
    %{
      input_tokens: get_in(start_u, ["input_tokens"]) || 0,
      output_tokens: get_in(delta_u, ["output_tokens"]) || 0,
      cache_creation_input_tokens: get_in(start_u, ["cache_creation_input_tokens"]) || 0,
      cache_read_input_tokens: get_in(start_u, ["cache_read_input_tokens"]) || 0
    }
  end

  # --- Request body construction --------------------------------------------

  defp split_system(messages) do
    {sys, rest} =
      Enum.split_with(messages, fn
        %User{metadata: %{role: :system}} -> true
        _ -> false
      end)

    system_text =
      sys
      |> Enum.map(fn %User{content: c} -> if is_binary(c), do: c, else: "" end)
      |> Enum.join("\n\n")
      |> case do
        "" -> nil
        s -> s
      end

    {system_text, rest}
  end

  defp build_body(system, messages, opts) do
    body = %{
      model: opts[:model] || @default_model,
      max_tokens: opts[:max_tokens] || @default_max_tokens,
      stream: true,
      messages: Enum.map(messages, &to_anthropic/1)
    }

    body
    |> maybe_put(:system, system_field(system, opts))
    |> maybe_put(:temperature, opts[:temperature])
    |> maybe_put(:tools, ToolSpec.adapt(opts[:tools], __MODULE__))
    |> maybe_put(:tool_choice, tool_choice(opts[:tool_choice]))
    |> maybe_put(:thinking, thinking(opts))
    |> maybe_put(:stop_sequences, opts[:stop_sequences])
  end

  defp system_field(nil, opts) do
    case opts[:system] do
      nil -> nil
      bin when is_binary(bin) -> bin
      blocks when is_list(blocks) -> blocks
    end
  end

  defp system_field(string, _opts), do: string

  defp tool_choice(nil), do: nil
  defp tool_choice(:auto), do: %{type: "auto"}
  defp tool_choice(:any), do: %{type: "any"}
  defp tool_choice(:none), do: %{type: "none"}
  defp tool_choice({:tool, name}), do: %{type: "tool", name: name}

  defp thinking(opts) do
    case opts[:reasoning] || opts[:thinking_budget] do
      nil ->
        nil

      level when level in [:minimal, :low, :medium, :high, :xhigh] ->
        %{type: "enabled", budget_tokens: budget_for(level)}

      n when is_integer(n) and n > 0 ->
        %{type: "enabled", budget_tokens: n}

      _ ->
        nil
    end
  end

  defp budget_for(:minimal), do: 1024
  defp budget_for(:low), do: 4096
  defp budget_for(:medium), do: 16_384
  defp budget_for(:high), do: 32_768
  defp budget_for(:xhigh), do: 64_000

  defp to_anthropic(%User{content: c}) when is_binary(c), do: %{role: "user", content: c}

  defp to_anthropic(%User{content: blocks}) when is_list(blocks),
    do: %{role: "user", content: Enum.map(blocks, &block_out/1)}

  defp to_anthropic(%Assistant{content: blocks}),
    do: %{role: "assistant", content: Enum.map(blocks, &block_out/1)}

  defp to_anthropic(%ToolResult{tool_call_id: id, content: c, is_error: e}) do
    %{
      role: "user",
      content: [
        %{type: "tool_result", tool_use_id: id, content: tool_result_content(c), is_error: e}
      ]
    }
  end

  defp tool_result_content(c) when is_binary(c), do: c
  defp tool_result_content(blocks) when is_list(blocks), do: Enum.map(blocks, &block_out/1)

  defp block_out(%{type: :text, text: t}), do: %{type: "text", text: t}

  defp block_out(%{type: :image, data: d, media_type: mt}),
    do: %{type: "image", source: %{type: "base64", media_type: mt, data: Base.encode64(d)}}

  defp block_out(%{type: :thinking, text: t, signature: sig}) do
    base = %{type: "thinking", thinking: t}
    if sig, do: Map.put(base, :signature, sig), else: base
  end

  defp block_out(%{type: :tool_call, id: id, name: name, arguments: args}),
    do: %{type: "tool_use", id: id, name: name, input: args || %{}}

  defp block_out(other), do: other

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # --- Auth & transport plumbing -------------------------------------------

  defp api_key(opts \\ %{}) do
    # Resolution order (first non-nil wins):
    #
    #   1. `opts[:api_key]` — per-call override; literal string or
    #      `{:vault, name}` reference.
    #   2. `Application.get_env(:tau, __MODULE__)[:api_key]` — kept
    #      for backwards compatibility with the pre-ADR-0016 path.
    #   3. `Tau.Settings.Vault.resolve({:vault, "ANTHROPIC_API_KEY"})`
    #      — dispatches through the configured vault backend (defaults
    #      to `Env`, which is `System.get_env/1`, preserving today's
    #      behaviour).
    Tau.Settings.Vault.resolve(opts[:api_key]) ||
      Application.get_env(:tau, __MODULE__, [])[:api_key] ||
      Tau.Settings.Vault.resolve({:vault, "ANTHROPIC_API_KEY"})
  end

  defp base_url do
    Application.get_env(:tau, __MODULE__, [])[:base_url] ||
      System.get_env("ANTHROPIC_BASE_URL") ||
      @api_url
  end

  defp headers(key) do
    [
      {"x-api-key", key},
      {"anthropic-version", @api_version},
      {"anthropic-beta", @beta_headers},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end
end
