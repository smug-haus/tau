defmodule Tau.Tools.Operations.Local do
  @moduledoc """
  Default file/process backend for built-in tools. Operates on the local
  filesystem and spawns subprocesses via `Port`.

  This is the *only* place that touches `File`, `Path`, `:os.cmd`, and
  process spawning. Tools call into this module so a future SSH/sandboxed
  backend just needs to implement the same functions.

  ## Process-tree cancellation: known limitation

  Bash commands run via `Port.open/2` with `{:spawn_executable, bash}`.
  The BEAM only owns the direct child (the `bash` PID), not the
  descendant tree the script may fan out into (`sleep 30 & sleep 30 &
  wait`, `make -j8`, `npm run build`, ...). When `Tau.cancel/1` or a
  timeout closes the port, only `bash` is killed; surviving descendants
  become orphans reparented to PID 1.

  An earlier prototype used `:erlexec` to send `SIGTERM` to the whole
  process group via `setpgid` + `kill(-pgid)`. That dep was dropped
  during the M0–M8 cleanup to keep CI portable; restoring it is tracked
  in issue #12. Until then, callers should not assume `cancel/1` is
  sufficient for resource cleanup of long-running shell scripts on
  Linux/macOS — wrap user commands in a parent that propagates signals
  (`exec` chaining, `setsid`, or `trap`) if it matters for the use case.
  Windows has no equivalent of process groups regardless.
  """

  @doc "Read a file as binary. Returns `{:ok, binary}` or `{:error, posix}`."
  @spec read(Path.t()) :: {:ok, binary()} | {:error, term()}
  def read(path), do: File.read(path)

  @doc "Read a file's stat without raising."
  @spec stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, term()}
  def stat(path), do: File.stat(path)

  @doc """
  Atomically write a file. Creates parent dirs. Writes to `path.tmp` then
  renames; on the same filesystem this is atomic on POSIX.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, term()}
  def write(path, data) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         tmp = path <> ".tau-tmp",
         :ok <- File.write(tmp, data),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  @doc "Resolve a path relative to `cwd`. Absolute paths pass through."
  @spec resolve(Path.t(), Path.t()) :: Path.t()
  def resolve(path, cwd) do
    cond do
      Path.type(path) == :absolute -> Path.expand(path)
      true -> Path.expand(path, cwd)
    end
  end

  @doc """
  Run a shell command. Returns `{:ok, %{stdout, stderr, exit_status, duration_ms}}`
  or `{:error, term()}`.

  Stdout and stderr are captured separately. The non-empty stderr blob
  is emitted on `[:tau, :tool, :bash, :stderr]` telemetry once at the
  end (Phase 6 calls for per-chunk events; we accept the coarser
  granularity here as the cost of doing it portably without `:erlexec`
  — see the moduledoc).

  When `:timeout_ms` is set and exceeded, closes the `Port`, which sends
  `SIGTERM` to the direct child only. See the moduledoc for the
  process-tree-kill caveat.
  """
  @spec bash(String.t(), keyword()) ::
          {:ok, %{stdout: binary, stderr: binary, exit_status: integer, duration_ms: integer}}
          | {:error, term()}
  def bash(command, opts \\ []) do
    timeout = opts[:timeout_ms]
    started = System.monotonic_time(:millisecond)
    stderr_path = stderr_temp_path()
    wrapped = "{ #{command} ; } 2> #{shell_quote(stderr_path)}"

    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash")},
        [
          :binary,
          :exit_status,
          :hide,
          :use_stdio,
          {:args, ["-c", wrapped]},
          {:env, env_pairs(opts[:env] || %{})}
        ]
      )

    deadline = if timeout, do: started + timeout, else: nil

    try do
      case collect_port(port, "", deadline) do
        {:ok, stdout, status} ->
          duration = System.monotonic_time(:millisecond) - started
          stderr = read_stderr(stderr_path)
          maybe_emit_stderr_telemetry(stderr)
          {:ok, %{stdout: stdout, stderr: stderr, exit_status: status, duration_ms: duration}}

        {:error, _} = e ->
          # On timeout, bash may have written some stderr already.
          stderr = read_stderr(stderr_path)
          maybe_emit_stderr_telemetry(stderr)
          e
      end
    after
      _ = File.rm(stderr_path)
    end
  end

  defp stderr_temp_path do
    suffix = :crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "tau-bash-stderr-#{suffix}.txt")
  end

  defp shell_quote(path) do
    # Single-quote and escape any embedded single quotes. Path comes from
    # mktemp-style random bytes so this is belt-and-braces, but we keep it
    # in case future callers pass arbitrary paths.
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end

  defp read_stderr(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      _ -> ""
    end
  end

  defp maybe_emit_stderr_telemetry(""), do: :ok

  defp maybe_emit_stderr_telemetry(stderr) when is_binary(stderr) do
    :telemetry.execute(
      [:tau, :tool, :bash, :stderr],
      %{bytes: byte_size(stderr), system_time: System.system_time()},
      %{stderr: stderr}
    )
  end

  # Deadline is computed once in bash/2 and passed through unchanged
  # so the timeout's wall-clock budget doesn't drift across many
  # small chunks (#60).
  defp collect_port(port, acc, deadline) do
    receive do
      {^port, {:data, data}} ->
        collect_port(port, acc <> data, deadline)

      {^port, {:exit_status, n}} ->
        {:ok, acc, n}
    after
      remaining_or_inf(deadline) ->
        try do
          Port.close(port)
        catch
          _, _ -> :ok
        end

        {:error, :timeout}
    end
  end

  defp remaining_or_inf(nil), do: :infinity
  defp remaining_or_inf(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp env_pairs(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {to_charlist(to_string(k)), to_charlist(to_string(v))} end)
  end
end
