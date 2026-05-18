defmodule Tau.Commands.Builtin.Copy do
  @moduledoc """
  Built-in `/copy` command.

  Copies the last assistant message's text to the system clipboard.
  Finds the last `%Tau.Message.Assistant{}` in `data.messages`, concatenates
  its `:text`-typed content blocks, and writes the result to the platform
  clipboard tool (`pbcopy` on macOS, `xclip -selection clipboard` on Linux,
  `clip.exe` on WSL/Windows).

  The clipboard write is fire-and-forget under `Tau.Tools.TaskSupervisor` —
  it never blocks the FSM.  The immediate return is `{:notice, …}` or
  `{:error, …}`; no provider turn is started (D-042).

  ## Headless decision

  When no clipboard tool is found on PATH, the command returns
  `{:error, "Clipboard unavailable in this environment."}` rather than
  crashing or printing to stdout.  This is the safest default for headless
  / SSH / CI contexts.  A future command-option (e.g. `/copy --stdout`)
  could add a plain-text fallback if needed.
  """

  @behaviour Tau.Commands.Builtin

  alias Tau.Message.Assistant

  @clipboard_tools [
    {"pbcopy", ["pbcopy"]},
    {"xclip", ["xclip", "-selection", "clipboard"]},
    {"xsel", ["xsel", "--clipboard", "--input"]},
    {"clip.exe", ["clip.exe"]}
  ]

  @impl Tau.Commands.Builtin
  def name, do: "/copy"

  @impl Tau.Commands.Builtin
  def run(_args, data) do
    case last_assistant_text(data) do
      nil ->
        {:error, "No assistant message to copy."}

      "" ->
        {:error, "No assistant message to copy."}

      text ->
        case find_clipboard_tool() do
          nil ->
            {:error, "Clipboard unavailable in this environment."}

          argv ->
            session_id = data.id
            _pid = fire_clipboard_write(text, argv, session_id)
            {:notice, "Copied last assistant message to clipboard."}
        end
    end
  end

  # Returns the concatenated text of all :text blocks in the last
  # Assistant message, or nil if no Assistant message exists.
  defp last_assistant_text(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.filter(&match?(%Assistant{}, &1))
    |> List.last()
    |> case do
      nil -> nil
      %Assistant{content: content} -> extract_text(content)
    end
  end

  defp last_assistant_text(_), do: nil

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%{type: :text}, &1))
    |> Enum.map_join("", & &1.text)
  end

  defp extract_text(_), do: ""

  defp find_clipboard_tool do
    Enum.find_value(@clipboard_tools, fn {bin, argv} ->
      case System.find_executable(bin) do
        nil -> nil
        _ -> argv
      end
    end)
  end

  defp fire_clipboard_write(text, argv, _session_id) do
    [cmd | args] = argv

    Task.Supervisor.start_child(Tau.Tools.TaskSupervisor, fn ->
      try do
        System.cmd(cmd, args, input: text, stderr_to_stdout: true)
      rescue
        _ -> :error
      end
    end)
  end
end
