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

  @doc """
  Optional. Resolve the on-disk path that holds the session transcript.

  Used by `Tau.Session` to populate the `transcript_path` field in hook
  payloads. Backends that don't materialise to a single file may return
  `nil`. Implementations are free to return a path that does not yet
  exist (callers treat the field as informational).
  """
  @callback path_for(session_id(), Path.t()) :: Path.t() | nil

  @optional_callbacks [path_for: 2]

  @doc "Look up the configured persistence module."
  @spec impl() :: module()
  def impl, do: Application.get_env(:tau, :persistence, Tau.Persistence.Jsonl)
end
