defmodule Tau.Providers.Replay do
  @moduledoc """
  Test-only provider that replays a recorded sequence of
  `Tau.Provider.Event` structs from a JSONL fixture file.

  Useful for end-to-end session tests and the `mix tau.hello` smoke task
  when no real provider key is available.

  ## Configuration

  Prefer `config/test.exs`:

      # config/test.exs
      config :tau, Tau.Providers.Replay, fixture: "test/fixtures/foo.jsonl"

  Tau's "no `Application.put_env/3` for runtime state" non-negotiable
  (see CLAUDE.md / TAU.md) applies here too — even though Replay is
  test-only, configuring it with `Application.put_env/3` from inside
  `setup` blocks bleeds state across tests and breaks `async: true`.
  Tests that need per-test fixture switching should pass the fixture
  through the `ctx` argument that `stream/3` already accepts:

      stream(messages, opts, %{replay_fixture: events})

  Each line of the fixture is a JSON object with an event `type` and the
  remaining fields used to build the corresponding event struct.
  """

  @behaviour Tau.Provider

  alias Tau.Provider.Event

  @impl Tau.Provider
  def default_model, do: "replay"

  @impl Tau.Provider
  def capabilities,
    do: %{thinking: false, tools: true, vision: false, prompt_caching: false, parallel_tools: false}

  @impl Tau.Provider
  def stream(_messages, _opts \\ %{}, _ctx \\ %{}) do
    fixture = Application.get_env(:tau, __MODULE__, [])[:fixture]

    events =
      cond do
        is_list(fixture) -> fixture
        is_binary(fixture) and File.regular?(fixture) -> from_file(fixture)
        true -> default_events()
      end

    {:ok, Stream.map(events, & &1)}
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
