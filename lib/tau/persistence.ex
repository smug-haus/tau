defmodule Tau.Persistence do
  @moduledoc """
  Behaviour for session storage.

  Implementations:

    * `Tau.Persistence.Jsonl` — newline-delimited JSON, one event per line
      (default; mirrors Pi).
    * `Tau.Persistence.Dets`  — single-file fallback, useful in tests.

  Events flow append-only; replay is via `stream/1`. `fork/3` is
  implementation-defined (JSONL writes a new file referencing a parent
  event id; DETS just clones).
  """

  @type session_id :: String.t()
  @type event :: map()

  @callback open(session_id(), keyword()) :: {:ok, handle :: term()} | {:error, term()}
  @callback append(handle :: term(), event()) :: :ok | {:error, term()}
  @callback stream(session_id()) :: Enumerable.t()
  @callback close(handle :: term()) :: :ok
  @callback list(filters :: map()) :: [Tau.Session.Meta.t()]

  @doc "Look up the configured persistence module."
  @spec impl() :: module()
  def impl, do: Application.get_env(:tau, :persistence, Tau.Persistence.Jsonl)
end
