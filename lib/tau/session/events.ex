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
end
