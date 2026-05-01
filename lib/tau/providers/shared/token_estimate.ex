defmodule Tau.Providers.Shared.TokenEstimate do
  @moduledoc """
  Cheap pre-flight token estimate shared across providers.

  Used by the rate limiter (ADR-0011) to take a TPM permit before the
  HTTP send — we don't have a real tokenizer integrated yet, and pulling
  one in (tiktoken, gpt-tokenizer) is a dependency decision that #39
  intentionally defers. The heuristic is `byte_size(text) / 4` summed
  over every string-shaped piece of every message, which is within
  ~30% of real for English prose and is fine for budget gating where
  the upstream API has the final say (and we react to its 429s).

  A future PR can swap this for a real tokenizer without touching
  callers — the contract is "given messages, return non_neg_integer()".
  """

  alias Tau.Message.{Assistant, ToolResult, User}

  @bytes_per_token 4

  @doc """
  Estimate the token cost of a list of messages.

  Walks every `User`, `Assistant`, and `ToolResult` and sums the byte
  size of every string content piece. Image data is *not* counted
  (image tokenisation is wildly model-specific; the rate limiter
  cares about RPM more than TPM here, and TPM is advisory).
  """
  @spec estimate([term()]) :: non_neg_integer()
  def estimate(messages) when is_list(messages) do
    bytes = Enum.reduce(messages, 0, &(&2 + bytes_in(&1)))
    div(bytes, @bytes_per_token)
  end

  def estimate(_), do: 0

  defp bytes_in(%User{content: c}), do: bytes_in_content(c)
  defp bytes_in(%Assistant{content: c}), do: bytes_in_content(c)
  defp bytes_in(%ToolResult{content: c}), do: bytes_in_content(c)
  defp bytes_in(s) when is_binary(s), do: byte_size(s)
  defp bytes_in(_), do: 0

  defp bytes_in_content(s) when is_binary(s), do: byte_size(s)

  defp bytes_in_content(blocks) when is_list(blocks) do
    Enum.reduce(blocks, 0, fn b, acc -> acc + bytes_in_block(b) end)
  end

  defp bytes_in_content(_), do: 0

  defp bytes_in_block(%{type: :text, text: t}) when is_binary(t), do: byte_size(t)
  defp bytes_in_block(%{type: :thinking, text: t}) when is_binary(t), do: byte_size(t)

  defp bytes_in_block(%{type: :tool_call, name: n, arguments: a}) do
    name_bytes = if is_binary(n), do: byte_size(n), else: 0
    args_bytes = if is_map(a), do: byte_size(Jason.encode!(a)), else: 0
    name_bytes + args_bytes
  end

  defp bytes_in_block(_), do: 0
end
