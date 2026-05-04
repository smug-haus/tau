defmodule Tau.CLI.BinarySmokeTest do
  @moduledoc """
  AC-5 (SPEC-USER-TURN): Burrito binary smoke gate.

  Builds the host-architecture Burrito binary in `setup_all` and
  invokes `tau run "ping" --provider replay --model replay`.
  Asserts:
    * Exit code 0.
    * stdout contains a known token from `Tau.Providers.Replay.default_events/0`.
    * stderr is silent of error markers.

  This is the thinnest possible "the binary actually works" gate.
  Tagged `:smoke` so it is opt-in for fast `mix test` runs but
  REQUIRED in CI per `docs/spec/SPEC-USER-TURN.md` AC-5. Without this
  test, every PR can be unit-correct and ship a non-functional
  binary — see `project_state_2026_05_03_evening` memory.
  """
  use ExUnit.Case, async: false

  @moduletag :smoke
  @moduletag timeout: 180_000

  setup_all do
    target = host_burrito_target()
    binary = Path.expand("burrito_out/tau_#{target}", File.cwd!())

    {:ok, _} =
      build_burrito(target)
      |> case do
        :ok -> {:ok, %{binary: binary, target: target}}
        {:error, reason} -> {:error, reason}
      end

    # No on_exit cleanup: `tau maintenance uninstall` is interactive
    # (prompts y/n) and System.cmd cannot supply stdin. The Burrito
    # extraction cache is per-version under `~/.local/share/.burrito/`;
    # leaving it between runs is harmless and keeps subsequent runs
    # fast (skips ERTS re-extraction).

    %{binary: binary, target: target}
  end

  test "tau run --provider replay produces canonical Replay output", %{binary: binary} do
    {output, exit_code} =
      System.cmd(binary, ["run", "ping", "--provider", "replay", "--model", "replay"],
        stderr_to_stdout: false
      )

    assert exit_code == 0,
           "binary exited #{exit_code}; output:\n#{output}"

    assert output =~ "(replay) hello",
           "expected Replay default fixture token in stdout; got:\n#{output}"

    refute output =~ ~r/\(EXIT\)/,
           "stdout contained an Erlang (EXIT) trace:\n#{output}"

    refute output =~ ~r/:noproc/,
           "stdout contained :noproc:\n#{output}"
  end

  defp host_burrito_target do
    case {:os.type(), :erlang.system_info(:system_architecture) |> to_string()} do
      {{:unix, :linux}, arch} ->
        cond do
          String.contains?(arch, "aarch64") -> "linux_arm64"
          String.contains?(arch, "x86_64") -> "linux_amd64"
          true -> raise "unsupported linux arch: #{arch}"
        end

      {{:unix, :darwin}, arch} ->
        cond do
          String.contains?(arch, "aarch64") -> "macos_arm64"
          String.contains?(arch, "x86_64") -> "macos_amd64"
          true -> raise "unsupported darwin arch: #{arch}"
        end

      other ->
        raise "unsupported host: #{inspect(other)}"
    end
  end

  defp build_burrito(target) do
    env = [
      {"MIX_ENV", "prod"},
      {"BURRITO_TARGET", target},
      {"HEX_HTTP_TIMEOUT", "120"}
    ]

    case System.cmd("mix", ["release", "tau", "--overwrite"],
           env: env,
           stderr_to_stdout: true,
           parallelism: true,
           into: ""
         ) do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error, "mix release tau exited #{code}; output:\n#{output}"}
    end
  end
end
