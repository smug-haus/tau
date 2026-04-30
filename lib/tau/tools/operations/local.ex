defmodule Tau.Tools.Operations.Local do
  @moduledoc """
  Default file/process backend for built-in tools. Operates on the local
  filesystem and spawns subprocesses via `Port` (Bash falls back to
  `:erlexec` for proper process-tree kill when available).

  This is the *only* place that touches `File`, `Path`, `:os.cmd`, and
  process spawning. Tools call into this module so a future SSH/sandboxed
  backend just needs to implement the same functions.
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

  When `:timeout_ms` is set and exceeded, kills the entire process group
  (via `:erlexec` if loaded, otherwise via `Port.close/1`).
  """
  @spec bash(String.t(), keyword()) ::
          {:ok, %{stdout: binary, stderr: binary, exit_status: integer, duration_ms: integer}}
          | {:error, term()}
  def bash(command, opts \\ []) do
    timeout = opts[:timeout_ms]
    started = System.monotonic_time(:millisecond)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          :use_stdio,
          {:args, ["-c", command]},
          {:env, env_pairs(opts[:env] || %{})}
        ]
      )

    case collect_port(port, "", timeout) do
      {:ok, output, status} ->
        duration = System.monotonic_time(:millisecond) - started
        {:ok, %{stdout: output, stderr: "", exit_status: status, duration_ms: duration}}

      {:error, _} = e ->
        e
    end
  end

  defp collect_port(port, acc, timeout) do
    deadline = if timeout, do: System.monotonic_time(:millisecond) + timeout, else: nil

    receive do
      {^port, {:data, data}} ->
        collect_port(port, acc <> data, remaining(deadline))

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

  defp remaining(nil), do: nil

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp remaining_or_inf(nil), do: :infinity
  defp remaining_or_inf(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp env_pairs(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {to_charlist(to_string(k)), to_charlist(to_string(v))} end)
  end
end
