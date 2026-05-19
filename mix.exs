defmodule Tau.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/smug-haus/tau"

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
      extra_applications: [:logger, :crypto, :ssl, :inets],
      included_applications: [:aws_credentials]
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

      # Markdown (D-028 / [C52-B5]): parse assistant text content as
      # CommonMark with GFM tables before TUI render so structured
      # markup doesn't appear raw in the transcript pane.
      {:earmark, "~> 1.4"},

      # Observability
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.0"},

      # OpenTelemetry export (SPEC-OTEL-REPORTER / D-055).
      # Optional: a build without these deps compiles cleanly. Include in
      # a release by setting MIX_OTEL=1 at build time (wired in PR2).
      {:opentelemetry_api, "~> 1.5", optional: true},
      {:opentelemetry, "~> 1.7", optional: true},
      {:opentelemetry_exporter, "~> 1.10", optional: true},

      # PubSub for session event fanout
      {:phoenix_pubsub, "~> 2.1"},

      # HTTP listener for the per-run `tau-context` MCP server that
      # tau spawns alongside each coding-agent subprocess
      # (SPEC-CODING-AGENT §4 B4). Bound to 127.0.0.1 only, with a
      # per-run secret token for auth.
      {:plug, "~> 1.14"},
      {:plug_cowboy, "~> 2.6"},

      # Filesystem watcher
      {:file_system, "~> 1.0"},

      # TUI — optional, only fetched for dev. Prod builds the stub branch
      # of Tau.TUI; tests run without it. Add to your env to use the TUI.
      {:ratatouille, "~> 0.5"},

      # CLI argv parser
      {:optimus, "~> 0.5"},

      # AWS credential chain (Bedrock provider) — optional; Bedrock falls
      # back to env-var auth when this isn't loaded.
      {:aws_credentials, "~> 0.3", optional: true},

      # SQLite for persistent memory store (FTS5 ships in bundled build;
      # no separate sqlite dep needed). See SPEC-MEMORY-STORE and ADR-0020.
      {:exqlite, "~> 0.27"},

      # ULIDs for sortable session/event ids
      {:uniq, "~> 0.6"},

      # Schema validation
      {:ex_json_schema, "~> 0.10"},
      {:nimble_options, "~> 1.1"},

      # Self-contained binary distribution. Runtime modules
      # (`Burrito.Util.Args`) are needed at runtime to read user
      # argv and the `__BURRITO_BIN_PATH` context marker.
      {:burrito, "~> 1.2"},

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
        # Release version is stamped with the git short-hash so Burrito's
        # extraction-cache path (`<app>_erts-<erts>_<release-version>`) is
        # unique per commit — a fresh build is never served from a stale
        # extraction (issue #200). The `+<sha>` form is SemVer build
        # metadata; `@version` (the Hex package version) stays unchanged.
        version: @version <> git_descriptor(),
        include_executables_for: [:unix],
        applications: [tau: :permanent],
        steps: [:assemble, &maybe_burrito/1]
      ]
    ]
  end

  # Compile-time git descriptor for the release version. Mirrors
  # `Tau.Build.descriptor/2`; the duplication is intentional — `mix.exs` is
  # compiled before `lib/` and cannot reference `Tau.Build`.
  # Clean → `"+<sha>"`, dirty → `"+<sha>.dirty"`, no git → `""`.
  defp git_descriptor do
    if System.find_executable("git") do
      case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
        {sha, 0} ->
          dirty? =
            case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
              {out, 0} -> String.trim(out) != ""
              _ -> false
            end

          suffix = if dirty?, do: ".dirty", else: ""
          "+" <> String.trim(sha) <> suffix

        _ ->
          ""
      end
    else
      ""
    end
  rescue
    _ -> ""
  end

  defp maybe_burrito(release) do
    if Code.ensure_loaded?(Burrito) and System.get_env("BURRITO_TARGET") do
      target = System.get_env("BURRITO_TARGET")

      target_atom =
        target
        |> String.split(",")
        |> Enum.map(&String.to_atom/1)

      # Burrito 1.5.0 reads its config from `release.options[:burrito]`
      # (`Burrito.Builder.build/1`, line ~70). Earlier versions tolerated a
      # top-level `release.burrito` field; current versions don't — putting
      # it at the top level leaves `options[:burrito]` nil, which trips
      # `Keyword.has_key?(nil, ...)` once `BURRITO_TARGET` is set.
      burrito_options = [
        targets: target_atoms_to_keyword(target_atom),
        debug: false,
        extra_steps: [
          patch: [post: [Tau.BurritoSteps.RelinkTermbox]]
        ]
      ]

      %{
        release
        | steps: [&Burrito.wrap/1],
          options: Keyword.put(release.options, :burrito, burrito_options)
      }
    else
      release
    end
  end

  defp target_atoms_to_keyword(targets) do
    targets
    |> Enum.map(fn
      :linux_amd64 ->
        {:linux_amd64, [os: :linux, cpu: :x86_64, skip_nifs: same_target?(:linux_amd64)]}

      :linux_arm64 ->
        {:linux_arm64, [os: :linux, cpu: :aarch64, skip_nifs: same_target?(:linux_arm64)]}

      :macos_amd64 ->
        {:macos_amd64, [os: :darwin, cpu: :x86_64, skip_nifs: same_target?(:macos_amd64)]}

      :macos_arm64 ->
        {:macos_arm64, [os: :darwin, cpu: :aarch64, skip_nifs: same_target?(:macos_arm64)]}

      :windows_amd64 ->
        {:windows_amd64, [os: :windows, cpu: :x86_64, skip_nifs: same_target?(:windows_amd64)]}

      other ->
        {other, []}
    end)
  end

  defp same_target?(target) do
    host =
      case {:os.type(), :erlang.system_info(:system_architecture)} do
        {{:unix, :linux}, arch} when is_list(arch) ->
          cond do
            arch |> to_string() |> String.contains?("aarch64") -> :linux_arm64
            arch |> to_string() |> String.contains?("x86_64") -> :linux_amd64
            true -> :unknown
          end

        {{:unix, :darwin}, arch} when is_list(arch) ->
          cond do
            arch |> to_string() |> String.contains?("aarch64") -> :macos_arm64
            arch |> to_string() |> String.contains?("x86_64") -> :macos_amd64
            true -> :unknown
          end

        {{:win32, _}, _} ->
          :windows_amd64

        _ ->
          :unknown
      end

    host == target
  end

  defp aliases do
    [
      "test.property": ["test --only property"],
      lint: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "dialyzer"
      ],
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
