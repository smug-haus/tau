defmodule Tau.Providers.Shared.OrderingCheck do
  @moduledoc """
  Runtime guard for the canonical request ordering contract
  (SPEC-PROMPT-CACHING §4 B2 / constraint C2 / AC-3).

  Provider prefix caching — explicit (Family A) or automatic
  (Families B/C) — only hits when stable content appears at the
  *start* of the request, in a fixed order:

      system → tools → historical messages (oldest first) →
      fresh user/tool-result input

  A change anywhere before a marker invalidates the cache from that
  point forward, so the ordering MUST be deterministic. `validate!/1`
  is called as the last step of an adapter's `build_body/3` and raises
  if the assembled body violates the contract.

  This PR ships the **Anthropic body-shape signature only**. The
  Anthropic Messages API body keeps `system` and `tools` as distinct
  top-level fields and `messages` as the conversation list, so the
  Anthropic check is structural: the three fields exist with the
  right types, and the `messages` list places its fresh input last
  (no historical message follows a fresh user input).

  Extension to other adapters (OpenAI-Chat-wire, Bedrock, Gemini) is
  a deferred follow-up — each needs a shape adapter or a per-provider
  validator. See SPEC-PROMPT-CACHING §8.
  """

  @typedoc """
  The Anthropic-shaped body fragment `validate!/1` inspects.

  `system` is `nil`, a string, or a block-array; `tools` is `nil` or
  a list of tool-spec maps; `messages` is the conversation list of
  `%{role: ..., content: ...}` maps in oldest-first order.
  """
  @type anthropic_body :: %{
          required(:system) => nil | String.t() | [map()],
          required(:tools) => nil | [map()],
          required(:messages) => [map()],
          optional(any()) => any()
        }

  @doc """
  Validates the canonical ordering of an Anthropic-shaped request body.

  Returns `:ok` when the body is ordering-compliant. Raises
  `ArgumentError` otherwise — an ordering violation is a programming
  error in `build_body/3`, never user input, so raising is correct.

  Violations detected:

    * `:system` / `:tools` / `:messages` keys absent.
    * `:system` not `nil`, a string, or a list.
    * `:tools` not `nil` or a list.
    * `:messages` not a list.
    * a non-`"user"` message appearing *after* the last `"user"`
      message — the fresh input MUST be the final message; any
      assistant/tool turn after it breaks the stable-prefix contract.
  """
  @spec validate!(anthropic_body()) :: :ok | no_return()
  def validate!(%{} = body) do
    unless Map.has_key?(body, :system) and Map.has_key?(body, :tools) and
             Map.has_key?(body, :messages) do
      raise ArgumentError,
            "OrderingCheck: body must carry :system, :tools and :messages keys; got #{inspect(Map.keys(body))}"
    end

    check_system!(body.system)
    check_tools!(body.tools)
    check_messages!(body.messages)
    :ok
  end

  def validate!(other) do
    raise ArgumentError, "OrderingCheck: expected a body map; got #{inspect(other)}"
  end

  defp check_system!(nil), do: :ok
  defp check_system!(s) when is_binary(s), do: :ok
  defp check_system!(s) when is_list(s), do: :ok

  defp check_system!(other) do
    raise ArgumentError,
          "OrderingCheck: :system must be nil, a string or a block list; got #{inspect(other)}"
  end

  defp check_tools!(nil), do: :ok
  defp check_tools!(t) when is_list(t), do: :ok

  defp check_tools!(other) do
    raise ArgumentError, "OrderingCheck: :tools must be nil or a list; got #{inspect(other)}"
  end

  defp check_messages!(messages) when is_list(messages) do
    last_user_index =
      messages
      |> Enum.with_index()
      |> Enum.reduce(-1, fn {msg, idx}, acc ->
        if message_role(msg) == "user", do: idx, else: acc
      end)

    # Every message *after* the last user message must not exist:
    # the fresh user/tool-result input is always the final message,
    # so a non-user message trailing it violates the stable prefix.
    if last_user_index >= 0 and last_user_index < length(messages) - 1 do
      raise ArgumentError,
            "OrderingCheck: fresh user input must be the last message; " <>
              "found a non-user message after index #{last_user_index}"
    end

    :ok
  end

  defp check_messages!(other) do
    raise ArgumentError, "OrderingCheck: :messages must be a list; got #{inspect(other)}"
  end

  defp message_role(%{role: r}), do: r
  defp message_role(%{"role" => r}), do: r
  defp message_role(_), do: nil
end
