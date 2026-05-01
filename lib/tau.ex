defmodule Tau do
  @moduledoc """
  Tau — an OTP/BEAM agentic coding harness.

  Tau is a from-scratch reimagining of the Pi harness (`badlogic/pi-mono`)
  built around Elixir/OTP idioms. The public API surface is small; everything
  beneath is processes, behaviours, and pure functions.

  See `TAU.md` and `CLAUDE.md` at the repo root for design philosophy and
  contribution guidelines.

  ## High-level usage

      {:ok, session_id} = Tau.start_session(provider: Tau.Providers.Anthropic)
      :ok = Tau.send(session_id, "Summarize this repo.")

      Tau.stream(session_id)
      |> Stream.each(&IO.inspect/1)
      |> Stream.run()

  All public functions return tagged tuples (`{:ok, _}` / `{:error, _}`)
  unless documented otherwise; nothing here raises on user-input errors.
  """

  alias Tau.Session

  @type session_id :: String.t()

  @doc """
  Start a new session under `Tau.Sessions.Supervisor`.

  ## Options

    * `:provider` — module implementing `Tau.Provider` (defaults to configured)
    * `:model` — provider-specific model id
    * `:cwd` — working directory the session operates from
    * `:system_prompt` — overrides the default system prompt
    * `:tools` — `:all` or a list of tool modules / names to whitelist
    * `:permissions_mode` — `:default | :accept_edits | :plan | :auto | :dont_ask | :bypass`
    * `:persistence` — module implementing `Tau.Persistence`
    * `:resume_from` — event id to fork from (creates a new session branched off another)
    * `:metadata` — arbitrary user metadata attached to the session.
      JSON-encodable values only — see `Tau.Session.Meta`.
    * `:provider_ctx` — map merged into the `ctx` argument every time
      this session calls `provider.stream/3`. Per-session, in-memory,
      not persisted, not propagated to forks/resumes. Use this for
      runtime provider config that must not bleed across sessions
      (replay fixtures in tests, per-session routing tags, etc.).
      See ADR-0002.
  """
  @spec start_session(keyword()) :: {:ok, session_id()} | {:error, term()}
  def start_session(opts \\ []) do
    Session.start(opts)
  end

  @doc """
  Send a user message to a running session. Returns immediately;
  consumers should subscribe via `stream/2` to receive the response.
  """
  @spec send(session_id(), String.t() | Tau.Message.t()) :: :ok | {:error, term()}
  defdelegate send(session_id, message), to: Session

  @doc """
  Subscribe to a session's event stream.

  Returns a `Stream.t()` that yields `Tau.Provider.Event`-and-friends structs
  until the session reports `%Tau.Session.Events.SessionEnd{}`.
  """
  @spec stream(session_id(), keyword()) :: Enumerable.t()
  defdelegate stream(session_id, opts \\ []), to: Session

  @doc """
  Resume a previously persisted session by id. Replays the JSONL transcript,
  rebuilds context, and transitions the FSM to `:awaiting_user`.
  """
  @spec resume(session_id()) :: {:ok, session_id()} | {:error, term()}
  defdelegate resume(session_id), to: Session

  @doc """
  Fork a session at a given event id, creating a new branch. The new session's
  first persisted event references the parent event's id, enabling tree-shaped
  conversation history.
  """
  @spec fork(session_id(), parent_event_id :: String.t()) :: {:ok, session_id()} | {:error, term()}
  defdelegate fork(session_id, parent_event_id), to: Session

  @doc """
  Cancel any in-flight work in a session. Terminates active tool tasks,
  stops the provider stream, and returns the FSM to `:awaiting_user`.
  """
  @spec cancel(session_id()) :: :ok
  defdelegate cancel(session_id), to: Session

  @doc """
  Reconfigure a live session's provider, model, or `provider_ctx`
  without restarting it. Any keys absent from `opts` keep their
  current value; `provider_ctx` is *merged* (not replaced).

  The change applies to the **next** turn the session starts. An
  in-flight `:provider_streaming` keeps using the previous
  provider/model — there is no mid-stream swap. The reconfiguration
  is persisted as a `"reconfigure"` event in the JSONL transcript so
  fork/resume can replay the history accurately.

  ## Options

    * `:provider` — module implementing `Tau.Provider`.
    * `:model` — provider-specific model id.
    * `:provider_ctx` — map merged into the session's existing
      `provider_ctx` (per-key replacement; values not in the new map
      are preserved).
  """
  @spec update_provider(session_id(), keyword()) :: :ok | {:error, :not_found}
  defdelegate update_provider(session_id, opts), to: Session

  @doc """
  Stop a session entirely. Runs `:stop` hooks (which may veto), flushes
  persistence, and removes the session process.
  """
  @spec stop(session_id()) :: :ok
  defdelegate stop(session_id), to: Session

  @doc """
  List persisted sessions. Filters on `:cwd`, `:since`, `:until`, `:limit`.
  """
  @spec list_sessions(map()) :: [Tau.Session.Meta.t()]
  defdelegate list_sessions(filters \\ %{}), to: Session

  @doc """
  Return a read-only snapshot of a live session — useful for tests,
  TUI panels, and debugging. The shape is stable across internal
  refactors. See `Tau.Session.snapshot/1`.
  """
  @spec snapshot(session_id()) :: {:ok, Tau.Session.snapshot()} | {:error, :not_found}
  defdelegate snapshot(session_id), to: Session
end
