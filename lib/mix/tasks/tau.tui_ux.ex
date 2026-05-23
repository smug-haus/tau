defmodule Mix.Tasks.Tau.TuiUx do
  @shortdoc "Build the Burrito binary and run the TUI UX protocol tests."

  @moduledoc """
  TUI UX protocol runner.

  Locates (or builds) the host-architecture Burrito binary, then runs the
  `:tui_smoke` and `:tui_ux` tagged protocol tests against it via the
  `Tau.Test.TuiPtyHelper` tmux harness. Reports per-step pass/fail.
  Exits non-zero if any step FAILs.

  Mirrors the structure and XDG isolation of `mix tau.qa`.

  ## Runtime dependency

  `tmux` MUST be on `$PATH`. The task checks for this before running
  tests and exits with code 3 if absent.

  ## Binary location / build

  The task checks for a pre-built Burrito binary at
  `burrito_out/tau_<target>`. If found, it uses it. If absent, it builds
  one via `MIX_ENV=prod mix release tau --overwrite` (same as layer B of
  `mix tau.qa`).

  ## XDG isolation

  `XDG_DATA_HOME` is set to `<cwd>/.xdg-data` when the caller has not
  set one, preventing the Burrito unpack-cache race against concurrent
  agents. Honours an externally-set `XDG_DATA_HOME` unchanged.

  ## Exit codes

  | exit | meaning                                              |
  |------|------------------------------------------------------|
  | 0    | all protocol steps green                            |
  | 2    | unsupported host (cannot derive Burrito target)     |
  | 3    | `tmux` not found on PATH                            |
  | 4    | binary build failed                                 |
  | 5    | one or more protocol steps FAILED                   |
  """

  use Mix.Task

  @exit_unsupported_host 2
  @exit_tmux_missing 3
  @exit_build_failed 4
  @exit_tests_failed 5

  @impl Mix.Task
  def run(_argv) do
    with :ok <- ensure_xdg_isolation(),
         {:ok, target} <- resolve_target(),
         :ok <- ensure_tmux(),
         {:ok, binary} <- ensure_binary(target),
         :ok <- run_protocol(binary) do
      Mix.shell().info("tau.tui_ux: OK (#{target})")
      :ok
    else
      {:error, code, message} ->
        Mix.shell().error("tau.tui_ux: #{message}")
        System.halt(code)
    end
  end

  # --- XDG isolation ---------------------------------------------------------

  defp ensure_xdg_isolation do
    case System.get_env("XDG_DATA_HOME") do
      v when is_binary(v) and v != "" ->
        :ok

      _ ->
        path = Path.expand(".xdg-data", File.cwd!())
        File.mkdir_p!(path)
        System.put_env("XDG_DATA_HOME", path)
        Mix.shell().info("tau.tui_ux: XDG_DATA_HOME=#{path} (auto-isolated)")
        :ok
    end
  end

  # --- target resolution -----------------------------------------------------

  defp resolve_target do
    case System.get_env("BURRITO_TARGET") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        detect_host_target()
    end
  end

  defp detect_host_target do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    case {:os.type(), arch} do
      {{:unix, :linux}, a} ->
        cond do
          String.contains?(a, "aarch64") -> {:ok, "linux_arm64"}
          String.contains?(a, "x86_64") -> {:ok, "linux_amd64"}
          true -> unsupported("linux arch #{inspect(a)} not supported")
        end

      {{:unix, :darwin}, a} ->
        cond do
          String.contains?(a, "aarch64") -> {:ok, "macos_arm64"}
          String.contains?(a, "x86_64") -> {:ok, "macos_amd64"}
          true -> unsupported("darwin arch #{inspect(a)} not supported")
        end

      other ->
        unsupported("host #{inspect(other)} not supported (set BURRITO_TARGET to override)")
    end
  end

  defp unsupported(msg), do: {:error, @exit_unsupported_host, "UNSUPPORTED_HOST: " <> msg}

  # --- tmux check ------------------------------------------------------------

  defp ensure_tmux do
    case System.find_executable("tmux") do
      nil ->
        {:error, @exit_tmux_missing,
         "TMUX_MISSING: install tmux to run the TUI UX protocol (apt/brew install tmux)"}

      path ->
        Mix.shell().info("tau.tui_ux: tmux found at #{path}")
        :ok
    end
  end

  # --- binary location / build -----------------------------------------------

  defp ensure_binary(target) do
    path = Path.expand("burrito_out/tau_#{target}", File.cwd!())

    if File.regular?(path) do
      Mix.shell().info("tau.tui_ux: using pre-built binary #{path}")
      {:ok, path}
    else
      Mix.shell().info("tau.tui_ux: no binary at #{path} — building")
      build_and_locate(target)
    end
  end

  defp build_and_locate(target) do
    Mix.shell().info("tau.tui_ux: MIX_ENV=prod mix release tau --overwrite (target=#{target})")

    env = [
      {"MIX_ENV", "prod"},
      {"BURRITO_TARGET", target},
      {"HEX_HTTP_TIMEOUT", "120"}
    ]

    case System.cmd("mix", ["release", "tau", "--overwrite"],
           env: env,
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_io, 0} ->
        path = Path.expand("burrito_out/tau_#{target}", File.cwd!())

        if File.regular?(path) do
          {:ok, path}
        else
          {:error, @exit_build_failed, "BUILD_FAILED: build succeeded but #{path} not found"}
        end

      {_io, code} ->
        {:error, @exit_build_failed, "BUILD_FAILED: `mix release tau --overwrite` exited #{code}"}
    end
  end

  # --- protocol run ----------------------------------------------------------

  defp run_protocol(binary) do
    Mix.shell().info("tau.tui_ux: running protocol (steps 1–3, tags :tui_smoke :tui_ux)")
    Mix.shell().info("tau.tui_ux: binary=#{binary}")

    # The TAU_TUI_BINARY env var tells the smoke test module which binary to
    # use. The test's setup calls binary_for_host/0 which checks for Burrito
    # binaries at predictable paths; we set TAU_TUI_BINARY to short-circuit
    # that and point directly at the binary we've already located/built.
    #
    # Tests are tagged :tui_smoke (steps 1–3) + :tui_ux (steps 4–10, to be
    # added by feature steps). We run both tags so a single invocation of
    # `mix tau.tui_ux` covers the full protocol as it grows.
    System.put_env("TAU_TUI_BINARY", binary)

    # Run tests tagged :tui_smoke OR :tui_ux. ExUnit's --only applies AND
    # logic when specified multiple times; to get OR semantics we use
    # --include for both tags and --exclude test (the default tag on all
    # tests), which is the same thing --only does internally.
    test_args = [
      "test",
      "--include",
      "tui_smoke",
      "--include",
      "tui_ux",
      "--exclude",
      "test",
      "--trace",
      "test/tau/cli/tui_smoke_test.exs"
    ]

    Mix.shell().info("tau.tui_ux: mix #{Enum.join(test_args, " ")}")

    case System.cmd("mix", test_args,
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_io, 0} ->
        :ok

      {_io, code} ->
        {:error, @exit_tests_failed,
         "TESTS_FAILED: protocol test run exited #{code} — see output above for per-step failures"}
    end
  end
end
