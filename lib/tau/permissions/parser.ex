defmodule Tau.Permissions.Parser do
  @moduledoc """
  Pure compiler from settings-shape string rules into the
  `{decision, matcher, compiled_rule}` triples consumed by
  `Tau.Permissions.Evaluator`.

  Settings layout:

      "permissions": {
        "allow": ["Read", "Bash(npm run *)", "WebFetch(domain:github.com)"],
        "deny":  ["Bash(rm *)", "Read(path:./.env)"],
        "ask":   ["Write"]
      }

  Sugars:

    * Bare tool name (e.g. `"Read"`) → `{:always, "Read"}`
    * `Tool(glob)`                   → `{:glob, "Tool", glob}`
    * `Tool(domain:host.com)`        → `{:domain, "Tool", "host.com"}`
    * `Tool(path:./prefix)`          → `{:path_prefix, "Tool", "./prefix"}`
    * `Tool(re:pattern)`             → `{:regex, "Tool", ~r/pattern/}`
  """

  @doc """
  Compile a permissions block (`%{allow: [...], deny: [...], ask: [...]}`)
  into a list of `{decision, matcher_module, compiled_rule}` triples.
  """
  @spec compile(map()) :: [{atom(), module(), term()}]
  def compile(perms) when is_map(perms) do
    [
      {:deny, Map.get(perms, :deny, []) ++ Map.get(perms, "deny", [])},
      {:ask, Map.get(perms, :ask, []) ++ Map.get(perms, "ask", [])},
      {:allow, Map.get(perms, :allow, []) ++ Map.get(perms, "allow", [])}
    ]
    |> Enum.flat_map(fn {decision, list} ->
      list
      |> Enum.map(&parse(decision, &1))
      |> Enum.reject(&is_nil/1)
    end)
  end

  def compile(_), do: []

  defp parse(decision, pattern) when is_binary(pattern) do
    case Regex.run(~r/^([A-Za-z][A-Za-z0-9_]*)\((.*)\)$/, pattern) do
      [_, tool, body] -> compile_inner(decision, tool, body)
      nil -> {decision, Tau.Permissions.Matchers.Always, pattern}
    end
  end

  defp parse(_decision, _other), do: nil

  defp compile_inner(decision, tool, "domain:" <> dom),
    do: {decision, Tau.Permissions.Matchers.Domain, {tool, dom}}

  defp compile_inner(decision, tool, "path:" <> prefix),
    do: {decision, Tau.Permissions.Matchers.PathPrefix, {tool, prefix}}

  defp compile_inner(decision, tool, "re:" <> re_src) do
    case Regex.compile(re_src) do
      {:ok, re} -> {decision, Tau.Permissions.Matchers.Regex, {tool, re}}
      _ -> nil
    end
  end

  defp compile_inner(decision, tool, glob),
    do: {decision, Tau.Permissions.Matchers.Glob, {tool, glob}}
end
