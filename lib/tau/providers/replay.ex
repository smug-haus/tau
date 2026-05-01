defmodule Tau.Providers.Replay do
  @moduledoc """
  Test-only provider that replays a recorded sequence of
  `Tau.Provider.Event` structs.

  Useful for end-to-end session tests and the `mix tau.hello` smoke
  task when no real provider key is available.

  ## Configuring per-session (preferred)

  Pass the fixture via `Tau.start_session/1`'s `:provider_ctx` opt
  (ADR-0002). This is per-session, in-memory, not persisted —
  non-JSON-encodable event structs are fine here, unlike
  `:metadata`.

      events = [
        %Tau.Provider.Event.TextDelta{block_id: "b", text: "hi"},
        %Tau.Provider.Event.Done{stop_reason: :stop}
      ]

      {:ok, sid} =
        Tau.start_session(
          provider: Tau.Providers.Replay,
          provider_ctx: %{replay_fixture: events}
        )

  Tests using this pattern can be `async: true` — there is no
  global `Application.put_env/3` to leak across processes.

  ## Configuring deployment-wide

  For the `mix tau.hello` smoke task (which can't pass a `ctx`),
  set the fixture in `config/test.exs`:

      config :tau, Tau.Providers.Replay, fixture: "test/fixtures/foo.jsonl"

  The `Application.get_env/2` fallback only runs when no
  `:replay_fixture` is supplied via `provider_ctx`. **Do not** set
  this from inside a `setup` block (per the project's "no
  `Application.put_env/3` for runtime state" non-negotiable).

  ## Fixture format

  A fixture is either:

  - A list of `%Tau.Provider.Event{}` structs (in-memory), or
  - A path to a JSONL file where each line is a JSON object with a
    `type` field and event-specific keys.

  ## Test-only ctx knobs (ADR-0017)

  - `:replay_delay_ms` — `Process.sleep/1` between events. Tests use
    this to keep the stream "open" long enough for a `:cancel` cast
    to race in.
  - `:replay_ignore_cancel` — when `true`, the provider does NOT
    check the `:cancel_flag`. Drives the brutal-kill fallback path
    in cancellation tests.

  Both are no-ops in production; do not set them outside tests.
  """

  @behaviour Tau.Provider

  alias Tau.Provider.Event

  @impl Tau.Provider
  def default_model, do: "replay"

  @impl Tau.Provider
  def capabilities,
    do: %{thinking: false, tools: true, vision: false, prompt_caching: false, parallel_tools: false}

  @impl Tau.Provider
  def stream(_messages, _opts \\ %{}, ctx \\ %{}) do
    events = resolve_fixture(ctx) |> Enum.to_list()
    cancel_flag = ctx[:cancel_flag]
    delay_ms = ctx[:replay_delay_ms] || 0
    ignore_cancel? = ctx[:replay_ignore_cancel] == true

    stream =
      Stream.resource(
        fn -> events end,
        fn
          [] ->
            {:halt, []}

          [head | tail] = _remaining ->
            if delay_ms > 0, do: Process.sleep(delay_ms)

            if not ignore_cancel? and cancelled?(cancel_flag) do
              # ADR-0017: cooperative cancellation. Emit the marker
              # and stop drawing from the fixture.
              {[%Event.Error{reason: :cancelled, retryable?: false}], []}
            else
              {[head], tail}
            end
        end,
        fn _ -> :ok end
      )

    {:ok, stream}
  end

  defp cancelled?(nil), do: false
  defp cancelled?(ref), do: :counters.get(ref, 1) > 0

  defp resolve_fixture(ctx) do
    cond do
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
            default_events()
        end
    end
  end

  defp from_file(path) do
    File.stream!(path, [:line])
    |> Stream.map(&String.trim_trailing(&1, "\n"))
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(fn line -> Jason.decode!(line) |> to_event() end)
  end

  defp default_events do
    [
      %Event.Start{request_id: "replay_default", model: "replay"},
      %Event.TextStart{block_id: "b0"},
      %Event.TextDelta{block_id: "b0", text: "(replay) "},
      %Event.TextDelta{block_id: "b0", text: "hello"},
      %Event.TextEnd{block_id: "b0"},
      %Event.Done{stop_reason: :stop, usage: %{}}
    ]
  end

  defp to_event(%{"type" => t} = m) do
    case t do
      "start" ->
        %Event.Start{request_id: m["request_id"] || "r", model: m["model"]}

      "text_start" ->
        %Event.TextStart{block_id: m["block_id"]}

      "text_delta" ->
        %Event.TextDelta{block_id: m["block_id"], text: m["text"] || ""}

      "text_end" ->
        %Event.TextEnd{block_id: m["block_id"]}

      "thinking_start" ->
        %Event.ThinkingStart{block_id: m["block_id"]}

      "thinking_delta" ->
        %Event.ThinkingDelta{block_id: m["block_id"], text: m["text"] || ""}

      "thinking_end" ->
        %Event.ThinkingEnd{block_id: m["block_id"], signature: m["signature"]}

      "tool_call_start" ->
        %Event.ToolCallStart{tool_call_id: m["id"], name: m["name"]}

      "tool_call_delta" ->
        %Event.ToolCallDelta{tool_call_id: m["id"], json_fragment: m["fragment"] || ""}

      "tool_call_end" ->
        %Event.ToolCallEnd{tool_call_id: m["id"], params: m["params"] || %{}}

      "done" ->
        %Event.Done{
          stop_reason: String.to_atom(m["stop_reason"] || "stop"),
          usage: m["usage"] || %{}
        }

      "error" ->
        %Event.Error{reason: m["reason"], retryable?: m["retryable?"] || false}

      _ ->
        nil
    end
  end
end
