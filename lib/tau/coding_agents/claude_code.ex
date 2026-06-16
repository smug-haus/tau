defmodule Tau.CodingAgents.ClaudeCode do
  @moduledoc """
  `Tau.CodingAgent` adapter for the Anthropic Claude Code CLI.

  Spawns `claude --output-format stream-json --verbose -p <prompt>` as
  a subprocess and normalises its NDJSON output into
  `Tau.CodingAgent.Event` structs.

  ## Responsibilities

    * Validate `task.workspace` exists and is a directory (D-033).
    * Locate the `claude` executable (`System.find_executable/1`).
      If absent, return `{:error, :claude_not_found}` synchronously
      — the dispatcher synthesises the `%Done{exit_status: -1}` for
      this case.
    * Build argv via `Tau.CodingAgents.ClaudeCode.Argv.build/2`.
    * Optionally write a temporary `--mcp-config` file when
      `task.mcp_servers` is non-empty; tear it down on `cancel/1`
      or stream completion.
    * Open a Port (`:spawn_executable`, `:exit_status`, `:line` of
      16384 bytes) and stream its stdout lines through
      `Tau.CodingAgents.ClaudeCode.StreamJson.decode_line/2`. stderr
      is intentionally NOT redirected to stdout — banner / warning
      lines that don't start with `{` would otherwise be parsed as
      malformed JSON and pollute every transcript with recoverable
      `:parse_error` events.
    * Open the Port inside `Stream.resource`'s start_fun so its
      owner is the drainer process — Port messages MUST route to
      the `receive` loop that consumes them. (Opening in `start/2`
      would make the caller — usually the dispatcher GenServer —
      the owner, and the drainer would never see any data.)
    * Honour `ctx.cancel_flag` between lines — `Port.close/1` + 250ms
      grace + SIGKILL (the dispatcher handles the cancel ladder; here
      we just close the Port cooperatively when the flag flips).
    * Surface auth and "not on PATH" failures as user-actionable
      `%Event.Error{}` events (AC-6).

  ## D-036 — no credential injection

  Tau MUST NOT inject or copy credentials into the subprocess. We do NOT
  read `~/.claude/credentials.json` and do NOT pass any auth flags. If the
  host user is not logged in, `claude` will emit `result/error_*` itself
  and we turn that into `%Event.Error{reason: {:auth_failed, ...}}`.

  ## D-375 — adapter-level metered-credential scrub (defense-in-depth)

  By default, `start/2` passes `{:env, [{~c"ANTHROPIC_API_KEY", false},
  {~c"ANTHROPIC_AUTH_TOKEN", false}, {~c"ANTHROPIC_BASE_URL", false}]}`
  to `Port.open` so the `claude` subprocess never inherits any metered
  Anthropic credential from the host environment. The Erlang Port driver
  treats a `false` value as "remove this variable from the child
  environment" (POSIX unsetenv semantics).

  The three scrubbed variables are all metered-spend vectors:
    - `ANTHROPIC_API_KEY`    — primary API key
    - `ANTHROPIC_AUTH_TOKEN` — metered bearer token honoured by the claude CLI
    - `ANTHROPIC_BASE_URL`   — proxy endpoint redirect (paid spend vector)

  The only opt-out is `ctx[:allow_metered] == true`, which passes all
  three through to the child unchanged. Use this only in controlled
  environments where metered access is intentional. Production callers
  MUST NOT set this flag.

  ## Test-friendly source injection

  `ctx[:claude_code_source]` lets tests skip the subprocess entirely.
  Accepted forms:

    * `{:fixture, path :: String.t()}` — read NDJSON lines from a
      fixture file and feed them through the same parser pipeline.
    * `{:lines, [binary()]}` — feed the lines directly.

  When `claude_code_source` is set, no Port is opened and no
  executable check runs. Used by the contract tests.
  """

  @behaviour Tau.CodingAgent

  alias Tau.CodingAgent.Event
  alias Tau.CodingAgents.ClaudeCode.Argv
  alias Tau.CodingAgents.ClaudeCode.ConfigDir
  alias Tau.CodingAgents.ClaudeCode.StreamJson

  require Logger

  @line_size 16_384
  @port_drain_timeout 1_000

  @impl Tau.CodingAgent
  def capabilities,
    do: %{
      streaming: true,
      tool_restriction: true,
      mcp_client: true,
      session_resume: true,
      cost_reporting: true,
      workspace_isolation: :either
    }

  @impl Tau.CodingAgent
  def configure(opts) when is_map(opts), do: {:ok, opts}

  @impl Tau.CodingAgent
  def start(task, ctx) when is_map(task) do
    with :ok <- validate_workspace(task) do
      case source_for(task, ctx) do
        {:lines, lines} ->
          {:ok, stream_from_lines(lines, ctx)}

        {:fixture, path} ->
          {:ok, stream_from_lines(read_fixture_lines(path), ctx)}

        :spawn ->
          start_spawn(task, ctx)
      end
    end
  end

  @impl Tau.CodingAgent
  def cancel(_handle) do
    # Cleanup happens elsewhere: BEAM closes the Port when the
    # dispatcher exits the drainer (subprocess gets EOF), and a janitor
    # `Process.monitor`s the drainer to unlink the MCP tempfile on
    # `:DOWN`. `cancel/1` is informational only.
    :ok
  end

  @doc """
  Seed an isolated Claude config directory for D-388 per-worker config isolation.

  Delegates to `ConfigDir.seed/2` with the `:source_creds` option (defaults
  to `ConfigDir.default_source_creds_path()`). Returns `target_dir`.

  Accepts either 1 argument (target_dir with default source creds) or 2
  arguments (target_dir plus keyword opts with optional `:source_creds`).
  """
  @spec seed_config_dir(String.t(), keyword()) :: String.t()
  def seed_config_dir(target_dir, opts \\ []) do
    source = Keyword.get(opts, :source_creds, ConfigDir.default_source_creds_path())
    :ok = ConfigDir.seed(target_dir, source)
    target_dir
  end

  # ── workspace validation (D-033) ──────────────────────────────────

  defp validate_workspace(%{workspace: path}) when is_binary(path) and path != "" do
    if File.dir?(path), do: :ok, else: {:error, {:workspace_invalid, path}}
  end

  defp validate_workspace(_), do: {:error, :workspace_missing}

  # ── source selection ─────────────────────────────────────────────

  defp source_for(task, ctx) do
    cond do
      match?({:lines, _}, ctx[:claude_code_source]) -> ctx[:claude_code_source]
      match?({:fixture, _}, ctx[:claude_code_source]) -> ctx[:claude_code_source]
      match?({:lines, _}, task[:claude_code_source]) -> task[:claude_code_source]
      match?({:fixture, _}, task[:claude_code_source]) -> task[:claude_code_source]
      true -> :spawn
    end
  end

  defp read_fixture_lines(path) do
    path
    |> File.stream!(:line)
    |> Enum.to_list()
  end

  # ── spawn path ───────────────────────────────────────────────────

  defp start_spawn(task, ctx) do
    # Resolve executable + MCP tempfile synchronously so configuration
    # errors surface via `{:error, _}` per D-035. The Port itself is
    # opened lazily inside `Stream.resource`'s start_fun so its owner
    # is the drainer process (the one that runs the `receive` loop),
    # not whatever process happened to call `start/2`. Without this
    # split, real-`claude` runs time out because Port messages route
    # to the dispatcher mailbox and the drainer never sees them.
    case find_executable() do
      nil ->
        {:error, :claude_not_found}

      exe ->
        case maybe_write_mcp_config(task) do
          {:error, _} = err ->
            err

          {:ok, mcp_path} ->
            argv = Argv.build(task, mcp_config_path: mcp_path)
            stream = stream_from_port(exe, argv, task, mcp_path, ctx)
            {:ok, stream}
        end
    end
  end

  defp find_executable, do: System.find_executable("claude")

  # ── mcp-config tempfile ──────────────────────────────────────────

  defp maybe_write_mcp_config(%{mcp_servers: servers}) when is_list(servers) and servers != [] do
    payload = %{"mcpServers" => normalise_mcp_servers(servers)}

    case Jason.encode(payload) do
      {:ok, json} ->
        tmp =
          Path.join(
            System.tmp_dir!(),
            "tau-claude-mcp-#{System.unique_integer([:positive])}.json"
          )

        case File.write(tmp, json) do
          :ok -> {:ok, tmp}
          {:error, reason} -> {:error, {:mcp_config_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:mcp_config_encode_failed, reason}}
    end
  end

  defp maybe_write_mcp_config(_task), do: {:ok, nil}

  defp normalise_mcp_servers(servers) do
    Enum.reduce(servers, %{}, fn server, acc ->
      name = Map.get(server, "name") || Map.get(server, :name) || "tau-mcp-#{map_size(acc)}"
      Map.put(acc, name, Map.drop(server, [:name, "name"]))
    end)
  end

  defp cleanup_tempfile(nil), do: :ok

  defp cleanup_tempfile(path) when is_binary(path) do
    _ = File.rm(path)
    :ok
  end

  # ── stream construction (port) ───────────────────────────────────

  defp stream_from_port(exe, argv, task, tempfile, ctx) do
    workspace = Map.fetch!(task, :workspace)
    allow_metered = Map.get(ctx, :allow_metered) == true

    Stream.resource(
      fn ->
        # Open the Port HERE — in the drainer process — so Port
        # messages route to the receive loop in `pull_port_line/1`.
        # See start_spawn/2 for the rationale.
        #
        # D-375 env scrub: remove all three metered Anthropic credential
        # variables from the child env by default so the claude subprocess
        # cannot reach any metered API path even if credentials are set in
        # the host environment. Erlang Port treats {key, false} as "unset
        # this variable in the child" (POSIX unsetenv semantics).
        # The only opt-out is ctx[:allow_metered] == true.
        # {:env, []} inherits all parent env vars unchanged;
        # {:env, [{key, false}, ...]} unsets the named vars and inherits the rest.
        #
        # Scrubbed variables (all three are metered-spend vectors):
        #   ANTHROPIC_API_KEY    — primary API key
        #   ANTHROPIC_AUTH_TOKEN — metered bearer token honoured by the claude CLI
        #   ANTHROPIC_BASE_URL   — proxy endpoint redirect (paid spend vector)
        # D-388: create a per-invocation isolated config dir so each subprocess
        # gets its own CLAUDE_CONFIG_DIR (OAuth creds only, no operator hooks).
        source_creds = Map.get(ctx, :claude_config_source, ConfigDir.default_source_creds_path())
        isolated_config_dir = ConfigDir.create_isolated(source_creds)

        port_env =
          if allow_metered do
            [{~c"CLAUDE_CONFIG_DIR", String.to_charlist(isolated_config_dir)}]
          else
            [
              {~c"ANTHROPIC_API_KEY", false},
              {~c"ANTHROPIC_AUTH_TOKEN", false},
              {~c"ANTHROPIC_BASE_URL", false},
              {~c"CLAUDE_CONFIG_DIR", String.to_charlist(isolated_config_dir)}
            ]
          end

        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :hide,
            :use_stdio,
            {:line, @line_size},
            {:args, argv},
            {:cd, workspace},
            {:env, port_env}
          ])

        # Janitor: monitors the drainer (this process) and unlinks
        # the MCP tempfile on :DOWN. Survives `Process.exit(_, :shutdown)`
        # which would otherwise bypass `Stream.resource`'s after_fun.
        janitor = spawn_tempfile_janitor(tempfile, self())

        %{
          port: port,
          tempfile: tempfile,
          janitor: janitor,
          partial: "",
          parser: StreamJson.new(),
          cancel_flag: Map.get(ctx, :cancel_flag),
          done_emitted?: false,
          exit_status: nil,
          tail_text: ""
        }
      end,
      &port_next/1,
      &port_done/1
    )
  end

  # The janitor is intentionally unsupervised — it's a single-purpose
  # `Process.monitor` + `File.rm` helper bound to one stream. It exits
  # `:normal` after cleanup. If the BEAM dies before cleanup, OS-level
  # /tmp cleanup is moot.
  defp spawn_tempfile_janitor(nil, _drain_pid), do: nil

  defp spawn_tempfile_janitor(tempfile, drain_pid) when is_binary(tempfile) do
    spawn(fn ->
      ref = Process.monitor(drain_pid)

      receive do
        {:DOWN, ^ref, :process, ^drain_pid, _reason} ->
          _ = File.rm(tempfile)
          :ok

        {:cleanup_done, ^drain_pid} ->
          Process.demonitor(ref, [:flush])
          :ok
      end
    end)
  end

  defp port_next(%{done_emitted?: true}), do: {:halt, %{}}

  defp port_next(%{cancel_flag: ref} = acc) when not is_nil(ref) do
    if cancelled?(ref) do
      close_port(acc.port)

      events = [
        %Event.Error{reason: :cancelled, recoverable: false}
      ]

      {events, %{acc | done_emitted?: true}}
    else
      pull_port_line(acc)
    end
  end

  defp port_next(acc), do: pull_port_line(acc)

  defp pull_port_line(%{port: port} = acc) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        full_line = acc.partial <> chunk
        {events, parser} = StreamJson.decode_line(full_line, acc.parser)

        {events,
         %{
           acc
           | partial: "",
             parser: parser,
             tail_text: tail_text(acc.tail_text, full_line),
             done_emitted?: acc.done_emitted? or terminal?(events)
         }}

      {^port, {:data, {:noeol, chunk}}} ->
        # A line that exceeded `:line` size. Accumulate and continue.
        {[], %{acc | partial: acc.partial <> chunk}}

      {^port, {:exit_status, status}} ->
        handle_port_exit(acc, status)
    after
      @port_drain_timeout ->
        # No data and no exit yet. Yield control so the dispatcher
        # can check the cancel flag again.
        {[], acc}
    end
  end

  # D-031: %Done{} is terminal — the first one ends the stream. Also
  # treat a non-recoverable %Error{} as terminal because the dispatcher
  # synthesises a %Done{} on its tail and we MUST NOT emit anything
  # after that.
  defp terminal?(events) when is_list(events) do
    Enum.any?(events, fn
      %Event.Done{} -> true
      %Event.Error{recoverable: false} -> true
      _ -> false
    end)
  end

  defp handle_port_exit(%{done_emitted?: true} = acc, status) do
    # The parser already produced a terminal event from a `result/*`
    # line; the post-exit path MUST NOT append another %Error{}
    # (D-031: Done is terminal — consumers may treat the first %Done{}
    # as end-of-stream). Drain any partial buffer in case it carries
    # non-terminal trailing JSON, but suppress synthetic closures.
    {leftover_events, parser} =
      if acc.partial != "" do
        StreamJson.decode_line(acc.partial, acc.parser)
      else
        {[], acc.parser}
      end

    # Filter out anything terminal so we never emit a Done/Error after
    # the real one.
    leftover_events = Enum.reject(leftover_events, &terminal_event?/1)

    {leftover_events, %{acc | partial: "", parser: parser, exit_status: status}}
  end

  defp handle_port_exit(acc, status) do
    {leftover_events, parser} =
      if acc.partial != "" do
        StreamJson.decode_line(acc.partial, acc.parser)
      else
        {[], acc.parser}
      end

    acc = %{acc | partial: "", parser: parser}

    # No result line ever arrived. Surface a synthetic terminal
    # %Error{recoverable: false} so the dispatcher can synthesise a
    # %Done{exit_status: -1} for the consumer.
    closing =
      if status == 0 do
        # Success exit but no result line. Anomalous (process exited 0
        # before flushing stream-json). Surface for diagnostics.
        [
          %Event.Error{
            reason: {:no_result_event, "claude exited 0 without emitting result"},
            recoverable: false
          }
        ]
      else
        {kind, message} = StreamJson.classify_failure(status, acc.tail_text)
        [%Event.Error{reason: {kind, message}, recoverable: false}]
      end

    events = leftover_events ++ closing
    {events, %{acc | done_emitted?: true, exit_status: status}}
  end

  defp terminal_event?(%Event.Done{}), do: true
  defp terminal_event?(%Event.Error{recoverable: false}), do: true
  defp terminal_event?(_), do: false

  defp port_done(%{port: port, tempfile: tempfile, janitor: janitor}) do
    close_port(port)
    cleanup_tempfile(tempfile)
    notify_janitor(janitor)
    :ok
  end

  defp port_done(_), do: :ok

  defp notify_janitor(nil), do: :ok

  defp notify_janitor(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Kernel.send(pid, {:cleanup_done, self()})
    end

    :ok
  end

  defp close_port(nil), do: :ok

  defp close_port(port) when is_port(port) do
    try do
      if Port.info(port) do
        Port.close(port)
      end
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp close_port(_), do: :ok

  defp cancelled?(ref), do: :counters.get(ref, 1) > 0

  # Keep a sliding tail of the last ~2k of raw output so AC-6 has
  # something to classify when the subprocess exits non-zero without
  # a structured result event.
  defp tail_text(prev, line) do
    combined = prev <> line <> "\n"

    if byte_size(combined) > 2048 do
      binary_part(combined, byte_size(combined) - 2048, 2048)
    else
      combined
    end
  end

  # ── stream construction (fixture / test injection) ───────────────

  defp stream_from_lines(lines, ctx) do
    Stream.resource(
      fn ->
        %{
          lines: lines,
          parser: StreamJson.new(),
          cancel_flag: Map.get(ctx, :cancel_flag),
          done_emitted?: false
        }
      end,
      &lines_next/1,
      fn _ -> :ok end
    )
  end

  defp lines_next(%{done_emitted?: true}), do: {:halt, %{}}

  defp lines_next(%{lines: []} = acc), do: {:halt, acc}

  defp lines_next(%{cancel_flag: ref} = acc) when not is_nil(ref) do
    if cancelled?(ref) do
      {[%Event.Error{reason: :cancelled, recoverable: false}], %{acc | done_emitted?: true}}
    else
      next_line(acc)
    end
  end

  defp lines_next(acc), do: next_line(acc)

  defp next_line(%{lines: [line | rest], parser: parser} = acc) do
    {events, parser} = StreamJson.decode_line(line, parser)
    {events, %{acc | lines: rest, parser: parser}}
  end
end
