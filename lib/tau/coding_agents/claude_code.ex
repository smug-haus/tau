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
      16384 bytes, `:stderr_to_stdout`) and stream its stdout lines
      through `Tau.CodingAgents.ClaudeCode.StreamJson.decode_line/2`.
    * Honour `ctx.cancel_flag` between lines — `Port.close/1` + 250ms
      grace + SIGKILL (the dispatcher handles the cancel ladder; here
      we just close the Port cooperatively when the flag flips).
    * Surface auth and "not on PATH" failures as user-actionable
      `%Event.Error{}` events (AC-6).

  ## D-036 — no credential injection

  The Port inherits the host user's full environment. We do NOT
  read `~/.claude/credentials.json`, do NOT set
  `ANTHROPIC_API_KEY`, and do NOT pass any auth flags. If the host
  user is not logged in, `claude` will emit `result/error_*` itself
  and we turn that into `%Event.Error{reason: {:auth_failed, ...}}`.

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
  def cancel(handle) do
    # The dispatcher owns the cancel ladder (Port.close → SIGTERM
    # → 250ms → SIGKILL); this callback is a notification hook.
    # We accept any handle shape because the dispatcher passes the
    # drainer pid, not the port.
    case handle do
      %{port: port, tempfile: tempfile} ->
        close_port(port)
        cleanup_tempfile(tempfile)
        :ok

      _ ->
        :ok
    end
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
    case find_executable() do
      nil ->
        {:error, :claude_not_found}

      exe ->
        case maybe_write_mcp_config(task) do
          {:error, _} = err ->
            err

          {:ok, mcp_path} ->
            argv = Argv.build(task, mcp_config_path: mcp_path)

            port =
              Port.open({:spawn_executable, exe}, [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                :hide,
                :use_stdio,
                {:line, @line_size},
                {:args, argv},
                {:cd, Map.fetch!(task, :workspace)}
              ])

            stream = stream_from_port(port, mcp_path, ctx)
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

  defp stream_from_port(port, tempfile, ctx) do
    Stream.resource(
      fn ->
        %{
          port: port,
          tempfile: tempfile,
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
         %{acc | partial: "", parser: parser, tail_text: tail_text(acc.tail_text, full_line)}}

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

  defp handle_port_exit(acc, status) do
    {leftover_events, parser} =
      if acc.partial != "" do
        StreamJson.decode_line(acc.partial, acc.parser)
      else
        {[], acc.parser}
      end

    acc = %{acc | partial: "", parser: parser}

    # If the parser already saw a `result/*` line it produced a
    # %Done{} (success) or %Error{recoverable: false} (failure). In
    # either case the dispatcher takes it from here. But if the
    # subprocess died without emitting one (e.g. crashed, killed by
    # signal, exit 127 from spawn races), surface a synthetic
    # terminal pair via %Error{recoverable: false} so the dispatcher
    # can synthesise a Done with status -1 (and we keep the original
    # exit_code in the reason for diagnostics).
    closing =
      if status == 0 do
        # Success exit but no result line. Treat as anomalous.
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

  defp port_done(%{port: port, tempfile: tempfile}) do
    close_port(port)
    cleanup_tempfile(tempfile)
    :ok
  end

  defp port_done(_), do: :ok

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
