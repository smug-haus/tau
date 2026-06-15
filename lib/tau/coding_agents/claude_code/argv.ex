defmodule Tau.CodingAgents.ClaudeCode.Argv do
  @moduledoc """
  Pure builder for the `claude` CLI argv list.

  Kept as a tiny standalone module so tests can verify argv shape
  without spawning a subprocess. The adapter itself only consumes
  `build/2`.

  ## Shape

  Base form:

      ["-p", prompt, "--output-format", "stream-json", "--verbose"]

  Optional extensions, all opt-in via fields on `Tau.CodingAgent.task()`:

    * `--resume <id>` when `task.resume_id` is a non-empty string.
    * `--mcp-config <path>` when the caller has written a temp
      mcp-config file (the path is passed in separately because
      the adapter is responsible for the tempfile lifecycle).
    * `--allowed-tools <csv>` when `task.allowed_tools` is a list.
      `:all` (the default) omits the flag.
    * `--dangerously-skip-permissions` when `task.skip_permissions` is
      `true` (D-383). Absent or `false` omits the flag — interactive
      default-deny is retained.

  D-036: no credentials are read or injected here. The CLI inherits
  the host user's auth on its own.
  """

  @type t :: Tau.CodingAgent.task()

  @doc """
  Build the `claude` CLI argv list for `task`.

  `opts` may carry `:mcp_config_path` (a tempfile path the adapter owns).
  Returns the full argv ready to pass to `System.cmd/3`.
  """
  @spec build(t(), keyword()) :: [String.t()]
  def build(task, opts \\ []) when is_map(task) do
    prompt = Map.fetch!(task, :prompt)

    base = ["-p", to_string(prompt), "--output-format", "stream-json", "--verbose"]

    base
    |> maybe_append_resume(task)
    |> maybe_append_mcp(Keyword.get(opts, :mcp_config_path))
    |> maybe_append_allowed_tools(task)
    |> maybe_append_skip_permissions(task)
  end

  defp maybe_append_resume(argv, %{resume_id: id}) when is_binary(id) and id != "" do
    argv ++ ["--resume", id]
  end

  defp maybe_append_resume(argv, _), do: argv

  defp maybe_append_mcp(argv, nil), do: argv
  defp maybe_append_mcp(argv, ""), do: argv

  defp maybe_append_mcp(argv, path) when is_binary(path) do
    argv ++ ["--mcp-config", path]
  end

  defp maybe_append_allowed_tools(argv, %{allowed_tools: list}) when is_list(list) and list != [] do
    argv ++ ["--allowed-tools", Enum.join(list, ",")]
  end

  defp maybe_append_allowed_tools(argv, _), do: argv

  defp maybe_append_skip_permissions(argv, %{skip_permissions: true}) do
    argv ++ ["--dangerously-skip-permissions"]
  end

  defp maybe_append_skip_permissions(argv, _), do: argv
end
