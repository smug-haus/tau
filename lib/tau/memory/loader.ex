defmodule Tau.Memory.Loader do
  @moduledoc """
  Loads `TAU.md` (and `CLAUDE.md` via `@import`) memory files.

  The cascade walks from `cwd` up to the git root collecting `TAU.md` at
  each level, plus `~/.tau/TAU.md`. Imports of the form `@path/to/file.md`
  (or `@~/shared.md`) are resolved recursively, max depth 5, cycle-detected
  via a canonicalised path set.

  Per-file cap: 25 KiB / 200 lines, enforced **post-import**.
  """

  @max_bytes 25 * 1024
  @max_lines 200
  @max_depth 5

  @doc """
  Load the cascade for `cwd`.

  Returns `[{path, body}, ...]` in cascade order (root → leaf), with
  imports already resolved and caps enforced.
  """
  @spec load(Path.t()) :: [{Path.t(), binary()}]
  def load(cwd) do
    home = System.user_home!() || "."
    candidates = ascend(cwd, []) ++ [Path.join(home, ".tau/TAU.md")]

    candidates
    |> Enum.uniq()
    |> Enum.map(&load_one/1)
    |> Enum.reject(&is_nil/1)
  end

  defp ascend(dir, acc) do
    candidate = Path.join(dir, "TAU.md")
    new_acc = if File.exists?(candidate), do: [candidate | acc], else: acc

    parent = Path.dirname(dir)

    cond do
      parent == dir ->
        new_acc

      File.dir?(Path.join(dir, ".git")) ->
        [candidate | acc] |> Enum.uniq() |> Enum.filter(&File.exists?/1)

      true ->
        ascend(parent, new_acc)
    end
  end

  defp load_one(path) do
    case File.read(path) do
      {:ok, body} ->
        body = resolve_imports(body, Path.dirname(path), MapSet.new([Path.expand(path)]), 0)
        body = cap(body)
        {path, body}

      _ ->
        nil
    end
  end

  defp resolve_imports(body, _base_dir, _seen, depth) when depth >= @max_depth, do: body

  defp resolve_imports(body, base_dir, seen, depth) do
    Regex.replace(~r/(?m)^@(\S+)\s*$/, body, fn _, target ->
      resolved = expand(target, base_dir)
      canonical = Path.expand(resolved)

      if MapSet.member?(seen, canonical) do
        "<!-- import cycle: #{target} -->"
      else
        case File.read(canonical) do
          {:ok, sub_body} ->
            seen2 = MapSet.put(seen, canonical)
            resolve_imports(sub_body, Path.dirname(canonical), seen2, depth + 1)

          _ ->
            "<!-- import failed: #{target} -->"
        end
      end
    end)
  end

  defp expand("~/" <> rest, _base), do: Path.join(System.user_home!(), rest)

  defp expand(target, base) do
    if Path.type(target) == :absolute, do: target, else: Path.expand(target, base)
  end

  defp cap(body) do
    truncated_by_bytes =
      if byte_size(body) > @max_bytes, do: binary_part(body, 0, @max_bytes), else: body

    lines = String.split(truncated_by_bytes, "\n")

    if length(lines) > @max_lines do
      lines |> Enum.take(@max_lines) |> Enum.join("\n")
    else
      truncated_by_bytes
    end
  end
end
