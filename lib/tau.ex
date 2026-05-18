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
    * `:tools_whitelist` — `:all` (default) or a list of tool name
      strings restricting which tools this session may call. Filter
      runs in `Tau.Session.dispatch_tools/2` before
      `Tau.Permissions.Evaluator`; calls outside the list synthesise an
      `is_error: true` ToolResult the same way deny rules do. Useful
      for sandboxed sessions and the subagent groundwork (ADR-0014/15).
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
    * `:active_skill` — `%Tau.Skill{}` to pin as the session's active
      skill from turn one. Used by `Tau.Tools.Builtin.Agent` (ADR-0015)
      to pre-install a sub-agent persona without round-tripping
      through `__activate_skill__`. Defaults to `nil`.
    * `:persona_lifetime` — `:turn` (default, ADR-0013) or `:session`
      (ADR-0015). `:turn` clears `data.active_skill` on `:end_turn`;
      `:session` pins it for the session's life so a sub-agent cannot
      dismiss its own persona. Has no effect when `:active_skill` is
      `nil`.
    * `:coding_agent` — module implementing `Tau.CodingAgent`
      (SPEC-CODING-AGENT). When set, user messages route through the
      coding-agent dispatcher (FSM state `:coding_agent_streaming`)
      instead of `provider.stream/3`. Default `nil` preserves the
      legacy provider path byte-identically. See `--coding-agent` on
      the CLI for the user-facing surface.
    * `:coding_agent_ctx` — per-run map threaded into the
      `Tau.CodingAgent` adapter's `ctx` argument. Same shape as
      `:provider_ctx` (ADR-0002): not persisted, not propagated to
      forks/resumes. Tests use this to thread Replay fixtures.
    * `:coding_agent_workspace_backend` — override the workspace
      backend (`Tau.CodingAgent.Workspace.Git` /
      `Tau.CodingAgent.Workspace.Cwd`). Default: Git when invoked
      inside a repo, Cwd otherwise.
    * `:coding_agent_workspace_opts` — extra opts (e.g. `:state_dir`)
      passed through to `Tau.CodingAgent.Workspace.prepare/1`.
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
  Swap the active model for a running session. Gated on the session being
  in `:awaiting_user` with no command task in flight (D-041 / [C54-B4]).

  Returns `{:ok, %{from: old_model, to: new_model}}` on success.
  Returns `{:error, :busy}` if streaming or running a command.
  Returns `{:error, :not_found}` if the session id is unknown.
  Returns `{:error, :invalid_model}` if `model` is blank or whitespace.
  """
  @spec swap_model(session_id(), String.t()) ::
          {:ok, %{from: String.t(), to: String.t()}}
          | {:error, :busy | :not_found | :invalid_model}
  defdelegate swap_model(session_id, model), to: Session

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

  @doc """
  Register `child_id` as a child of `parent_id` so that `Tau.cancel/1`
  and `Tau.stop/1` on the parent cascade to it (ADR-0014, issue #92).

  Intended for the upcoming `Agent` tool: after a successful
  `Tau.start_session/1` for a sub-agent, the spawn task casts
  `{:register_child, child_id}` to its parent FSM via this helper. Returns
  `:ok` even if the parent isn't currently registered (cast semantics).
  """
  @spec register_child(session_id(), session_id()) :: :ok
  def register_child(parent_id, child_id) when is_binary(parent_id) and is_binary(child_id) do
    case Registry.lookup(Tau.Sessions.Registry, parent_id) do
      [{pid, _}] -> :gen_statem.cast(pid, {:register_child, child_id})
      _ -> :ok
    end
  end

  @doc """
  Drop `child_id` from `parent_id`'s child-cascade set. Called by the
  `Agent` tool's spawn task when it observes the child's
  `%Tau.Session.Events.SessionEnd{}` so a subsequent `Tau.cancel/1` on
  the parent doesn't `Tau.cancel/1` an already-stopped session.
  """
  @spec unregister_child(session_id(), session_id()) :: :ok
  def unregister_child(parent_id, child_id) when is_binary(parent_id) and is_binary(child_id) do
    case Registry.lookup(Tau.Sessions.Registry, parent_id) do
      [{pid, _}] -> :gen_statem.cast(pid, {:unregister_child, child_id})
      _ -> :ok
    end
  end
end
