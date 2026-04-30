defmodule Tau.Skills.Frontmatter do
  @moduledoc """
  Parse YAML-ish front-matter from a `SKILL.md` file.

      ---
      name: deploy
      description: Deploy the application
      allowed-tools: Bash(npm run build) Bash(git push)
      disable-model-invocation: true
      paths:
        - "src/**/*.ts"
      ---

      # Deploy

      Body of the skill in markdown follows.

  We don't pull in a full YAML parser — we only need a small, predictable
  subset (key: value scalars + simple list-of-strings). Unknown keys are
  preserved as strings.
  """

  @doc """
  Parse a front-matter block. Returns `{frontmatter_map, body_string}`.
  Files without front-matter return `{%{}, body}`.
  """
  @spec parse(binary()) :: {map(), binary()}
  def parse(<<"---\n", rest::binary>>), do: split_and_parse(rest)
  def parse(<<"---\r\n", rest::binary>>), do: split_and_parse(rest)
  def parse(body), do: {%{}, body}

  defp split_and_parse(rest) do
    case :binary.split(rest, ["\n---\n", "\r\n---\r\n", "\n---"]) do
      [fm, body] -> {parse_block(fm), body}
      [_only] -> {%{}, rest}
    end
  end

  defp parse_block(block) do
    block
    |> String.split("\n")
    |> parse_lines(%{}, nil)
  end

  defp parse_lines([], acc, _list_key), do: acc

  defp parse_lines([line | rest], acc, list_key) do
    cond do
      String.match?(line, ~r/^\s*-\s+/) and is_binary(list_key) ->
        item = Regex.replace(~r/^\s*-\s+/, line, "") |> String.trim() |> dequote()
        list = Map.get(acc, list_key, [])
        parse_lines(rest, Map.put(acc, list_key, list ++ [item]), list_key)

      String.match?(line, ~r/^[A-Za-z][A-Za-z0-9_\-]*:/) ->
        [k, v] = String.split(line, ":", parts: 2)
        key = String.trim(k)
        v = String.trim(v)

        cond do
          v == "" -> parse_lines(rest, Map.put(acc, key, []), key)
          v == "true" -> parse_lines(rest, Map.put(acc, key, true), nil)
          v == "false" -> parse_lines(rest, Map.put(acc, key, false), nil)
          true -> parse_lines(rest, Map.put(acc, key, dequote(v)), nil)
        end

      String.trim(line) == "" ->
        parse_lines(rest, acc, list_key)

      true ->
        parse_lines(rest, acc, list_key)
    end
  end

  defp dequote(<<"\"", _::binary>> = s) do
    s |> String.trim_leading("\"") |> String.trim_trailing("\"")
  end

  defp dequote(<<"'", _::binary>> = s) do
    s |> String.trim_leading("'") |> String.trim_trailing("'")
  end

  defp dequote(s), do: s
end
