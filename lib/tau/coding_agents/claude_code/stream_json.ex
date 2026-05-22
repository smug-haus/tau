defmodule Tau.CodingAgents.ClaudeCode.StreamJson do
  @moduledoc """
  Line-oriented parser for the `claude --output-format stream-json`
  protocol. Translates each NDJSON line into zero, one, or more
  `Tau.CodingAgent.Event` structs.

  Lives in its own module so it can be exercised without spawning
  `claude`: feed lines in, get events out.

  ## Contract (D-031, D-035)

  * `decode_line/2` MUST NOT raise on any binary input. Malformed
    JSON, unknown shapes, and missing keys all return
    `%Event.Error{recoverable: true}` (or, for fully-unrecognised
    types, an empty list — the upstream stream just logs and
    continues).
  * One stream-json line can yield multiple events. A `result/success`
    line emits both a `%Cost{}` and a `%Done{}`. The function
    therefore returns `{events :: [Event.t()], state}` where state
    threads the running `turn` counter.

  ## Stream-json shapes handled

  Stream-json subtypes handled:

      system/init               → %Start{}
      system/<other subtype>    → ignored (e.g. hook_started, hook_response)
      assistant content[text]   → %AssistantText{}
      assistant content[tool_use]
                                → %ToolUse{}
      user     content[tool_result]
                                → %ToolResult{}
      result/success            → %Cost{} ; %Done{exit_status: 0}
      result/error_*            → %Error{recoverable: false}
      rate_limit_event          → ignored (informational; future:
                                  could surface as Cost metadata)
      <unknown>                 → ignored (defensive: Claude Code
                                  ships new event types over time)
  """

  alias Tau.CodingAgent.Event

  require Logger

  @typedoc """
  Threaded parser state.

  * `turn` — monotonic 0-based counter incremented on each assistant
    text emission.
  * `last_session_id` — captured from `system/init` and `result/*`;
    not consumed yet but reserved for future resume-id surfacing
    (Team D persistence).
  """
  @type t :: %__MODULE__{turn: non_neg_integer(), last_session_id: String.t() | nil}

  defstruct turn: 0, last_session_id: nil

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Decode a single stream-json line.

  Returns `{[Event.t()], t()}`. Never raises.
  """
  @spec decode_line(binary(), t()) :: {[Event.t()], t()}
  def decode_line(line, %__MODULE__{} = state) when is_binary(line) do
    trimmed = line |> String.trim_trailing("\n") |> String.trim_trailing("\r")

    case trimmed do
      "" ->
        {[], state}

      _ ->
        case Jason.decode(trimmed) do
          {:ok, obj} when is_map(obj) ->
            translate(obj, state)

          {:ok, _} ->
            # Top-level non-object — not stream-json. Recoverable.
            {[
               %Event.Error{
                 reason: {:malformed_event, "non-object JSON value"},
                 recoverable: true
               }
             ], state}

          {:error, %Jason.DecodeError{} = err} ->
            {[
               %Event.Error{
                 reason: {:parse_error, Exception.message(err)},
                 recoverable: true
               }
             ], state}
        end
    end
  end

  # ── translation ──────────────────────────────────────────────────

  defp translate(%{"type" => "system", "subtype" => "init"} = obj, state) do
    state = %{state | last_session_id: obj["session_id"]}

    # SPEC-CODING-AGENT §7 Q5: surface the Claude-Code-side session id
    # in `%Event.Start{}` so the session FSM can persist it for the
    # next launch's `task.resume_id` (Team D).
    event = %Event.Start{
      agent: :claude_code,
      version: obj["claude_code_version"],
      pid: nil,
      session_id: obj["session_id"]
    }

    {[event], state}
  end

  defp translate(%{"type" => "system"}, state) do
    # hook_started, hook_response, and any future system subtype.
    {[], state}
  end

  defp translate(%{"type" => "assistant", "message" => %{"content" => content}}, state)
       when is_list(content) do
    Enum.flat_map_reduce(content, state, &assistant_content/2)
  end

  defp translate(%{"type" => "user", "message" => %{"content" => content}}, state)
       when is_list(content) do
    events =
      Enum.flat_map(content, fn
        %{"type" => "tool_result"} = block ->
          [
            %Event.ToolResult{
              tool_use_id: block["tool_use_id"] || "",
              content: tool_result_content(block["content"]),
              is_error: block["is_error"] == true
            }
          ]

        _ ->
          []
      end)

    {events, state}
  end

  defp translate(%{"type" => "result", "subtype" => subtype} = obj, state) do
    state = %{state | last_session_id: obj["session_id"] || state.last_session_id}
    result_events(subtype, obj, state)
  end

  defp translate(%{"type" => "rate_limit_event"}, state), do: {[], state}

  defp translate(%{"type" => other}, state) do
    Logger.debug(fn -> "ClaudeCode stream-json: ignoring unknown type #{inspect(other)}" end)
    {[], state}
  end

  defp translate(_other, state) do
    # Object without a "type" field. Recoverable.
    {[%Event.Error{reason: {:malformed_event, "missing type"}, recoverable: true}], state}
  end

  # ── assistant content blocks ─────────────────────────────────────

  defp assistant_content(%{"type" => "text", "text" => text}, state) when is_binary(text) do
    event = %Event.AssistantText{text: text, turn: state.turn}
    {[event], %{state | turn: state.turn + 1}}
  end

  defp assistant_content(%{"type" => "tool_use"} = block, state) do
    event = %Event.ToolUse{
      id: block["id"] || "",
      name: block["name"] || "",
      input: block["input"] || %{}
    }

    {[event], state}
  end

  defp assistant_content(_other, state), do: {[], state}

  # ── result events ────────────────────────────────────────────────

  defp result_events("success", obj, state) do
    usage = obj["usage"] || %{}
    cost_usd = obj["total_cost_usd"]
    duration_ms = obj["duration_ms"] || 0
    final = obj["result"]

    events = [
      %Event.Cost{
        tokens: usage,
        usd: cost_usd,
        duration_ms: duration_ms
      },
      %Event.Done{exit_status: 0, final_message: final}
    ]

    {events, state}
  end

  defp result_events(subtype, obj, state) when is_binary(subtype) do
    msg = obj["error"] || obj["result"] || "claude reported #{subtype}"
    msg_str = to_string(msg)

    reason =
      if auth_related?(msg_str) do
        {:auth_failed, msg_str}
      else
        {String.to_atom(subtype), msg_str}
      end

    {[%Event.Error{reason: reason, recoverable: false}], state}
  end

  defp result_events(_subtype, _obj, state), do: {[], state}

  defp auth_related?(text) do
    String.contains?(text, "/login") or
      String.contains?(text, "Authentication") or
      String.contains?(text, "authenticat")
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp tool_result_content(s) when is_binary(s), do: s

  defp tool_result_content(list) when is_list(list) do
    Enum.map_join(list, "\n", fn
      %{"type" => "text", "text" => t} when is_binary(t) -> t
      %{"text" => t} when is_binary(t) -> t
      other -> Jason.encode!(other)
    end)
  end

  defp tool_result_content(nil), do: ""
  defp tool_result_content(other), do: Jason.encode!(other)

  @doc """
  Classify a non-zero exit code or surfaced error text into a
  user-actionable atom + message tuple. Used by the adapter to
  decorate Port-level failures before emitting `%Event.Error{}`.

  AC-6: auth-related failures get a distinct `:auth_failed` tag so
  the TUI can render the "run `claude /login`" hint without parsing
  free-form messages a second time.
  """
  @spec classify_failure(integer(), binary()) :: {atom(), String.t()}
  def classify_failure(exit_status, text)
      when is_integer(exit_status) and is_binary(text) do
    cond do
      exit_status == 127 ->
        {:not_found, "claude executable exited 127 (not found on PATH)"}

      String.contains?(text, "/login") or
        String.contains?(text, "Authentication required") or
        String.contains?(text, "not authenticated") or
          String.contains?(text, "Please run") ->
        {:auth_failed, text}

      exit_status != 0 ->
        {:nonzero_exit, "claude exited #{exit_status}: #{text}"}

      true ->
        {:unknown, text}
    end
  end
end
