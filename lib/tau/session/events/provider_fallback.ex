defmodule Tau.Session.Events.ProviderFallback do
  @moduledoc """
  Broadcast on `Phoenix.PubSub` topic `"session:<id>"` when the
  session FSM falls back from one provider to another mid-turn
  on a retryable `%Tau.Provider.Event.Error{retryable?: true}`
  (ADR-0012).

  Fields:

    * `:session_id`     — the session id (for filtering across
      multi-session subscribers).
    * `:from_provider`  — provider module the session was using
      when the error arrived.
    * `:to_provider`    — provider module the session is now
      retrying against.
    * `:reason`         — the original `Event.Error` reason term.
  """

  @enforce_keys [:session_id, :from_provider, :to_provider]
  defstruct [:session_id, :from_provider, :to_provider, :reason]

  @type t :: %__MODULE__{
          session_id: String.t(),
          from_provider: module(),
          to_provider: module(),
          reason: term()
        }
end
