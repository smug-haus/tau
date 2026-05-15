defmodule Tau.CodingAgents.Replay do
  @moduledoc """
  Test-fixture adapter for `Tau.CodingAgent`.

  Reads a sequence of pre-recorded `Tau.CodingAgent.Event` structs
  and emits them in order. Used to exercise the dispatcher and
  downstream consumers without depending on an external coding-agent
  CLI being on PATH.

  Mirrors `Tau.Providers.Replay` in spirit: per-run fixture via
  `task` / `ctx`, or a deployment-wide default via
  `Application.get_env(:tau, Tau.CodingAgents.Replay)[:fixture]`.

  ## Configuring per-run

      task = %{
        prompt: "noop",
        workspace: cwd,
        # fixture is either a list of Event structs or a JSONL path
        replay_fixture: events_or_path
      }

      {:ok, stream} = Tau.CodingAgents.Replay.start(task, %{})

  Tests using this pattern can be `async: true` — there is no global
  state mutation.

  ## Test-only ctx knobs

  - `:replay_delay_ms` — `Process.sleep/1` between emissions. Tests
    use this to widen the race window for cancel-mid-stream.
  - `:replay_ignore_cancel` — when `true`, the adapter does NOT
    consult the cancel flag. Drives the brutal-kill-equivalent
    path in cancellation tests.

  ## Fixture format

  A list of `%Tau.CodingAgent.Event{}` structs, OR a path to a
  JSONL file where each line is a JSON object with a `"type"`
  field and event-specific keys.
  """

  @behaviour Tau.CodingAgent

  alias Tau.CodingAgent.Event

  @default_fixture_path "test/fixtures/coding_agent_replay_default.jsonl"

  @impl Tau.CodingAgent
  def capabilities,
    do: %{
      streaming: true,
      tool_restriction: false,
      mcp_client: false,
      session_resume: false,
      cost_reporting: true,
      workspace_isolation: :either
    }

  @impl Tau.CodingAgent
  def configure(opts) when is_map(opts), do: {:ok, opts}

  @impl Tau.CodingAgent
  def start(task, ctx) when is_map(task) do
    with :ok <- validate_workspace(task) do
      events = resolve_fixture(task, ctx)
      cancel_flag = Map.get(ctx, :cancel_flag)
      delay_ms = Map.get(ctx, :replay_delay_ms, 0)
      ignore_cancel? = Map.get(ctx, :replay_ignore_cancel) == true

      stream =
        Stream.resource(
          fn -> events end,
          fn
            [] ->
              {:halt, []}

            [head | tail] ->
              if delay_ms > 0, do: Process.sleep(delay_ms)

              if not ignore_cancel? and cancelled?(cancel_flag) do
                {[%Event.Error{reason: :cancelled, recoverable: false}], []}
              else
                {[head], tail}
              end
          end,
          fn _ -> :ok end
        )

      {:ok, stream}
    end
  end

  @impl Tau.CodingAgent
  def cancel(_handle), do: :ok

  # ── helpers ───────────────────────────────────────────────────

  defp validate_workspace(%{workspace: path}) when is_binary(path) do
    # D-033: explicit workspace. We don't require it to exist
    # (tests use synthetic paths), but we DO require the field
    # be present and stringy. A real adapter would also stat it.
    :ok
  end

  defp validate_workspace(_), do: {:error, :workspace_missing}

  defp cancelled?(nil), do: false
  defp cancelled?(ref), do: :counters.get(ref, 1) > 0

  defp resolve_fixture(task, ctx) do
    cond do
      is_list(task[:replay_fixture]) ->
        task[:replay_fixture]

      is_binary(task[:replay_fixture]) and File.regular?(task[:replay_fixture]) ->
        from_file(task[:replay_fixture])

      is_list(ctx[:replay_fixture]) ->
        ctx[:replay_fixture]

      is_binary(ctx[:replay_fixture]) and File.regular?(ctx[:replay_fixture]) ->
        from_file(ctx[:replay_fixture])

      true ->
        case Application.get_env(:tau, __MODULE__, [])[:fixture] do
          fixture when is_list(fixture) ->
            fixture

          fixture when is_binary(fixture) ->
            if File.regular?(fixture), do: from_file(fixture), else: default_events()

          _ ->
            if File.regular?(@default_fixture_path) do
              from_file(@default_fixture_path)
            else
              default_events()
            end
        end
    end
  end

  defp from_file(path) do
    path
    |> File.stream!(:line)
    |> Stream.map(&String.trim_trailing(&1, "\n"))
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(fn line ->
      line
      |> Jason.decode!()
      |> to_event()
    end)
    |> Stream.reject(&is_nil/1)
    |> Enum.to_list()
  end

  defp default_events do
    [
      %Event.Start{agent: :replay, version: "0.0.0", pid: nil},
      %Event.AssistantText{text: "(replay) hello", turn: 0},
      %Event.Cost{tokens: %{}, usd: 0.0, duration_ms: 0},
      %Event.Done{exit_status: 0, final_message: nil}
    ]
  end

  defp to_event(%{"type" => t} = m) do
    case t do
      "start" ->
        %Event.Start{
          agent: atomize(m["agent"], :replay),
          version: m["version"],
          pid: m["pid"],
          session_id: m["session_id"]
        }

      "assistant_text" ->
        %Event.AssistantText{text: m["text"] || "", turn: m["turn"] || 0}

      "tool_use" ->
        %Event.ToolUse{id: m["id"], name: m["name"], input: m["input"] || %{}}

      "tool_result" ->
        %Event.ToolResult{
          tool_use_id: m["tool_use_id"],
          content: m["content"] || "",
          is_error: m["is_error"] == true
        }

      "file_edit" ->
        %Event.FileEdit{path: m["path"], kind: atomize(m["kind"], :modify)}

      "cost" ->
        %Event.Cost{
          tokens: m["tokens"] || %{},
          usd: m["usd"],
          duration_ms: m["duration_ms"] || 0
        }

      "error" ->
        %Event.Error{reason: m["reason"], recoverable: m["recoverable"] == true}

      "done" ->
        %Event.Done{
          exit_status: m["exit_status"] || 0,
          final_message: m["final_message"]
        }

      _ ->
        nil
    end
  end

  defp to_event(_), do: nil

  defp atomize(nil, default), do: default
  defp atomize(value, _default) when is_atom(value), do: value

  defp atomize(value, default) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> default
  end
end
