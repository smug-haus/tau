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
  Identify where the session's transcript can be retrieved.

  Used by `Tau.Session` to populate the `transcript_path` field in
  hook payloads — every payload always carries a non-nil binary,
  regardless of backend. **Required.**

  For file-backed backends (`Tau.Persistence.Jsonl`), return an
  absolute filesystem path. For non-file backends (DETS, remote DB,
  …), return a pseudo-URI that uniquely identifies the transcript
  location in the backend's address space (`"dets://table/sid"`,
  `"db://schema/sid"`, …). Implementations are free to return a
  string that does not yet exist on disk; callers treat the field
  as an addressing identifier, not a guarantee of readability.

  See `Tau.Persistence.Jsonl.path_for/2` for an example, and the
  `Tau.Hook` payload contract for what hooks should expect when
  reading the transcript concurrently with the writer.
  """
  @callback path_for(session_id(), Path.t()) :: String.t()

  @doc "Look up the configured persistence module."
  @spec impl() :: module()
  def impl, do: Application.get_env(:tau, :persistence, Tau.Persistence.Jsonl)
end
