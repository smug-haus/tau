defmodule Tau.CLI do
  @moduledoc """
  Escript entry point.

  Subcommands currently registered in `spec/0`:

      tau                              # interactive TUI (M6+)
      tau run "prompt" [opts]          # one-shot non-interactive, FSM-backed
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

  ## Headless FSM-backed run (D-058 / AC-10 / SPEC-USER-TURN §4 B2)

  `tau run` drives a full `Tau.Session` FSM: tools (including `Agent` and
  `Bash`) are registered, every turn is persisted to JSONL, and the session
  receives the same permissions/compaction/PubSub infrastructure as a TUI
  session. This resolves issue #213 (tau run bypassed the FSM entirely).

  The run loop subscribes to the session's PubSub topic BEFORE calling
  `Tau.start_session/1` (D-004 compliance), sends the prompt, and consumes
  the event stream until `%Tau.Session.Events.SessionEnd{}` is received.
  Text output is written to stdout; tool events are silently consumed.
  Exit code: 0 on `:end_turn`, 1 on error or abnormal session end.

  Optional `--system-prompt <text>` (or `--system-prompt-file <path>`)
  prepends a system-level persona to the session. The content is injected
  as an `active_skill` with `:persona_lifetime :session` so it survives
  multi-turn iteration inside a single `tau run` invocation.
  """

  alias Tau.Session.Events

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
      version: Tau.Build.version(),
      subcommands: [
        run: [
          name: "run",
          about: "Run a single prompt non-interactively via the FSM (streams to stdout).",
          args: [prompt: [help: "The prompt", required: true]],
          options: [
            provider: [short: "-p", long: "--provider", help: "Provider id"],
            model: [short: "-m", long: "--model", help: "Model id"],
            session: [short: "-s", long: "--session", help: "Session id (resume)"],
            # D-058 / AC-10 (SPEC-USER-TURN): headless system-prompt injection
            # seam. Contents are injected as an active_skill with
            # :persona_lifetime :session so they survive multi-turn iteration.
            system_prompt: [
              long: "--system-prompt",
              help: "System prompt text prepended to the session (persona injection seam)"
            ],
            system_prompt_file: [
              long: "--system-prompt-file",
              help: "Path to a file whose contents become the system prompt"
            ]
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
              about: "Force the MCP reconciler to reconcile against settings.",
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
            model: [short: "-m", long: "--model", help: "Model id"],
            # SPEC-CODING-AGENT (#191) — session-mode coding-agent surface.
            # When set, the TUI's "Send" routes user messages to the
            # named coding-agent (e.g. `claude_code`, `replay`) via the
            # `Tau.CodingAgent.Dispatcher` and the FSM's
            # `:coding_agent_streaming` state, in place of the provider
            # path. Default `nil` preserves the legacy `Tau.Provider`
            # path byte-identically.
            coding_agent: [
              long: "--coding-agent",
              help:
                "Run the TUI in coding-agent session mode (claude_code|replay|<Module>); skips the provider path"
            ]
          ]
        ]
      ]
    )
  end

  # D-058 / AC-10 (SPEC-USER-TURN §4 B2): headless FSM-backed session run.
  #
  # Drives a full Tau.Session FSM so that tools (Agent, Bash, etc.) are
  # registered, every turn is JSONL-persisted, and the session is
  # lifecycle-identical to a TUI session. Prior to this, `tau run` called
  # provider.stream/3 directly — no FSM, no tools, no persistence (#213).
  #
  # Subscribe-before-start ordering (D-004): Phoenix.PubSub.subscribe/2 is
  # called BEFORE Tau.start_session/1 returns so that the SessionStart event
  # (broadcast synchronously inside init/1) is not lost even though we don't
  # consume it here. Tau.stream/2 subscribes inside its Stream.resource
  # setup function, which runs when we first pull from the stream — that
  # happens AFTER start_session returns, violating D-004. We therefore
  # subscribe manually, start the session, send the message, then enumerate
  # the PubSub mailbox via receive instead of going through Tau.stream/2.
  defp run_cmd(parsed) do
    prompt = parsed.args.prompt
    provider = resolve_provider(parsed.options[:provider])
    model = parsed.options[:model]

    case resolve_system_prompt(parsed.options) do
      {:error, reason} ->
        IO.puts(:stderr, "system-prompt error: #{reason}")
        1

      {:ok, system_prompt_text} ->
        session_id = Tau.Session.generate_id()

        # D-004: subscribe BEFORE start_session so SessionStart is not missed.
        Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{session_id}")

        start_opts =
          [session_id: session_id, provider: provider]
          |> put_if_not_nil(:model, model)
          |> put_if_not_nil(:active_skill, build_headless_skill(system_prompt_text))
          |> put_if_not_nil(:persona_lifetime, system_prompt_text && :session)

        case Tau.start_session(start_opts) do
          {:ok, ^session_id} ->
            case Tau.send(session_id, prompt) do
              :ok ->
                drain_run_loop(session_id)

              {:error, reason} ->
                IO.puts(:stderr, "send error: #{inspect(reason)}")
                1
            end

          {:error, reason} ->
            IO.puts(:stderr, "session start error: #{inspect(reason)}")
            1
        end
    end
  end

  # Consume PubSub events for the headless run until SessionEnd.
  # Returns 0 on a clean stop, 1 on any error or abnormal end.
  #
  # Logic: enumerate FAILURE stop_reasons (exit 1) and the CONTINUE
  # stop_reason (loop); every other terminal stop_reason means the model
  # produced a final assistant message → exit 0.
  #
  # Failure set (verified against session.ex, message.ex, providers/):
  #   :error            — session-level error (session.ex:972, 1004, 2526, 2816)
  #   :tool_loop_aborted — tool iteration cap reached (session.ex:1844)
  #   :aborted          — coding-agent subprocess exited -2 (session.ex:2871)
  #   :compaction_failed — 3 consecutive compaction failures (session.ex:1743)
  #
  # Continue: :tool_use — more tool iterations follow; do NOT exit.
  #
  # Everything else (:stop, :length, :stop_sequence, :end_turn,
  # :content_filter, and any future provider atom) means "model finished
  # its turn and produced a usable response" → exit 0.  This inversion
  # ensures new provider atoms default to success rather than misreporting
  # as crashes (f-1 fix, D-058 amendment).
  @doc false
  def drain_run_loop(session_id) do
    receive do
      %Events.MessageEnd{session_id: ^session_id, message: msg} ->
        case msg.stop_reason do
          :tool_use ->
            # More tool iterations follow in the same session; keep waiting.
            drain_run_loop(session_id)

          failure when failure in [:error, :tool_loop_aborted, :aborted, :compaction_failed] ->
            error_text = extract_error_text(msg)
            IO.puts(:stderr, "session error (#{failure}): #{error_text}")
            Tau.stop(session_id)
            drain_session_end(session_id, 1)

          _completed ->
            # Any other stop_reason means the model produced a final assistant
            # message (:stop, :length, :stop_sequence, :content_filter, etc.).
            text = extract_assistant_text(msg)
            if text != "", do: IO.puts(text)
            # Stop the session to flush JSONL, then await SessionEnd.
            Tau.stop(session_id)
            drain_session_end(session_id, 0)
        end

      %Events.SessionEnd{session_id: ^session_id, reason: reason} ->
        # SessionEnd may arrive before we call Tau.stop (e.g. error path).
        case reason do
          :normal -> 0
          :user -> 0
          _ -> 1
        end

      # Ignore other events (ToolStart, ToolEnd, MessageStart, MessageUpdate,
      # SessionStart, SystemNotice, SkillActivated, Cancelled).
      _ ->
        drain_run_loop(session_id)
    after
      120_000 ->
        # B3 fix (D-058): timeout MUST also flush JSONL before returning.
        # Tau.stop/1 is async; drain_session_end/2 blocks until SessionEnd
        # (bounded by 10 s) so the flush completes before we exit.
        IO.puts(:stderr, "run timed out waiting for session response")
        Tau.stop(session_id)
        drain_session_end(session_id, 1)
    end
  end

  # After calling Tau.stop/1, wait for SessionEnd to confirm JSONL flush.
  @doc false
  def drain_session_end(session_id, exit_code) do
    receive do
      %Events.SessionEnd{session_id: ^session_id} -> exit_code
      _ -> drain_session_end(session_id, exit_code)
    after
      10_000 -> exit_code
    end
  end

  # Extract plain text from an assistant message (TextBlock type: :text).
  @doc false
  def extract_assistant_text(%Tau.Message.Assistant{content: blocks})
      when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{type: :text, text: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("")
  end

  def extract_assistant_text(_), do: ""

  # Extract error_message or synthesise one from content blocks.
  @doc false
  def extract_error_text(%Tau.Message.Assistant{error_message: msg})
      when is_binary(msg) and msg != "",
      do: msg

  # Fallback: no dedicated error_message field — synthesise from text blocks.
  def extract_error_text(message), do: extract_assistant_text(message)

  # Resolve --system-prompt / --system-prompt-file to {:ok, text | nil}.
  @doc false
  def resolve_system_prompt(%{system_prompt: text})
      when is_binary(text) and text != "",
      do: {:ok, text}

  def resolve_system_prompt(%{system_prompt_file: path})
      when is_binary(path) and path != "" do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  def resolve_system_prompt(_), do: {:ok, nil}

  # Build a transient %Tau.Skill{} from inline system-prompt text so the
  # session FSM injects it as a system-role message via prepend_skill_messages/2
  # (the same mechanism used by on-disk skills loaded from CLAUDE.md / .claude/
  # skills). :persona_lifetime :session is set by run_cmd/1 so the persona
  # survives multi-turn tool iteration within a single `tau run` invocation.
  @doc false
  def build_headless_skill(nil), do: nil

  def build_headless_skill(text) when is_binary(text) do
    %Tau.Skill{
      name: "headless-system-prompt",
      body: text,
      path: "<cli:--system-prompt>",
      description: "System prompt injected via --system-prompt / --system-prompt-file"
    }
  end

  defp put_if_not_nil(opts, _key, nil), do: opts
  defp put_if_not_nil(opts, key, value), do: Keyword.put(opts, key, value)

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
    IO.puts("tau #{Tau.Build.version()}")
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
        IO.puts(
          "provider Tau.Providers.Anthropic: " <> Tau.Providers.Anthropic.Auth.describe_error(err)
        )
    end

    # D-056 / C82: report Copilot auth state alongside Anthropic.
    copilot_status =
      case Tau.Providers.Copilot.Auth.resolve_oauth(%{}) do
        {:ok, _oauth_token} ->
          # Attempt to surface cached token expiry if the store has one.
          case Tau.Providers.Copilot.TokenStore.get() do
            {:ok, %{expires_at: exp}} ->
              ttl_s = max(div(exp - :os.system_time(:millisecond), 1000), 0)
              "oauth (token expires in #{ttl_s}s)"

            _ ->
              "oauth (token not yet fetched — will refresh on first use)"
          end

        {:error, _} = err ->
          Tau.Providers.Copilot.Auth.describe_error(err)
      end

    IO.puts("provider Tau.Providers.Copilot: #{copilot_status}")

    deepseek_key =
      Application.get_env(:tau, Tau.Providers.DeepSeek, [])[:api_key] ||
        System.get_env("DEEPSEEK_API_KEY")

    deepseek_status = if deepseek_key, do: "configured", else: "not configured"
    IO.puts("provider Tau.Providers.DeepSeek: deepseek #{deepseek_status}")

    groq_key =
      Application.get_env(:tau, Tau.Providers.Groq, [])[:api_key] ||
        System.get_env("GROQ_API_KEY")

    groq_status = if groq_key, do: "configured", else: "not configured"
    IO.puts("provider Tau.Providers.Groq: groq #{groq_status}")

    mistral_key =
      Application.get_env(:tau, Tau.Providers.Mistral, [])[:api_key] ||
        System.get_env("MISTRAL_API_KEY")

    mistral_status = if mistral_key, do: "configured", else: "not configured"
    IO.puts("provider Tau.Providers.Mistral: mistral #{mistral_status}")

    azure_env = Application.get_env(:tau, Tau.Providers.AzureOpenAI, [])

    azure_key = azure_env[:api_key] || System.get_env("AZURE_OPENAI_API_KEY")
    azure_endpoint = azure_env[:endpoint] || System.get_env("AZURE_OPENAI_ENDPOINT")
    azure_deployment = azure_env[:deployment] || System.get_env("AZURE_OPENAI_DEPLOYMENT")

    azure_status =
      cond do
        is_nil(azure_key) or azure_key == "" -> "api_key not configured"
        is_nil(azure_endpoint) or azure_endpoint == "" -> "endpoint not configured"
        is_nil(azure_deployment) or azure_deployment == "" -> "deployment not configured"
        true -> "configured (deployment: #{azure_deployment})"
      end

    IO.puts("provider Tau.Providers.AzureOpenAI: #{azure_status}")

    custom_env = Application.get_env(:tau, Tau.Providers.Custom, [])
    custom_base_url = custom_env[:base_url] || System.get_env("CUSTOM_BASE_URL")

    custom_api_key =
      custom_env[:api_key] ||
        System.get_env("CUSTOM_API_KEY")

    custom_base_url_status = if custom_base_url, do: "set (#{custom_base_url})", else: "not set"
    custom_key_status = if custom_api_key, do: "configured", else: "none (optional)"

    IO.puts(
      "provider Tau.Providers.Custom: base_url #{custom_base_url_status}, api_key #{custom_key_status}"
    )

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
    |> tui_put(:coding_agent, opts[:coding_agent], &resolve_coding_agent/1)
  end

  defp tui_opts(_), do: []

  defp tui_put(opts, _key, nil, _xform), do: opts
  defp tui_put(opts, key, value, xform), do: Keyword.put(opts, key, xform.(value))

  # SPEC-CODING-AGENT §4 B1 / D-031: adapters are addressed by atom in
  # tau's runtime (the FSM's `data.coding_agent` is an atom module).
  # Mirrors `resolve_provider/1`'s pattern: known short names map to
  # concrete modules; anything else is treated as a `Tau.CodingAgents.<X>`
  # module reference. Used by Optimus value -> module conversion when
  # building `Tau.TUI.RuntimeOpts`.
  @doc false
  def resolve_coding_agent(nil), do: nil
  def resolve_coding_agent("claude_code"), do: Tau.CodingAgents.ClaudeCode
  def resolve_coding_agent("claudecode"), do: Tau.CodingAgents.ClaudeCode
  def resolve_coding_agent("replay"), do: Tau.CodingAgents.Replay

  def resolve_coding_agent(other) when is_binary(other) do
    Module.concat(["Tau", "CodingAgents", String.capitalize(other)])
  end

  def resolve_coding_agent(mod) when is_atom(mod), do: mod

  defp resolve_provider(nil), do: Tau.Provider.default()
  defp resolve_provider("anthropic"), do: Tau.Providers.Anthropic
  defp resolve_provider("openai"), do: Tau.Providers.OpenAI.Chat
  defp resolve_provider("ollama"), do: Tau.Providers.OpenAI.Chat
  defp resolve_provider("local"), do: Tau.Providers.OpenAI.Chat
  defp resolve_provider("bedrock"), do: Tau.Providers.Bedrock
  defp resolve_provider("gemini"), do: Tau.Providers.Gemini
  defp resolve_provider("deepseek"), do: Tau.Providers.DeepSeek
  defp resolve_provider("groq"), do: Tau.Providers.Groq
  defp resolve_provider("mistral"), do: Tau.Providers.Mistral
  defp resolve_provider("azure"), do: Tau.Providers.AzureOpenAI
  defp resolve_provider("azure-openai"), do: Tau.Providers.AzureOpenAI
  defp resolve_provider("custom"), do: Tau.Providers.Custom
  defp resolve_provider("replay"), do: Tau.Providers.Replay

  # Last-resort fallback for "Foo" → Tau.Providers.Foo style atoms.
  # `String.capitalize/1` only touches the first byte, which is wrong
  # for compound names like "openai" (-> "Openai" ≠ "OpenAI"). Known
  # short names are handled above; this clause only fires for genuinely
  # custom provider modules a caller registers themselves.
  defp resolve_provider(other) when is_binary(other) do
    Module.concat(["Tau", "Providers", String.capitalize(other)])
  end

  defp halt(code) when is_integer(code), do: System.halt(code)
  defp halt(_), do: System.halt(0)
end
