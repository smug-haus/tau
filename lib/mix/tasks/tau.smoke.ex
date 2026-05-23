defmodule Mix.Tasks.Tau.Smoke do
  @shortdoc "Build the Burrito binary and run a replay smoke."

  @moduledoc """
  Deployed-artifact smoke gate.

  One command, deterministic, machine-checkable:

      mix tau.smoke

  Builds the host-architecture Burrito release of `tau`, invokes the
  produced binary with `run "hello" --provider replay --model replay`,
  and asserts:

    * The binary exits 0.
    * Stdout contains `(replay) hello` — the canonical Replay fixture
      token from `Tau.Providers.Replay.default_events/0`.

  Exits 0 on full success. Exits non-zero on every failure with a
  distinct exit code so CI logs name the failure mode:

  | exit | symbol               | meaning                                     |
  |------|----------------------|---------------------------------------------|
  | 0    | OK                   | Built and smoke-ran cleanly.                |
  | 2    | UNSUPPORTED_HOST     | Not a host we know how to target.           |
  | 3    | BUILD_FAILED         | `mix release tau --overwrite` exited != 0.  |
  | 4    | BINARY_MISSING       | Build returned 0 but no `burrito_out/tau_*` |
  | 5    | BINARY_NONZERO_EXIT  | Binary ran but exited != 0.                 |
  | 6    | OUTPUT_MISMATCH      | Binary ran 0 but stdout missing fixture.    |

  ## Host assumption

  When `BURRITO_TARGET` is set in the environment it is honoured.
  Otherwise this task detects the host: on Linux/x86_64 it sets
  `BURRITO_TARGET=linux_amd64` (the only target CI runs this on); on
  Linux/aarch64 `linux_arm64`; on macOS x86_64/aarch64 the matching
  `macos_*`. Other hosts (notably Windows) exit with
  `UNSUPPORTED_HOST` (2) — the task is intended for the CI smoke job
  and the Linux dev box, not Windows.

  ## Burrito unpack-cache bust (#266)

  Burrito caches the unpacked ERTS bundle under
  `~/.local/share/.burrito/tau_erts-*`. The cache key does NOT include
  the binary's content hash, so a stale cache can silently mask a
  freshly-built broken binary — see #266. To remove that trap this
  task wipes any matching cache directory before the smoke runs.
  """

  use Mix.Task

  @cache_glob_basename "tau_erts-*"
  @exit_unsupported_host 2
  @exit_build_failed 3
  @exit_binary_missing 4
  @exit_binary_nonzero_exit 5
  @exit_output_mismatch 6

  @smoke_token "(replay) hello"

  @impl Mix.Task
  def run(_argv) do
    with {:ok, target} <- resolve_target(),
         :ok <- bust_burrito_cache(),
         :ok <- build_release(target),
         {:ok, binary} <- locate_binary(target),
         :ok <- smoke_binary(binary) do
      Mix.shell().info("tau.smoke: OK (#{target})")
      :ok
    else
      {:error, code, message} ->
        Mix.shell().error("tau.smoke: #{message}")
        System.halt(code)
    end
  end

  # --- target resolution ---------------------------------------------------

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

  # --- cache bust ----------------------------------------------------------

  defp bust_burrito_cache do
    cache_root =
      case System.get_env("XDG_DATA_HOME") do
        v when is_binary(v) and v != "" -> Path.join(v, ".burrito")
        _ -> Path.expand("~/.local/share/.burrito")
      end

    cache_root
    |> Path.join(@cache_glob_basename)
    |> Path.wildcard()
    |> Enum.each(fn dir ->
      Mix.shell().info("tau.smoke: bust burrito cache #{dir}")
      File.rm_rf!(dir)
    end)

    :ok
  end

  # --- release build -------------------------------------------------------

  defp build_release(target) do
    env = [
      {"MIX_ENV", "prod"},
      {"BURRITO_TARGET", target},
      {"HEX_HTTP_TIMEOUT", "120"}
    ]

    Mix.shell().info("tau.smoke: mix release tau --overwrite (target=#{target})")

    case System.cmd("mix", ["release", "tau", "--overwrite"],
           env: env,
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_io, 0} ->
        :ok

      {_io, code} ->
        {:error, @exit_build_failed, "BUILD_FAILED: `mix release tau --overwrite` exited #{code}"}
    end
  end

  # --- binary location -----------------------------------------------------

  defp locate_binary(target) do
    path = Path.expand("burrito_out/tau_#{target}", File.cwd!())

    if File.regular?(path) do
      {:ok, path}
    else
      {:error, @exit_binary_missing, "BINARY_MISSING: expected #{path} after a successful build"}
    end
  end

  # --- smoke run -----------------------------------------------------------

  defp smoke_binary(binary) do
    Mix.shell().info("tau.smoke: #{binary} run \"hello\" --provider replay --model replay")

    {output, exit_code} =
      System.cmd(binary, ["run", "hello", "--provider", "replay", "--model", "replay"],
        stderr_to_stdout: true
      )

    cond do
      exit_code != 0 ->
        {:error, @exit_binary_nonzero_exit,
         "BINARY_NONZERO_EXIT: binary exited #{exit_code}; output:\n#{output}"}

      not String.contains?(output, @smoke_token) ->
        {:error, @exit_output_mismatch,
         "OUTPUT_MISMATCH: stdout missing #{inspect(@smoke_token)}; got:\n#{output}"}

      true ->
        IO.write(output)
        :ok
    end
  end
end
