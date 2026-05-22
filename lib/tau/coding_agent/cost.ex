defmodule Tau.CodingAgent.Cost do
  @moduledoc """
  Adapter-tagged cost record (SPEC-CODING-AGENT §7 Q4, D-038).

  Wraps `Tau.CodingAgent.Event.Cost` with the metadata needed for
  the session-cost aggregator to break the total down by source:
  `coding_agent.claude_code` vs `provider.anthropic` etc. The user
  sees the split so the rationale for using a Claude Max plan
  (avoid raw API tokens) is observable.

  ## Shape

      %Tau.CodingAgent.Cost{
        session_id: "01H...",         # tau session id
        agent: :claude_code,          # adapter atom
        adapter_session_id: "abc-1",  # the agent's own session id, when known
        usd: 0.0123,                  # may be nil (Aider)
        duration_ms: 1234,
        input_tokens: 100,
        output_tokens: 250,
        cache_read: 0,
        cache_write: 0,
        raw_tokens: %{"input_tokens" => 100, ...}
      }

  The `source/0` helper returns the canonical line-item tag
  (`"coding_agent.claude_code"`) for telemetry / persistence.

  ## Pure module

  No process, no state. The session FSM constructs one from each
  `%Event.Cost{}` and hands it to `Tau.Cost.Tracker` via the
  `[:tau, :coding_agent, :cost]` telemetry event. Pricing-by-model is
  not computed here.
  """

  alias Tau.CodingAgent.Event

  @enforce_keys [:agent]
  defstruct [
    :agent,
    :session_id,
    :adapter_session_id,
    :usd,
    duration_ms: 0,
    input_tokens: 0,
    output_tokens: 0,
    cache_read: 0,
    cache_write: 0,
    raw_tokens: %{}
  ]

  @type t :: %__MODULE__{
          agent: atom(),
          session_id: String.t() | nil,
          adapter_session_id: String.t() | nil,
          usd: float() | nil,
          duration_ms: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          raw_tokens: map()
        }

  @doc """
  Build a tagged record from an in-stream `%Event.Cost{}`. The
  caller threads `agent`, the tau `session_id`, and (optionally)
  the captured `adapter_session_id`.

  Normalises the free-form `tokens` map into the four canonical
  counters used by `Tau.Cost.Tracker`. Unknown keys are preserved
  in `raw_tokens` for downstream inspection.
  """
  @spec from_event(Event.Cost.t(), keyword()) :: t()
  def from_event(%Event.Cost{} = ev, opts) do
    {input, output, cr, cw} = normalise_tokens(ev.tokens)

    %__MODULE__{
      agent: Keyword.fetch!(opts, :agent),
      session_id: Keyword.get(opts, :session_id),
      adapter_session_id: Keyword.get(opts, :adapter_session_id),
      usd: ev.usd,
      duration_ms: ev.duration_ms || 0,
      input_tokens: input,
      output_tokens: output,
      cache_read: cr,
      cache_write: cw,
      raw_tokens: ev.tokens || %{}
    }
  end

  @doc """
  Canonical line-item tag for this record (`"coding_agent.<agent>"`).
  Mirrors `"provider.<provider>"` on the existing path so the user
  sees a uniform split.
  """
  @spec source(t() | atom()) :: String.t()
  def source(%__MODULE__{agent: a}), do: source(a)
  def source(agent) when is_atom(agent), do: "coding_agent." <> agent_slug(agent)

  @doc """
  JSONL-safe view (string keys, primitive values). Used by the
  session FSM when persisting a `coding_agent_cost` event so
  `/resume` can recompute totals from disk.
  """
  @spec to_jsonl(t()) :: map()
  def to_jsonl(%__MODULE__{} = c) do
    %{
      "agent" => Atom.to_string(c.agent),
      "source" => source(c),
      "session_id" => c.session_id,
      "adapter_session_id" => c.adapter_session_id,
      "usd" => c.usd,
      "duration_ms" => c.duration_ms,
      "input_tokens" => c.input_tokens,
      "output_tokens" => c.output_tokens,
      "cache_read" => c.cache_read,
      "cache_write" => c.cache_write,
      "raw_tokens" => stringify_keys(c.raw_tokens)
    }
  end

  @doc """
  Inverse of `to_jsonl/1`. Used by `/resume` to fold persisted cost
  events back into the in-memory aggregator. Tolerates missing keys
  (zero defaults) so older JSONL files (pre-D-038) read cleanly.
  """
  @spec from_jsonl(map()) :: t() | nil
  def from_jsonl(%{} = m) do
    case m["agent"] do
      nil ->
        nil

      bin when is_binary(bin) ->
        %__MODULE__{
          agent: agent_atom(bin),
          session_id: m["session_id"],
          adapter_session_id: m["adapter_session_id"],
          usd: m["usd"],
          duration_ms: as_int(m["duration_ms"]),
          input_tokens: as_int(m["input_tokens"]),
          output_tokens: as_int(m["output_tokens"]),
          cache_read: as_int(m["cache_read"]),
          cache_write: as_int(m["cache_write"]),
          raw_tokens: m["raw_tokens"] || %{}
        }

      _ ->
        nil
    end
  end

  def from_jsonl(_), do: nil

  @doc """
  Sum the dollar / token / duration columns of a list of records.
  Useful for the TUI's session-cost panel and for resume folding.
  """
  @spec totals([t()]) :: %{
          required(:usd) => float(),
          required(:duration_ms) => non_neg_integer(),
          required(:input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          required(:cache_read) => non_neg_integer(),
          required(:cache_write) => non_neg_integer(),
          required(:by_source) => %{String.t() => float()}
        }
  def totals(records) when is_list(records) do
    Enum.reduce(
      records,
      %{
        usd: 0.0,
        duration_ms: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_read: 0,
        cache_write: 0,
        by_source: %{}
      },
      fn %__MODULE__{} = c, acc ->
        usd = c.usd || 0.0
        tag = source(c)

        %{
          acc
          | usd: acc.usd + usd,
            duration_ms: acc.duration_ms + c.duration_ms,
            input_tokens: acc.input_tokens + c.input_tokens,
            output_tokens: acc.output_tokens + c.output_tokens,
            cache_read: acc.cache_read + c.cache_read,
            cache_write: acc.cache_write + c.cache_write,
            by_source: Map.update(acc.by_source, tag, usd, &(&1 + usd))
        }
      end
    )
  end

  # ── helpers ───────────────────────────────────────────────────

  # Claude Code's stream-json (and Aider's) hand back token counts
  # under a handful of well-known keys; tolerate both string and
  # atom keys, both new (`input_tokens`) and legacy (`prompt_tokens`).
  defp normalise_tokens(nil), do: {0, 0, 0, 0}

  defp normalise_tokens(map) when is_map(map) do
    {
      pick(map, ["input_tokens", :input_tokens, "prompt_tokens", :prompt_tokens]),
      pick(map, ["output_tokens", :output_tokens, "completion_tokens", :completion_tokens]),
      pick(map, [
        "cache_read_input_tokens",
        :cache_read_input_tokens,
        "cache_read",
        :cache_read
      ]),
      pick(map, [
        "cache_creation_input_tokens",
        :cache_creation_input_tokens,
        "cache_write",
        :cache_write
      ])
    }
  end

  defp normalise_tokens(_), do: {0, 0, 0, 0}

  defp pick(map, keys) do
    Enum.find_value(keys, 0, fn k ->
      case Map.get(map, k) do
        n when is_integer(n) and n >= 0 -> n
        _ -> nil
      end
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp as_int(n) when is_integer(n) and n >= 0, do: n
  defp as_int(_), do: 0

  # Atom-safe conversion: only resolve to already-loaded atoms so
  # an arbitrary JSONL string can't grow the atom table.
  defp agent_atom(bin) when is_binary(bin) do
    String.to_existing_atom(bin)
  rescue
    ArgumentError -> :unknown
  end

  defp agent_slug(:claude_code), do: "claude_code"

  defp agent_slug(agent) when is_atom(agent) do
    # `Tau.CodingAgents.Replay` → `"replay"`; `:claude_code` → `"claude_code"`.
    agent
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end
end
