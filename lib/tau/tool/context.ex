defmodule Tau.Tool.Context do
  @moduledoc """
  Per-call context handed to `Tau.Tool.execute/2`.

    * `:tool_call_id` — identity for pairing with the eventual `ToolResult`
    * `:cancel_ref` — monitored ref; if the FSM `Process.demonitor`s it,
      the tool should observe the `:DOWN` and abort
    * `:cwd` — working directory the session operates from (tools should
      resolve relative paths against this)
    * `:session_id` — owning session
    * `:operations` — pluggable file/process backend (default
      `Tau.Tools.Operations.Local`); enables future SSH/sandboxed backends
      without touching tool code
    * `:emit` — `(event :: term -> :ok)` closure for streaming partial
      updates back to the session FSM
    * `:metadata` — arbitrary data passed through from `start_session/1`
  """

  @enforce_keys [:tool_call_id, :session_id]
  defstruct [
    :tool_call_id,
    :session_id,
    :cancel_ref,
    :cwd,
    :emit,
    operations: Tau.Tools.Operations.Local,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          session_id: String.t(),
          cancel_ref: reference() | nil,
          cwd: String.t() | nil,
          emit: (term() -> :ok) | nil,
          operations: module(),
          metadata: map()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__,
      tool_call_id: Keyword.fetch!(opts, :tool_call_id),
      session_id: Keyword.fetch!(opts, :session_id),
      cancel_ref: opts[:cancel_ref],
      cwd: opts[:cwd] || File.cwd!(),
      emit: opts[:emit] || fn _ -> :ok end,
      operations: opts[:operations] || Tau.Tools.Operations.Local,
      metadata: opts[:metadata] || %{}
    )
  end
end
