defmodule Tau.Commands.Builtin.Export do
  @moduledoc """
  Built-in `/export [format]` command.

  Writes the session transcript to `$TAU_DATA_DIR/exports/<session_id>.<ext>`.
  Supported formats: `jsonl` (default), `html`.

  The file write is fire-and-forget under `Tau.Tools.TaskSupervisor`; the FSM
  is never blocked.  The spawned task broadcasts a follow-up
  `%Tau.Session.Events.SystemNotice{}` with the output path once the write
  completes.

  Immediate return values:
  - `{:notice, "Exporting..."}` — write dispatched.
  - `{:error, "Unknown export format: <fmt>"}` — unrecognised format; no write.

  No provider turn is started (D-042).

  ## Format details

  - **jsonl**: one JSON object per message, schema `{role, content, timestamp}`.
    Each `content` entry preserves the block map as-is.
  - **html**: a minimal self-contained HTML document with pre-formatted turns.
    Intended for reading in a browser; not a styled transcript viewer.
  """

  @behaviour Tau.Commands.Builtin

  alias Tau.Message.{Assistant, ToolResult, User}
  alias Tau.Session.Events

  @supported_formats ~w[jsonl html]

  @impl Tau.Commands.Builtin
  def name, do: "/export"

  @impl Tau.Commands.Builtin
  def run(args, data) do
    format = args |> String.trim() |> normalise_format()

    if format in @supported_formats do
      dispatch_export(format, data)
      {:notice, "Exporting..."}
    else
      {:error, "Unknown export format: #{format}"}
    end
  end

  defp normalise_format(""), do: "jsonl"
  defp normalise_format(f), do: String.downcase(f)

  defp dispatch_export(format, data) do
    session_id = data.id
    messages = data.messages || []
    ext = format

    Task.Supervisor.start_child(Tau.Tools.TaskSupervisor, fn ->
      export_dir = Path.join(Tau.Settings.data_dir(), "exports")
      File.mkdir_p!(export_dir)

      filename = "#{session_id}.#{ext}"
      path = Path.join(export_dir, filename)

      body = render(format, session_id, messages)
      File.write!(path, body)

      Phoenix.PubSub.broadcast(
        Tau.PubSub,
        "session:#{session_id}",
        %Events.SystemNotice{session_id: session_id, text: "Export written to: #{path}"}
      )
    end)
  end

  # --- Renderers (grouped together) ---

  defp render("jsonl", _session_id, messages) do
    messages
    |> Enum.map(&message_to_jsonl_map/1)
    |> Enum.map_join("\n", &Jason.encode!/1)
  end

  defp render("html", session_id, messages) do
    turns = Enum.map_join(messages, "\n", &message_to_html/1)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <title>Tau session #{session_id}</title>
      <style>
        body { font-family: monospace; max-width: 900px; margin: 2rem auto; padding: 0 1rem; }
        .turn { margin: 1.5rem 0; padding: 1rem; border-left: 4px solid #ccc; white-space: pre-wrap; }
        .turn.user { border-color: #4a90e2; }
        .turn.assistant { border-color: #7ed321; }
        .turn.tool_result { border-color: #f5a623; }
        .role { font-weight: bold; margin-bottom: 0.5rem; font-size: 0.85em; text-transform: uppercase; color: #666; }
      </style>
    </head>
    <body>
      <h1>Session: #{session_id}</h1>
    #{turns}
    </body>
    </html>
    """
  end

  # --- JSONL helpers ---

  defp message_to_jsonl_map(%User{content: content, timestamp: ts}) do
    %{role: "user", content: content, timestamp: DateTime.to_iso8601(ts)}
  end

  defp message_to_jsonl_map(%Assistant{content: content, timestamp: ts}) do
    %{role: "assistant", content: content, timestamp: DateTime.to_iso8601(ts)}
  end

  defp message_to_jsonl_map(%ToolResult{tool_name: name, content: content, timestamp: ts}) do
    %{role: "tool_result", tool_name: name, content: content, timestamp: DateTime.to_iso8601(ts)}
  end

  # --- HTML helpers ---

  defp message_to_html(%User{content: content}) do
    text = extract_html_text(content)
    "<div class=\"turn user\"><div class=\"role\">User</div>#{html_escape(text)}</div>"
  end

  defp message_to_html(%Assistant{content: content}) do
    text = extract_html_text(content)
    "<div class=\"turn assistant\"><div class=\"role\">Assistant</div>#{html_escape(text)}</div>"
  end

  defp message_to_html(%ToolResult{tool_name: name, content: content}) do
    text = extract_html_text(content)

    "<div class=\"turn tool_result\"><div class=\"role\">Tool result: #{html_escape(name)}</div>#{html_escape(text)}</div>"
  end

  defp extract_html_text(content) when is_binary(content), do: content

  defp extract_html_text(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%{type: :text}, &1))
    |> Enum.map_join("\n", & &1.text)
  end

  defp extract_html_text(_), do: ""

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
