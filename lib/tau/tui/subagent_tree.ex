defmodule Tau.TUI.SubagentTree do
  @moduledoc """
  Pure fold module for the sub-agent tree maintained in the TUI MVU model.

  No process, no GenServer — this is stateless derived render state folded
  synchronously in `Tau.TUI.App.update/2` (OTP non-negotiables #1/#3).

  The tree is keyed by `subagent_id`. `Tau.TUI.SubagentTree.fold/2` accepts
  any `%Tau.Session.Events.Subagent*{}` event and returns an updated tree map
  `%{subagent_id => SubagentNode.t()}`.

  ## Invariants (SPEC-TUI-HEADLESS §5c, D-150..D-154)

  - **D-150**: events arrive on the parent topic; this module has no topic
    awareness — callers route the right events here.
  - **D-152**: an unknown `subagent_id` or unknown `kind` is silently ignored
    (returns the tree unchanged). A crash on unknown input would violate OTP
    non-negotiable #8 (pure functions are safe by default).
  - **D-153**: cost stored in the node MUST NOT be folded into the parent's
    own cost. Caller's responsibility.
  - **D-154**: state transitions are monotone — once `:done`, `:failed`, or
    `:cancelled`, no further event can revert to `:running`.
  """

  alias Tau.Session.Events

  defmodule SubagentNode do
    @moduledoc """
    Per-sub-agent accumulated state for TUI rendering.

    `kind` is `:builtin_agent` or `:coding_agent` (closed set, D-152).
    `state` transitions monotonically: `:running` → `:done` | `:failed` | `:cancelled`.
    `owned_tool_call_ids` is the set of child tool-call ids whose render is
    owned by this node (used for de-dup by the transcript render, B1 rule).
    """
    defstruct [
      :subagent_id,
      :kind,
      :label,
      :parent_tool_call_id,
      :child_session_id,
      state: :running,
      tool_calls: 0,
      last_activity: nil,
      tokens: nil,
      usd: nil,
      duration_ms: nil,
      summary: nil,
      owned_tool_call_ids: MapSet.new()
    ]

    @type state :: :running | :done | :failed | :cancelled
    @type kind :: :builtin_agent | :coding_agent

    @type t :: %__MODULE__{
            subagent_id: String.t(),
            kind: kind(),
            label: String.t(),
            parent_tool_call_id: String.t() | nil,
            child_session_id: String.t() | nil,
            state: state(),
            tool_calls: non_neg_integer(),
            last_activity: term(),
            tokens: map() | nil,
            usd: float() | nil,
            duration_ms: non_neg_integer() | nil,
            summary: String.t() | nil,
            owned_tool_call_ids: MapSet.t()
          }
  end

  @type tree :: %{String.t() => SubagentNode.t()}

  @valid_kinds [:builtin_agent, :coding_agent]
  @terminal_states [:done, :failed, :cancelled]

  @doc """
  Fold a `%Tau.Session.Events.Subagent*{}` event into the tree.

  Unknown `subagent_id` (for Progress/Cost/End) and unknown `kind` (for Start)
  are silently ignored — returns the tree unchanged. This is D-152.

  State transitions are monotone: a node already in a terminal state ignores
  further non-Start events.
  """
  @spec fold(tree(), term()) :: tree()
  def fold(tree, %Events.SubagentStart{subagent_id: id, kind: kind} = ev)
      when kind in @valid_kinds do
    node = %SubagentNode{
      subagent_id: id,
      kind: kind,
      label: ev.label,
      parent_tool_call_id: ev.parent_tool_call_id,
      child_session_id: ev.child_session_id,
      state: :running
    }

    Map.put(tree, id, node)
  end

  # Unknown kind — ignored (D-152).
  def fold(tree, %Events.SubagentStart{}), do: tree

  def fold(tree, %Events.SubagentProgress{subagent_id: id} = ev) do
    case Map.get(tree, id) do
      nil ->
        # Unknown subagent_id — ignore (D-152).
        tree

      %SubagentNode{state: s} when s in @terminal_states ->
        # Terminal — monotone, no revert.
        tree

      node ->
        updated =
          node
          |> maybe_increment_tool_calls(ev.activity)
          |> maybe_track_tool_call_id(ev.child_tool_call_id)
          |> Map.put(:last_activity, ev.activity)

        Map.put(tree, id, updated)
    end
  end

  def fold(tree, %Events.SubagentCost{subagent_id: id} = ev) do
    case Map.get(tree, id) do
      nil ->
        tree

      node ->
        updated = %{node | tokens: ev.tokens, usd: ev.usd, duration_ms: ev.duration_ms}
        Map.put(tree, id, updated)
    end
  end

  def fold(tree, %Events.SubagentEnd{subagent_id: id, state: state} = ev)
      when state in @terminal_states do
    case Map.get(tree, id) do
      nil ->
        tree

      node ->
        updated = %{node | state: state, summary: ev.summary}
        Map.put(tree, id, updated)
    end
  end

  # Unknown terminal state or non-matching SubagentEnd — ignore.
  def fold(tree, %Events.SubagentEnd{}), do: tree

  # Non-subagent events — pass through unchanged.
  def fold(tree, _other), do: tree

  @doc """
  Returns true if the given `tool_call_id` is owned by any sub-agent node
  in the tree. Used by the render layer to de-dup: a parent-topic
  `%ToolStart{}` / `%ToolEnd{}` whose tool_call_id is owned MUST NOT be
  rendered as an inline tool call — the sub-agent marker owns it (B1 rule,
  D-151).
  """
  @spec tool_call_owned?(tree(), String.t() | nil) :: boolean()
  def tool_call_owned?(_tree, nil), do: false

  def tool_call_owned?(tree, tool_call_id) do
    Enum.any?(tree, fn {_id, node} ->
      MapSet.member?(node.owned_tool_call_ids, tool_call_id)
    end)
  end

  @doc """
  Returns the sub-agent node that owns the given `tool_call_id`, or `nil`.
  """
  @spec node_for_tool_call(tree(), String.t() | nil) :: SubagentNode.t() | nil
  def node_for_tool_call(_tree, nil), do: nil

  def node_for_tool_call(tree, tool_call_id) do
    Enum.find_value(tree, fn {_id, node} ->
      if MapSet.member?(node.owned_tool_call_ids, tool_call_id), do: node
    end)
  end

  @doc """
  Format the start marker line for a sub-agent.
  Returns `"┌─ sub-agent: <label> [running]"`.
  """
  @spec format_start_marker(SubagentNode.t()) :: String.t()
  def format_start_marker(%SubagentNode{label: label}) do
    "┌─ sub-agent: #{label} [running]"
  end

  @doc """
  Format the end marker line for a sub-agent.
  Returns `"└─ sub-agent: <label> [<state> · <N> tool calls · <duration> · $<cost>]"`.
  """
  @spec format_end_marker(SubagentNode.t()) :: String.t()
  def format_end_marker(%SubagentNode{} = node) do
    state_str =
      case node.state do
        :done -> "done"
        :failed -> "failed"
        :cancelled -> "cancelled"
        _ -> "ended"
      end

    parts = [state_str, "#{node.tool_calls} tool calls"]

    parts =
      if node.duration_ms do
        parts ++ [format_duration(node.duration_ms)]
      else
        parts
      end

    parts =
      if node.usd do
        parts ++ ["$#{:erlang.float_to_binary(node.usd, decimals: 4)}"]
      else
        parts
      end

    summary = Enum.join(parts, " · ")
    "└─ sub-agent: #{node.label} [#{summary}]"
  end

  # --- Private helpers ---

  defp maybe_increment_tool_calls(node, {:tool_call, _name}) do
    %{node | tool_calls: node.tool_calls + 1}
  end

  defp maybe_increment_tool_calls(node, _activity), do: node

  defp maybe_track_tool_call_id(node, nil), do: node

  defp maybe_track_tool_call_id(node, tool_call_id) do
    %{node | owned_tool_call_ids: MapSet.put(node.owned_tool_call_ids, tool_call_id)}
  end

  defp format_duration(ms) when is_integer(ms) do
    secs = div(ms, 1000)
    mins = div(secs, 60)
    rem_secs = rem(secs, 60)

    if mins > 0 do
      "#{mins}m#{String.pad_leading(Integer.to_string(rem_secs), 2, "0")}s"
    else
      "#{secs}s"
    end
  end

  defp format_duration(_), do: "?"
end
