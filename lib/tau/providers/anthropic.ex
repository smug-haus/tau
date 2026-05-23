defmodule Tau.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages API client.

  Streams `POST /v1/messages?stream=true` (SSE). Uses the shared
  `Tau.Providers.Shared.FinchStream` engine and parses Anthropic's
  content-block events into normalised `Tau.Provider.Event` structs.

  ## Configuration

  Auth resolution lives in `Tau.Providers.Anthropic.Auth` (D-017).
  Two paths are supported as first-class:

  1. **API key** (`x-api-key` header). Resolved from explicit
     `:api_key` opt → `Application.get_env(:tau, Tau.Providers.Anthropic)[:api_key]`
     → `Tau.Settings.Vault.resolve({:vault, "ANTHROPIC_API_KEY"})`.
  2. **Claude Code OAuth** (`Authorization: Bearer <token>` plus
     `anthropic-beta: oauth-2025-04-20`). Sourced from
     `~/.claude/.credentials.json` (key `claudeAiOauth`). Pro/Max
     subscribers do NOT have API keys; this is the dominant path.

  The vault tail of the chain dispatches through the configured
  `Tau.Settings.Vault` backend (defaults to the `Env` passthrough,
  which preserves the historical `System.get_env("ANTHROPIC_API_KEY")`
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
  alias Tau.Providers.Anthropic.Auth
  alias Tau.Providers.Shared.{FinchStream, ToolSpec}

  alias Tau.Provider.ContextWindows
  alias Tau.Providers.Shared.OrderingCheck

  @api_url "https://api.anthropic.com"
  @api_version "2023-06-01"
  # SPEC-PROMPT-CACHING C7: 5-min ephemeral TTL only in this PR. The
  # `extended-cache-ttl-2025-04-11` beta header is removed (it enabled
  # the 1h tier, which costs 2x write and offers no benefit for active
  # coordinator sessions). The base `prompt-caching-2024-07-31` header
  # stays — it is GA-equivalent and harmless.
  @beta_headers "prompt-caching-2024-07-31"
  @default_model "claude-opus-4-7"
  @default_max_tokens 8192
  # SPEC-PROMPT-CACHING D-064: an ephemeral cache_control marker.
  @cache_control %{type: "ephemeral"}

  @impl Tau.Provider
  def default_model, do: @default_model

  @impl Tau.Provider
  def context_window(model), do: ContextWindows.lookup(__MODULE__, model)

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

  @doc """
  Prompt-caching policy switch for a turn (SPEC-PROMPT-CACHING B1 / D-063).

  Anthropic is a Family A (explicit-marker) provider. This returns:

    * `:explicit` — when the session has at least one message AND
      `opts[:caching]` is not explicitly disabled. `build_body/3` then
      injects markers per D-064.
    * `:none`     — when `opts[:caching] == false`, or the session is
      empty. `build_body/3` skips all marker injection.
  """
  @impl Tau.Provider
  @spec cache_regions([Tau.Message.t()], map()) :: :explicit | :none
  def cache_regions(messages, opts \\ %{}) do
    cond do
      opts[:caching] == false -> :none
      is_list(messages) and messages != [] -> :explicit
      true -> :none
    end
  end

  @impl Tau.Provider
  def stream(messages, opts \\ %{}, ctx \\ %{}) do
    case Auth.resolve(opts) do
      {:error, _} = err ->
        # D-017 / D-018: surface a structured auth error. The
        # session FSM's :start_provider error branch translates this
        # into an Assistant message whose content includes the
        # actionable renewal instruction (D-009). Preserves the
        # historical `:missing_api_key` shape ONLY for the legacy
        # "no auth at all" case, so existing callers that switch on
        # that atom keep working until migrated.
        case err do
          {:error, :no_auth} -> {:error, :missing_api_key}
          other -> other
        end

      {:ok, auth} ->
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
                headers(auth),
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

  # Normalises Anthropic's `usage` payloads into the canonical Tau
  # usage-map keys (SPEC-PROMPT-CACHING §4 B3 hop 1 / D-065).
  #
  # `merge_usage/2` folds the `usage` block from `message_start` (the
  # cumulative input / cache counters) with the `usage` block from
  # `message_delta` (the output count) into the canonical map the cost
  # ledger reads:
  #
  #   * `cache_creation_input_tokens` -> `:cache_write`
  #   * `cache_read_input_tokens`     -> `:cache_read`
  #   * `cache_breakdown` carries the Anthropic 5m / 1h ephemeral split
  #     (`ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`)
  #     under `:ephemeral_5m` / `:ephemeral_1h`, when the response
  #     includes the `cache_creation` sub-object.
  #
  # Tau never opts into the 1h tier (C7 — the adapter never emits
  # `ttl: "1h"`). If the server promotes anyway, the 1h tokens still
  # appear in `cache_breakdown.ephemeral_1h` for diagnostics AND are
  # already summed into `cache_write` because `cache_creation_input_tokens`
  # is Anthropic's total of both tiers.
  @doc false
  @spec merge_usage(map(), map()) :: map()
  def merge_usage(start_u, delta_u) do
    start_u = start_u || %{}
    delta_u = delta_u || %{}

    cache_write = nonneg(get_in(start_u, ["cache_creation_input_tokens"]))
    cache_read = nonneg(get_in(start_u, ["cache_read_input_tokens"]))

    %{
      input_tokens: nonneg(get_in(start_u, ["input_tokens"])),
      output_tokens: nonneg(get_in(delta_u, ["output_tokens"])),
      cache_read: cache_read,
      cache_write: cache_write,
      cache_breakdown: cache_breakdown(start_u)
    }
  end

  defp nonneg(n) when is_integer(n) and n >= 0, do: n
  defp nonneg(_), do: 0

  # Anthropic reports the 5m / 1h split under `usage.cache_creation`
  # when prompt caching is active. Absent that sub-object, the
  # breakdown is empty.
  defp cache_breakdown(%{"cache_creation" => %{} = cc}) do
    %{
      ephemeral_5m: nonneg(cc["ephemeral_5m_input_tokens"]),
      ephemeral_1h: nonneg(cc["ephemeral_1h_input_tokens"])
    }
  end

  defp cache_breakdown(_), do: %{}

  # --- Request body construction --------------------------------------------

  # SPEC-PROMPT-CACHING D-064 / Appendix B: `split_system/1` now
  # returns the system content as a **block-array** —
  # `[%{type: "text", text: ...}]`, one block per non-empty system
  # message — rather than a single joined string. The block-array
  # shape is what marker A annotates: `cache_control` is placed on
  # the LAST text block.
  defp split_system(messages) do
    {sys, rest} =
      Enum.split_with(messages, fn
        %User{metadata: %{role: :system}} -> true
        _ -> false
      end)

    blocks =
      sys
      |> Enum.map(fn %User{content: c} -> if is_binary(c), do: c, else: "" end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&%{type: "text", text: &1})

    case blocks do
      [] -> {nil, rest}
      list -> {list, rest}
    end
  end

  # Builds the Anthropic Messages API request body for a turn.
  #
  # Made `@doc false`-public (SPEC-PROMPT-CACHING AC-1) so the
  # cache-policy test can assert marker placement directly on the wire
  # body without driving a full stream.
  #
  # `system` is the block-array (or `nil`) from `split_system/1`;
  # `messages` is the non-system conversation list; `opts` is the
  # `t:Tau.Provider.stream_opts/0` map.
  #
  # When `cache_regions/2` returns `:explicit`, up to three ephemeral
  # `cache_control` markers are injected per D-064. The body is
  # validated by `Tau.Providers.Shared.OrderingCheck.validate!/1` as
  # the last step (C2 / AC-3). Marker derivation is a pure function of
  # `(system, tools, messages, opts)` — it reads no ambient state
  # (C4 / D-064).
  @doc false
  @spec build_body(nil | [map()], [Tau.Message.t()], map()) :: map()
  def build_body(system, messages, opts) do
    policy = cache_regions(messages, opts)
    tools = ToolSpec.adapt(opts[:tools], __MODULE__)
    wire_messages = Enum.map(messages, &to_anthropic/1)
    system_blocks = system_field(system, opts)

    {system_blocks, tools, wire_messages} =
      case policy do
        :explicit ->
          {mark_system(system_blocks), mark_tools(tools), mark_messages(messages, wire_messages)}

        :none ->
          {system_blocks, tools, wire_messages}
      end

    body =
      %{
        model: opts[:model] || @default_model,
        max_tokens: opts[:max_tokens] || @default_max_tokens,
        stream: true,
        messages: wire_messages
      }
      |> maybe_put(:system, system_blocks)
      |> maybe_put(:temperature, opts[:temperature])
      |> maybe_put(:tools, tools)
      |> maybe_put(:tool_choice, tool_choice(opts[:tool_choice]))
      |> maybe_put(:thinking, thinking(opts))
      |> maybe_put(:stop_sequences, opts[:stop_sequences])

    # C2 / AC-3: canonical-ordering guard, last step.
    OrderingCheck.validate!(%{
      system: body[:system],
      tools: body[:tools],
      messages: body.messages
    })

    body
  end

  # `system_field/2` normalises the system content to the block-array
  # wire shape. A `split_system/1` block-array passes through; an
  # explicit `opts[:system]` string/list is adapted; absent system
  # content is `nil`.
  defp system_field(blocks, _opts) when is_list(blocks), do: blocks

  defp system_field(nil, opts) do
    case opts[:system] do
      nil -> nil
      bin when is_binary(bin) -> [%{type: "text", text: bin}]
      "" -> nil
      blocks when is_list(blocks) -> blocks
    end
  end

  # --- D-064 cache-marker injection (pure function) -------------------------

  # Marker A — last text block of the system block-array.
  defp mark_system(nil), do: nil
  defp mark_system([]), do: []

  defp mark_system(blocks) when is_list(blocks) do
    mark_last(blocks, &put_cache_control/1)
  end

  # Marker B — last tool spec in the tools array.
  defp mark_tools(nil), do: nil
  defp mark_tools([]), do: []

  defp mark_tools(tools) when is_list(tools) do
    mark_last(tools, &put_cache_control/1)
  end

  # Marker C — last content block of the last-stable-boundary
  # message (D-064). `domain_messages` is the pre-wire
  # `[Tau.Message.t()]`; `wire_messages` is the encoded list, index-aligned.
  defp mark_messages(domain_messages, wire_messages) do
    case stable_boundary_index(domain_messages) do
      nil ->
        wire_messages

      idx ->
        List.update_at(wire_messages, idx, &mark_message_last_block/1)
    end
  end

  # D-064 stable-boundary selection, in order of preference:
  #   (i)   the latest-list-position compaction-summary message —
  #         the strongest cache anchor when present;
  #   (ii)  the message immediately before the freshest input (the
  #         second-to-last message overall) IF its role is :assistant
  #         or it is a %ToolResult{};
  #   (iii) nil — skip marker C (no stable boundary, e.g. a first turn
  #         with a single user message, or a second-to-last message
  #         that is a plain user message).
  defp stable_boundary_index(messages) do
    indexed = Enum.with_index(messages)

    compaction_idx =
      indexed
      |> Enum.filter(fn {m, _i} -> compaction_summary?(m) end)
      |> List.last()
      |> case do
        {_m, i} -> i
        nil -> nil
      end

    cond do
      not is_nil(compaction_idx) ->
        compaction_idx

      length(messages) >= 2 ->
        # (ii) the message immediately before the freshest input.
        penultimate_idx = length(messages) - 2
        penultimate = Enum.at(messages, penultimate_idx)
        if assistant_or_tool_result?(penultimate), do: penultimate_idx, else: nil

      true ->
        nil
    end
  end

  defp compaction_summary?(%User{metadata: %{role: :compaction_summary}}), do: true
  defp compaction_summary?(_), do: false

  defp assistant_or_tool_result?(%Assistant{}), do: true
  defp assistant_or_tool_result?(%ToolResult{}), do: true
  defp assistant_or_tool_result?(_), do: false

  # --- marker placement primitives ------------------------------------------

  defp mark_last([], _fun), do: []

  defp mark_last(list, fun) when is_list(list) do
    last = length(list) - 1
    List.update_at(list, last, fun)
  end

  defp put_cache_control(%{} = block), do: Map.put(block, :cache_control, @cache_control)

  # Marker C on a wire message: annotate the LAST content block.
  # A string-content message is promoted to a one-block array so the
  # marker has a block to land on.
  defp mark_message_last_block(%{content: content} = msg) when is_binary(content) do
    %{msg | content: [%{type: "text", text: content, cache_control: @cache_control}]}
  end

  defp mark_message_last_block(%{content: blocks} = msg) when is_list(blocks) and blocks != [] do
    %{msg | content: mark_last(blocks, &put_cache_control/1)}
  end

  defp mark_message_last_block(msg), do: msg

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

  defp base_url do
    Application.get_env(:tau, __MODULE__, [])[:base_url] ||
      System.get_env("ANTHROPIC_BASE_URL") ||
      @api_url
  end

  # D-017: header dispatch. API-key auth uses `x-api-key`; OAuth uses
  # `Authorization: Bearer ...` AND requires the `oauth-2025-04-20`
  # beta header for the Messages API to honor the token.
  defp headers({:api_key, key}) do
    [
      {"x-api-key", key},
      {"anthropic-version", @api_version},
      {"anthropic-beta", @beta_headers},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end

  defp headers({:oauth, %{access_token: token}}) do
    [
      {"authorization", "Bearer " <> token},
      {"anthropic-version", @api_version},
      {"anthropic-beta", "oauth-2025-04-20," <> @beta_headers},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end
end
