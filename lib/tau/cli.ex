defmodule Tau.CLI do
  @moduledoc """
  Escript entry point.

  Subcommands currently registered in `spec/0`:

      tau                              # interactive TUI (M6+)
      tau run "prompt" [opts]          # one-shot non-interactive
      tau resume <session-id>          # replay <session-id>'s JSONL into
                                       # a NEW session (returns the new
                                       # session's id; the original is
                                       # untouched on disk)
      tau sessions list|show           # inspect persisted sessions
      tau version                      # print version
      tau doctor                       # diagnose environment, providers, MCP

  Argument parsing uses `Optimus`. Subcommands return integer exit codes.

  ### Not yet implemented

  Earlier drafts of this moduledoc advertised `tau config`, `tau mcp`,
  and `tau extensions` subcommands plus `tau sessions delete`, none of
  which are wired to `spec/0` — invoking them would error with
  "unknown subcommand". They are tracked together in the CLI
  subcommands feature request so users hitting the doc first don't
  trip on the gap.
  """

  alias Tau.Provider.Event

  def main(argv \\ []) do
    Application.ensure_all_started(:tau)

    case Optimus.parse!(spec(), argv) do
      {[:run], parsed} -> run_cmd(parsed) |> halt()
      {[:resume], parsed} -> resume_cmd(parsed) |> halt()
      {[:sessions, :list], _} -> sessions_list() |> halt()
      {[:sessions, :show], parsed} -> sessions_show(parsed) |> halt()
      {[:version], _} -> version_cmd() |> halt()
      {[:doctor], _} -> doctor_cmd() |> halt()
      {[:tui], _} -> tui_cmd() |> halt()
      {[], _} -> tui_cmd() |> halt()
      _ -> :ok
    end
  end

  defp spec do
    Optimus.new!(
      name: "tau",
      description: "Tau — an OTP/BEAM agentic coding harness.",
      version: version(),
      subcommands: [
        run: [
          name: "run",
          about: "Run a single prompt non-interactively (streams to stdout).",
          args: [prompt: [help: "The prompt", required: true]],
          options: [
            provider: [short: "-p", long: "--provider", help: "Provider id"],
            model: [short: "-m", long: "--model", help: "Model id"],
            session: [short: "-s", long: "--session", help: "Session id (resume)"]
          ]
        ],
        resume: [
          name: "resume",
          about: "Resume an existing session.",
          args: [id: [help: "Session id", required: true]]
        ],
        sessions: [
          name: "sessions",
          about: "Inspect persisted sessions.",
          subcommands: [
            list: [name: "list", about: "List sessions"],
            show: [name: "show", args: [id: [required: true]]]
          ]
        ],
        version: [name: "version", about: "Print Tau version"],
        doctor: [name: "doctor", about: "Diagnose environment, providers, MCP"],
        tui: [name: "tui", about: "Launch the interactive TUI"]
      ]
    )
  end

  defp run_cmd(parsed) do
    prompt = parsed.args.prompt
    provider = resolve_provider(parsed.options[:provider])
    model = parsed.options[:model] || provider.default_model()

    msgs = [Tau.Message.User.new(prompt)]

    case provider.stream(msgs, %{model: model}, %{}) do
      {:ok, stream} ->
        Enum.reduce_while(stream, 0, fn
          %Event.TextDelta{text: t}, _ ->
            IO.write(t)
            {:cont, 0}

          %Event.Done{}, _ ->
            IO.puts("")
            {:halt, 0}

          %Event.Error{reason: r}, _ ->
            IO.puts("\nerror: #{inspect(r)}")
            {:halt, 1}

          _, acc ->
            {:cont, acc}
        end)

      {:error, reason} ->
        IO.puts(:stderr, "provider error: #{inspect(reason)}")
        1
    end
  end

  defp resume_cmd(parsed) do
    case Tau.resume(parsed.args.id) do
      {:ok, _} ->
        IO.puts("resumed: #{parsed.args.id}")
        0

      {:error, reason} ->
        IO.puts(:stderr, "resume failed: #{inspect(reason)}")
        1
    end
  end

  defp sessions_list do
    Tau.list_sessions()
    |> Enum.each(fn s ->
      IO.puts("#{s.id}\t#{s.cwd}\t#{s.model}\t#{s.created_at}")
    end)

    0
  end

  defp sessions_show(parsed) do
    Tau.Persistence.impl().stream(parsed.args.id)
    |> Enum.each(&IO.puts(Jason.encode!(&1)))

    0
  end

  defp version_cmd do
    IO.puts("tau #{version()}")
    0
  end

  defp doctor_cmd do
    IO.puts("Elixir: #{System.version()}")
    IO.puts("OTP: #{System.otp_release()}")
    IO.puts("data_dir: #{Tau.Settings.data_dir()}")

    [Tau.Providers.Anthropic]
    |> Enum.each(fn mod ->
      key_env =
        case mod do
          Tau.Providers.Anthropic -> "ANTHROPIC_API_KEY"
          _ -> ""
        end

      ok = if System.get_env(key_env), do: "ok", else: "missing key"
      IO.puts("provider #{inspect(mod)}: #{ok}")
    end)

    0
  end

  defp tui_cmd do
    if Code.ensure_loaded?(Tau.TUI) and function_exported?(Tau.TUI, :start, 0) do
      Tau.TUI.start()
      0
    else
      IO.puts(:stderr, "TUI not available (Ratatouille not loaded?)")
      1
    end
  end

  defp resolve_provider(nil), do: Tau.Provider.default()
  defp resolve_provider("anthropic"), do: Tau.Providers.Anthropic

  defp resolve_provider(other) do
    Module.concat(["Tau", "Providers", String.capitalize(other)])
  end

  defp version do
    case Application.spec(:tau, :vsn) do
      nil -> "0.0.0-dev"
      v -> to_string(v)
    end
  end

  defp halt(code) when is_integer(code), do: System.halt(code)
  defp halt(_), do: System.halt(0)
end
