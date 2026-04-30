defmodule Tau.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/smug-haus/aoc2020"

  def project do
    [
      app: :tau,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      escript: escript(),
      releases: releases(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        dialyzer: :dev,
        "test.property": :test
      ],
      package: package(),
      description: description(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      mod: {Tau.Application, []},
      extra_applications: [:logger, :crypto, :ssl, :inets]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # JSON, HTTP, streaming
      {:jason, "~> 1.4"},
      {:finch, "~> 0.18"},
      {:mint, "~> 1.6"},
      {:castore, "~> 1.0"},

      # Observability
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.0"},

      # PubSub for session event fanout
      {:phoenix_pubsub, "~> 2.1"},

      # Filesystem watcher
      {:file_system, "~> 1.0"},

      # TUI
      {:ratatouille, "~> 0.5"},

      # CLI argv parser
      {:optimus, "~> 0.5"},

      # Bash with proper process-tree kill
      {:erlexec, "~> 2.0"},

      # AWS credential chain (Bedrock provider)
      {:aws_credentials, "~> 0.3"},

      # ULIDs for sortable session/event ids
      {:uniq, "~> 0.6"},

      # Schema validation
      {:ex_json_schema, "~> 0.10"},
      {:nimble_options, "~> 1.1"},

      # Self-contained binary distribution (release-only)
      {:burrito, "~> 1.2", runtime: false},

      # Dev / test
      {:mox, "~> 1.2", only: :test},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:bypass, "~> 2.1", only: :test},
      {:briefly, "~> 0.5", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp escript do
    [
      main_module: Tau.CLI,
      name: "tau",
      app: nil,
      embed_elixir: true
    ]
  end

  defp releases do
    [
      tau: [
        include_executables_for: [:unix],
        applications: [tau: :permanent],
        steps: [:assemble]
      ]
    ]
  end

  defp aliases do
    [
      "test.property": ["test --only property"],
      lint: ["format --check-formatted", "credo --strict", "dialyzer"],
      "tau.gen.schema": ["run priv/scripts/gen_settings_schema.exs"]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_local_path: "priv/plts/local.plt",
      plt_core_path: "priv/plts/core.plt",
      flags: [:error_handling, :unknown, :extra_return, :missing_return]
    ]
  end

  defp package do
    [
      maintainers: ["smug-haus"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE TAU.md)
    ]
  end

  defp description do
    "An OTP/BEAM agentic coding harness. Configurable, flexible, extensible — a from-scratch reimagining of the Pi harness in Elixir."
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "TAU.md"],
      groups_for_modules: [
        "Public API": [Tau],
        Behaviours: [
          Tau.Tool,
          Tau.Provider,
          Tau.Hook,
          Tau.Permissions.Matcher,
          Tau.Persistence,
          Tau.MCP.Transport,
          Tau.Compactor,
          Tau.Extension
        ],
        Session: [Tau.Session, Tau.Message, Tau.Message.Assembler],
        Providers: [
          Tau.Providers.Anthropic,
          Tau.Providers.Gemini,
          Tau.Providers.Bedrock,
          Tau.Providers.OpenAI.Responses,
          Tau.Providers.OpenAI.Chat
        ],
        Tools: [
          Tau.Tools.Builtin.Read,
          Tau.Tools.Builtin.Write,
          Tau.Tools.Builtin.Edit,
          Tau.Tools.Builtin.Bash
        ],
        MCP: [Tau.MCP.Manager, Tau.MCP.Server, Tau.MCP.ToolAdapter]
      ]
    ]
  end
end
