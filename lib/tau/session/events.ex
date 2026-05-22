defmodule Tau.Session.Events do
  @moduledoc """
  Session-level events broadcast on `Phoenix.PubSub` topic
  `"session:<id>"`.

  Distinct from `Tau.Provider.Event` (which is what providers yield); these
  are higher-level lifecycle events that subscribers (TUI, log, telemetry)
  consume. Provider events are wrapped inside `%MessageUpdate{event: ...}`.
  """

  defmodule SessionStart do
    @enforce_keys [:session_id]
    defstruct [:session_id, :provider, :model, :cwd, :metadata]
    @type t :: %__MODULE__{}
  end

  defmodule MessageStart do
    @enforce_keys [:session_id, :message]
    defstruct [:session_id, :message]
    @type t :: %__MODULE__{}
  end

  defmodule MessageUpdate do
    @enforce_keys [:session_id, :event, :message]
    defstruct [:session_id, :event, :message]
    @type t :: %__MODULE__{}
  end

  defmodule MessageEnd do
    @enforce_keys [:session_id, :message]
    defstruct [:session_id, :message]
    @type t :: %__MODULE__{}
  end

  defmodule ToolStart do
    @enforce_keys [:session_id, :tool_call_id, :name, :arguments]
    defstruct [:session_id, :tool_call_id, :name, :arguments]
    @type t :: %__MODULE__{}
  end

  defmodule ToolUpdate do
    @enforce_keys [:session_id, :tool_call_id, :payload]
    defstruct [:session_id, :tool_call_id, :payload]
    @type t :: %__MODULE__{}
  end

  defmodule ToolEnd do
    @enforce_keys [:session_id, :tool_call_id, :result]
    defstruct [:session_id, :tool_call_id, :result]
    @type t :: %__MODULE__{}
  end

  defmodule Cancelled do
    @enforce_keys [:session_id]
    defstruct [:session_id, :reason]
    @type t :: %__MODULE__{}
  end

  defmodule SkillActivated do
    @moduledoc """
    Broadcast when the model activates a discovered skill via the
    synthetic `__activate_skill__` tool (issue #17, ADR-0013).

    Activation lives on the FSM's `data.active_skill` field for the
    remainder of the current turn (cleared on `:end_turn` or `:cancel`).
    """
    @enforce_keys [:session_id, :skill_name]
    defstruct [:session_id, :skill_name, :tool_call_id]
    @type t :: %__MODULE__{}
  end

  defmodule SystemNotice do
    @moduledoc """
    Broadcast when a built-in FSM slash command (e.g. `/model`) needs
    to surface a message to the user without starting a provider turn.
    The `text` field contains a human-readable notice line appended to
    the TUI transcript.
    """
    @enforce_keys [:session_id, :text]
    defstruct [:session_id, :text]
    @type t :: %__MODULE__{}
  end

  defmodule SessionEnd do
    @enforce_keys [:session_id]
    defstruct [:session_id, :reason]
    @type t :: %__MODULE__{}
  end

  defmodule CommandCatalog do
    @moduledoc """
    Broadcast by the session FSM once at `SessionStart` and again on every
    `/reload` so the TUI completion menu always has a current catalog
    (D-103, D-108 / SPEC-TUI-COMPLETION §4 B1).

    `entries` is the result of `Tau.Commands.Catalog.list/1` for the current
    session. The TUI stores it in `model.catalog` and uses it to populate
    the slash-command autocomplete menu. The TUI MUST NOT call the session
    synchronously on the render path to fetch catalog data (D-103).
    """
    @enforce_keys [:session_id, :entries]
    defstruct [:session_id, :entries]
    @type t :: %__MODULE__{}
  end

  defmodule PermissionRequest do
    @moduledoc """
    Broadcast when a tool call receives an `:ask` verdict from
    `Tau.Permissions.Evaluator` and the session is interactive (D-092,
    SPEC-PERMISSION-PROMPTS §4 B2).

    The TUI (or any subscriber) casts `{:permission_decision, tool_call_id,
    verdict}` back to the session to resolve the request. The session FSM
    waits in `:awaiting_permission` until all pending requests are resolved.

    Non-interactive sessions (e.g. `tau run`) never broadcast this event —
    they resolve `:ask` immediately to fail-closed `:deny` (D-093).
    """
    @enforce_keys [:session_id, :tool_call_id, :name, :arguments, :decision_reason]
    defstruct [:session_id, :tool_call_id, :name, :arguments, :decision_reason]
    @type t :: %__MODULE__{}
  end

  defmodule QueueRestored do
    @moduledoc """
    Broadcast by the session FSM when a `:cancel` drains the steering queue
    back to the caller rather than delivering the queued messages as turns.

    D-082 (#339 / SPEC-USER-TURN §6): a steering message was enqueued to
    redirect a turn that no longer exists. On `:cancel`, the FSM drains the
    steering queue and broadcasts this event carrying the restored messages.
    The TUI repopulates the input editor from `messages` (joining with newline)
    so the user can review, edit, or re-submit what they typed.

    The follow-up queue is NOT included — follow-up messages survive a cancel
    and run on the post-cancel turn (see D-080).

    Receivers MUST treat this event as idempotent: a re-delivered
    `%QueueRestored{}` after a reconnect MUST NOT double-append to the editor.
    """
    @enforce_keys [:session_id, :messages]
    defstruct [:session_id, :messages]
    @type t :: %__MODULE__{}
  end

  defmodule SubagentStart do
    @moduledoc """
    Broadcast on the **parent** session topic when a sub-agent is dispatched.

    D-150 (SPEC-TUI-HEADLESS §5c): sub-agent lifecycle events MUST be emitted
    on the parent topic `"session:<parent_id>"` so the TUI EventBridge, which
    subscribes only to the parent topic, receives them without needing a
    per-child subscription.

    `kind` is a closed atom set: `:builtin_agent` (the `Agent` builtin tool,
    Path A) or `:coding_agent` (the coding-agent dispatcher, Path B). Consumers
    MUST pattern-match on atoms; unknown `kind` values MUST be ignored, not
    crashed (D-152).

    `parent_tool_call_id` is the parent FSM's tool-call id for this Agent
    invocation, used by the render layer to de-dup owned child tool calls (B1).
    """
    @enforce_keys [:session_id, :subagent_id, :kind, :label]
    defstruct [:session_id, :subagent_id, :kind, :label, :parent_tool_call_id, :child_session_id]
    @type t :: %__MODULE__{}
  end

  defmodule SubagentProgress do
    @moduledoc """
    Broadcast on the **parent** session topic for each notable child activity:
    a tool call, an assistant-text chunk, or a file edit.

    D-151 (SPEC-TUI-HEADLESS §5c): progress is coalesced — one event per child
    tool-call / text chunk, never per token — to bound mailbox and render cost.

    `child_tool_call_id` is the child session's tool-call id (may be `nil` for
    non-tool activity). The render layer uses it to correlate: a parent-topic
    `%ToolStart{}` / `%ToolEnd{}` whose `tool_call_id` belongs to a known
    sub-agent is NOT rendered inline — the sub-agent markers own it (B1 rule).

    `activity` is one of:
      - `{:tool_call, name}` — child invoked a tool
      - `{:assistant_text, excerpt}` — child produced assistant text (short excerpt)
      - `{:file_edit, path, kind}` — child performed a file edit
    """
    @enforce_keys [:session_id, :subagent_id, :activity]
    defstruct [:session_id, :subagent_id, :activity, :child_tool_call_id]
    @type t :: %__MODULE__{}
  end

  defmodule SubagentCost do
    @moduledoc """
    Broadcast on the **parent** session topic when the sub-agent reports cost
    information (e.g. on completion or via a cost event from the adapter).

    D-153 (SPEC-TUI-HEADLESS §5c): sub-agent cost MUST NOT be folded into the
    parent's own cost line. The node owns its cost; the parent status bar shows
    parent-only cost. This prevents double-counting (R4).
    """
    @enforce_keys [:session_id, :subagent_id]
    defstruct [:session_id, :subagent_id, :tokens, :usd, :duration_ms]
    @type t :: %__MODULE__{}
  end

  defmodule SubagentEnd do
    @moduledoc """
    Broadcast on the **parent** session topic when the sub-agent terminates.

    D-154 (SPEC-TUI-HEADLESS §5c): `SubagentEnd` MUST be emitted on ALL FIVE
    terminal branches of `await_child/4`: `natural_end`, `failure_end`,
    `SessionEnd`, `{:DOWN, …}`, and the `after`-timeout. A missed branch
    produces a node stuck `▶ running` after the parent turn ends (AC-7 failure).

    `state` is a closed atom set: `:done`, `:failed`, or `:cancelled`.
    `summary` is a short human-readable string for the transcript end marker.
    """
    @enforce_keys [:session_id, :subagent_id, :state]
    defstruct [:session_id, :subagent_id, :state, :summary]
    @type t :: %__MODULE__{}
  end
end
