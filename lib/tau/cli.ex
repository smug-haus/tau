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
      tau config [get|set]             # inspect/edit settings cascade
      tau mcp list|status|reload       # inspect MCP server connections
      tau extensions list|reload       # inspect loaded extensions
      tau version                      # print version
      tau doctor                       # diagnose environment, providers, MCP
      tau init                         # interactive onboarding wizard

  Argument parsing uses `Optimus`. Subcommands return integer exit codes.
  Most read-oriented subcommands also support `--json` for piping.

  `tau init` walks a fresh user from a clean clone to a working
  `.tau/settings.local.json`; see `Tau.CLI.Init`.
  """

  alias Tau.Provider.Event

  def main(argv \\ []) do
    Application.ensure_all_started(:tau)

    case Optimus.parse!(spec(), argv) do
      {[:run], parsed} ->
        run_cmd(parsed) |> halt()

      {[:resume], parsed} ->
        resume_cmd(parsed) |> halt()

      {[:sessions, :list], _} ->
        sessions_list() |> halt()

      {[:sessions, :show], parsed} ->
        sessions_show(parsed) |> halt()

      {[:config], parsed} ->
        Tau.CLI.Config.show(opts_with_json(parsed)) |> halt()

      {[:config, :get], parsed} ->
        config_get(parsed) |> halt()

      {[:config, :set], parsed} ->
        config_set(parsed) |> halt()

      {[:mcp], parsed} ->
        Tau.CLI.MCP.list(opts_with_json(parsed)) |> halt()

      {[:mcp, :list], parsed} ->
        Tau.CLI.MCP.list(opts_with_json(parsed)) |> halt()

      {[:mcp, :status], parsed} ->
        Tau.CLI.MCP.status(opts_with_json(parsed)) |> halt()

      {[:mcp, :reload], parsed} ->
        Tau.CLI.MCP.reload(opts_with_json(parsed)) |> halt()

      {[:extensions], parsed} ->
        Tau.CLI.Extensions.list(opts_with_json(parsed)) |> halt()

      {[:extensions, :list], parsed} ->
        Tau.CLI.Extensions.list(opts_with_json(parsed)) |> halt()

      {[:extensions, :reload], parsed} ->
        Tau.CLI.Extensions.reload(opts_with_json(parsed)) |> halt()

      {[:version], _} ->
        version_cmd() |> halt()

      {[:doctor], _} ->
        doctor_cmd() |> halt()

      {[:init], parsed} ->
        init_cmd(parsed) |> halt()

      {[:tui], parsed} ->
        tui_cmd(parsed) |> halt()

      {[], _} ->
        tui_cmd(%Optimus.ParseResult{}) |> halt()

      %Optimus.ParseResult{} = parsed ->
        tui_cmd(parsed) |> halt()

      _ ->
        :ok
    end
  end

  defp opts_with_json(parsed) do
    [json: !!(parsed.flags[:json] || parsed.options[:json] in [true, "true"])]
  end

  defp config_get(parsed) do
    Tau.CLI.Config.get(parsed.args.key, opts_with_json(parsed))
  end

  defp config_set(parsed) do
    Tau.CLI.Config.set(parsed.args.key, parsed.args.value, opts_with_json(parsed))
  end

  @doc """
  The Optimus parser spec. Public so tests can drive `Optimus.parse/2`
  with hand-built argv without going through `main/1` (which calls
  `System.halt/1`).
  """
  def spec do
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
        config: [
          name: "config",
          about: "Show / edit the merged settings cascade.",
          flags: [json: [long: "--json", help: "Emit JSON"]],
          subcommands: [
            get: [
              name: "get",
              about: "Read a top-level setting from the cascade.",
              args: [key: [required: true]],
              flags: [json: [long: "--json", help: "Emit JSON"]]
            ],
            set: [
              name: "set",
              about: "Write a top-level setting to .tau/settings.local.json.",
              args: [key: [required: true], value: [required: true]],
              flags: [json: [long: "--json", help: "Emit JSON"]]
            ]
          ]
        ],
        mcp: [
          name: "mcp",
          about: "Inspect MCP server connections.",
          flags: [json: [long: "--json", help: "Emit JSON"]],
          subcommands: [
            list: [
              name: "list",
              about: "List configured MCP servers.",
              flags: [json: [long: "--json", help: "Emit JSON"]]
            ],
            status: [
              name: "status",
              about: "Show health of configured MCP servers.",
              flags: [json: [long: "--json", help: "Emit JSON"]]
            ],
            reload: [
              name: "reload",
              about: "Force MCP manager to reconcile against settings.",
              flags: [json: [long: "--json", help: "Emit JSON"]]
            ]
          ]
        ],
        extensions: [
          name: "extensions",
          about: "Inspect loaded extensions.",
          flags: [json: [long: "--json", help: "Emit JSON"]],
          subcommands: [
            list: [
              name: "list",
              about: "List loaded extensions.",
              flags: [json: [long: "--json", help: "Emit JSON"]]
            ],
            reload: [
              name: "reload",
              about: "Reload all configured extensions.",
              flags: [json: [long: "--json", help: "Emit JSON"]]
            ]
          ]
        ],
        version: [name: "version", about: "Print Tau version"],
        doctor: [name: "doctor", about: "Diagnose environment, providers, MCP"],
        init: [
          name: "init",
          about: "Interactive onboarding wizard (providers, permissions, MCP, skills).",
          flags: [
            reconfigure: [
              long: "--reconfigure",
              help: "Re-run the wizard against existing settings (start clean)."
            ],
            non_interactive: [
              long: "--non-interactive",
              help: "Skip prompts, accept defaults (CI / scripted setup)."
            ]
          ]
        ],
        tui: [
          name: "tui",
          about: "Launch the interactive TUI",
          options: [
            provider: [short: "-p", long: "--provider", help: "Provider id"],
            model: [short: "-m", long: "--model", help: "Model id"]
          ]
        ]
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

    # D-019: report which Anthropic auth path is configured.
    case Tau.Providers.Anthropic.Auth.resolve(%{}) do
      {:ok, {:api_key, _}} ->
        IO.puts("provider Tau.Providers.Anthropic: api_key (env / settings)")

      {:ok, {:oauth, info}} ->
        ttl_s = max(div(info.expires_at - :os.system_time(:millisecond), 1000), 0)

        IO.puts(
          "provider Tau.Providers.Anthropic: oauth (#{info.subscription_type}, " <>
            "expires in #{ttl_s}s)"
        )

      {:error, _} = err ->
        IO.puts("provider Tau.Providers.Anthropic: " <> Tau.Providers.Anthropic.Auth.describe_error(err))
    end

    0
  end

  defp init_cmd(parsed) do
    opts = [
      reconfigure: parsed.flags[:reconfigure] || false,
      non_interactive: parsed.flags[:non_interactive] || false
    ]

    case Tau.CLI.Init.run(File.cwd!(), opts) do
      {:ok, :no_write} ->
        IO.puts("init: declined to write — no changes made.")
        0

      {:ok, path} ->
        IO.puts("init: wrote #{path}.")
        0

      {:error, reason} ->
        IO.puts(:stderr, "init failed: #{inspect(reason)}")
        1
    end
  end

  defp tui_cmd(parsed) do
    if Code.ensure_loaded?(Tau.TUI) and function_exported?(Tau.TUI, :start, 1) do
      Tau.TUI.start(tui_opts(parsed))
      0
    else
      IO.puts(:stderr, "TUI not available (Ratatouille not loaded?)")
      1
    end
  end

  defp tui_opts(%Optimus.ParseResult{options: opts}) when is_map(opts) do
    []
    |> tui_put(:provider, opts[:provider], &resolve_provider/1)
    |> tui_put(:model, opts[:model], & &1)
  end

  defp tui_opts(_), do: []

  defp tui_put(opts, _key, nil, _xform), do: opts
  defp tui_put(opts, key, value, xform), do: Keyword.put(opts, key, xform.(value))

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
