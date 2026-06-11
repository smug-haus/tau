defmodule Tau.Factory.Merge.Health do
  @moduledoc """
  Pre-push tip health check (D-303, AC-5).

  A pure function that compiles and tests a git working tree via the
  language-specific toolchain adapter. The engine owns execution AND judgement
  (HR-3 / FC-5): the exit code of the subprocess determines the result —
  no adapter `:green` claim can bypass the gate.

  ## Contract

    - `check/3` returns `:green` when every step exits 0.
    - `check/3` returns `{:red, report}` on the first non-zero exit, where
      `report` is a map with at minimum `:phase` (`:toolchain | :build | :test`)
      and `:output` (truncated stdout+stderr).

  ## Telemetry

  Emits `[:tau, :factory, :merge, :health]` with `metadata[:result]` of
  `:green` or `:red` so the caller can observe the judgement without parsing
  the return value.
  """

  alias Tau.Factory.Toolchain

  @output_limit 4096

  @doc """
  Run the build + test pipeline for `repo_dir` using the toolchain for `lang`.

  Returns `:green` when both steps succeed (exit 0), or `{:red, report}` on
  the first failure. `report` always has:

    * `:phase` — the failing phase (`:toolchain | :build | :test`).
    * `:output` — truncated combined stdout+stderr from the failing step.

  Emits `[:tau, :factory, :merge, :health]` telemetry with `result: :green |
  :red` in the metadata.
  """
  @spec check(String.t(), atom(), map()) :: :green | {:red, map()}
  def check(repo_dir, lang, ctx) do
    result = do_check(repo_dir, lang, ctx)
    emit_telemetry(result)
    result
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_check(repo_dir, lang, ctx) do
    case Toolchain.for(lang) do
      {:error, _} = _err ->
        {:red, %{phase: :toolchain, output: "unsupported language: #{inspect(lang)}"}}

      mod ->
        run_pipeline(repo_dir, mod, ctx)
    end
  end

  defp run_pipeline(repo_dir, mod, ctx) do
    build_recipe = mod.build(ctx)
    test_recipe = mod.test_descriptor(ctx)

    with :ok <- run_step(repo_dir, build_recipe.argv, Map.to_list(build_recipe.env), :build),
         :ok <- run_step(repo_dir, test_recipe.argv, Map.to_list(test_recipe.env), :test) do
      :green
    end
  end

  defp run_step(repo_dir, argv, env, phase) do
    [cmd | args] = argv

    {output, exit_code} =
      System.cmd(cmd, args, cd: repo_dir, env: env, stderr_to_stdout: true)

    if exit_code == 0 do
      :ok
    else
      {:red, %{phase: phase, output: truncate(output)}}
    end
  end

  defp truncate(output) when byte_size(output) > @output_limit do
    binary_part(output, 0, @output_limit) <> "\n[...truncated]"
  end

  defp truncate(output), do: output

  defp emit_telemetry(:green) do
    :telemetry.execute(
      [:tau, :factory, :merge, :health],
      %{},
      %{result: :green}
    )
  end

  defp emit_telemetry({:red, report}) do
    :telemetry.execute(
      [:tau, :factory, :merge, :health],
      %{},
      %{result: :red, phase: report[:phase]}
    )
  end
end
