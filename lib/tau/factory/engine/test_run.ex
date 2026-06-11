defmodule Tau.Factory.Engine.TestRun do
  @moduledoc """
  Engine component C6: executes a `%Tau.Toolchain.TestDescriptor{}` as a
  subprocess, captures the artifact it writes, and parses that artifact via
  `Tau.Toolchain.ReportParser` — returning an engine-produced
  `%Tau.Toolchain.TestReport{}`.

  ## HR-3 anti-gaming contract (SPEC-FACTORY-GATE §4 B4/B5, D-354)

  The verdict comes EXCLUSIVELY from parsing the artifact file. Any field the
  adapter (descriptor) may carry — `__adapter_verdict__`, `__adapter_result__`,
  or any other key beyond the four canonical ones (`argv`, `env`, `report`,
  `artifact`) — is IGNORED. The engine reads only:

    1. `descriptor.argv`     — the command to run.
    2. `descriptor.env`      — environment variables for the subprocess.
    3. `descriptor.report`   — format tag selecting the trusted parser.
    4. `descriptor.artifact` — relative path to the output file.

  The `ReportParser` is engine-owned (trusted); the adapter never supplies a
  parser or a pre-computed result.

  ## Subprocess execution

  Uses `System.cmd/3` for one-shot capture (stdout + stderr captured, not
  streamed). The subprocess receives an expanded environment containing both
  the inherited process env and the descriptor's `:env` map. The artifact path
  is resolved relative to `workspace_dir`; if absent after the recipe exits,
  `execute/2` returns `{:error, :artifact_missing}`.

  ## Return

    * `{:ok, %TestReport{}}` — artifact read and parsed successfully.
    * `{:error, reason}`     — recipe failed to start, crashed, or the artifact
      was absent. Reason is a tagged atom or tuple; never a fabricated pass.
  """

  alias Tau.Toolchain.ReportParser
  alias Tau.Toolchain.TestReport

  @doc """
  Execute `descriptor` in `workspace_dir`, parse the artifact, return a report.

  The second argument is an absolute path to the workspace directory. The
  descriptor's `:artifact` field is a relative path within that directory.
  """
  @spec execute(map(), String.t()) :: {:ok, TestReport.t()} | {:error, term()}
  def execute(descriptor, workspace_dir) when is_binary(workspace_dir) do
    [cmd | args] = descriptor.argv
    env_list = build_env(descriptor.env)

    opts = [
      env: env_list,
      cd: workspace_dir,
      stderr_to_stdout: true
    ]

    case System.cmd(cmd, args, opts) do
      {_output, _exit_code} ->
        # We do not check exit_code — the artifact is the truth (HR-3).
        # A recipe that writes a correct artifact and exits non-zero is still
        # valid (e.g. mix test exits 1 when tests fail but the report is written).
        artifact_path = Path.join(workspace_dir, descriptor.artifact)
        read_and_parse(artifact_path, descriptor.report)
    end
  rescue
    e in ErlangError ->
      # System.cmd raises ErlangError when the executable is not found.
      {:error, {:exec_failed, e.original}}

    _ ->
      {:error, :exec_failed}
  catch
    _, _ ->
      {:error, :exec_failed}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_env(env_map) when is_map(env_map) do
    Enum.map(env_map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp build_env(_), do: []

  defp read_and_parse(artifact_path, format_tag) do
    case File.read(artifact_path) do
      {:ok, bytes} ->
        report = ReportParser.parse(bytes, format_tag)
        {:ok, report}

      {:error, _} ->
        {:error, :artifact_missing}
    end
  end
end
