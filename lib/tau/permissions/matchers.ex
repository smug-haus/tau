defmodule Tau.Permissions.Matchers.Always do
  @moduledoc """
  Matches any tool call for the rule's bare tool name.

  The compiled rule is the bare pattern string (e.g. `"Read"`); the
  match succeeds when `tool_name` equals that string, or when the
  pattern is `"*"` (true blanket across all tools).

  Bare-tool-name patterns deliberately do NOT match other tools — a
  rule like `allow: ["Read"]` allows `Read` only, not `Bash`. Pre-#16
  semantics. See issue #123.
  """
  @behaviour Tau.Permissions.Matcher
  @impl true
  def match?("*", _tool_name, _args, _ctx), do: true
  def match?(rule, tool_name, _args, _ctx) when is_binary(rule), do: rule == tool_name
  def match?(_, _, _, _), do: false
end

defmodule Tau.Permissions.Matchers.Glob do
  @moduledoc """
  Glob matcher. Patterns look like `Bash(npm run *)`, `Read(./*.exs)`.

  Match logic:

    * Tool name must equal the rule's tool, or pattern's tool is `*`.
    * Argument string is built per tool — Bash uses `command`, Read/Write/Edit
      use `path` — and matched against the glob with `?` and `*`.
  """
  @behaviour Tau.Permissions.Matcher

  @impl true
  def match?({tool, glob}, tool_name, args, _ctx) do
    if tool == "*" or tool == tool_name do
      arg_str = arg_for(tool_name, args)
      glob_match?(glob, arg_str)
    else
      false
    end
  end

  @doc "Trivial `*`/`?` glob matcher (no character classes)."
  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(pattern, str) do
    re = compile(pattern)
    Regex.match?(re, str)
  end

  defp arg_for("Bash", %{"command" => c}), do: c
  defp arg_for("Read", %{"path" => p}), do: p
  defp arg_for("Write", %{"path" => p}), do: p
  defp arg_for("Edit", %{"path" => p}), do: p
  defp arg_for(_, _), do: ""

  defp compile(pattern) do
    body =
      pattern
      |> String.codepoints()
      |> Enum.map_join("", fn
        "*" -> ".*"
        "?" -> "."
        c when c in [".", "^", "$", "+", "(", ")", "[", "]", "{", "}", "|", "\\"] -> "\\" <> c
        c -> c
      end)

    Regex.compile!("^" <> body <> "$")
  end
end

defmodule Tau.Permissions.Matchers.PathPrefix do
  @moduledoc "Matches when the tool argument's path is under the given prefix."
  @behaviour Tau.Permissions.Matcher

  @impl true
  def match?({tool, prefix}, tool_name, args, ctx) do
    if tool == "*" or tool == tool_name do
      path = args["path"] || ""
      cwd = ctx[:cwd] || File.cwd!()
      full = Path.expand(path, cwd)
      String.starts_with?(full, Path.expand(prefix, cwd))
    else
      false
    end
  end
end

defmodule Tau.Permissions.Matchers.Domain do
  @moduledoc "Matches when a URL argument's host matches the given domain."
  @behaviour Tau.Permissions.Matcher

  @impl true
  def match?({tool, domain}, tool_name, args, _ctx) do
    if tool == "*" or tool == tool_name do
      url = args["url"] || ""

      case URI.parse(url) do
        %URI{host: host} when is_binary(host) ->
          host == domain or String.ends_with?(host, "." <> domain)

        _ ->
          false
      end
    else
      false
    end
  end
end

defmodule Tau.Permissions.Matchers.Regex do
  @moduledoc "Matches a regex against a tool-specific argument string."
  @behaviour Tau.Permissions.Matcher

  @impl true
  def match?({tool, %Regex{} = re}, tool_name, args, _ctx) do
    if tool == "*" or tool == tool_name do
      arg_str = arg_for(tool_name, args)
      Regex.match?(re, arg_str)
    else
      false
    end
  end

  defp arg_for("Bash", %{"command" => c}), do: c
  defp arg_for(_, %{"path" => p}), do: p
  defp arg_for(_, %{"url" => u}), do: u
  defp arg_for(_, _), do: ""
end
