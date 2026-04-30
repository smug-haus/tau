defmodule Tau.Tools.Builtin.Write do
  @moduledoc """
  Atomically write a file. Creates parent directories.

  Overwrites existing files without prompting — permission gating happens
  at the `Tau.Permissions` layer, not in the tool.
  """

  @behaviour Tau.Tool

  alias Tau.Tool.Result

  @impl Tau.Tool
  def name, do: "Write"

  @impl Tau.Tool
  def description,
    do: "Write content to a file. Creates parent directories. Overwrites existing files."

  @impl Tau.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "content" => %{"type" => "string"}
      },
      "required" => ["path", "content"],
      "additionalProperties" => false
    }
  end

  @impl Tau.Tool
  def execution_mode, do: :sequential

  @impl Tau.Tool
  def execute(%{"path" => path, "content" => content}, ctx) do
    full = ctx.operations.resolve(path, ctx.cwd)
    bytes = byte_size(content)

    case ctx.operations.write(full, content) do
      :ok ->
        {:ok, Result.text("Wrote #{bytes} bytes to #{full}", details: %{path: full, bytes: bytes})}

      {:error, e} ->
        {:ok, Result.error("Write failed: #{inspect(e)}")}
    end
  end
end
