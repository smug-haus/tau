defmodule Mix.Tasks.Tau.Qa do
  @shortdoc "Six-layer factory-loop QA gate (closes #268)."

  @moduledoc """
  Factory-loop closing-move QA routine — issue #268.

  One command, six layers, ordered. Each layer that fails halts the
  task with a distinct exit code so CI logs name the failure mode.

  Supersedes `mix tau.smoke` as the CI gate; `mix tau.smoke` is left
  in place as a faster (B+C+D-only) subset for local iteration.

  ## Layers

  | # | Layer | What it runs | Defect class it catches |
  |---|---|---|---|
  | A | source quality | `mix compile --warnings-as-errors && mix test && mix format --check-formatted && mix credo --strict` | code defects |
  | B | artifact build | `BURRITO_TARGET=<host> MIX_ENV=prod mix release tau --overwrite` (with `XDG_DATA_HOME` isolation) | NIF cross-compile failures, broken Burrito post-steps |
  | C | artifact boot  | `<binary> help run`; assert exit 0; assert `--system-prompt-file` flag present | flag drift, escript/binary packaging gaps |
  | D | replay smoke   | `<binary> run "hello" --provider replay --model replay`; assert exit 0; stdout contains `(replay) hello` | NIF load failures (#264) |
  | E | tool exposure  | `mix test test/tau/qa/tool_exposure_test.exs` | the #267 class — model literally cannot call its tools |
  | F | coordinator round-trip | `mix test test/tau/qa/coordinator_roundtrip_test.exs` | whole coordinator pipeline (persona → tool exposure → Agent → child → result) |

  ## Exit codes

  | exit | layer | meaning                                  |
  |------|-------|------------------------------------------|
  | 0    | —     | every layer green                        |
  | 10   | A     | source-quality layer failed              |
  | 11   | B     | artifact build failed                    |
  | 12   | C     | binary boot failed (or `--system-prompt-file` missing) |
  | 13   | D     | binary replay smoke failed               |
  | 14   | E     | tool-exposure smoke failed               |
  | 15   | F     | coordinator round-trip failed            |
  |  2   | —     | unsupported host (cannot derive Burrito target) |

  ## Host assumption

  `BURRITO_TARGET`, when set, is honoured. Otherwise the host is
  detected the same way `mix tau.smoke` detects it (linux_amd64 /
  linux_arm64 / macos_amd64 / macos_arm64). Other hosts exit with
  `2` (unsupported).

  ## XDG isolation

  `XDG_DATA_HOME` is set to `<cwd>/.xdg-data` when the caller hasn't
  set one already, so concurrent agents building from different
  worktrees do not race on `~/.local/share/.burrito/`. Honours an
  externally-set `XDG_DATA_HOME` unchanged.

  ## Layer subset (local iteration)

  This task is intended for the CI gate; for local iteration use
  `mix tau.smoke` (B+C+D only — faster) or run layers (E)/(F)
  directly via `mix test test/tau/qa/`.
  """

  use Mix.Task

  @exit_unsupported_host 2
  @exit_layer_a 10
  @exit_layer_b 11
  @exit_layer_c 12
  @exit_layer_d 13
  @exit_layer_e 14
  @exit_layer_f 15

  @smoke_token "(replay) hello"
  @help_flag_marker "--system-prompt-file"

  @impl Mix.Task
  def run(_argv) do
    with :ok <- ensure_xdg_isolation(),
         {:ok, target} <- resolve_target(),
         :ok <- layer_a(),
         :ok <- bust_burrito_cache(),
         :ok <- layer_b(target),
         {:ok, binary} <- locate_binary(target),
         :ok <- layer_c(binary),
         :ok <- layer_d(binary),
         :ok <- layer_e(),
         :ok <- layer_f() do
      Mix.shell().info("tau.qa: OK (#{target})")
      :ok
    else
      {:error, code, message} ->
        Mix.shell().error("tau.qa: #{message}")
        System.halt(code)
    end
  end

  # --- XDG isolation -------------------------------------------------------

  defp ensure_xdg_isolation do
    case System.get_env("XDG_DATA_HOME") do
      v when is_binary(v) and v != "" ->
        :ok

      _ ->
        path = Path.expand(".xdg-data", File.cwd!())
        File.mkdir_p!(path)
        System.put_env("XDG_DATA_HOME", path)
        Mix.shell().info("tau.qa: XDG_DATA_HOME=#{path} (auto-isolated)")
        :ok
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

  # --- cache bust (shared with tau.smoke) ---------------------------------

  defp bust_burrito_cache do
    cache_root =
      case System.get_env("XDG_DATA_HOME") do
        v when is_binary(v) and v != "" -> Path.join(v, ".burrito")
        _ -> Path.expand("~/.local/share/.burrito")
      end

    cache_root
    |> Path.join("tau_erts-*")
    |> Path.wildcard()
    |> Enum.each(fn dir ->
      Mix.shell().info("tau.qa: bust burrito cache #{dir}")
      File.rm_rf!(dir)
    end)

    :ok
  end

  # --- (A) source quality --------------------------------------------------

  defp layer_a do
    Mix.shell().info("tau.qa: (A) source quality")

    steps = [
      {"mix compile --warnings-as-errors", ["compile", "--warnings-as-errors"]},
      {"mix test", ["test"]},
      {"mix format --check-formatted", ["format", "--check-formatted"]},
      {"mix credo --strict", ["credo", "--strict"]}
    ]

    Enum.reduce_while(steps, :ok, fn {label, args}, _ ->
      Mix.shell().info("tau.qa:   - #{label}")

      case System.cmd("mix", args,
             stderr_to_stdout: true,
             into: IO.stream(:stdio, :line)
           ) do
        {_io, 0} ->
          {:cont, :ok}

        {_io, code} ->
          {:halt, {:error, @exit_layer_a, "LAYER_A_FAILED: `#{label}` exited #{code}"}}
      end
    end)
  end

  # --- (B) artifact build --------------------------------------------------

  defp layer_b(target) do
    Mix.shell().info("tau.qa: (B) mix release tau --overwrite (target=#{target})")

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
        :ok

      {_io, code} ->
        {:error, @exit_layer_b, "LAYER_B_FAILED: `mix release tau --overwrite` exited #{code}"}
    end
  end

  defp locate_binary(target) do
    path = Path.expand("burrito_out/tau_#{target}", File.cwd!())

    if File.regular?(path) do
      {:ok, path}
    else
      {:error, @exit_layer_b,
       "LAYER_B_FAILED: expected #{path} after a successful build, not found"}
    end
  end

  # --- (C) artifact boot ---------------------------------------------------

  defp layer_c(binary) do
    Mix.shell().info("tau.qa: (C) #{binary} help run")

    {output, exit_code} = System.cmd(binary, ["help", "run"], stderr_to_stdout: true)

    cond do
      exit_code != 0 ->
        {:error, @exit_layer_c,
         "LAYER_C_FAILED: binary exited #{exit_code} on `help run`; output:\n#{output}"}

      not String.contains?(output, @help_flag_marker) ->
        {:error, @exit_layer_c,
         "LAYER_C_FAILED: `help run` output missing #{inspect(@help_flag_marker)}; got:\n#{output}"}

      true ->
        :ok
    end
  end

  # --- (D) replay smoke ----------------------------------------------------

  defp layer_d(binary) do
    Mix.shell().info("tau.qa: (D) #{binary} run \"hello\" --provider replay --model replay")

    {output, exit_code} =
      System.cmd(binary, ["run", "hello", "--provider", "replay", "--model", "replay"],
        stderr_to_stdout: true
      )

    cond do
      exit_code != 0 ->
        {:error, @exit_layer_d,
         "LAYER_D_FAILED: binary exited #{exit_code} on replay run; output:\n#{output}"}

      not String.contains?(output, @smoke_token) ->
        {:error, @exit_layer_d,
         "LAYER_D_FAILED: stdout missing #{inspect(@smoke_token)}; got:\n#{output}"}

      true ->
        IO.write(output)
        :ok
    end
  end

  # --- (E) tool exposure smoke ---------------------------------------------

  defp layer_e do
    Mix.shell().info("tau.qa: (E) mix test test/tau/qa/tool_exposure_test.exs")

    case System.cmd("mix", ["test", "test/tau/qa/tool_exposure_test.exs"],
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_io, 0} ->
        :ok

      {_io, code} ->
        {:error, @exit_layer_e,
         "LAYER_E_FAILED: `mix test test/tau/qa/tool_exposure_test.exs` exited #{code}"}
    end
  end

  # --- (F) coordinator round-trip ------------------------------------------

  defp layer_f do
    Mix.shell().info("tau.qa: (F) mix test test/tau/qa/coordinator_roundtrip_test.exs")

    case System.cmd("mix", ["test", "test/tau/qa/coordinator_roundtrip_test.exs"],
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_io, 0} ->
        :ok

      {_io, code} ->
        {:error, @exit_layer_f,
         "LAYER_F_FAILED: `mix test test/tau/qa/coordinator_roundtrip_test.exs` exited #{code}"}
    end
  end
end
