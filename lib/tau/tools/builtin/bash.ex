defmodule Tau.Tools.Builtin.Bash do
  @moduledoc """
  Run a bash command. stdout and stderr are captured separately;
  `details.stderr_bytes` lets a caller cheaply check whether the
  command wrote to stderr without re-reading the merged blob. The
  model-facing `content` is stdout followed by stderr (merged so the
  model sees the whole output stream).

  Output is truncated at 1000 lines or 32 KiB tail-truncated; full
  output is written to `~/.tau/sessions/<id>/bash-<call_id>.log` when
  truncation fires (path returned in `details.full_output_path`).

  ## Cancellation — known limitation

  Bash runs via `Port.open/2` with `{:spawn_executable, bash}`. The
  BEAM owns only the direct child (the `bash` PID), not the
  descendant tree the script may fan out into. When a session is
  cancelled or a timeout fires, `Port.close/1` only sends `SIGTERM` to
  bash; descendants (`sleep 30 & sleep 30 & wait`, parallel `make`,
  `npm run build`, ...) survive as orphans reparented to PID 1.

  An earlier prototype used `:erlexec` to send `SIGTERM` to the whole
  process group via `setpgid` + `kill(-pgid)`. That dep was dropped
  to keep CI portable. Windows has no equivalent of process groups
  regardless — even if `:erlexec` comes back on Linux/macOS, Windows
  callers will still need an in-script `taskkill /T /PID …` wrapper
  if descendant cleanup matters.
  """

  @behaviour Tau.Tool

  alias Tau.Tool.Result

  @max_lines 1000
  @max_bytes 32 * 1024

  @impl Tau.Tool
  def name, do: "Bash"

  @impl Tau.Tool
  def description,
    do:
      "Execute a bash command. Captures combined stdout+stderr. Optional timeout in seconds. Output is tail-truncated at 1000 lines / 32 KiB."

  @impl Tau.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string"},
        "timeout" => %{"type" => "integer", "minimum" => 1, "description" => "Seconds"}
      },
      "required" => ["command"],
      "additionalProperties" => false
    }
  end

  @impl Tau.Tool
  def execution_mode, do: :sequential

  @impl Tau.Tool
  def execute(%{"command" => cmd} = params, ctx) do
    timeout_ms = if t = params["timeout"], do: t * 1000, else: nil

    case ctx.operations.bash(cmd, timeout_ms: timeout_ms, env: System.get_env()) do
      {:ok, %{stdout: out, stderr: err, exit_status: status, duration_ms: dur}} ->
        merged = merge_streams(out, err)
        {body, truncated?, full_path} = truncate(merged, ctx.session_id, ctx.tool_call_id)

        prefix =
          cond do
            status == 0 -> ""
            true -> "(exit #{status})\n"
          end

        full = prefix <> body

        {:ok,
         %Result{
           content: full,
           details: %{
             exit_status: status,
             duration_ms: dur,
             truncated?: truncated?,
             full_output_path: full_path,
             command: cmd,
             stderr_bytes: byte_size(err)
           },
           is_error: status != 0
         }}

      {:error, :timeout} ->
        {:ok, Result.error("Command timed out", details: %{command: cmd, timeout_ms: timeout_ms})}

      {:error, e} ->
        {:ok, Result.error("Bash failed: #{inspect(e)}", details: %{command: cmd})}
    end
  end

  defp merge_streams(stdout, ""), do: stdout
  defp merge_streams("", stderr), do: stderr
  defp merge_streams(stdout, stderr), do: stdout <> stderr

  defp truncate(output, session_id, call_id) do
    bytes = byte_size(output)
    lines = String.split(output, "\n")
    line_count = length(lines)

    cond do
      bytes <= @max_bytes and line_count <= @max_lines ->
        {output, false, nil}

      true ->
        full_path = persist_full(output, session_id, call_id)
        kept_lines = Enum.take(lines, -@max_lines)
        body = Enum.join(kept_lines, "\n")

        body =
          if byte_size(body) > @max_bytes do
            <<_::binary-size(byte_size(body) - @max_bytes), tail::binary>> = body
            tail
          else
            body
          end

        marker = "[…truncated; full output: #{full_path}]\n"
        {marker <> body, true, full_path}
    end
  end

  defp persist_full(output, session_id, call_id) do
    dir =
      Tau.Settings.data_dir()
      |> Path.join("sessions")
      |> Path.join(session_id || "default")

    File.mkdir_p!(dir)
    path = Path.join(dir, "bash-#{call_id}.log")
    File.write!(path, output)
    path
  end
end
