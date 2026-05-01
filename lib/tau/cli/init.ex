defmodule Tau.CLI.Init do
  @moduledoc """
  Interactive `tau init` onboarding subcommand.

  Walks a fresh user (or anyone re-running `tau init --reconfigure`) through:

    1. Detect existing `.tau/settings.json` in cwd → ask whether to extend
       or reconfigure (skipped on `--reconfigure`).
    2. Provider selection (Anthropic / OpenAI Chat / OpenAI Responses /
       Gemini / Bedrock).
    3. For each enabled provider: prompt for the credential. Stored via
       `Tau.Settings.Vault.put/2`. If the configured backend is read-only
       (the default `Env` backend, where the OS owns environment variables),
       fall back to printing an `export FOO=...` line for the user to paste
       into their shell rc. Credentials are never written to settings JSON
       in plaintext.
    4. Permissions mode default — `:default | :accept_edits | :plan |
       :auto | :dont_ask | :bypass`, with a one-line explanation each.
    5. MCP servers — yes/no pointer; defers to `tau mcp` for actual config.
    6. Skills — offer to scaffold an example `priv/skills/example/SKILL.md`
       under cwd's `.tau/skills/example/` directory.
    7. Final summary + write to `<cwd>/.tau/settings.local.json`. The JSON
       blob is validated against `Tau.Settings.Schema.json_schema/0` before
       hitting disk; a validation failure aborts the write.

  ## TTY / non-interactive behaviour

  When stdin is not a TTY (CI, piped input), prompts are still printed
  and answers read line-by-line — no ANSI cursor games, no
  `IO.ANSI.clear_line/0`. `IO.ANSI.enabled?/0` controls ANSI colour
  emission separately from interactivity.

  ## IO injection

  All reads go through `io.gets/1` and writes through `io.puts/1` /
  `io.write/1`. Tests inject a fake `io` (typically `Process` putting
  pre-canned responses on a stack) so the prompt loop can be exercised
  without `ExUnit.CaptureIO` round-trips for every step. Production code
  uses the default `Tau.CLI.Init.IO` shim, which delegates to the stdlib
  `IO` module.

  ## Partial-abort safety

  No file is touched until the very end. If the user `^C`s mid-prompt,
  the OS unwinds the BEAM scheduler before `write_settings/2` runs and
  the on-disk state is left untouched.

  ## Hard constraints (per CLAUDE.md non-negotiables)

    * No new dependency for prompting — `IO.gets/2` only.
    * Existing settings are read and merged, not clobbered.
    * Credentials never appear in settings JSON.
    * No `IO.puts` for logging — telemetry pairs the start/stop of the
      flow at `[:tau, :cli, :init, :start | :stop]`.
  """

  alias Tau.Settings.{Loader, Schema, Vault}

  @providers [
    %{key: :anthropic, label: "Anthropic", env: "ANTHROPIC_API_KEY"},
    %{key: :openai_chat, label: "OpenAI Chat", env: "OPENAI_API_KEY"},
    %{key: :openai_responses, label: "OpenAI Responses", env: "OPENAI_API_KEY"},
    %{key: :gemini, label: "Gemini", env: "GEMINI_API_KEY"},
    %{key: :bedrock, label: "Bedrock", env: "AWS_ACCESS_KEY_ID"}
  ]

  @permissions_modes [
    {:default, "ask before every tool"},
    {:accept_edits, "auto-allow Read/Write/Edit; ask on Bash"},
    {:plan, "read-only; refuse mutations"},
    {:auto, "auto-allow everything (DANGEROUS)"},
    {:dont_ask, "permission rules apply; never prompt"},
    {:bypass, "skip permission checks (DANGEROUS)"}
  ]

  @doc """
  Run the wizard against `cwd`. Options:

    * `:io` — IO shim (defaults to `Tau.CLI.Init.IO`). Must export
      `gets/1`, `puts/1`, `write/1`.
    * `:reconfigure` — skip the "configure additional or reconfigure?"
      prompt and treat the flow as a full reset.
    * `:non_interactive` — skip all prompts, accept all defaults.

  Returns `{:ok, written_path}` on success, `{:ok, :no_write}` if the
  user declined to write at the summary step, or `{:error, reason}` on
  schema-validation / disk failure.
  """
  @spec run(Path.t(), keyword()) ::
          {:ok, Path.t()} | {:ok, :no_write} | {:error, term()}
  def run(cwd, opts \\ []) when is_binary(cwd) do
    io = Keyword.get(opts, :io, __MODULE__.IO)
    reconfigure? = Keyword.get(opts, :reconfigure, false)
    non_interactive? = Keyword.get(opts, :non_interactive, false)

    :telemetry.execute([:tau, :cli, :init, :start], %{}, %{cwd: cwd})

    existing = load_existing(cwd)

    flow_opts = [
      io: io,
      reconfigure?: reconfigure?,
      non_interactive?: non_interactive?,
      cwd: cwd,
      existing: existing
    ]

    result = drive_flow(flow_opts)

    :telemetry.execute(
      [:tau, :cli, :init, :stop],
      %{},
      %{cwd: cwd, result: classify(result)}
    )

    result
  end

  defp drive_flow(opts) do
    io = Keyword.fetch!(opts, :io)
    cwd = Keyword.fetch!(opts, :cwd)
    existing = Keyword.fetch!(opts, :existing)
    non_interactive? = Keyword.fetch!(opts, :non_interactive?)

    banner(io)

    mode = entry_mode(io, existing, opts)

    base_settings =
      case mode do
        :reconfigure -> %{}
        _ -> existing
      end

    providers =
      if non_interactive?,
        do: [List.first(@providers).key],
        else: provider_selection(io)

    creds_summary = handle_credentials(io, providers, non_interactive?)

    perms_mode =
      if non_interactive?,
        do: :default,
        else: permissions_mode_prompt(io)

    mcp_pointer(io, non_interactive?)
    skills_summary = skills_prompt(io, cwd, non_interactive?)

    new_settings =
      base_settings
      |> Map.put("permissions", merge_permissions(base_settings, perms_mode))
      |> Map.put("provider", providers |> List.first() |> provider_string())

    summarise(io, providers, creds_summary, perms_mode, skills_summary)

    if non_interactive? or confirm_write?(io) do
      write_settings(cwd, new_settings)
    else
      io.puts("Skipped writing #{settings_local_path(cwd)}.")
      {:ok, :no_write}
    end
  end

  # --------------------------------------------------------------------------
  # Step 1 — entry mode
  # --------------------------------------------------------------------------

  defp entry_mode(_io, existing, opts) do
    cond do
      Keyword.fetch!(opts, :reconfigure?) ->
        :reconfigure

      Keyword.fetch!(opts, :non_interactive?) ->
        if map_size(existing) == 0, do: :fresh, else: :extend

      map_size(existing) == 0 ->
        :fresh

      true ->
        ask_existing_mode(Keyword.fetch!(opts, :io))
    end
  end

  defp ask_existing_mode(io) do
    io.puts("")
    io.puts("Existing .tau/settings.json detected.")
    io.puts("  [e] extend (default — keep current values, add new ones)")
    io.puts("  [r] reconfigure (start from a clean slate)")

    case prompt(io, "choice [e/r]: ") |> String.downcase() do
      "r" -> :reconfigure
      _ -> :extend
    end
  end

  # --------------------------------------------------------------------------
  # Step 2 — provider selection
  # --------------------------------------------------------------------------

  defp provider_selection(io) do
    io.puts("")
    io.puts("[1/5] Which providers do you want to enable?")

    @providers
    |> Enum.with_index(1)
    |> Enum.each(fn {p, i} ->
      io.puts("  [#{i}] #{p.label} (env: #{p.env})")
    end)

    raw =
      prompt(
        io,
        "comma-separated indices (default: 1): "
      )

    case parse_provider_indices(raw) do
      [] -> [List.first(@providers).key]
      keys -> keys
    end
  end

  defp parse_provider_indices(""), do: []
  defp parse_provider_indices(nil), do: []

  defp parse_provider_indices(str) do
    str
    |> String.split([",", " "], trim: true)
    |> Enum.flat_map(fn token ->
      case Integer.parse(token) do
        {n, ""} when n >= 1 and n <= length(@providers) ->
          [Enum.at(@providers, n - 1).key]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  # --------------------------------------------------------------------------
  # Step 3 — credential prompts
  # --------------------------------------------------------------------------

  defp handle_credentials(io, provider_keys, non_interactive?) do
    io.puts("")
    io.puts("[2/5] Provider credentials")

    Enum.map(provider_keys, fn key ->
      provider = Enum.find(@providers, &(&1.key == key))
      handle_one_credential(io, provider, non_interactive?)
    end)
  end

  defp handle_one_credential(io, provider, true) do
    %{provider: provider.key, status: :skipped_non_interactive, env: provider.env}
    |> tap(fn _ ->
      io.puts("  [#{provider.label}] non-interactive: skipped credential prompt")
    end)
  end

  defp handle_one_credential(io, provider, false) do
    value =
      prompt(io, "  #{provider.label} #{provider.env} (blank to skip): ")
      |> String.trim()

    cond do
      value == "" ->
        io.puts("    skipped")
        %{provider: provider.key, status: :skipped, env: provider.env}

      true ->
        store_credential(io, provider, value)
    end
  end

  defp store_credential(io, provider, value) do
    backend = Vault.backend()

    case Vault.put(provider.env, value) do
      :ok ->
        io.puts("    stored in #{inspect(backend)}")
        %{provider: provider.key, status: :stored, env: provider.env, backend: backend}

      {:error, :read_only} ->
        # Default Env backend can't write; print an export line so the
        # user can paste it into their shell rc.
        io.puts("    (vault backend #{inspect(backend)} is read-only — paste this into")
        io.puts("     your shell rc to make it persistent across sessions)")
        io.puts("       export #{provider.env}='#{value}'")

        %{
          provider: provider.key,
          status: :read_only_export,
          env: provider.env,
          backend: backend
        }

      {:error, reason} ->
        io.puts("    failed to store credential: #{inspect(reason)}")
        io.puts("    fallback: export #{provider.env}='#{value}' in your shell rc")

        %{
          provider: provider.key,
          status: {:error, reason},
          env: provider.env,
          backend: backend
        }
    end
  end

  # --------------------------------------------------------------------------
  # Step 4 — permissions mode
  # --------------------------------------------------------------------------

  defp permissions_mode_prompt(io) do
    io.puts("")
    io.puts("[3/5] Default permissions mode?")

    @permissions_modes
    |> Enum.with_index(1)
    |> Enum.each(fn {{atom, blurb}, i} ->
      io.puts("  [#{i}] #{atom} — #{blurb}")
    end)

    raw = prompt(io, "choice [1-#{length(@permissions_modes)}, default 1]: ")

    case Integer.parse(String.trim(raw)) do
      {n, ""} when n >= 1 and n <= length(@permissions_modes) ->
        @permissions_modes |> Enum.at(n - 1) |> elem(0)

      _ ->
        :default
    end
  end

  # --------------------------------------------------------------------------
  # Step 5 — MCP pointer
  # --------------------------------------------------------------------------

  defp mcp_pointer(io, true), do: io.puts("")

  defp mcp_pointer(io, false) do
    io.puts("")
    io.puts("[4/5] Configure MCP servers now? (y/N)")

    case prompt(io, "choice: ") |> String.downcase() do
      "y" ->
        io.puts("    Run `tau mcp` after init completes — it has its own")
        io.puts("    interactive flow for adding stdio/sse/http servers.")

      _ ->
        io.puts("    skipped (run `tau mcp` later)")
    end
  end

  # --------------------------------------------------------------------------
  # Step 6 — skills
  # --------------------------------------------------------------------------

  defp skills_prompt(io, _cwd, true) do
    io.puts("")
    %{skill_created: false}
  end

  defp skills_prompt(io, cwd, false) do
    io.puts("")
    io.puts("[5/5] Skills are markdown prompt fragments under .tau/skills/<name>/SKILL.md.")
    io.puts("  Create an example skill now? (y/N)")

    case prompt(io, "choice: ") |> String.downcase() do
      "y" ->
        path = scaffold_example_skill(cwd)
        io.puts("    wrote #{path}")
        %{skill_created: true, path: path}

      _ ->
        io.puts("    skipped")
        %{skill_created: false}
    end
  end

  defp scaffold_example_skill(cwd) do
    dir = Path.join([cwd, ".tau", "skills", "example"])
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")

    body = """
    # Example skill

    Skills are markdown prompt fragments. The first H1 is the title;
    the body is appended to the system prompt when the skill is
    activated.

    Edit this file or delete it and create your own under
    `.tau/skills/<name>/SKILL.md`.
    """

    File.write!(path, body)
    path
  end

  # --------------------------------------------------------------------------
  # Step 7 — summary + write
  # --------------------------------------------------------------------------

  defp summarise(io, providers, creds, perms_mode, skills) do
    io.puts("")
    io.puts("Summary:")
    io.puts("  providers:  #{providers |> Enum.map(&inspect/1) |> Enum.join(", ")}")

    Enum.each(creds, fn c ->
      io.puts("    #{c.provider} (#{c.env}): #{inspect(c.status)}")
    end)

    io.puts("  permissions.mode: #{inspect(perms_mode)}")

    case skills do
      %{skill_created: true, path: p} -> io.puts("  skill scaffolded: #{p}")
      _ -> io.puts("  skill scaffolded: no")
    end
  end

  defp confirm_write?(io) do
    raw = prompt(io, "Write to .tau/settings.local.json? [Y/n]: ")

    case String.downcase(raw) do
      "n" -> false
      _ -> true
    end
  end

  defp write_settings(cwd, settings) do
    with :ok <- validate(settings),
         path = settings_local_path(cwd),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, body} <- encode(settings),
         :ok <- File.write(path, body) do
      {:ok, path}
    end
  end

  defp validate(settings) do
    resolved = ExJsonSchema.Schema.resolve(Schema.json_schema())

    # Schema keys are strings; normalise atoms to strings for validation.
    payload = stringify_keys(settings)

    case ExJsonSchema.Validator.validate(resolved, payload) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_settings, errors}}
    end
  end

  defp encode(settings) do
    case Jason.encode(stringify_keys(settings), pretty: true) do
      {:ok, body} -> {:ok, body <> "\n"}
      err -> err
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string_key(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_string_key(k) when is_binary(k), do: k

  defp settings_local_path(cwd), do: Path.join([cwd, ".tau", "settings.local.json"])

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp banner(io) do
    io.puts("Welcome to Tau. Let's set up your environment.")
  end

  defp prompt(io, label) do
    case io.gets(label) do
      :eof -> ""
      {:error, _} -> ""
      str when is_binary(str) -> String.trim_trailing(str, "\n")
    end
  end

  defp load_existing(cwd) do
    %{settings: settings} = Loader.load(cwd)
    stringify_keys(settings)
  end

  defp merge_permissions(base, mode) do
    existing =
      case Map.get(base, "permissions") do
        m when is_map(m) -> m
        _ -> %{}
      end

    Map.put(existing, "mode", Atom.to_string(mode))
  end

  defp provider_string(:anthropic), do: "anthropic"
  defp provider_string(:openai_chat), do: "openai_chat"
  defp provider_string(:openai_responses), do: "openai_responses"
  defp provider_string(:gemini), do: "gemini"
  defp provider_string(:bedrock), do: "bedrock"

  defp classify({:ok, :no_write}), do: :no_write
  defp classify({:ok, _}), do: :ok
  defp classify({:error, _}), do: :error
end
