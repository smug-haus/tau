defmodule Tau.Command.Context do
  @moduledoc """
  Per-call context handed to `Tau.Command.execute/2`.

  Mirrors `Tau.Tool.Context` for the slash-command surface so commands
  can make per-session decisions (consult `:cwd`, gate on
  `:permissions_mode`, emit interim events back to the session via
  `:emit`) instead of being effectively stateless.

    * `:session_id` — owning session
    * `:cwd` — working directory the session operates from (commands
      should resolve relative paths against this)
    * `:permissions_mode` — the session's current permissions mode
      (`:default | :accept_edits | :plan | :auto | :dont_ask | :bypass`)
    * `:emit` — `(event :: term -> :ok)` closure for sending events on
      the session's PubSub topic
    * `:metadata` — arbitrary session metadata propagated from
      `Tau.start_session/1`
  """

  @enforce_keys [:session_id]
  defstruct [
    :session_id,
    :cwd,
    :emit,
    permissions_mode: :default,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          cwd: String.t() | nil,
          permissions_mode: Tau.Permissions.RuleSet.mode(),
          emit: (term() -> :ok) | nil,
          metadata: map()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__,
      session_id: Keyword.fetch!(opts, :session_id),
      cwd: opts[:cwd],
      permissions_mode: opts[:permissions_mode] || :default,
      emit: opts[:emit] || fn _ -> :ok end,
      metadata: opts[:metadata] || %{}
    )
  end
end
