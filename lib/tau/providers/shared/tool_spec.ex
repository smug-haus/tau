defmodule Tau.Providers.Shared.ToolSpec do
  @moduledoc """
  Pure cross-provider tool-schema normaliser.

  Each provider expects a different on-the-wire shape for tool/function
  declarations:

    * Anthropic — `%{name, description, input_schema}`
    * OpenAI Chat — `%{type: "function", function: %{name, description, parameters}}`
    * OpenAI Responses — `%{type: "function", name, description, parameters}`
    * Gemini — `%{name, description, parameters}` after a JSON-Schema
      down-shift (see `Tau.Providers.Shared.ToolSpec.GeminiSubset`)
    * Bedrock — Anthropic-on-Bedrock uses the Anthropic shape

  Callers (notably each provider's `build_body/*`) hand `adapt/2` a list
  whose elements are either `Tau.Tool` modules or already-normalised
  maps with `:name`/`:description`/`:parameters` keys. The helper
  produces the provider-native shape; `nil` and `[]` pass through as
  themselves so callers can keep the "omit when absent" pattern.

  Pure module — no processes, no side effects beyond a single
  `Logger.warning/2` from the Gemini down-shifter on lossy input.
  """

  alias Tau.Providers.Shared.ToolSpec.GeminiSubset

  @typedoc """
  Either a `Tau.Tool` implementation module or a raw map carrying
  `:name`, `:description`, and `:parameters` keys (string keys also
  accepted).
  """
  @type tool_input :: module() | map()

  @doc """
  Adapt a list of tool inputs to `provider`'s native tool-spec shape.

  Returns `nil` when given `nil`, `[]` when given `[]`, otherwise a
  list of provider-native maps.
  """
  @spec adapt([tool_input()] | nil, module()) :: [map()] | nil
  def adapt(nil, _provider), do: nil
  def adapt([], _provider), do: []

  def adapt(tools, provider) when is_list(tools) and is_atom(provider) do
    tools
    |> Enum.map(&extract/1)
    |> Enum.map(&shape(&1, provider))
  end

  # --- generic-form extraction ---------------------------------------------

  # Modules implementing Tau.Tool — pull canonical fields from callbacks.
  defp extract(mod) when is_atom(mod) do
    %{
      name: mod.name(),
      description: mod.description(),
      parameters: mod.parameters()
    }
  end

  # Already-normalised maps. Accept both atom and string keys; output
  # is always atom-keyed so downstream pattern matching is uniform.
  defp extract(%{} = map) do
    %{
      name: fetch(map, :name),
      description: fetch(map, :description),
      parameters: fetch(map, :parameters)
    }
  end

  defp fetch(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  # --- per-provider shaping -------------------------------------------------

  defp shape(generic, Tau.Providers.Anthropic), do: anthropic_shape(generic)

  defp shape(%{name: n, description: d, parameters: p}, Tau.Providers.OpenAI.Chat) do
    %{type: "function", function: %{name: n, description: d, parameters: p}}
  end

  defp shape(%{name: n, description: d, parameters: p}, Tau.Providers.OpenAI.Responses) do
    %{type: "function", name: n, description: d, parameters: p}
  end

  # OpenAI-compatible providers — same Chat Completions wire shape.
  # Enumerated explicitly (no blanket catch-all) so that a genuinely
  # unknown provider still raises `FunctionClauseError` rather than
  # silently producing a malformed tool spec.
  # Each future OpenAI-compatible provider PR adds its own clause here.
  defp shape(%{name: n, description: d, parameters: p}, Tau.Providers.DeepSeek) do
    %{type: "function", function: %{name: n, description: d, parameters: p}}
  end

  defp shape(%{name: n, description: d, parameters: p}, Tau.Providers.Groq) do
    %{type: "function", function: %{name: n, description: d, parameters: p}}
  end

  defp shape(%{name: n, description: d, parameters: p}, Tau.Providers.Mistral) do
    %{type: "function", function: %{name: n, description: d, parameters: p}}
  end

  defp shape(%{name: n, description: d, parameters: p}, Tau.Providers.Gemini) do
    %{name: n, description: d, parameters: GeminiSubset.downshift(p)}
  end

  # Bedrock: today, only Anthropic-on-Bedrock is wired up (see
  # Tau.Providers.Bedrock @moduledoc). Mirror Anthropic's shape;
  # additional inner-model branches can dispatch on `opts[:model]` here
  # when added.
  defp shape(generic, Tau.Providers.Bedrock), do: anthropic_shape(generic)

  defp anthropic_shape(%{name: n, description: d, parameters: p}) do
    %{name: n, description: d, input_schema: p}
  end
end
