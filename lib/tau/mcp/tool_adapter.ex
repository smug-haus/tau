defmodule Tau.MCP.ToolAdapter do
  @moduledoc """
  Generates one-shot `Tau.Tool`-implementing modules per discovered MCP
  tool. Each adapter forwards `execute/2` to the owning
  `Tau.MCP.Server` GenServer and translates the JSON-RPC result into a
  `Tau.Tool.Result`.

  Constructed at runtime via `Module.create/3` because each MCP tool has
  a different name, description, and JSON schema — a metaprogrammed
  module per tool keeps the rest of the harness oblivious to MCP's
  dynamism.
  """

  alias Tau.Tool.Result

  @doc """
  Build (and load) a Tau.Tool-implementing module for one MCP tool.
  """
  @spec build(module(), String.t(), String.t(), String.t(), map()) :: module()
  def build(mod_name, server_name, namespaced_name, description, parameters) do
    body =
      quote do
        @behaviour Tau.Tool

        @impl true
        def name, do: unquote(namespaced_name)

        @impl true
        def description, do: unquote(description)

        @impl true
        def parameters, do: unquote(Macro.escape(parameters))

        @impl true
        def execution_mode, do: :parallel

        @impl true
        def execute(params, _ctx) do
          tool_local_name =
            unquote(namespaced_name)
            |> String.replace_prefix("mcp__#{unquote(server_name)}__", "")

          Tau.MCP.ToolAdapter.invoke_remote(unquote(server_name), tool_local_name, params)
        end
      end

    Module.create(mod_name, body, Macro.Env.location(__ENV__))
    mod_name
  end

  @doc false
  def invoke_remote(server_name, tool_name, params) do
    case Tau.MCP.Server.invoke(server_name, tool_name, params || %{}) do
      {:ok, %{"content" => blocks} = res} ->
        {:ok,
         %Result{
           content: render_blocks(blocks),
           details: Map.delete(res, "content"),
           is_error: Map.get(res, "isError", false)
         }}

      {:ok, other} ->
        {:ok, %Result{content: inspect(other), details: %{}}}

      {:error, err} ->
        {:ok, %Result{content: "MCP error: #{inspect(err)}", is_error: true}}
    end
  end

  defp render_blocks(blocks) when is_list(blocks) do
    blocks
    |> Enum.map_join("\n", fn
      %{"type" => "text", "text" => t} -> t
      %{"type" => "image"} -> "(image content omitted)"
      other -> inspect(other)
    end)
  end

  defp render_blocks(other), do: inspect(other)
end
