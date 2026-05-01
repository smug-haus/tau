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

  defmodule SessionEnd do
    @enforce_keys [:session_id]
    defstruct [:session_id, :reason]
    @type t :: %__MODULE__{}
  end
end
