defmodule Tau.Tools.Builtin.Read do
  @moduledoc """
  Read a file (text or image) and return its contents.

  Truncates at 1000 lines or 32 KiB, whichever is smaller. 1-indexed
  `:offset` and `:limit` enable continuation reads. Image files
  (PNG/JPG/GIF/WEBP) are returned as base64 image content blocks; the
  caller (assembler/provider) decides whether to downgrade to a text
  placeholder for non-vision models.
  """

  @behaviour Tau.Tool

  alias Tau.Tool.Result

  @max_lines 1000
  @max_bytes 32 * 1024

  @impl Tau.Tool
  def name, do: "Read"

  @impl Tau.Tool
  def description,
    do:
      "Read a file from the local filesystem. Returns text contents (truncated at 1000 lines or 32 KiB). Image files (png/jpg/gif/webp) are returned as image blocks for vision-capable models."

  @impl Tau.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path to the file (relative to cwd or absolute)"
        },
        "offset" => %{
          "type" => "integer",
          "description" => "1-indexed line to start reading from",
          "minimum" => 1
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of lines to return",
          "minimum" => 1
        }
      },
      "required" => ["path"],
      "additionalProperties" => false
    }
  end

  @impl Tau.Tool
  def execution_mode, do: :parallel

  @impl Tau.Tool
  def execute(%{"path" => path} = params, ctx) do
    full = ctx.operations.resolve(path, ctx.cwd)
    offset = params["offset"]
    limit = params["limit"]

    case ctx.operations.read(full) do
      {:ok, bin} -> finalize(bin, full, offset, limit)
      {:error, :enoent} -> {:ok, Result.error("File not found: #{full}")}
      {:error, posix} -> {:ok, Result.error("Read failed: #{inspect(posix)}")}
    end
  end

  defp finalize(bin, full, offset, limit) do
    cond do
      image?(full) ->
        media_type = guess_image_type(full)
        block = %{type: :image, data: bin, media_type: media_type}

        {:ok,
         %Result{
           content: [block],
           details: %{kind: :image, bytes: byte_size(bin), media_type: media_type}
         }}

      true ->
        text_finalize(bin, offset, limit)
    end
  end

  defp text_finalize(bin, offset, limit) do
    lines = String.split(bin, "\n")
    total = length(lines)

    {start_idx, end_idx} = window(total, offset, limit)
    selected = Enum.slice(lines, start_idx, end_idx - start_idx + 1)

    {selected, truncated?, byte_count} = enforce_byte_cap(selected)

    body = Enum.join(selected, "\n")

    {:ok,
     %Result{
       content: body,
       details: %{
         kind: :text,
         total_lines: total,
         start_line: start_idx + 1,
         end_line: start_idx + length(selected),
         bytes: byte_count,
         truncated?: truncated? or end_idx + 1 < total
       }
     }}
  end

  defp window(total, nil, nil), do: {0, min(@max_lines, total) - 1}

  defp window(total, offset, nil),
    do: {clamp(offset - 1, 0, max(total - 1, 0)), min(offset - 1 + @max_lines, total) - 1}

  defp window(total, nil, limit), do: {0, Enum.min([limit, @max_lines, total]) - 1}

  defp window(total, offset, limit) do
    {clamp(offset - 1, 0, max(total - 1, 0)), min(offset - 1 + min(limit, @max_lines), total) - 1}
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp enforce_byte_cap(lines) do
    {kept, total_bytes, truncated?} =
      Enum.reduce_while(lines, {[], 0, false}, fn line, {acc, bytes, _} ->
        line_bytes = byte_size(line) + 1

        if bytes + line_bytes > @max_bytes do
          {:halt, {acc, bytes, true}}
        else
          {:cont, {[line | acc], bytes + line_bytes, false}}
        end
      end)

    {Enum.reverse(kept), truncated?, total_bytes}
  end

  defp image?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in ~w(.png .jpg .jpeg .gif .webp)
  end

  defp guess_image_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end
end
