defmodule Tau.Session do
  @moduledoc """
  Per-session `:gen_statem` (callback mode `:handle_event_function`).

  States:

      :awaiting_user
      :provider_streaming
      :tool_executing
      :compacting
      :stopped

  Cross-cutting events (`{:cancel, _}`, `{:DOWN, _, ...}`) are handled
  uniformly via `handle_event/4` rather than duplicating clauses across
  per-state callback functions.

  Each session:
    * is registered in `Tau.Sessions.Registry` under its `session_id`
    * broadcasts `Tau.Session.Events` on PubSub topic `"session:<id>"`
    * persists every state-changing event via `Tau.Persistence` (default
      `Tau.Persistence.Jsonl`)
    * holds a reference to a linked `provider_task` while streaming
    * spawns tool executions under `Tau.Tools.TaskSupervisor` (`async_stream_nolink`
      for `:parallel` tools; inline for `:sequential`)
  """

  @behaviour :gen_statem

  alias Tau.Message.{Assembler, Assistant, ToolResult, User}
  alias Tau.Session.Events
  alias Tau.Provider.Event, as: PEvent
  alias Tau.Settings.Cache, as: SettingsCache
  # SPEC-CODING-AGENT (#191): coding-agent session mode. The FSM hosts
  # a parallel `:coding_agent_streaming` state. When `data.coding_agent`
  # is non-nil, user messages route through `Tau.CodingAgent.Dispatcher`
  # instead of `data.provider.stream/3`; the dispatcher's normalized
  # events fold into `data.messages` as `%Assistant{}` / `%ToolResult{}`
  # so the existing TUI render path, persistence, and `/resume` apply
  # unchanged (D-037).
  alias Tau.CodingAgent.Event, as: CAEvent
  alias Tau.CodingAgent.Workspace, as: CAWorkspace

  # #17: name of the synthetic FSM-internal tool the model emits to
  # activate a discovered skill. Not registered as a `Tau.Tool` module
  # — interception happens in `dispatch_tools/2` before any executor
  # would see it.
  @activate_skill_tool_name "__activate_skill__"

  @type id :: String.t()

  defmodule Meta do
    @moduledoc """
    Session metadata returned by `Tau.list_sessions/1`.

    ## The `:metadata` field — contract

    `:metadata` is an arbitrary user-supplied map propagated from
    `Tau.start_session/1`'s `:metadata` opt. It travels with the
    session through fork/resume, is persisted in the JSONL session
    header, and is reachable by tools (`Tau.Tool.Context.metadata`)
    and slash commands (`Tau.Command.Context.metadata`).

    Two consequences for callers:

      * **Values must be JSON-encodable.** The session's persistence
        layer (`Tau.Persistence.Jsonl`) writes the header via
        `Jason.encode!/2`. PIDs, references, anonymous functions,
        ports, tuples (other than the ones Jason supports natively),
        and module structs without a `Jason.Encoder` impl will crash
        the session at init time. Stick to: maps, lists, strings,
        numbers, booleans, `nil`, and atoms (encoded as strings).
        For things that need a process handle, register a name with
        `Process.register/2` and put the atom in metadata.

      * **Namespace your keys.** Tau itself reserves a small set of
        keys; future versions may grow that set. To avoid collisions,
        put your keys under a project-specific prefix (e.g.
        `"my_app__foo"`) or use a tagged tuple as a value.

    ### Reserved metadata keys

    Read or written by Tau today:

      * `:permissions_mode` — atom controlling tool permissions
        evaluation. Read by `Tau.Session.dispatch_tools/2` and
        plumbed through to `Tau.Command.Context.permissions_mode`.
        Defaults to `:default` if unset. Valid values:
        `:default | :accept_edits | :plan | :auto | :dont_ask | :bypass`.

      * `:forked_from` — `%{session: parent_id, event: parent_event_id}`
        map, written by `Tau.fork/2` onto the new session's metadata
        so the JSONL header records its provenance. Do not set this
        manually.

    Both keys live under the atom namespace; do not shadow them with
    string-keyed equivalents.
    """
    @enforce_keys [:id, :cwd, :created_at]
    defstruct [:id, :cwd, :created_at, :updated_at, :provider, :model, :metadata]

    @type t :: %__MODULE__{
            id: String.t(),
            cwd: String.t(),
            created_at: DateTime.t(),
            updated_at: DateTime.t() | nil,
            provider: String.t() | module() | nil,
            model: String.t() | nil,
            metadata: map() | nil
          }
  end

  # --- Public API (delegated from Tau) -------------------------------------

  @spec start(keyword()) :: {:ok, id()} | {:error, term()}
  def start(opts) do
    id = opts[:session_id] || generate_id()

    case Tau.Sessions.Supervisor.start_session(Keyword.put(opts, :session_id, id)) do
      {:ok, _pid} -> {:ok, id}
      {:error, _} = e -> e
    end
  end

  @spec send(id(), String.t() | Tau.Message.t()) :: :ok | {:error, term()}
  def send(id, message) do
    with {:ok, pid} <- whereis(id) do
      msg =
        case message do
          %User{} -> message
          s when is_binary(s) -> User.new(s)
          %{} -> message
        end

      :gen_statem.cast(pid, {:user_message, msg})
    end
  end

  @spec stream(id(), keyword()) :: Enumerable.t()
  def stream(id, _opts \\ []) do
    Stream.resource(
      fn ->
        Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{id}")
        :ok
      end,
      fn :ok ->
        receive do
          %Events.SessionEnd{} = e -> {[e], :halt}
          msg when is_struct(msg) -> {[msg], :ok}
        after
          60_000 -> {:halt, :ok}
        end
      end,
      fn _ -> :ok end
    )
  end

  @spec resume(id()) :: {:ok, id()} | {:error, term()}
  def resume(id) do
    case whereis(id) do
      {:ok, _pid} ->
        {:ok, id}

      _ ->
        # Replay JSONL into a fresh session.
        events = Tau.Persistence.impl().stream(id) |> Enum.to_list()

        case events do
          [] ->
            {:error, :not_found}

          [%{"kind" => "session_header", "data" => d} | rest] ->
            # SPEC-CODING-AGENT §7 Q4/Q5 (D-037/D-038): thread the
            # post-header event log into `:preload_events` so init/1's
            # `coding_agent_state_from_preload/1` and
            # `coding_agent_costs_from_preload/1` can rehydrate the
            # adapter-side session_id (for the next dispatcher's
            # `task.resume_id`) and the per-session cost ledger.
            # Mirrors `fork/2`'s shape — provider-only sessions pass
            # an event list with no coding_agent_* kinds, and the
            # helpers fall back to safe defaults (nil / []).
            opts = [
              session_id: id,
              cwd: d["cwd"],
              provider: resolve_provider(d["provider"]),
              model: d["model"],
              metadata: d["metadata"] || %{},
              resume?: true,
              preload_events: rest
            ]

            start(opts)
        end
    end
  end

  @spec fork(id(), String.t()) :: {:ok, id()} | {:error, term()}
  def fork(parent_id, parent_event_id) do
    persistence = Tau.Persistence.impl()

    events = persistence.stream(parent_id) |> Enum.to_list()

    case events do
      [] ->
        {:error, :parent_not_found}

      [%{"kind" => "session_header", "data" => header} | rest] ->
        # Find the cutoff: keep all events up to and including parent_event_id.
        kept =
          rest
          |> Enum.reduce_while([], fn event, acc ->
            new_acc = [event | acc]

            if event["id"] == parent_event_id do
              {:halt, new_acc}
            else
              {:cont, new_acc}
            end
          end)
          |> Enum.reverse()

        if kept == [] and parent_event_id != nil do
          {:error, :parent_event_not_found}
        else
          new_id = generate_id()

          opts = [
            session_id: new_id,
            cwd: header["cwd"],
            provider: resolve_provider(header["provider"]),
            model: header["model"],
            metadata:
              Map.put(header["metadata"] || %{}, :forked_from, %{
                session: parent_id,
                event: parent_event_id
              }),
            parent_event_id: parent_event_id,
            preload_events: kept
          ]

          start(opts)
        end
    end
  end

  @spec cancel(id()) :: :ok
  def cancel(id) do
    with {:ok, pid} <- whereis(id) do
      :gen_statem.cast(pid, :cancel)
    end

    :ok
  end

  @spec stop(id()) :: :ok
  def stop(id) do
    with {:ok, pid} <- whereis(id) do
      :gen_statem.cast(pid, :stop)
    end

    :ok
  end

  @spec update_provider(id(), keyword()) :: :ok | {:error, :not_found}
  def update_provider(id, opts) when is_list(opts) do
    case whereis(id) do
      {:ok, pid} ->
        :gen_statem.cast(pid, {:reconfigure, opts})
        :ok

      err ->
        err
    end
  end

  @doc """
  Swap the active model for a session mid-session. Gated: only allowed
  while the FSM is in `:awaiting_user` with no command task in flight.

  Returns `{:ok, %{from: old_model, to: new_model}}` on success.
  Returns `{:error, :busy}` if the session is streaming or running a command.
  Returns `{:error, :not_found}` if the session id is unknown.
  Returns `{:error, :invalid_model}` if `model` is blank or whitespace.
  """
  @spec swap_model(id(), String.t()) ::
          {:ok, %{from: String.t(), to: String.t()}}
          | {:error, :busy | :not_found | :invalid_model}
  def swap_model(id, model) do
    case whereis(id) do
      {:ok, pid} -> :gen_statem.call(pid, {:swap_model, model})
      err -> err
    end
  end

  @spec list_sessions(map()) :: [Meta.t()]
  def list_sessions(filters \\ %{}), do: Tau.Persistence.impl().list(filters)

  @typedoc """
  Curated read-only view of a live session, returned by `snapshot/1`.

  The shape is **stable** across internal refactors — adding a field
  is allowed; renaming or repurposing one isn't. Callers (tests,
  TUI panels, debug tools) depend on this contract.
  """
  @type snapshot :: %{
          id: String.t(),
          state: atom(),
          cwd: String.t(),
          provider: module() | nil,
          model: String.t() | nil,
          messages: [Tau.Message.t()],
          message_count: non_neg_integer(),
          skills: [{String.t(), Tau.Skill.t()}],
          metadata: map(),
          permissions_mode: atom(),
          tools_whitelist: [String.t()] | :all,
          child_session_ids: MapSet.t(String.t()),
          tool_iterations: non_neg_integer(),
          max_tool_iterations: pos_integer()
        }

  @doc """
  Return a read-only snapshot of a live session's data (#58).

  Tests and inspection tools should call this instead of reaching
  into the FSM via `:sys.get_state/1` — it insulates callers from
  internal data-shape refactors. Returns `{:error, :not_found}`
  for a session id that isn't currently registered.
  """
  @spec snapshot(id()) :: {:ok, snapshot()} | {:error, :not_found}
  def snapshot(id) do
    with {:ok, pid} <- whereis(id) do
      {state, data} = :sys.get_state(pid)

      {:ok,
       %{
         id: data.id,
         state: state,
         cwd: data.cwd,
         provider: data.provider,
         model: data.model,
         messages: data.messages,
         message_count: length(data.messages),
         skills: data.skills,
         metadata: data.metadata,
         permissions_mode: Map.get(data.metadata, :permissions_mode, :default),
         tools_whitelist: data.tools_whitelist,
         child_session_ids: data.child_session_ids,
         tool_iterations: Map.get(data, :tool_iterations, 0),
         max_tool_iterations: Map.get(data, :max_tool_iterations, 20)
       }}
    end
  end

  defp whereis(id) do
    case Registry.lookup(Tau.Sessions.Registry, id) do
      [{pid, _}] -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Generate a fresh session id (UUIDv7 if available, prefixed random
  bytes otherwise). Public so callers that need to subscribe to
  `"session:<id>"` PubSub events BEFORE `start_session/1` returns can
  pre-allocate the id and pass it via `:session_id` (D-004).
  """
  @spec generate_id() :: id()
  def generate_id do
    case Code.ensure_loaded?(Uniq.UUID) do
      true -> apply(Uniq.UUID, :uuid7, [])
      _ -> "sess_" <> (:crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false))
    end
  end

  defp resolve_provider(nil), do: Tau.Provider.default()

  defp resolve_provider(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      _ -> Tau.Provider.default()
    end
  end

  defp resolve_provider(m) when is_atom(m), do: m

  # --- :gen_statem plumbing -------------------------------------------------

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    id = Keyword.fetch!(opts, :session_id)
    :gen_statem.start_link(via(id), __MODULE__, opts, [])
  end

  defp via(id), do: {:via, Registry, {Tau.Sessions.Registry, id}}

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(opts) do
    id = Keyword.fetch!(opts, :session_id)
    cwd = opts[:cwd] || File.cwd!()
    provider = opts[:provider] || Tau.Provider.default()
    # D-002 (SPEC-USER-TURN [C29]): resolve nil model to the provider's
    # default at session init, NOT at stream-call time. Without this,
    # `data.model` stays nil through telemetry, persistence header, and
    # the assembler — all of which expect a real model id.
    #
    # D-041 / [C54-B4]: fold the last persisted `model_swap` event from
    # preload so resume and fork both converge on the swapped model.
    # Mirrors `coding_agent_state_from_preload/1`.
    model =
      model_from_preload(opts[:preload_events] || []) || opts[:model] || provider.default_model()

    metadata = opts[:metadata] || %{}
    provider_ctx = opts[:provider_ctx] || %{}
    persistence = opts[:persistence] || Tau.Persistence.impl()
    preload = opts[:preload_events] || []
    # SPEC-CODING-AGENT §4 B1 / D-037: coding-agent session mode. When
    # `:coding_agent` is set the FSM routes user messages through the
    # `:coding_agent_streaming` state. CLI flag overrides settings;
    # settings provides the deployment-wide default.
    coding_agent =
      opts[:coding_agent] ||
        coding_agent_from_settings()

    coding_agent_workspace_backend =
      opts[:coding_agent_workspace_backend] ||
        if(coding_agent, do: CAWorkspace.resolve_default_backend(cwd), else: nil)

    coding_agent_workspace_opts = opts[:coding_agent_workspace_opts] || []
    # SPEC-CODING-AGENT §4 B1: per-run knobs for the coding-agent
    # adapter. Mirrors `:provider_ctx` (ADR-0002) — not persisted, not
    # propagated to forks/resumes. Tests use this to thread a Replay
    # fixture into the adapter without touching settings or env.
    coding_agent_ctx = opts[:coding_agent_ctx] || %{}

    case persistence.open(id,
           cwd: cwd,
           provider: inspect(provider),
           model: model,
           metadata: metadata,
           parent_event_id: opts[:parent_event_id]
         ) do
      {:ok, persist_handle} ->
        register_builtins()

        :telemetry.execute(
          [:tau, :session, :start],
          %{system_time: System.system_time()},
          %{session_id: id, provider: provider}
        )

        broadcast(id, %Events.SessionStart{
          session_id: id,
          provider: provider,
          model: model,
          cwd: cwd,
          metadata: metadata
        })

        skills = load_skills(cwd)

        # ADR-0013 / ADR-0015: skills with `disable_model_invocation: true`
        # are background-only — their bodies (and `# Skill: <name>` headings)
        # MUST NOT enter the model-visible system_blob, lest internal
        # personas leak. Filter at the assembly site; `prepend_skill_messages/2`
        # also filters as defence-in-depth.
        model_visible_skills =
          Enum.reject(skills, fn {_name, s} -> s.disable_model_invocation end)

        messages =
          preload
          |> events_to_messages()
          |> prepend_skill_messages(model_visible_skills)
          |> inject_memory(cwd)

        data = %{
          id: id,
          cwd: cwd,
          provider: provider,
          # ADR-0012: original_provider is the user-configured provider for
          # the lifetime of the session. data.provider shape-shifts during
          # a fallback turn; finalize_assistant/2 restores it from
          # original_provider so the next turn always starts against the
          # primary (per-message fallback semantics).
          original_provider: provider,
          model: model,
          metadata: metadata,
          provider_ctx: provider_ctx,
          messages: messages,
          skills: skills,
          persistence: persistence,
          persist_handle: persist_handle,
          provider_task: nil,
          # ADR-0012: per-stream tag (a fresh `make_ref/0`) used to
          # distinguish events emitted by the *current* provider task
          # from stragglers left over from a predecessor that was killed
          # mid-stream during a fallback transition. Re-issued in every
          # `:start_provider`; matched on in every `{:provider_event, _,
          # _}`, `{:provider_done, _}`, `{:provider_failed, _, _}`
          # handler. Stale messages whose ref doesn't match are dropped
          # by the catch-all clause.
          stream_ref: nil,
          # C76 (SPEC-OTEL-REPORTER): per-request OTel span discriminator.
          # Generated at [:tau, :provider, :request, :start] emit time;
          # echoed through *.stop / *.cancelled / *.brutal_kill so the
          # OTel reporter can correlate them to the open span. Cleared
          # whenever the FSM leaves the request (reset to nil alongside
          # stream_ref). Each fallback attempt generates a fresh ref —
          # that is correct: a fallback is a distinct provider request.
          provider_span_ref: nil,
          # ADR-0017: per-stream cooperative-cancel flag (a `:counters`
          # ref). Allocated freshly in `:start_provider`; consulted by the
          # `:cancel` handler before falling back to brutal-kill.
          cancel_flag: nil,
          assembler: nil,
          # ADR-0012: per-turn fallback queue. Re-derived from
          # Tau.Settings.Cache at the start of every :start_provider so a
          # settings reload between turns is picked up automatically.
          fallback_chain_remaining: [],
          tools_in_flight: %{},
          # #33: pid of the per-turn parallel-tool dispatcher (a child of
          # Tau.Tools.TaskSupervisor that drives Task.Supervisor.async_stream_nolink/4
          # over the turn's tool calls). Stored so :cancel can brutal-kill
          # the iterator; orphaned tool tasks remain under the supervisor
          # and complete or are reaped naturally.
          tool_dispatcher: nil,
          # ADR-0008: slash-command tasks (user code) run isolated under
          # Tau.Tools.TaskSupervisor, never inline in the FSM.
          command_task: nil,
          # ADR-0013 (#16): currently-active skill, or nil. When set,
          # `Tau.Permissions.Evaluator` denies any tool not on
          # `active_skill.allowed_tools` before consulting the rule set.
          # Per-turn lifetime by default: cleared in `finalize_assistant/2`
          # when the assistant returns `stop_reason == :end_turn` and on
          # `:cancel`. ADR-0015 sub-agents may pre-pin a persona at start
          # time via the `:active_skill` opt + `:persona_lifetime: :session`
          # so the persona survives `:end_turn` and stays live for the
          # session's whole life (the child can't dismiss it).
          active_skill: opts[:active_skill],
          # ADR-0015: `:turn` (default) clears `active_skill` on
          # `:end_turn`; `:session` pins it for the session's life. Only
          # the `Agent` tool sets `:session` today; everything else
          # behaves exactly like ADR-0013.
          persona_lifetime: opts[:persona_lifetime] || :turn,
          # #91: spawn-time tool whitelist (`:all` or `[String.t()]`).
          # Filter applies in `dispatch_tools/2` before
          # `Tau.Permissions.Evaluator`; calls outside the list synthesise
          # an `is_error: true` ToolResult the same way deny rules do.
          # Foundation for ADR-0014/15 subagent personas (the parent's
          # `Agent` tool plumbs the child skill's `allowed_tools` through
          # this opt). `:all` preserves today's behaviour.
          tools_whitelist: opts[:tools_whitelist] || :all,
          # ADR-0014 (#92): set of currently-running child session ids
          # spawned by this session via the `Agent` tool. Populated by
          # `{:register_child, _}` casts from the spawn task and emptied
          # by `{:unregister_child, _}` when a child reports `%SessionEnd{}`.
          # `Tau.cancel/1` and `Tau.stop/1` cascade across this set before
          # tearing down the parent's own provider/tool/command tasks so
          # children get a clean shutdown path (flush JSONL, emit
          # `%SessionEnd{reason: :user}`) rather than being reaped from
          # above. Supervisor is `:one_for_one`; a parent crash does *not*
          # propagate to children — that's the whole point of explicit
          # cascade on the user-driven shutdown paths.
          child_session_ids: MapSet.new(),
          # D-005 / AC-6 (SPEC-USER-TURN [C24]): tool-call iteration cap.
          # Counts tool-dispatch rounds within a single user turn; reset to
          # 0 when the FSM returns to :awaiting_user (clean end_turn OR
          # tool_loop_aborted). Capped at max_tool_iterations; overflow
          # emits [:tau, :session, :tool_iteration_cap] telemetry and aborts
          # the turn with stop_reason: :tool_loop_aborted.
          tool_iterations: 0,
          max_tool_iterations:
            opts[:max_tool_iterations] ||
              get_in(SettingsCache.get(), [:session, :max_tool_iterations]) ||
              20,
          # SPEC-CODING-AGENT (#191):
          #
          # `coding_agent` — adapter module or nil. When set, user
          # messages route to `:coding_agent_streaming`.
          #
          # `coding_agent_workspace_backend` — pluggable backend module
          # (`Workspace.Git` for repo-detected, `Workspace.Cwd`
          # otherwise). Resolved at init time from `cwd`; lazily
          # `prepare/2`'d on the first `:coding_agent_streaming`
          # transition so a session that never runs an agent pays no
          # worktree cost.
          #
          # `coding_agent_workspace_opts` — extra opts threaded through
          # to `Workspace.prepare/1` (e.g. `:state_dir` overrides in
          # tests).
          #
          # `coding_agent_workspace` — the prepared `%Workspace{}` once
          # established; persists across turns within the same session
          # so the agent keeps editing the same isolated branch.
          # Cleaned up in `terminate/3`.
          #
          # `coding_agent_dispatcher` — pid of the currently-running
          # dispatcher, or nil. Holds the cancel target for
          # `:cancel` in `:coding_agent_streaming`.
          #
          # `coding_agent_pending` — the in-progress `%Assistant{}`
          # being assembled from dispatcher events. Finalized on `Done`.
          #
          # `coding_agent_blocks` — ordered content-block accumulator
          # for the in-progress assistant message. AssistantText events
          # append to a single text block (per turn); ToolUse events
          # append `%{type: :tool_call, ...}` blocks. Mirrors the
          # provider-side `Assembler`'s `:order` semantics.
          coding_agent: coding_agent,
          coding_agent_ctx: coding_agent_ctx,
          coding_agent_workspace_backend: coding_agent_workspace_backend,
          coding_agent_workspace_opts: coding_agent_workspace_opts,
          coding_agent_workspace: nil,
          coding_agent_dispatcher: nil,
          coding_agent_pending: nil,
          coding_agent_blocks: [],
          # SPEC-CODING-AGENT §7 Q5 / D-037: adapter-side session
          # state. Today carries the Claude-Code-side `session_id`
          # captured from `%Event.Start{}` so the next dispatcher
          # launch can thread it as `task.resume_id`. Persisted to
          # JSONL via the `coding_agent_session` event so `/resume`
          # recovers it across BEAM restarts.
          coding_agent_state:
            coding_agent_state_from_preload(preload) ||
              %{session_id: nil, agent: nil},
          # SPEC-CODING-AGENT §7 Q4 / D-038: per-session list of
          # adapter-tagged cost records, folded from `%Event.Cost{}`
          # events. Sums the dollar/token/duration split for the
          # active session. Persisted line-by-line via the
          # `coding_agent_cost` JSONL event so `/resume` can fold
          # the totals back.
          coding_agent_costs: coding_agent_costs_from_preload(preload),
          # D-048 / D-049 / C67-B4: async compaction worker state.
          #
          # `compaction_task` — pid of the running compaction worker task, or nil.
          # Set in the {:async_compact, _} arm of handle_builtin_command/4;
          # cleared by every terminal clause of the :compacting state (worker
          # success, worker crash, timeout, :cancel).
          #
          # `compaction_monitor` — monitor ref returned by Task.Supervisor.async_nolink/3,
          # the discriminating guard key for the five terminal clauses. Presence
          # guards on demonitor/exit calls (BLOCKING-2/3 fixes).
          #
          # `compaction_failures` — per-session consecutive failure counter (D-016).
          # Shared across sync (maybe_compact/2) and async paths — NOT path-tagged.
          # Reset to 0 on any successful compaction; NOT reset by :cancel (a
          # cancelled compaction is not a success; resetting would let users mask
          # a broken compactor). Re-initialised to 0 on resume/fork (not persisted).
          compaction_task: nil,
          compaction_monitor: nil,
          compaction_failures: 0
        }

        {:ok, :awaiting_user, data}

      err ->
        {:stop, err}
    end
  end

  @impl :gen_statem
  def terminate(reason, _state, %{persistence: p, persist_handle: h, id: id} = data) do
    p.close(h)

    # SPEC-CODING-AGENT D-032 + Workspace cleanup. Runs on every
    # terminate path — normal exit, crash, supervisor shutdown — so
    # the worktree never leaks across BEAM restarts. Best-effort and
    # idempotent (no-op when workspace is nil or already cleaned).
    if Map.get(data, :coding_agent_dispatcher) do
      pid = data.coding_agent_dispatcher
      if Process.alive?(pid), do: Tau.CodingAgent.Dispatcher.cancel(pid)
    end

    CAWorkspace.cleanup(Map.get(data, :coding_agent_workspace))

    broadcast(id, %Events.SessionEnd{session_id: id, reason: reason})

    :telemetry.execute([:tau, :session, :stop], %{system_time: System.system_time()}, %{
      session_id: id,
      reason: inspect(reason)
    })

    :ok
  end

  def terminate(_reason, _state, _data), do: :ok

  # --- Event handlers -------------------------------------------------------

  @impl :gen_statem
  # ADR-0008: while a slash-command task is in flight, postpone any
  # subsequent user_message casts. They get re-delivered when the FSM
  # next transitions, which guarantees order without dropping input.
  def handle_event(:cast, {:user_message, _}, state, %{command_task: t} = data)
      when t != nil do
    emit_user_message_telemetry(:enqueued, data, state)
    {:keep_state_and_data, [{:postpone, true}]}
  end

  # ADR-0009: outside :awaiting_user (provider streaming or tool
  # executing) postpone the cast so the next provider turn doesn't
  # interleave with the current one.
  def handle_event(:cast, {:user_message, _}, state, data)
      when state != :awaiting_user do
    emit_user_message_telemetry(:enqueued, data, state)
    {:keep_state_and_data, [{:postpone, true}]}
  end

  def handle_event(:cast, {:user_message, msg}, :awaiting_user, %{command_task: nil} = data) do
    emit_user_message_telemetry(:delivered, data, :awaiting_user)

    case classify_slash_command(msg, data.skills) do
      {:builtin, mod, args, msg} ->
        handle_builtin_command(mod, args, msg, data)

      {:async, mod, args, msg} ->
        spawn_command_task(mod, args, msg, data)

      {:skill_activation, skill, rewritten_msg} ->
        data = activate_skill_via_slash(data, skill)
        process_user_message(rewritten_msg, data)

      {:model_command, "", _msg} ->
        # /model with no args: show current model
        notice = "Current model: #{data.model}"
        broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})
        {:keep_state, data}

      {:model_command, new_model, _msg} ->
        # /model <id>: attempt swap
        handle_slash_model_swap(data, new_model)

      {:sync, msg} ->
        process_user_message(msg, data)
    end
  end

  def handle_event(:info, {:command_done, result, original_msg}, _state, data) do
    msg = apply_command_result(result, original_msg)
    process_user_message(msg, %{data | command_task: nil})
  end

  def handle_event(
        :info,
        {:command_timeout, pid, original_msg, ms},
        _state,
        %{command_task: pid} = data
      ) do
    if Process.alive?(pid), do: Process.exit(pid, :brutal_kill)
    msg = apply_command_result({:timeout, ms}, original_msg)
    process_user_message(msg, %{data | command_task: nil})
  end

  def handle_event(:info, {:command_timeout, _pid, _msg, _ms}, _state, data) do
    # Late timeout — task already completed and {:command_done, ...}
    # has already been processed. Drop.
    {:keep_state, data}
  end

  def handle_event(:internal, :start_provider, :provider_streaming, data) do
    transition(data.id, data, :provider_streaming)

    # ADR-0012: re-derive the fallback chain from settings on every fresh
    # turn (i.e. only when the chain hasn't already been seeded by a
    # previous fallback within this same turn). data.provider here is
    # always the original_provider for the first call of a turn — by
    # construction, fallback iterations rebuild data with a non-empty
    # remaining list and do NOT re-enter via this branch's seeding.
    data =
      if data.fallback_chain_remaining == [] and data.provider == data.original_provider do
        %{data | fallback_chain_remaining: lookup_fallback_chain(data.original_provider)}
      else
        data
      end

    parent = self()

    # ADR-0017: cooperative cancellation. Allocate a fresh per-stream
    # `:counters` ref and thread it through the provider ctx. The
    # `:cancel` handler flips slot 1 to signal abort; the streaming
    # engine (and Replay, for tests) checks it at every chunk boundary.
    cancel_flag = :counters.new(1, [])

    ctx =
      data.provider_ctx
      |> Map.merge(%{session_id: data.id, cancel_flag: cancel_flag})

    # C76 (SPEC-OTEL-REPORTER): generate a per-request discriminator ref so the
    # OTel reporter can correlate *.stop / *.cancelled / *.brutal_kill back to
    # this *.start span even when multiple requests from the same session to the
    # same provider are in flight concurrently (e.g. parallel sessions).
    provider_span_ref = make_ref()

    :telemetry.execute(
      [:tau, :provider, :request, :start],
      %{system_time: System.system_time()},
      %{
        provider: data.provider,
        model: data.model,
        session_id: data.id,
        span_ref: provider_span_ref
      }
    )

    stream_opts =
      %{model: data.model}
      |> maybe_put_tools(skill_activation_tool_spec(data.skills))

    # AC-7 (SPEC-CIRCUIT-BREAKER): wrap the provider call with the circuit
    # breaker façade. The thunk returns `{:ok, stream}` or `{:error, reason}`;
    # the façade records the outcome and, when the breaker is `:open`, short-
    # circuits with `{:error, :circuit_open}` before the thunk is invoked
    # (B3 contract, D-043). An open breaker falls through to the synchronous
    # error path below and surfaces as a user-visible `%Events.MessageEnd{}`
    # — it does NOT trigger ADR-0012 fallback (the fallback path is only
    # entered via in-stream `%PEvent.Error{retryable?: true}` events, not by
    # synchronous `{:error, _}` returns from this call site).
    case Tau.CircuitBreaker.call(data.provider, [], fn ->
           data.provider.stream(data.messages, stream_opts, ctx)
         end) do
      {:ok, stream} ->
        # ADR-0012: tag each stream's mailbox traffic with a fresh ref so
        # stragglers from a killed predecessor (e.g. a provider task whose
        # `:provider_done` was already in the parent mailbox when fallback
        # kicked in) get dropped instead of finalising a fresh assembler.
        stream_ref = make_ref()

        task =
          Task.async(fn ->
            try do
              Enum.each(stream, fn ev ->
                Process.send(parent, {:provider_event, stream_ref, ev}, [])
              end)

              Process.send(parent, {:provider_done, stream_ref}, [])
            rescue
              e ->
                Process.send(
                  parent,
                  {:provider_failed, stream_ref, Exception.message(e)},
                  []
                )
            end
          end)

        assembler = Assembler.new(provider: data.provider, model: data.model)
        broadcast(data.id, %Events.MessageStart{session_id: data.id, message: assembler.message})

        {:next_state, :provider_streaming,
         %{
           data
           | provider_task: task,
             assembler: assembler,
             cancel_flag: cancel_flag,
             stream_ref: stream_ref,
             provider_span_ref: provider_span_ref
         }}

      {:error, :circuit_open} ->
        # D-043 (SPEC-CIRCUIT-BREAKER): an open breaker on one provider MUST
        # advance the fallback chain rather than killing the turn immediately.
        # Only when the chain is exhausted (every provider's breaker open or
        # no fallback left) does the turn surface a terminal error. This
        # mirrors the in-stream `%PEvent.Error{retryable?: true}` path
        # (ADR-0012) and guarantees the all-open chain terminates: N providers
        # all open ⇒ N synchronous `{:error, :circuit_open}` returns ⇒ one
        # terminal error, no infinite loop (each recursive call pops one
        # element from `fallback_chain_remaining`).
        case data.fallback_chain_remaining do
          [next | rest] ->
            from_provider = data.provider

            :telemetry.execute(
              [:tau, :provider, :fallback],
              %{system_time: System.system_time()},
              %{
                from_provider: from_provider,
                to_provider: next,
                reason: :circuit_open,
                session_id: data.id
              }
            )

            broadcast(data.id, %Events.ProviderFallback{
              session_id: data.id,
              from_provider: from_provider,
              to_provider: next,
              reason: :circuit_open
            })

            data =
              persist_event(data, "provider_fallback", %{
                from_provider: inspect(from_provider),
                to_provider: inspect(next),
                reason: "circuit_open"
              })

            transformed =
              Tau.Providers.Shared.ContentTransform.transform(
                data.messages,
                from_provider,
                next
              )

            handle_event(
              :internal,
              :start_provider,
              :provider_streaming,
              %{
                data
                | provider: next,
                  messages: transformed,
                  fallback_chain_remaining: rest,
                  assembler: nil,
                  provider_task: nil,
                  stream_ref: nil
              }
            )

          [] ->
            # All providers exhausted — surface terminal error.
            reason_str = describe_provider_error(:circuit_open)

            msg =
              Assistant.new(
                stop_reason: :error,
                error_message: reason_str,
                content: [%{type: :text, text: "Error: " <> reason_str}]
              )

            broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: msg})

            {:next_state, :awaiting_user,
             %{data | cancel_flag: nil, stream_ref: nil, provider_span_ref: nil}}
        end

      {:error, reason} ->
        # Synchronous provider error — emit and return to awaiting_user.
        # D-009 (SPEC-USER-TURN [C12]/[C19]): the assistant message MUST
        # carry a non-empty content block so render paths that iterate
        # `msg.content` (e.g. `Tau.TUI.App.on_message_end/2`) surface the
        # error to the user. Without the text block the TUI silently drops
        # the error, presenting "TUI does nothing" to the user.
        #
        # D-018 (SPEC-USER-TURN [C46]/[C48]): for Anthropic auth atoms
        # (`:missing_api_key`, `:oauth_expired`, etc.) substitute the
        # human-readable, actionable renewal instruction so the user
        # learns to run `claude /login` instead of staring at an opaque
        # `:oauth_expired`.
        reason_str = describe_provider_error(reason)

        msg =
          Assistant.new(
            stop_reason: :error,
            error_message: reason_str,
            content: [%{type: :text, text: "Error: " <> reason_str}]
          )

        broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: msg})

        {:next_state, :awaiting_user,
         %{data | cancel_flag: nil, stream_ref: nil, provider_span_ref: nil}}
    end
  end

  # ── coding-agent streaming (SPEC-CODING-AGENT §4 B1 / D-037) ─────
  #
  # Parallel to `:start_provider`. Spins up a dispatcher under
  # `Tau.CodingAgent.Supervisor`, hands it the prepared workspace
  # path, and consumes the normalized event stream. Each event lands
  # in the FSM mailbox tagged `{:coding_agent_event, pid, struct}` and
  # is dispatched in `handle_event(:info, {:coding_agent_event, ...},
  # :coding_agent_streaming, _)`.
  def handle_event(:internal, :start_coding_agent, :coding_agent_streaming, data) do
    transition(data.id, data, :coding_agent_streaming)

    :telemetry.execute(
      [:tau, :session, :coding_agent_streaming, :start],
      %{system_time: System.system_time()},
      %{session_id: data.id, agent: data.coding_agent}
    )

    case ensure_coding_agent_workspace(data) do
      {:ok, data, workspace_path} ->
        start_coding_agent_dispatcher(data, workspace_path)

      {:error, reason} ->
        emit_coding_agent_sync_error(data, reason)
    end
  end

  # Forward dispatcher events into the FSM. Stale events (from a
  # previous run that was cancelled and superseded) are dropped by the
  # `current_run?/2` pid check — analogous to `stream_ref` for the
  # provider path (ADR-0012). This clause MUST stay before the
  # state-agnostic catch-all below.
  def handle_event(
        :info,
        {:coding_agent_event, pid, event},
        :coding_agent_streaming,
        data
      ) do
    if current_run?(data, {:coding_agent, pid}),
      do: handle_coding_agent_event(event, data),
      else: {:keep_state, data}
  end

  # Stale or out-of-order event — dispatcher mismatch. Drop silently;
  # the dispatcher's `restart: :temporary` guarantees no zombie pid
  # is resurrected.
  def handle_event(:info, {:coding_agent_event, _other_pid, _event}, _state, data) do
    {:keep_state, data}
  end

  # ADR-0012: retryable mid-stream errors fall back to the next provider
  # in `data.fallback_chain_remaining`. Inserted *before* the generic
  # :provider_event clause so a non-empty chain takes over before the
  # error reaches the assembler. Empty chain → fall through to the
  # generic clause, which records the error and finalises the message.
  #
  # CLAUSE ORDERING IS LOAD-BEARING: the generic :provider_event clause
  # below no longer head-discriminates on `stream_ref` (it uses
  # `current_run?/2` in its body), so only source order keeps this
  # fallback clause winning. If reordered, retryable mid-stream errors
  # would silently skip the ADR-0012 fallback and finalize as terminal
  # errors. This fallback clause MUST stay first.
  def handle_event(
        :info,
        {:provider_event, ref, %PEvent.Error{retryable?: true} = ev},
        :provider_streaming,
        %{fallback_chain_remaining: [next | rest], stream_ref: ref} = data
      ) do
    from_provider = data.provider

    :telemetry.execute(
      [:tau, :provider, :fallback],
      %{system_time: System.system_time()},
      %{
        from_provider: from_provider,
        to_provider: next,
        reason: ev.reason,
        session_id: data.id
      }
    )

    broadcast(data.id, %Events.ProviderFallback{
      session_id: data.id,
      from_provider: from_provider,
      to_provider: next,
      reason: ev.reason
    })

    data =
      persist_event(data, "provider_fallback", %{
        from_provider: inspect(from_provider),
        to_provider: inspect(next),
        reason: inspect(ev.reason)
      })

    # Shut down the still-running provider task (it might still be
    # emitting events or about to send :provider_done). Stragglers
    # already in the mailbox are tagged with the *previous* stream_ref
    # and get dropped by the catch-all `handle_event` clause once
    # `:start_provider` re-issues a fresh ref.
    if data.provider_task && Process.alive?(data.provider_task.pid) do
      Task.shutdown(data.provider_task, :brutal_kill)
    end

    transformed =
      Tau.Providers.Shared.ContentTransform.transform(data.messages, from_provider, next)

    handle_event(
      :internal,
      :start_provider,
      :provider_streaming,
      %{
        data
        | provider: next,
          messages: transformed,
          fallback_chain_remaining: rest,
          assembler: nil,
          provider_task: nil,
          stream_ref: nil
      }
    )
  end

  def handle_event(
        :info,
        {:provider_event, ref, ev},
        :provider_streaming,
        data
      ) do
    if current_run?(data, {:provider, ref}) do
      new_assembler = Assembler.step(data.assembler, ev)

      broadcast(data.id, %Events.MessageUpdate{
        session_id: data.id,
        event: ev,
        message: new_assembler.message
      })

      if Assembler.done?(new_assembler) do
        finalize_assistant(new_assembler, data)
      else
        {:keep_state, %{data | assembler: new_assembler}}
      end
    else
      {:keep_state, data}
    end
  end

  def handle_event(
        :info,
        {:provider_done, ref},
        :provider_streaming,
        data
      ) do
    if current_run?(data, {:provider, ref}) do
      if data.assembler && Assembler.done?(data.assembler) do
        {:keep_state, data}
      else
        # Stream ended without a Done event — synthesise one.
        assembler =
          Assembler.step(data.assembler || Assembler.new(), %PEvent.Done{stop_reason: :stop})

        finalize_assistant(assembler, data)
      end
    else
      {:keep_state, data}
    end
  end

  def handle_event(
        :info,
        {:provider_failed, ref, msg},
        :provider_streaming,
        data
      ) do
    if current_run?(data, {:provider, ref}) do
      assembler =
        Assembler.step(data.assembler || Assembler.new(), %PEvent.Error{
          reason: msg,
          retryable?: false
        })

      finalize_assistant(assembler, data)
    else
      {:keep_state, data}
    end
  end

  # ADR-0014 (#92): bookkeeping casts from the (future) `Agent` tool task.
  # On a successful `Tau.start_session/1` for a child, the spawn task casts
  # `{:register_child, child_id}` to its parent FSM. When the child's
  # `%SessionEnd{}` is observed (the spawn task is subscribed to the child
  # topic), it casts `{:unregister_child, child_id}` so the cancel cascade
  # doesn't `Tau.cancel/1` an already-stopped session. Both clauses are
  # state-agnostic — child wiring is independent of the parent's turn state.
  def handle_event(:cast, {:register_child, child_id}, _state, data)
      when is_binary(child_id) do
    :telemetry.execute(
      [:tau, :session, :child_registered],
      %{system_time: System.system_time()},
      %{session_id: data.id, child_id: child_id}
    )

    {:keep_state, %{data | child_session_ids: MapSet.put(data.child_session_ids, child_id)}}
  end

  def handle_event(:cast, {:unregister_child, child_id}, _state, data)
      when is_binary(child_id) do
    :telemetry.execute(
      [:tau, :session, :child_unregistered],
      %{system_time: System.system_time()},
      %{session_id: data.id, child_id: child_id}
    )

    {:keep_state, %{data | child_session_ids: MapSet.delete(data.child_session_ids, child_id)}}
  end

  def handle_event(:cast, :cancel, _state, data) do
    # ADR-0014 (#92): cascade to children first so each child's FSM gets
    # a chance to flush persistence and emit `%SessionEnd{reason: :user}`
    # on its own topic before this parent's tools/provider are torn down.
    # Casts are fire-and-forget; children live under
    # `Tau.Sessions.Supervisor` (`:one_for_one`) and are not linked to
    # the parent — their cleanup happens on their own scheduler slot.
    cascade_to_children(data, :cancel)

    # ADR-0017: cooperative-first cancellation of the provider stream.
    # Set the per-stream `:counters` flag and yield up to 250ms for the
    # streaming task to halt cleanly via `%Event.Error{reason: :cancelled}`.
    # Brutal-kill is the fallback path only — preserves clean upstream
    # socket release in the common case while keeping a hard escape
    # hatch for wedged providers.
    cancel_mechanism = cancel_provider_task(data)

    # #33: with async_stream_nolink the dispatcher owns the tool tasks.
    # Brutal-killing it stops the iterator; in-flight tool processes under
    # Tau.Tools.TaskSupervisor finish on their own (no link to dispatcher)
    # and any late `:tool_done` messages drop into the catch-all clause.
    if data.tool_dispatcher && Process.alive?(data.tool_dispatcher) do
      Process.exit(data.tool_dispatcher, :brutal_kill)
    end

    if data.command_task && Process.alive?(data.command_task) do
      Process.exit(data.command_task, :brutal_kill)
    end

    # C67-B4 (BLOCKING-3 fix): guard every demonitor/exit on the compaction
    # worker fields — an unguarded demonitor(nil) crashes the FSM. This handler
    # runs in _state so it fires even outside :compacting (e.g. user types
    # /cancel while the FSM is in :awaiting_user with no compaction running).
    # compaction_failures is NOT reset by :cancel — a cancelled compaction is
    # not a success; resetting would let users mask a broken compactor.
    if data.compaction_monitor,
      do: Process.demonitor(data.compaction_monitor, [:flush])

    if data.compaction_task && Process.alive?(data.compaction_task),
      do: Process.exit(data.compaction_task, :brutal_kill)

    # SPEC-CODING-AGENT D-032: subprocess lifecycle bound to session.
    # Cancel the dispatcher cooperatively; it will emit a synthetic
    # `%Done{exit_status: -2}` event that we ignore here (the cancel
    # cascade has already broadcast `%Cancelled{}` for the user).
    if data.coding_agent_dispatcher && Process.alive?(data.coding_agent_dispatcher) do
      Tau.CodingAgent.Dispatcher.cancel(data.coding_agent_dispatcher)
    end

    broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})

    persist_event(data, "cancellation", %{
      cause: "user",
      # ADR-0017: distinguishes the cooperative path (clean socket
      # release, partial content captured) from the brutal-kill
      # fallback (provider task didn't yield within 250ms).
      reason: Atom.to_string(cancel_mechanism)
    })

    {:next_state, :awaiting_user,
     %{
       data
       | provider_task: nil,
         cancel_flag: nil,
         stream_ref: nil,
         # C76 (SPEC-OTEL-REPORTER): clear discriminator; the OTel reporter
         # consumed it at the *.cancelled / *.brutal_kill emit site above.
         provider_span_ref: nil,
         tools_in_flight: %{},
         tool_dispatcher: nil,
         assembler: nil,
         command_task: nil,
         # ADR-0013 (#16): cancel ends the current turn — drop any
         # active skill alongside it.
         active_skill: nil,
         # D-027: reset per-turn tool-iteration counter on every
         # return to :awaiting_user, including cancellation.
         tool_iterations: 0,
         # SPEC-CODING-AGENT: dispatcher state is per-turn; reset on
         # cancel. Workspace is per-session — preserved.
         coding_agent_dispatcher: nil,
         coding_agent_pending: nil,
         coding_agent_blocks: [],
         # C67-B4: clear compaction worker fields. compaction_failures
         # is intentionally NOT reset (see guard comment above).
         compaction_task: nil,
         compaction_monitor: nil
     }}
  end

  def handle_event(:cast, :stop, _state, data) do
    # ADR-0014 (#92): cascade `Tau.stop/1` to children before terminating.
    # Each child runs its own `terminate/3` which broadcasts `%SessionEnd{}`
    # on the child's topic.
    cascade_to_children(data, :stop)
    {:stop, :normal, data}
  end

  # #38: in-place provider/model/provider_ctx update. The change applies
  # to the next provider call — an in-flight :provider_streaming keeps
  # using the previous provider until it completes.
  # [C54-B4]: when opts[:model] is present and non-nil, route it through
  # do_swap_model/2 (the single data.model mutation site). A nil opts[:model]
  # (provider-only reconfigure) MUST NOT touch data.model. No model_swap
  # event is emitted here — only the single "reconfigure" event below.
  def handle_event(:cast, {:reconfigure, opts}, _state, data) do
    data =
      data
      |> maybe_replace(:provider, opts[:provider])
      # ADR-0012: keep original_provider in lockstep with the user-
      # configured provider. Reconfigure replaces both — fallback chains
      # are looked up keyed by the *new* primary on the next turn.
      |> maybe_replace(:original_provider, opts[:provider])
      |> reconfigure_model(opts[:model])
      |> merge_provider_ctx(opts[:provider_ctx])
      # SPEC-CODING-AGENT (#191): reconfigure may also adjust the
      # coding-agent per-run ctx. Used by tests to thread a different
      # Replay fixture across turns; the production surface lets the
      # TUI swap inactivity-timeout / cancel-flag without restarting.
      |> maybe_replace(:coding_agent_ctx, opts[:coding_agent_ctx])

    :telemetry.execute(
      [:tau, :session, :reconfigure],
      %{system_time: System.system_time()},
      %{session_id: data.id, provider: data.provider, model: data.model}
    )

    data =
      persist_event(data, "reconfigure", %{
        provider: inspect(data.provider),
        model: data.model
      })

    {:keep_state, data}
  end

  def handle_event(:info, {:tool_done, call_id, result_msg}, :tool_executing, data) do
    tools = Map.delete(data.tools_in_flight, call_id)

    data =
      data
      |> append_message(result_msg)
      |> persist_event("tool_result", tool_result_to_data(result_msg))

    broadcast(data.id, %Events.ToolEnd{
      session_id: data.id,
      tool_call_id: call_id,
      result: result_msg
    })

    if map_size(tools) == 0 do
      handle_event(
        :internal,
        :start_provider,
        :provider_streaming,
        %{data | tools_in_flight: tools, tool_dispatcher: nil}
      )
    else
      {:keep_state, %{data | tools_in_flight: tools}}
    end
  end

  # D-041 / [C54-B4]: synchronous, state-gated model swap. Allowed only in
  # :awaiting_user with no in-flight command task. Any other state is :busy.
  # do_swap_model/2 is the single data.model mutation site ([C54-B4]).
  def handle_event({:call, from}, {:swap_model, model}, :awaiting_user, %{command_task: nil} = data) do
    case apply_model_swap(data, model) do
      {:error, :invalid_model} ->
        {:keep_state_and_data, [{:reply, from, {:error, :invalid_model}}]}

      {:ok, data2, result} ->
        {:keep_state, data2, [{:reply, from, {:ok, result}}]}
    end
  end

  # Busy: state is not :awaiting_user, or command_task is in flight.
  def handle_event({:call, from}, {:swap_model, _model}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}
  end

  # ---------------------------------------------------------------------------
  # :compacting state — five terminal clauses (D-048, D-049, C67-B4)
  #
  # Source order is LOAD-BEARING. Clauses must precede the catch-all below.
  # Ordering rationale:
  #
  #   Clause 1  — worker success {ref, result}: typed, guards on compaction_monitor
  #   Clause 2a — benign {:DOWN, :normal}: typed, guards on compaction_monitor
  #   Clause 2b — crash {:DOWN, reason}: typed, guards on compaction_monitor
  #   Clause 3  — live timeout: typed, guards on compaction_task pid
  #   Clause 4  — stale timeout: catch-all (MUST come AFTER Clause 3)
  #
  # After any terminal clause both compaction_task and compaction_monitor are
  # set to nil. Stale {ref,result} / {:DOWN} messages that arrive after the
  # fields are cleared fail the %{compaction_monitor: ref} guard and fall
  # through to the catch-all (which drops them via {:keep_state, data}).
  # This is the BLOCKING-1 fix.
  #
  # All five clauses MUST precede the catch-all (next clause below).
  # ---------------------------------------------------------------------------

  # Clause 1 — worker success: Task.Supervisor.async_nolink/3 delivers
  # {ref, result} on completion. Guard on compaction_monitor (the ref)
  # ensures stale results from a prior worker (cleared fields) are ignored.
  def handle_event(:info, {ref, result}, :compacting, %{compaction_monitor: ref} = data)
      when is_reference(ref) do
    # Demonitor first to flush any pending {:DOWN} that is already enqueued.
    # Process.demonitor with [:flush] removes the monitor and purges any
    # {:DOWN, ref, ...} already in the mailbox. Combined with clearing both
    # worker fields, stale {:DOWN} messages from this worker can no longer
    # match Clauses 2a/2b (BLOCKING-1 fix).
    Process.demonitor(ref, [:flush])

    data = %{data | compaction_task: nil, compaction_monitor: nil}

    {notice, data} =
      case result do
        {:ok, new_messages, summary_text} ->
          data =
            persist_event(data, "compaction", %{
              before_count: length(data.messages),
              after_count: length(new_messages),
              summary: format_summary_for_persist(summary_text)
            })

          :telemetry.execute(
            [:tau, :compaction, :stop],
            %{system_time: System.system_time()},
            %{session_id: data.id, after_count: length(new_messages), async: true}
          )

          data = %{data | messages: new_messages, compaction_failures: 0}
          {"Compaction complete.", data}

        {:error, reason} ->
          :telemetry.execute(
            [:tau, :compaction, :exception],
            %{system_time: System.system_time()},
            %{session_id: data.id, reason: reason, kind: :compactor_error, async: true}
          )

          failures = data.compaction_failures + 1
          data = %{data | compaction_failures: failures}
          {"Compaction failed (#{failures} consecutive failure(s)).", data}
      end

    broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})

    {:next_state, :awaiting_user, data}
  end

  # Clause 2a — benign {:DOWN, :normal}: async_nolink emits both {ref, result}
  # AND {:DOWN, ref, :process, _, :normal} on clean task exit. The mailbox
  # ordering is non-deterministic; :normal DOWN may arrive before the result.
  # Guard on compaction_monitor; do NOT demonitor here — the result (Clause 1)
  # may arrive next and will perform the demonitor+flush. Keep state.
  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, :normal},
        :compacting,
        %{compaction_monitor: ref} = data
      )
      when is_reference(ref) do
    # The pending {ref, result} message will drive Clause 1. Keep waiting.
    {:keep_state, data}
  end

  # Clause 2b — worker crash: {:DOWN, reason} where reason != :normal means
  # the task process died without delivering a result. Increment failure counter,
  # clear worker fields, return to :awaiting_user.
  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        :compacting,
        %{compaction_monitor: ref} = data
      )
      when is_reference(ref) do
    :telemetry.execute(
      [:tau, :compaction, :exception],
      %{system_time: System.system_time()},
      %{session_id: data.id, reason: reason, kind: :worker_down, async: true}
    )

    failures = data.compaction_failures + 1
    notice = "Compaction worker crashed (#{failures} consecutive failure(s))."
    data = %{data | compaction_task: nil, compaction_monitor: nil, compaction_failures: failures}
    broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})

    {:next_state, :awaiting_user, data}
  end

  # Clause 3 — live timeout: fired while the worker is still running.
  # Guard on compaction_task pid ensures this is the timeout for the CURRENT
  # worker. Only this clause calls demonitor/exit (BLOCKING-2 fix: an unguarded
  # demonitor(nil) would crash the FSM). MUST be ordered BEFORE Clause 4.
  def handle_event(
        :info,
        {:compaction_timeout, pid, _ms},
        :compacting,
        %{compaction_task: pid} = data
      )
      when is_pid(pid) do
    if data.compaction_monitor, do: Process.demonitor(data.compaction_monitor, [:flush])

    if pid && Process.alive?(pid), do: Process.exit(pid, :brutal_kill)

    :telemetry.execute(
      [:tau, :compaction, :exception],
      %{system_time: System.system_time()},
      %{session_id: data.id, kind: :timeout, async: true}
    )

    failures = data.compaction_failures + 1
    notice = "Compaction timed out (#{failures} consecutive failure(s))."
    data = %{data | compaction_task: nil, compaction_monitor: nil, compaction_failures: failures}
    broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})

    {:next_state, :awaiting_user, data}
  end

  # Clause 4 — stale timeout: arrives AFTER the worker already completed
  # (Clause 1 cleared compaction_task to nil, so pid != data.compaction_task).
  # Drop with NO demonitor — both worker fields are already nil (BLOCKING-2 fix).
  # MUST be ordered AFTER Clause 3.
  def handle_event(:info, {:compaction_timeout, _pid, _ms}, _state, data) do
    {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # End of :compacting terminal clauses
  # ---------------------------------------------------------------------------

  def handle_event(_type, _event, _state, data), do: {:keep_state, data}

  # Is the inbound event tagged with the currently-live run token?
  # Provider events carry a `stream_ref`; coding-agent events carry a
  # dispatcher pid. Stale events from superseded runs return false and
  # are dropped by the caller (ADR-0012).
  @spec current_run?(map(), {:provider, reference()} | {:coding_agent, pid()}) :: boolean()
  defp current_run?(%{stream_ref: ref}, {:provider, ref}) when is_reference(ref), do: true

  defp current_run?(%{coding_agent_dispatcher: pid}, {:coding_agent, pid}) when is_pid(pid),
    do: true

  defp current_run?(_data, _token), do: false

  # --- Helpers --------------------------------------------------------------

  # ADR-0017: drive the cooperative-then-brutal cancellation handshake
  # for the in-flight provider stream task. Returns `:cooperative` if
  # the task drained on its own within the 250ms grace period (in
  # which case the stream observed the flag, halted, and Stream.resource
  # called its cleanup hook), `:brutal_kill` if we had to shut it
  # down forcibly, or `:noop` if no provider task was active.
  # Pairs with `[:tau, :provider, :request, :start]`.
  defp cancel_provider_task(%{provider_task: nil}), do: :noop

  defp cancel_provider_task(%{provider_task: task} = data) do
    if not Process.alive?(task.pid) do
      :noop
    else
      if data.cancel_flag, do: :counters.add(data.cancel_flag, 1, 1)

      mechanism =
        case Task.yield(task, 250) do
          {:ok, _} -> :cooperative
          {:exit, _} -> :cooperative
          nil -> brutal_kill_provider_task(task)
        end

      # ADR-0017: telemetry event names are decoupled from the persisted
      # mechanism atom — `:cooperative` surfaces as
      # `[:tau, :provider, :request, :cancelled]` (the user-facing
      # outcome), while `:brutal_kill` keeps its mechanism-named event
      # so observability dashboards can flag the forced path explicitly.
      telemetry_event_name =
        case mechanism do
          :cooperative -> :cancelled
          :brutal_kill -> :brutal_kill
        end

      :telemetry.execute(
        [:tau, :provider, :request, telemetry_event_name],
        %{system_time: System.system_time()},
        %{
          provider: data.provider,
          model: data.model,
          session_id: data.id,
          # C76 (SPEC-OTEL-REPORTER): echo the per-request discriminator so
          # the OTel reporter can close the span opened at *.start.
          span_ref: data.provider_span_ref
        }
      )

      mechanism
    end
  end

  defp brutal_kill_provider_task(task) do
    Task.shutdown(task, :brutal_kill)
    :brutal_kill
  end

  # Common path that handles a user_message after any slash-command
  # expansion has resolved. Called both by the synchronous
  # handle_event(:cast, {:user_message, _}, _, _) clause (no slash
  # command, or file-command) and by the
  # handle_event(:info, {:command_done, _, _}, _, _) clause when the
  # slash-command Task delivers its result (ADR-0008).
  defp process_user_message(msg, data) do
    case Tau.Hooks.Dispatcher.run(
           :user_prompt_submit,
           hook_payload(data, :user_prompt_submit, %{message: msg})
         ) do
      {:halt, reason} ->
        broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: {:hook_halt, reason}})
        {:keep_state, data}

      {:deny, reason} ->
        broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: {:hook_deny, reason}})
        {:keep_state, data}

      {:cont, payload} ->
        msg = Map.get(payload, :message, msg)

        data =
          data
          |> append_message(msg)
          |> persist_event("user_message", message_to_data(msg))

        # SPEC-CODING-AGENT (#191) / D-037: route to the coding-agent
        # dispatcher when one is configured; preserve the legacy
        # provider path otherwise. The byte-identity guarantee for
        # the no-coding-agent case lives here.
        if data.coding_agent do
          handle_event(:internal, :start_coding_agent, :coding_agent_streaming, data)
        else
          handle_event(:internal, :start_provider, :provider_streaming, data)
        end
    end
  end

  defp finalize_assistant(assembler, data) do
    msg = Assembler.assistant(assembler)
    data = data |> append_message(msg) |> persist_event("assistant_message", message_to_data(msg))
    broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: msg})

    # #40: feed Tau.Cost.Tracker (ADR-0010). The tracker subscribes to this
    # event and folds the per-turn usage into ETS counters keyed by
    # {date, provider, model, session_id}.
    :telemetry.execute(
      [:tau, :provider, :request, :stop],
      %{system_time: System.system_time(), usage: msg.usage || %{}},
      %{
        provider: data.provider,
        model: data.model,
        session_id: data.id,
        stop_reason: msg.stop_reason,
        # C76 (SPEC-OTEL-REPORTER): echo the per-request discriminator so the
        # OTel reporter can close the span opened at *.start.
        span_ref: data.provider_span_ref
      }
    )

    # D-016: maybe_compact/2 delegates to do_compact/2 which can return
    # {:abort, data} when compaction_failures reaches 3 consecutive failures
    # (shared across sync and async paths — NOT path-tagged). On abort, surface
    # the failure as a synthetic assistant message with stop_reason:
    # :compaction_failed and return to :awaiting_user without continuing.
    # {:soft_error, data} increments the counter but lets the turn continue.
    # Plain data (or unwrapped soft_error) proceeds to tool dispatch.
    case maybe_compact(data, msg.usage || %{}) do
      {:abort, data} ->
        abort_msg =
          Assistant.new(
            stop_reason: :compaction_failed,
            content: [
              %{
                type: :text,
                text:
                  "Turn aborted: repeated or background compaction failure (3 consecutive errors). " <>
                    "Check the compactor configuration or contact support if this persists."
              }
            ]
          )

        data =
          data
          |> append_message(abort_msg)
          |> persist_event("assistant_message", message_to_data(abort_msg))

        broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: abort_msg})

        {:next_state, :awaiting_user,
         %{
           data
           | provider_task: nil,
             assembler: nil,
             cancel_flag: nil,
             stream_ref: nil,
             provider_span_ref: nil,
             tool_iterations: 0
         }}

      compact_result ->
        # Unwrap {:soft_error, data} — soft_error increments compaction_failures
        # but the turn continues normally.
        data =
          if match?({:soft_error, _}, compact_result),
            do: elem(compact_result, 1),
            else: compact_result

        # ADR-0012: per-message fallback semantics. Restore the working
        # provider to the user-configured original_provider so the next
        # turn's :start_provider re-derives the chain freshly and starts
        # against the primary. A still-running tool call keeps using the
        # provider that produced *this* message until the next provider
        # turn — that's correct: the tool result feeds the same model
        # that asked for the call.
        data = %{data | provider: data.original_provider, fallback_chain_remaining: []}

        # ADR-0013 (#16): skill activation is per-turn by default. The
        # skill's lifetime ends when the model decides the task is complete
        # (`:end_turn`). Tool-call turns keep the active skill so subsequent
        # dispatch is still gated; only `:end_turn` clears it.
        #
        # ADR-0015 sub-agent persona: when `:persona_lifetime` is `:session`
        # (set by `Tau.Tools.Builtin.Agent` at start time) the persona is
        # pinned for the session's whole life — `:end_turn` does NOT clear
        # it. The child can't dismiss its own persona this way, which is
        # the safety property the ADR demands.
        data =
          if msg.stop_reason == :end_turn and Map.get(data, :persona_lifetime, :turn) == :turn do
            %{data | active_skill: nil}
          else
            data
          end

        tool_calls = Enum.filter(msg.content, &match?(%{type: :tool_call}, &1))

        cond do
          tool_calls == [] ->
            # ADR-0017: drop the now-stale cancel flag — the stream that
            # owned it has finished. The next turn's :start_provider
            # allocates a fresh one. Same applies to ADR-0012's stream_ref.
            # D-005: reset the per-turn tool-iteration counter on clean
            # return to :awaiting_user.
            {:next_state, :awaiting_user,
             %{
               data
               | provider_task: nil,
                 assembler: nil,
                 cancel_flag: nil,
                 stream_ref: nil,
                 provider_span_ref: nil,
                 tool_iterations: 0
             }}

          true ->
            # D-005 / AC-6 (SPEC-USER-TURN [C24]): enforce the per-turn
            # tool-call iteration cap before dispatching the next round.
            # Check against the already-dispatched count so that cap=N allows
            # exactly N dispatches (tool_iterations counts rounds dispatched).
            cap = data.max_tool_iterations

            if data.tool_iterations >= cap do
              aborted_iter = data.tool_iterations

              :telemetry.execute(
                [:tau, :session, :tool_iteration_cap],
                %{iterations: aborted_iter, cap: cap},
                %{session_id: data.id}
              )

              abort_msg =
                Assistant.new(
                  stop_reason: :tool_loop_aborted,
                  content: [
                    %{
                      type: :text,
                      text:
                        "Tool-call iteration cap (#{cap}) exceeded. Turn aborted to prevent runaway loops."
                    }
                  ]
                )

              data =
                data
                |> append_message(abort_msg)
                |> persist_event("assistant_message", message_to_data(abort_msg))

              broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: abort_msg})

              {:next_state, :awaiting_user,
               %{
                 data
                 | provider_task: nil,
                   assembler: nil,
                   cancel_flag: nil,
                   stream_ref: nil,
                   provider_span_ref: nil,
                   tool_iterations: 0
               }}
            else
              dispatch_tools(tool_calls, %{data | tool_iterations: data.tool_iterations + 1})
            end
        end
    end
  end

  # Thin sync adapter: decides whether to compact, then delegates to do_compact/2.
  # Returns data | {:abort, data} (D-016: on 3 consecutive failures, aborts the turn).
  defp maybe_compact(data, usage) do
    compactor = Tau.Compactor.impl()

    if compactor.should_compact?(data.messages, usage) do
      do_compact(data, %{provider: data.provider, model: data.model})
    else
      data
    end
  end

  # Shared compaction core — invoked by the sync post-turn path (maybe_compact/2)
  # and by the async `:compacting` worker handler (Clause 1 in handle_event).
  #
  # Returns:
  #   data2            — {:ok, ...} success; messages swapped, telemetry emitted,
  #                      compaction_failures reset to 0
  #   {:soft_error, data2} — {:error, ...} but failures < 3; caller broadcasts
  #                      a notice and continues
  #   {:abort, data2}  — {:error, ...} and failures >= 3 (D-016); caller aborts
  #                      the turn with stop_reason: :compaction_failed
  #
  # D-016: compaction_failures is SHARED across sync and async paths (NOT path-tagged).
  # A broken compactor is a session-level fault; alternating paths must not
  # mask it by keeping separate counters.
  defp do_compact(data, ctx) do
    compactor = Tau.Compactor.impl()

    :telemetry.execute([:tau, :compaction, :start], %{system_time: System.system_time()}, %{
      session_id: data.id,
      message_count: length(data.messages)
    })

    case compactor.compact(data.messages, ctx) do
      {:ok, new_messages, summary_text} ->
        data =
          persist_event(data, "compaction", %{
            before_count: length(data.messages),
            after_count: length(new_messages),
            summary: format_summary_for_persist(summary_text)
          })

        :telemetry.execute([:tau, :compaction, :stop], %{system_time: System.system_time()}, %{
          session_id: data.id,
          after_count: length(new_messages)
        })

        %{data | messages: new_messages, compaction_failures: 0}

      {:error, reason} ->
        :telemetry.execute(
          [:tau, :compaction, :exception],
          %{system_time: System.system_time()},
          %{session_id: data.id, reason: reason, kind: :compactor_error}
        )

        failures = data.compaction_failures + 1

        if failures >= 3 do
          {:abort, %{data | compaction_failures: failures}}
        else
          {:soft_error, %{data | compaction_failures: failures}}
        end
    end
  end

  defp dispatch_tools(tool_calls, data) do
    transition(data.id, data, :tool_executing)
    parent = self()

    # #17: intercept synthetic `__activate_skill__` tool calls *before*
    # permissions / hooks. Activation is FSM-internal — it never reaches
    # the executor pool. The handler updates `data.active_skill` and
    # synthesises a tool_result so the model's next turn sees an
    # acknowledgement; subsequent tool calls in the same activation are
    # then gated by the skill's `allowed_tools` list (ADR-0013).
    {activation_calls, tool_calls} =
      Enum.split_with(tool_calls, fn %{name: name} -> name == @activate_skill_tool_name end)

    {data, activated_in_flight} = handle_skill_activations(activation_calls, data, parent)

    # #91: spawn-time tools_whitelist filter. Runs *before* the permissions
    # evaluator so the evaluator stays a pure permission-rule decision.
    # Calls outside the list synthesise an `is_error: true` ToolResult the
    # same way deny rules do; the filter is a no-op when `:all`.
    {whitelisted_out, tool_calls} = split_tools_whitelist(tool_calls, data.tools_whitelist)

    Enum.each(whitelisted_out, fn %{id: id, name: name} ->
      result =
        ToolResult.new(
          tool_call_id: id,
          tool_name: name,
          content: "Tool '#{name}' not in this session's whitelist.",
          is_error: true
        )

      Process.send(parent, {:tool_done, id, result}, [])

      :telemetry.execute(
        [:tau, :session, :tool_whitelisted],
        %{system_time: System.system_time()},
        %{
          session_id: data.id,
          tool_name: name,
          whitelist_size: whitelist_size(data.tools_whitelist)
        }
      )
    end)

    rule_set = Tau.Permissions.RuleSet.get()
    mode = Map.get(data.metadata, :permissions_mode, :default)

    eval_ctx = %{cwd: data.cwd, active_skill: data.active_skill}

    {gated, allowed} =
      Enum.split_with(tool_calls, fn %{name: name, arguments: args} ->
        Tau.Permissions.Evaluator.evaluate(rule_set, name, args, eval_ctx, mode) == :deny
      end)

    # Synthesise tool_results for denied calls — model sees them as is_error.
    Enum.each(gated, fn %{id: id, name: name} ->
      result =
        ToolResult.new(
          tool_call_id: id,
          tool_name: name,
          content: deny_reason(name, data.active_skill),
          is_error: true
        )

      Process.send(parent, {:tool_done, id, result}, [])

      :telemetry.execute([:tau, :permissions, :decision], %{system_time: System.system_time()}, %{
        tool: name,
        decision: :deny,
        session_id: data.id
      })
    end)

    # Run :pre_tool_use synchronously per call. Hook-vetoed calls synthesise
    # a tool_result on the spot; survivors form the parallel batch handed to
    # the dispatcher (#33).
    {_hook_denied, parallel_calls} =
      Enum.reduce(allowed, {[], []}, fn %{id: id, name: name, arguments: args}, {denied, kept} ->
        case Tau.Hooks.Dispatcher.run(
               :pre_tool_use,
               hook_payload(data, :pre_tool_use, %{
                 tool_name: name,
                 tool_call_id: id,
                 tool_input: args
               })
             ) do
          {:halt, reason} ->
            result =
              ToolResult.new(
                tool_call_id: id,
                tool_name: name,
                content: "Hook blocked: #{inspect(reason)}",
                is_error: true
              )

            Process.send(parent, {:tool_done, id, result}, [])
            {[id | denied], kept}

          {:deny, reason} ->
            result =
              ToolResult.new(
                tool_call_id: id,
                tool_name: name,
                content: "Hook denied: #{reason}",
                is_error: true
              )

            Process.send(parent, {:tool_done, id, result}, [])
            {[id | denied], kept}

          {:cont, payload} ->
            rewritten_args = Map.get(payload, :tool_input, args)
            {denied, [{id, name, rewritten_args} | kept]}
        end
      end)

    parallel_calls = Enum.reverse(parallel_calls)

    dispatcher_pid =
      case parallel_calls do
        [] -> nil
        _ -> spawn_parallel_dispatcher(parallel_calls, data, parent)
      end

    real_tasks = Enum.into(parallel_calls, %{}, fn {id, _n, _a} -> {id, :running} end)

    initial_in_flight =
      real_tasks
      |> Map.merge(Enum.into(gated, %{}, fn %{id: id} -> {id, :denied} end))
      |> Map.merge(Enum.into(whitelisted_out, %{}, fn %{id: id} -> {id, :whitelist_filtered} end))
      |> Map.merge(activated_in_flight)

    {:next_state, :tool_executing,
     %{
       data
       | tools_in_flight: initial_in_flight,
         tool_dispatcher: dispatcher_pid,
         provider_task: nil,
         assembler: nil,
         stream_ref: nil,
         # C76 (SPEC-OTEL-REPORTER): the provider.request span was closed in
         # finalize_assistant/2 before dispatch_tools/2 is called. Clear the
         # ref so it doesn't linger stale across the tool-execution phase.
         provider_span_ref: nil
     }}
  end

  # #33: single iterator over the parallel batch via
  # Task.Supervisor.async_stream_nolink/4. One process per turn drives the
  # stream; per-tool tasks run concurrently under Tau.Tools.TaskSupervisor.
  # Crash isolation: an exiting tool task surfaces as `{:exit, reason}` from
  # the stream — we synthesise an `is_error: true` ToolResult so the FSM
  # never loses a tool_call → tool_result correspondence. `ordered: true`
  # so we can zip the input call back onto each result (needed to recover
  # the call id on `{:exit, _}`); throughput is unchanged because tool
  # tasks still run concurrently up to `max_concurrency`.
  defp spawn_parallel_dispatcher(parallel_calls, data, parent) do
    {:ok, pid} =
      Task.Supervisor.start_child(Tau.Tools.TaskSupervisor, fn ->
        Enum.each(parallel_calls, fn {id, name, args} ->
          broadcast(data.id, %Events.ToolStart{
            session_id: data.id,
            tool_call_id: id,
            name: name,
            arguments: args
          })
        end)

        Tau.Tools.TaskSupervisor
        |> Task.Supervisor.async_stream_nolink(
          parallel_calls,
          fn {id, name, args} -> run_tool(name, id, args, data) end,
          max_concurrency: System.schedulers_online(),
          timeout: :infinity,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Stream.zip(parallel_calls)
        |> Enum.each(fn {stream_result, {id, name, _args}} ->
          result =
            case stream_result do
              {:ok, %ToolResult{} = r} ->
                r

              {:exit, reason} ->
                ToolResult.new(
                  tool_call_id: id,
                  tool_name: name,
                  content: "Tool task crashed: #{inspect(reason)}",
                  is_error: true
                )
            end

          # :post_tool_use hook may rewrite the result.
          post_event = if result.is_error, do: :post_tool_use_failure, else: :post_tool_use

          result =
            case Tau.Hooks.Dispatcher.run(
                   post_event,
                   hook_payload(data, post_event, %{
                     tool_name: name,
                     tool_call_id: id,
                     result: result
                   })
                 ) do
              {:cont, %{result: rewritten}} when is_struct(rewritten, ToolResult) -> rewritten
              _ -> result
            end

          Process.send(parent, {:tool_done, id, result}, [])
        end)
      end)

    pid
  end

  # #91: split tool calls into {filtered_out, kept} based on the session's
  # spawn-time `:tools_whitelist`. `:all` is the no-op identity (everything
  # in `kept`); a list keeps only calls whose `name` is in the list. Stays
  # ordering-preserving so downstream `Enum.into/2` and synthesis preserve
  # the model's emit order.
  defp split_tools_whitelist(tool_calls, :all), do: {[], tool_calls}

  defp split_tools_whitelist(tool_calls, list) when is_list(list) do
    Enum.split_with(tool_calls, fn %{name: name} -> name not in list end)
  end

  defp whitelist_size(:all), do: :all
  defp whitelist_size(list) when is_list(list), do: length(list)

  # ADR-0013 / #16: format the synthetic ToolResult content for a
  # permissions :deny. When an active skill is in effect AND the tool is
  # not on its allowed_tools list, the denial is attributed to the skill;
  # otherwise the failure originated from a rule-set deny rule.
  defp deny_reason(name, %Tau.Skill{name: skill_name, allowed_tools: list})
       when is_list(list) and list != [] do
    if name in list do
      "Permission denied: #{name} blocked by deny rule"
    else
      "Tool '#{name}' not on active skill '#{skill_name}' allowed_tools whitelist"
    end
  end

  defp deny_reason(name, _active_skill),
    do: "Permission denied: #{name} blocked by deny rule"

  defp run_tool(name, call_id, args, data) do
    started = System.monotonic_time(:millisecond)

    case Tau.Tool.lookup(name) do
      {:ok, mod} ->
        case Tau.Tool.Validator.validate(mod, args) do
          :ok ->
            run_tool_validated(name, call_id, args, data, mod, started)

          {:error, errors} ->
            summary = Tau.Tool.Validator.format_errors(errors)

            :telemetry.execute(
              [:tau, :tool, :validate, :error],
              %{system_time: System.system_time()},
              %{tool: name, tool_call_id: call_id, errors: summary}
            )

            ToolResult.new(
              tool_call_id: call_id,
              tool_name: name,
              content: "Invalid arguments for tool #{name}: #{summary}",
              is_error: true
            )
        end

      :error ->
        ToolResult.new(
          tool_call_id: call_id,
          tool_name: name,
          content: "Unknown tool: #{name}",
          is_error: true
        )
    end
  end

  defp run_tool_validated(name, call_id, args, data, mod, started) do
    ctx =
      Tau.Tool.Context.new(
        tool_call_id: call_id,
        session_id: data.id,
        cwd: data.cwd,
        emit: fn payload ->
          broadcast(data.id, %Events.ToolUpdate{
            session_id: data.id,
            tool_call_id: call_id,
            payload: payload
          })

          :ok
        end
      )

    :telemetry.execute(
      [:tau, :tool, :execute, :start],
      %{system_time: System.system_time()},
      %{tool: name, tool_call_id: call_id}
    )

    result =
      try do
        case mod.execute(args || %{}, ctx) do
          {:ok, %Tau.Tool.Result{} = r} ->
            ToolResult.new(
              tool_call_id: call_id,
              tool_name: name,
              content: r.content,
              details: r.details,
              is_error: r.is_error
            )

          {:error, reason} ->
            ToolResult.new(
              tool_call_id: call_id,
              tool_name: name,
              content: "Tool error: #{inspect(reason)}",
              is_error: true
            )
        end
      rescue
        e ->
          :telemetry.execute(
            [:tau, :tool, :execute, :exception],
            %{duration: System.monotonic_time(:millisecond) - started},
            # D-052 / C78 (SPEC-OTEL-REPORTER): tool_call_id MUST be present so
            # the OTel reporter can correlate this exception span to its *.start span.
            %{tool: name, tool_call_id: call_id, error: Exception.message(e)}
          )

          ToolResult.new(
            tool_call_id: call_id,
            tool_name: name,
            content: "Tool exception: #{Exception.message(e)}",
            is_error: true
          )
      end

    :telemetry.execute(
      [:tau, :tool, :execute, :stop],
      %{duration: System.monotonic_time(:millisecond) - started},
      %{tool: name, tool_call_id: call_id, is_error: result.is_error}
    )

    result
  end

  defp append_message(data, msg), do: %{data | messages: data.messages ++ [msg]}

  # [C54-B4]: single data.model mutation site. Pure function — no side effects.
  # Returns {:ok, updated_data, from_model} | {:error, :invalid_model}.
  # "invalid" means nil, empty string, or whitespace-only.
  defp do_swap_model(data, model) do
    if is_binary(model) and String.trim(model) != "" do
      {:ok, %{data | model: model}, data.model}
    else
      {:error, :invalid_model}
    end
  end

  # D-041: shared helper for swap_model telemetry + persist, used by both the
  # {:call, from} {:swap_model} FSM clause and the /model slash-command path.
  defp apply_model_swap(data, model) do
    case do_swap_model(data, model) do
      {:error, :invalid_model} ->
        {:error, :invalid_model}

      {:ok, data2, from_model} ->
        :telemetry.execute(
          [:tau, :session, :model_swapped],
          %{system_time: System.system_time()},
          %{session_id: data2.id, from: from_model, to: model, provider: data2.provider}
        )

        data2 = persist_event(data2, "model_swap", %{"from" => from_model, "to" => model})
        {:ok, data2, %{from: from_model, to: model}}
    end
  end

  # [C54-B4]: route reconfigure's model opt through do_swap_model/2 so
  # data.model has a single mutation site. nil means "no change" — a
  # provider-only reconfigure must NOT touch data.model (preserves the
  # update_provider_test.exs assertion that a model-only reconfigure
  # persists one "reconfigure" event carrying data.model).
  defp reconfigure_model(data, nil), do: data

  defp reconfigure_model(data, model) do
    case do_swap_model(data, model) do
      {:ok, data2, _from} -> data2
      {:error, :invalid_model} -> data
    end
  end

  # #38 helpers — in-place data updates for {:reconfigure, opts}.
  defp maybe_replace(data, _key, nil), do: data
  defp maybe_replace(data, key, value), do: Map.put(data, key, value)

  defp merge_provider_ctx(data, nil), do: data

  defp merge_provider_ctx(data, ctx) when is_map(ctx) do
    %{data | provider_ctx: Map.merge(data.provider_ctx || %{}, ctx)}
  end

  defp persist_event(data, kind, payload) do
    event = %{
      "id" => generate_event_id(),
      "parent_id" => parent_event_id(data),
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => kind,
      "data" => payload
    }

    case data.persistence.append(data.persist_handle, event) do
      {:ok, h} -> %{data | persist_handle: h}
      {:error, _} -> data
    end
  end

  defp generate_event_id do
    case Code.ensure_loaded?(Uniq.UUID) do
      true -> apply(Uniq.UUID, :uuid7, [])
      _ -> "evt_" <> (:crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false))
    end
  end

  defp parent_event_id(_data), do: nil

  # ADR-0012: read the per-original-provider fallback list from settings.
  # Returns [] when no chain is configured or when settings carry a typo
  # (fail-closed via Tau.Settings.Schema.resolve_fallback_chains/1).
  # Both atom and string keys are accepted (Settings.Loader uses
  # `keys: :atoms`; Jason leaves *values* as strings, so the resolver
  # is the canonical str → module step).
  # SPEC-CODING-AGENT §5 / D-037: deployment-wide default for the
  # coding-agent surface. Read from the merged settings cascade at
  # session init only — the CLI flag overrides; in-flight sessions
  # are not affected by mid-session settings reloads (D-007).
  defp coding_agent_from_settings do
    settings = SettingsCache.get()

    raw =
      get_in(settings, [:coding_agent, :default_agent]) ||
        get_in(settings, ["coding_agent", "default_agent"])

    case raw do
      nil -> nil
      mod when is_atom(mod) -> mod
      str when is_binary(str) -> Tau.CLI.resolve_coding_agent(str)
    end
  end

  defp lookup_fallback_chain(original_provider) when is_atom(original_provider) do
    settings = Tau.Settings.Cache.get()

    case Tau.Settings.Schema.resolve_fallback_chains(settings) do
      {:ok, chains} -> Map.get(chains, original_provider, [])
      {:error, _} -> []
    end
  end

  defp transition(id, _data, to) do
    :telemetry.execute([:tau, :session, :transition], %{system_time: System.system_time()}, %{
      session_id: id,
      to: to
    })

    :ok
  end

  defp broadcast(id, event) do
    Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{id}", event)
  end

  # D-018: translate known provider auth atoms into user-actionable
  # strings. Other reasons fall through to inspect/1 (the original
  # D-009 behavior).
  defp describe_provider_error(:missing_api_key) do
    Tau.Providers.Anthropic.Auth.describe_error({:error, :no_auth})
  end

  defp describe_provider_error(:oauth_expired) do
    Tau.Providers.Anthropic.Auth.describe_error({:error, :oauth_expired})
  end

  defp describe_provider_error(:oauth_missing_scope) do
    Tau.Providers.Anthropic.Auth.describe_error({:error, :oauth_missing_scope})
  end

  defp describe_provider_error(:oauth_malformed) do
    Tau.Providers.Anthropic.Auth.describe_error({:error, :oauth_malformed})
  end

  # AC-7 (SPEC-CIRCUIT-BREAKER §4 B3): breaker is open — surface a
  # user-actionable message. The user can wait for the cooldown or switch
  # providers; the exact cooldown duration is not surfaced here because it
  # is an ETS-internal value. Generic wording avoids surfacing internals.
  defp describe_provider_error(:circuit_open) do
    "Provider is temporarily unavailable (circuit breaker open). " <>
      "The provider has returned too many consecutive errors. " <>
      "Please wait a moment and try again, or switch providers."
  end

  defp describe_provider_error(other), do: inspect(other)

  # ADR-0014 (#92): walk the child set and cast the chosen lifecycle
  # operation. Both `Tau.cancel/1` and `Tau.stop/1` are :ok-or-:ok casts
  # against a registry lookup — a child id that's already gone is a
  # silent no-op (this is exactly the case we want when a child finished
  # naturally between its `%SessionEnd{}` broadcast and the parent's
  # cancel landing). Recursion is implicit: each child runs the same
  # cascade against its own descendants.
  defp cascade_to_children(%{child_session_ids: ids}, op) when op in [:cancel, :stop] do
    Enum.each(ids, fn child_id ->
      case op do
        :cancel -> Tau.cancel(child_id)
        :stop -> Tau.stop(child_id)
      end
    end)
  end

  # ADR-0009: telemetry pairs but does not span — postponed events
  # may emit :enqueued multiple times if the FSM transitions through
  # several non-idle states before reaching :awaiting_user. Each
  # :enqueued reflects a real postpone-and-rewind decision.
  defp emit_user_message_telemetry(event, data, state) do
    :telemetry.execute(
      [:tau, :session, :user_message, event],
      %{system_time: System.system_time()},
      %{session_id: data.id, from_state: state}
    )
  end

  # --- Coding-agent streaming (SPEC-CODING-AGENT §4 B1 / D-037) ------------
  #
  # Helpers for the `:coding_agent_streaming` FSM state. The split mirrors
  # the provider path's helpers (Assembler + finalize_assistant +
  # cancel_provider_task) but operates on `Tau.CodingAgent.Event` instead
  # of `Tau.Provider.Event`. Folding into a unified message type happens
  # here so the TUI render, persistence, and `/resume` reuse the provider
  # path unchanged.

  # Ensure a per-session workspace exists. Re-uses an already-prepared
  # workspace for subsequent turns within the same session (the worktree
  # / cwd survives across user turns; only torn down at session end).
  # Returns `{:ok, data, path}` on success, `{:error, reason}` on failure.
  defp ensure_coding_agent_workspace(%{coding_agent_workspace: %CAWorkspace{} = ws} = data) do
    {:ok, data, ws.path}
  end

  defp ensure_coding_agent_workspace(%{coding_agent_workspace: nil} = data) do
    backend = data.coding_agent_workspace_backend || CAWorkspace.resolve_default_backend(data.cwd)

    opts =
      Keyword.merge(
        [
          backend: backend,
          session_id: data.id,
          cwd: data.cwd
        ],
        data.coding_agent_workspace_opts || []
      )

    case CAWorkspace.prepare(opts) do
      {:ok, ws} -> {:ok, %{data | coding_agent_workspace: ws}, ws.path}
      {:error, reason} -> {:error, {:workspace_prepare_failed, reason}}
    end
  end

  # Synchronous pre-dispatch error (workspace prepare failed, supervisor
  # refused to start a dispatcher, …). Surfaces as an `%Assistant{}` with
  # `stop_reason: :error` and a non-empty content block — mirrors D-009
  # for the provider path so the existing TUI render path Just Works.
  defp emit_coding_agent_sync_error(data, reason) do
    reason_str = describe_coding_agent_error(reason)

    msg =
      Assistant.new(
        stop_reason: :error,
        error_message: reason_str,
        content: [%{type: :text, text: "Error: " <> reason_str}]
      )

    data =
      data
      |> append_message(msg)
      |> persist_event("assistant_message", message_to_data(msg))

    broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: msg})

    :telemetry.execute(
      [:tau, :session, :coding_agent_streaming, :exception],
      %{system_time: System.system_time()},
      %{session_id: data.id, agent: data.coding_agent, reason: reason}
    )

    {:next_state, :awaiting_user,
     %{data | coding_agent_dispatcher: nil, coding_agent_pending: nil, coding_agent_blocks: []}}
  end

  # Start a fresh dispatcher under `Tau.CodingAgent.Supervisor` and
  # broadcast `MessageStart` so the TUI's `:streaming` indicator lights
  # up immediately (no waiting for the first AssistantText event).
  defp start_coding_agent_dispatcher(data, workspace_path) do
    user_text = latest_user_text(data.messages)

    # SPEC-CODING-AGENT §7 Q5: thread the captured adapter-side
    # session_id (from a previous %Event.Start{}) as
    # `task.resume_id`. Claude Code picks up where the prior tau
    # turn left off; other adapters that don't honour `resume_id`
    # ignore the field. Emits a telemetry event so the audit test
    # can assert the resume path was taken.
    resume_id = get_in(data, [:coding_agent_state, :session_id])

    task = %{
      prompt: user_text,
      workspace: workspace_path,
      session_id: data.id,
      resume_id: resume_id,
      allowed_tools: :all,
      mcp_servers: [],
      timeout: :infinity
    }

    if is_binary(resume_id) do
      :telemetry.execute(
        [:tau, :coding_agent, :resume],
        %{system_time: System.system_time()},
        %{
          session_id: data.id,
          agent: data.coding_agent,
          adapter_session_id: resume_id
        }
      )
    end

    ctx =
      Map.merge(
        %{
          session_id: data.id,
          request_id: generate_event_id()
        },
        data.coding_agent_ctx || %{}
      )

    args = [
      adapter: data.coding_agent,
      task: task,
      ctx: ctx,
      subscriber: self()
    ]

    case Tau.CodingAgent.Supervisor.start_dispatcher(args) do
      {:ok, pid} ->
        pending =
          Assistant.new(
            provider: data.coding_agent,
            model: nil,
            api: :coding_agent,
            content: []
          )

        broadcast(data.id, %Events.MessageStart{session_id: data.id, message: pending})

        {:next_state, :coding_agent_streaming,
         %{
           data
           | coding_agent_dispatcher: pid,
             coding_agent_pending: pending,
             coding_agent_blocks: []
         }}

      {:error, reason} ->
        emit_coding_agent_sync_error(data, {:dispatcher_start_failed, reason})
    end
  end

  defp latest_user_text(messages) do
    # Walk from the end to find the most recent user-supplied text.
    # The skill/memory injection prepends synthetic User messages with
    # `metadata.role in [:system, :compaction_summary]`; skip those.
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %User{metadata: %{role: r}} when r in [:system, :compaction_summary] ->
        nil

      %User{content: c} when is_binary(c) ->
        c

      %User{content: blocks} when is_list(blocks) ->
        Enum.map_join(blocks, "\n", fn
          %{type: :text, text: t} -> t
          %{"type" => "text", "text" => t} -> t
          _ -> ""
        end)

      _ ->
        nil
    end)
  end

  # ── Event-by-event handlers (D-031: pattern match on struct module).
  #
  # AssistantText accumulates into a single text block per turn (or
  # restarts when a `turn` jump is observed). ToolUse and ToolResult
  # emit their own messages so the assembled assistant message reflects
  # the agent's actual content shape, matching the provider path. Cost
  # and FileEdit emit telemetry; Cost is also NOT yet aggregated into
  # session cost totals (Team D's scope). Error / Done finalize.

  defp handle_coding_agent_event(%CAEvent.Start{} = ev, data) do
    :telemetry.execute(
      [:tau, :session, :coding_agent_streaming, :adapter_start],
      %{system_time: System.system_time()},
      %{session_id: data.id, agent: data.coding_agent, version: ev.version}
    )

    # SPEC-CODING-AGENT §7 Q5: capture the adapter-side session_id.
    # Persist a `coding_agent_session` JSONL event so a later
    # `Tau.resume/1` can recover it and pass it as `task.resume_id`
    # on the next dispatcher launch. Implementation deliberately
    # lives below the other handle_coding_agent_event/2 clauses to
    # keep them grouped (compiler warning otherwise).
    data = maybe_capture_coding_agent_session(data, ev)

    {:keep_state, data}
  end

  defp handle_coding_agent_event(%CAEvent.AssistantText{text: t}, data) do
    blocks = append_assistant_text(data.coding_agent_blocks, t)
    pending = %{data.coding_agent_pending | content: blocks}

    broadcast(data.id, %Events.MessageUpdate{
      session_id: data.id,
      event: %CAEvent.AssistantText{text: t},
      message: pending
    })

    {:keep_state, %{data | coding_agent_blocks: blocks, coding_agent_pending: pending}}
  end

  defp handle_coding_agent_event(%CAEvent.ToolUse{id: id, name: name, input: input}, data) do
    # Anthropic-compatible content-block shape — same as the provider
    # path's `%{type: :tool_call, ...}` blocks the Assembler emits.
    block = %{type: :tool_call, id: id, name: name, arguments: input || %{}}
    blocks = data.coding_agent_blocks ++ [block]
    pending = %{data.coding_agent_pending | content: blocks}

    broadcast(data.id, %Events.MessageUpdate{
      session_id: data.id,
      event: %CAEvent.ToolUse{id: id, name: name, input: input},
      message: pending
    })

    # ToolStart broadcast mirrors the provider path so existing TUI /
    # audit subscribers see the same tool-call surface regardless of
    # which event source produced it (D-031).
    broadcast(data.id, %Events.ToolStart{
      session_id: data.id,
      tool_call_id: id,
      name: name,
      arguments: input || %{}
    })

    {:keep_state, %{data | coding_agent_blocks: blocks, coding_agent_pending: pending}}
  end

  defp handle_coding_agent_event(
         %CAEvent.ToolResult{tool_use_id: tool_id, content: content, is_error: is_err},
         data
       ) do
    # ToolResult is a separate message in Anthropic's wire format. We
    # finalise the current assistant message (so the user can see what
    # the agent said BEFORE the tool result), append a ToolResult
    # message, broadcast ToolEnd, then start a new pending assistant
    # message for any subsequent AssistantText.
    {data, _} = flush_pending_assistant(data, :tool_use)

    tool_result =
      ToolResult.new(
        tool_call_id: tool_id,
        # ToolUse may not have been observed (some adapters emit
        # ToolResult standalone); we don't have the tool name here, so
        # fall back to "tool" — matches Anthropic's permissive shape.
        tool_name: tool_name_for(data, tool_id),
        content: content,
        is_error: is_err
      )

    data =
      data
      |> append_message(tool_result)
      |> persist_event("tool_result", tool_result_to_data(tool_result))

    broadcast(data.id, %Events.ToolEnd{
      session_id: data.id,
      tool_call_id: tool_id,
      result: tool_result
    })

    # Start a fresh assistant message for any further AssistantText
    # the agent emits before `Done`.
    pending =
      Assistant.new(
        provider: data.coding_agent,
        model: nil,
        api: :coding_agent,
        content: []
      )

    broadcast(data.id, %Events.MessageStart{session_id: data.id, message: pending})

    {:keep_state, %{data | coding_agent_pending: pending, coding_agent_blocks: []}}
  end

  defp handle_coding_agent_event(%CAEvent.FileEdit{path: path, kind: kind}, data) do
    :telemetry.execute(
      [:tau, :session, :coding_agent_streaming, :file_edit],
      %{system_time: System.system_time()},
      %{session_id: data.id, agent: data.coding_agent, path: path, kind: kind}
    )

    {:keep_state, data}
  end

  defp handle_coding_agent_event(%CAEvent.Cost{} = cost, data) do
    # Team D will fold this into session cost totals; for now we just
    # surface telemetry so observers (tau doctor, future TUI panel)
    # can see it. The hook below is the deliberate extension point.
    :telemetry.execute(
      [:tau, :session, :coding_agent_streaming, :cost],
      %{
        system_time: System.system_time(),
        duration_ms: cost.duration_ms,
        usd: cost.usd || 0.0
      },
      %{session_id: data.id, agent: data.coding_agent, tokens: cost.tokens}
    )

    {:keep_state, maybe_apply_cost_hook(data, cost)}
  end

  defp handle_coding_agent_event(%CAEvent.Error{reason: reason, recoverable: rec?}, data) do
    reason_str = describe_coding_agent_error(reason)

    if rec? do
      # Recoverable: stash an error-content block so the user sees
      # *something* and let the dispatcher continue.
      blocks =
        data.coding_agent_blocks ++ [%{type: :text, text: "[adapter error] " <> reason_str}]

      pending = %{data.coding_agent_pending | content: blocks, error_message: reason_str}

      broadcast(data.id, %Events.MessageUpdate{
        session_id: data.id,
        event: %CAEvent.Error{reason: reason, recoverable: rec?},
        message: pending
      })

      {:keep_state, %{data | coding_agent_blocks: blocks, coding_agent_pending: pending}}
    else
      # Non-recoverable: the dispatcher will follow with a synthetic
      # Done. Mark the pending message and let the Done finaliser
      # render. We don't transition here — Done does the FSM move.
      pending = %{
        data.coding_agent_pending
        | error_message: reason_str,
          stop_reason: :error
      }

      {:keep_state, %{data | coding_agent_pending: pending}}
    end
  end

  defp handle_coding_agent_event(%CAEvent.Done{} = done, data) do
    finalize_coding_agent_turn(done, data)
  end

  defp handle_coding_agent_event(_other, data), do: {:keep_state, data}

  # Build / extend the in-progress text block. AssistantText events
  # within one turn concatenate into a single text content block — this
  # mirrors how Anthropic's stream-json folds text deltas.
  defp append_assistant_text(blocks, t) when is_binary(t) do
    case List.last(blocks) do
      %{type: :text, text: existing} ->
        Enum.drop(blocks, -1) ++ [%{type: :text, text: existing <> t}]

      _ ->
        blocks ++ [%{type: :text, text: t}]
    end
  end

  # Push the current pending assistant message into `data.messages`,
  # persist, broadcast `MessageEnd`. Leaves the FSM state untouched
  # (caller decides). Returns `{data, msg}`.
  defp flush_pending_assistant(%{coding_agent_pending: nil} = data, _stop_reason),
    do: {data, nil}

  defp flush_pending_assistant(data, stop_reason) do
    effective_stop = data.coding_agent_pending.stop_reason || stop_reason

    msg =
      Assembler.finalize(data.coding_agent_pending, data.coding_agent_blocks,
        stop_reason: effective_stop
      )

    data =
      data
      |> append_message(msg)
      |> persist_event("assistant_message", message_to_data(msg))

    broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: msg})

    {data, msg}
  end

  defp finalize_coding_agent_turn(%CAEvent.Done{exit_status: status} = done, data) do
    stop_reason =
      cond do
        data.coding_agent_pending && data.coding_agent_pending.stop_reason == :error -> :error
        # Synthetic cancel sentinel (D-032).
        status == -2 -> :aborted
        # Synthetic dispatcher / adapter death.
        status == -1 -> :error
        status == 0 -> :end_turn
        true -> :error
      end

    # Inject the final_message as a trailing text block if the agent
    # supplied one and we don't already have content covering it.
    blocks =
      case done.final_message do
        nil -> data.coding_agent_blocks
        "" -> data.coding_agent_blocks
        text -> append_assistant_text(data.coding_agent_blocks, "\n" <> text)
      end

    data = %{data | coding_agent_blocks: blocks}

    {data, _msg} = flush_pending_assistant(data, stop_reason)

    :telemetry.execute(
      [:tau, :session, :coding_agent_streaming, :stop],
      %{system_time: System.system_time()},
      %{
        session_id: data.id,
        agent: data.coding_agent,
        exit_status: status,
        stop_reason: stop_reason
      }
    )

    {:next_state, :awaiting_user,
     %{
       data
       | coding_agent_dispatcher: nil,
         coding_agent_pending: nil,
         coding_agent_blocks: []
     }}
  end

  # Recover a tool name from the in-progress message's ToolUse blocks
  # for a given `tool_use_id`. Falls back to "tool" if the ToolUse
  # event wasn't observed (some adapters elide it for cheap tools).
  defp tool_name_for(data, tool_use_id) do
    blocks = (data.coding_agent_pending && data.coding_agent_pending.content) || []

    Enum.find_value(blocks, "tool", fn
      %{type: :tool_call, id: ^tool_use_id, name: n} -> n
      _ -> nil
    end)
  end

  # SPEC-CODING-AGENT §7 Q4 / D-038: fold `%Event.Cost{}` into
  # session totals as an adapter-tagged line item. Three side
  # effects, all wrapped so a failure in one MUST NOT crash the
  # session (D-035):
  #
  # 1. Build a `%Tau.CodingAgent.Cost{}` and append to
  #    `data.coding_agent_costs` so the in-process aggregator
  #    has the line item.
  # 2. Persist a `coding_agent_cost` JSONL event so `/resume` can
  #    recompute totals from disk.
  # 3. Emit `[:tau, :coding_agent, :cost]` telemetry so
  #    `Tau.Cost.Tracker` folds the tokens into its ETS table
  #    alongside provider-direct costs.
  defp maybe_apply_cost_hook(data, %CAEvent.Cost{} = cost) do
    try do
      tagged =
        Tau.CodingAgent.Cost.from_event(cost,
          agent: data.coding_agent,
          session_id: data.id,
          adapter_session_id: get_in(data, [:coding_agent_state, :session_id])
        )

      data = persist_event(data, "coding_agent_cost", Tau.CodingAgent.Cost.to_jsonl(tagged))

      :telemetry.execute(
        [:tau, :coding_agent, :cost],
        %{
          system_time: System.system_time(),
          usd: tagged.usd || 0.0,
          duration_ms: tagged.duration_ms,
          input_tokens: tagged.input_tokens,
          output_tokens: tagged.output_tokens,
          cache_read: tagged.cache_read,
          cache_write: tagged.cache_write
        },
        %{
          session_id: data.id,
          agent: data.coding_agent,
          model: data.model,
          source: Tau.CodingAgent.Cost.source(tagged),
          adapter_session_id: tagged.adapter_session_id
        }
      )

      %{data | coding_agent_costs: (data.coding_agent_costs || []) ++ [tagged]}
    rescue
      e ->
        # D-035: cost-folding errors don't crash the session. Surface
        # diagnostically and continue with the original data.
        :telemetry.execute(
          [:tau, :coding_agent, :cost, :failed],
          %{system_time: System.system_time()},
          %{
            session_id: data.id,
            agent: data.coding_agent,
            reason: Exception.message(e)
          }
        )

        data
    end
  end

  # SPEC-CODING-AGENT §7 Q5: only persist when (a) the adapter
  # actually surfaced a session_id and (b) it's new. This avoids
  # appending a JSONL line per turn for adapters (e.g. Replay) that
  # don't expose a session concept, and avoids duplicate writes
  # when the same id arrives twice.
  defp maybe_capture_coding_agent_session(data, %CAEvent.Start{session_id: nil}), do: data

  defp maybe_capture_coding_agent_session(data, %CAEvent.Start{session_id: sid} = ev)
       when is_binary(sid) do
    state = data.coding_agent_state || %{session_id: nil, agent: nil}

    if state.session_id == sid do
      data
    else
      new_state = %{state | session_id: sid, agent: data.coding_agent}

      data
      |> Map.put(:coding_agent_state, new_state)
      |> persist_event("coding_agent_session", %{
        "session_id" => sid,
        "agent" => agent_to_string(data.coding_agent),
        "version" => ev.version
      })
    end
  end

  defp maybe_capture_coding_agent_session(data, _ev), do: data

  defp agent_to_string(nil), do: nil
  defp agent_to_string(agent) when is_atom(agent), do: Atom.to_string(agent)
  defp agent_to_string(bin) when is_binary(bin), do: bin

  # Translate a coding-agent error reason into a user-visible string.
  # Mirrors `describe_provider_error/1` for the provider path.
  defp describe_coding_agent_error({:workspace_prepare_failed, reason}),
    do: "Workspace preparation failed: " <> inspect(reason)

  defp describe_coding_agent_error({:dispatcher_start_failed, reason}),
    do: "Coding-agent dispatcher failed to start: " <> inspect(reason)

  defp describe_coding_agent_error(:cancelled), do: "cancelled"
  defp describe_coding_agent_error(:inactivity_timeout), do: "Coding-agent inactivity timeout"

  defp describe_coding_agent_error(other) when is_binary(other), do: other
  defp describe_coding_agent_error(other), do: inspect(other)

  # --- Hook payload --------------------------------------------------------
  #
  # Phase 10's hook contract (mirroring Claude Code's): every hook payload
  # carries session_id, cwd, permission_mode, hook_event_name, and
  # transcript_path in addition to event-specific fields. Callers pass only
  # the event-specific extras; the canonical fields are always present.

  defp hook_payload(data, event, extras) when is_map(extras) do
    Map.merge(
      %{
        session_id: data.id,
        cwd: data.cwd,
        permission_mode: Map.get(data.metadata, :permissions_mode, :default),
        hook_event_name: to_string(event),
        transcript_path: transcript_path(data),
        metadata: data.metadata || %{}
      },
      extras
    )
  end

  defp transcript_path(%{persistence: p, id: id, cwd: cwd}) do
    # path_for/2 is a required Tau.Persistence callback (#61). Backends
    # without an on-disk file return a pseudo-URI; the field on the
    # hook payload is always a non-nil binary.
    p.path_for(id, cwd)
  end

  # --- Skill activation (issue #17) -----------------------------------------
  #
  # Mechanism A (ADR-0013): the model activates a discovered skill by
  # emitting a tool_call to the synthetic `__activate_skill__` tool. The
  # tool is FSM-internal — it never reaches the executor pool, never
  # passes through permissions or hooks. Skills with
  # `disable_model_invocation: true` are excluded from the exposed enum;
  # their bodies are still injected as system messages (background
  # context) by `prepend_skill_messages/2`.

  defp model_invokable_skills(skills) do
    Enum.reject(skills, fn {_name, s} -> s.disable_model_invocation end)
  end

  defp skill_activation_tool_spec(skills) do
    case model_invokable_skills(skills) do
      [] ->
        nil

      list ->
        names = Enum.map(list, fn {name, _s} -> name end)

        descriptions =
          list
          |> Enum.map(fn {name, %Tau.Skill{description: d}} ->
            case d do
              "" -> "  - #{name}"
              nil -> "  - #{name}"
              desc -> "  - #{name}: #{desc}"
            end
          end)
          |> Enum.join("\n")

        description =
          "Activate one of the available skills for the current turn. " <>
            "Activation scopes subsequent tool calls to the skill's allowed_tools " <>
            "whitelist (if set) and ends when you emit `end_turn`. " <>
            "Available skills:\n" <> descriptions

        %{
          name: @activate_skill_tool_name,
          description: description,
          parameters: %{
            "type" => "object",
            "properties" => %{
              "name" => %{
                "type" => "string",
                "enum" => names,
                "description" => "Name of the skill to activate."
              }
            },
            "required" => ["name"],
            "additionalProperties" => false
          }
        }
    end
  end

  defp maybe_put_tools(opts, nil), do: opts
  defp maybe_put_tools(opts, tool_spec), do: Map.put(opts, :tools, [tool_spec])

  # Process every `__activate_skill__` call inline. Returns the new
  # `data` (with `active_skill` set on success) and the partial
  # `tools_in_flight` map for these calls — they share the `:tool_done`
  # mailbox path with regular tool results so the FSM bookkeeping is
  # uniform.
  defp handle_skill_activations([], data, _parent), do: {data, %{}}

  defp handle_skill_activations(calls, data, parent) do
    Enum.reduce(calls, {data, %{}}, fn %{id: id, name: tool_name, arguments: args},
                                       {data_acc, in_flight_acc} ->
      requested = skill_name_from_args(args)

      {data_acc, result} = activate_skill(data_acc, requested, id)

      :telemetry.execute(
        [:tau, :session, :skill_activated],
        %{system_time: System.system_time()},
        %{
          session_id: data_acc.id,
          skill_name: requested,
          tool_name: tool_name,
          disabled?: result.is_error
        }
      )

      Process.send(parent, {:tool_done, id, result}, [])
      {data_acc, Map.put(in_flight_acc, id, :activated)}
    end)
  end

  defp skill_name_from_args(args) when is_map(args) do
    Map.get(args, "name") || Map.get(args, :name)
  end

  defp skill_name_from_args(_), do: nil

  # Issue #95: user-initiated slash-command skill activation.
  #
  # Called when `classify_slash_command/2` matches the slash-command name
  # against `data.skills`. Sets `data.active_skill`, persists a JSONL
  # `skill_activated` event, broadcasts `%Events.SkillActivated{}`, and
  # emits telemetry — reusing the same side-effects as model-initiated
  # activation, but without a tool_call_id (nil).
  defp activate_skill_via_slash(data, %Tau.Skill{name: name} = skill) do
    data =
      %{data | active_skill: skill}
      |> persist_event("skill_activated", %{
        skill_name: name,
        tool_call_id: nil,
        allowed_tools: skill.allowed_tools
      })

    broadcast(data.id, %Events.SkillActivated{
      session_id: data.id,
      skill_name: name,
      tool_call_id: nil
    })

    :telemetry.execute(
      [:tau, :session, :skill_activated],
      %{},
      %{session_id: data.id, skill_name: name, disabled?: false}
    )

    data
  end

  # Look up `name` on `data.skills`; honour `disable_model_invocation`.
  # On success, set `data.active_skill`, persist a JSONL event, and
  # broadcast `%Events.SkillActivated{}`. On failure, return an
  # `is_error: true` ToolResult and leave `data` unchanged.
  defp activate_skill(data, nil, call_id) do
    {data,
     ToolResult.new(
       tool_call_id: call_id,
       tool_name: @activate_skill_tool_name,
       content: "Skill activation failed: missing 'name' parameter.",
       is_error: true
     )}
  end

  defp activate_skill(data, name, call_id) when is_binary(name) do
    case List.keyfind(data.skills, name, 0) do
      {^name, %Tau.Skill{disable_model_invocation: true}} ->
        {data,
         ToolResult.new(
           tool_call_id: call_id,
           tool_name: @activate_skill_tool_name,
           content:
             "Skill '#{name}' has disable-model-invocation set; it cannot be activated by the model.",
           is_error: true
         )}

      {^name, %Tau.Skill{} = skill} ->
        data =
          %{data | active_skill: skill}
          |> persist_event("skill_activated", %{
            skill_name: name,
            tool_call_id: call_id,
            allowed_tools: skill.allowed_tools
          })

        broadcast(data.id, %Events.SkillActivated{
          session_id: data.id,
          skill_name: name,
          tool_call_id: call_id
        })

        {data,
         ToolResult.new(
           tool_call_id: call_id,
           tool_name: @activate_skill_tool_name,
           content: "Skill activated: #{name}",
           is_error: false
         )}

      nil ->
        {data,
         ToolResult.new(
           tool_call_id: call_id,
           tool_name: @activate_skill_tool_name,
           content: "Unknown skill: #{name}",
           is_error: true
         )}
    end
  end

  defp register_builtins do
    Enum.each(
      Application.get_env(:tau, :builtin_tools, []),
      fn mod ->
        case Tau.Tool.register(mod) do
          {:ok, _} -> :ok
          {:error, {:already_registered, _}} -> :ok
          _ -> :ok
        end
      end
    )
  end

  defp message_to_data(%User{} = m), do: %{role: "user", content: serialize_content(m.content)}

  defp message_to_data(%Assistant{} = m) do
    %{
      role: "assistant",
      content: Enum.map(m.content, &serialize_block/1),
      stop_reason: m.stop_reason && to_string(m.stop_reason),
      usage: m.usage,
      model: m.model
    }
  end

  defp message_to_data(%ToolResult{} = m), do: tool_result_to_data(m)

  defp tool_result_to_data(%ToolResult{} = m) do
    %{
      role: "tool_result",
      tool_call_id: m.tool_call_id,
      tool_name: m.tool_name,
      content: serialize_content(m.content),
      is_error: m.is_error,
      details: m.details
    }
  end

  defp serialize_content(s) when is_binary(s), do: s
  defp serialize_content(blocks) when is_list(blocks), do: Enum.map(blocks, &serialize_block/1)

  defp serialize_block(%{type: :text, text: t}), do: %{"type" => "text", "text" => t}

  defp serialize_block(%{type: :image, data: d, media_type: mt}) when is_binary(d) do
    %{"type" => "image", "media_type" => mt, "data_b64" => Base.encode64(d)}
  end

  defp serialize_block(%{type: :tool_call} = b),
    do: %{"type" => "tool_call", "id" => b.id, "name" => b.name, "arguments" => b.arguments}

  defp serialize_block(%{type: :thinking, text: t, signature: s}),
    do: %{"type" => "thinking", "text" => t, "signature" => s}

  defp serialize_block(other), do: other

  # --- Skill loading + injection --------------------------------------------
  #
  # Per ADR-0005 the session is a read-only consumer of skill data:
  # filesystem-discovered skills come from the pure
  # Tau.Skills.Loader.discover/1, extension-provided skills come
  # from the registry that Tau.Extensions.Loader populates once at
  # boot. We merge both, deduplicating by name (filesystem wins on
  # conflict, since cwd-local should mask priv/bundled).

  defp load_skills(cwd) do
    discovered = Tau.Skills.Loader.discover(cwd)
    extension = Tau.Skills.Loader.list_extension_skills()

    skills =
      (extension ++ discovered)
      |> Enum.uniq_by(fn {name, _} -> name end)
      |> Enum.sort_by(fn {name, _} -> name end)

    if skills != [] do
      active_count = Enum.count(skills, fn {_n, s} -> not s.disable_model_invocation end)

      :telemetry.execute(
        [:tau, :skills, :loaded],
        %{count: length(skills), active: active_count, skipped: length(skills) - active_count},
        %{cwd: cwd}
      )
    end

    skills
  end

  defp prepend_skill_messages(messages, skills) do
    active = Enum.reject(skills, fn {_name, s} -> s.disable_model_invocation end)

    case active do
      [] ->
        messages

      list ->
        Enum.map(list, fn {name, %Tau.Skill{} = s} ->
          Tau.Message.User.new(render_skill(name, s),
            metadata: %{role: :system, source: :skill, name: name, path: s.path}
          )
        end) ++ messages
    end
  end

  defp render_skill(name, %Tau.Skill{description: desc, body: body}) do
    header =
      if is_binary(desc) and desc != "" do
        "# Skill: #{name}\n\n_#{desc}_\n\n"
      else
        "# Skill: #{name}\n\n"
      end

    header <> body
  end

  # --- Memory injection -----------------------------------------------------

  defp inject_memory(messages, cwd) do
    case Tau.Memory.Loader.load(cwd) do
      [] ->
        messages

      cascade ->
        bytes = Enum.reduce(cascade, 0, fn {_p, b}, acc -> acc + byte_size(b) end)

        :telemetry.execute(
          [:tau, :memory, :loaded],
          %{file_count: length(cascade), bytes: bytes},
          %{cwd: cwd}
        )

        memory_messages =
          Enum.map(cascade, fn {path, body} ->
            Tau.Message.User.new(body, metadata: %{role: :system, source: :memory, path: path})
          end)

        memory_messages ++ messages
    end
  end

  # --- Event replay (for fork/resume) ---------------------------------------

  defp events_to_messages(events) do
    events
    |> Enum.map(&event_to_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp event_to_message(%{"kind" => "user_message", "data" => d}) do
    Tau.Message.User.new(d["content"])
  end

  defp event_to_message(%{"kind" => "assistant_message", "data" => d}) do
    Tau.Message.Assistant.new(
      content: deserialize_blocks(d["content"]),
      stop_reason: stop_reason_atom(d["stop_reason"]),
      usage: d["usage"] || %{},
      model: d["model"]
    )
  end

  defp event_to_message(%{"kind" => "tool_result", "data" => d}) do
    Tau.Message.ToolResult.new(
      tool_call_id: d["tool_call_id"],
      tool_name: d["tool_name"],
      content: d["content"],
      details: d["details"] || %{},
      is_error: d["is_error"] || false
    )
  end

  defp event_to_message(%{"kind" => "compaction", "data" => %{"summary" => s}})
       when is_binary(s) and s != "" do
    Tau.Message.User.new(s, metadata: %{role: :compaction_summary})
  end

  defp event_to_message(_), do: nil

  # D-041 / [C54-B4]: fold the last persisted model_swap event from a
  # preload list so resume and fork both converge on the swapped model.
  # Returns the most recent "to" value, or nil when no swap is recorded.
  # Mirrors coding_agent_state_from_preload/1.
  defp model_from_preload(preload) when is_list(preload) do
    Enum.reduce(preload, nil, fn
      %{"kind" => "model_swap", "data" => %{"to" => to}}, _acc when is_binary(to) -> to
      _, acc -> acc
    end)
  end

  defp model_from_preload(_), do: nil

  # SPEC-CODING-AGENT §7 Q5: recover the most recent
  # adapter-side session_id from a preload event log so a resumed
  # session can pass it back as `task.resume_id`. Walks events in
  # order so the LAST `coding_agent_session` wins (Claude Code
  # rotates session_id across restarts in some failure modes).
  defp coding_agent_state_from_preload(preload) when is_list(preload) do
    Enum.reduce(preload, nil, fn
      %{"kind" => "coding_agent_session", "data" => %{} = d}, _acc ->
        %{
          session_id: d["session_id"],
          agent: agent_to_atom(d["agent"])
        }

      _, acc ->
        acc
    end)
  end

  defp coding_agent_state_from_preload(_), do: nil

  # SPEC-CODING-AGENT §7 Q4 / D-038: fold persisted `coding_agent_cost`
  # events back into in-memory records so the resumed session's
  # cost panel doesn't lose history. Skips malformed lines silently
  # (forward-compat — newer schema fields land here as additions).
  defp coding_agent_costs_from_preload(preload) when is_list(preload) do
    preload
    |> Enum.filter(&match?(%{"kind" => "coding_agent_cost"}, &1))
    |> Enum.map(fn %{"data" => d} -> Tau.CodingAgent.Cost.from_jsonl(d) end)
    |> Enum.reject(&is_nil/1)
  end

  defp coding_agent_costs_from_preload(_), do: []

  defp agent_to_atom(nil), do: nil

  defp agent_to_atom(bin) when is_binary(bin) do
    String.to_existing_atom(bin)
  rescue
    ArgumentError -> nil
  end

  defp agent_to_atom(a) when is_atom(a), do: a
  defp agent_to_atom(_), do: nil

  # --- Compaction helpers --------------------------------------------------
  #
  # We persist the full <conversation_summary>...</conversation_summary>
  # block as the JSONL "summary" field so events_to_messages/1's
  # "compaction" clause can reconstruct the synthetic message verbatim
  # on Tau.fork/2 / Tau.resume/1. The compactor returns just the inner
  # text via the new tri-tuple contract (#57); we wrap it here.

  defp format_summary_for_persist(nil), do: nil

  defp format_summary_for_persist(summary_text) when is_binary(summary_text) do
    "<conversation_summary>\n#{summary_text}\n</conversation_summary>"
  end

  defp deserialize_blocks(blocks) when is_list(blocks),
    do: Enum.map(blocks, &deserialize_block/1)

  defp deserialize_blocks(other), do: other

  defp deserialize_block(%{"type" => "text", "text" => t}), do: %{type: :text, text: t}

  defp deserialize_block(%{"type" => "tool_call", "id" => id, "name" => n, "arguments" => a}),
    do: %{type: :tool_call, id: id, name: n, arguments: a}

  defp deserialize_block(%{"type" => "thinking", "text" => t} = b),
    do: %{type: :thinking, text: t, signature: b["signature"]}

  defp deserialize_block(other), do: other

  defp stop_reason_atom(nil), do: nil
  defp stop_reason_atom(s) when is_binary(s), do: String.to_atom(s)
  defp stop_reason_atom(s), do: s

  # --- Slash commands (ADR-0008) -------------------------------------------
  #
  # Programmatic slash-command bodies (Tau.Command modules) run in a
  # supervised Task — never inline in the FSM — so a misbehaving
  # extension can't deadlock the session. File-commands stay
  # synchronous; they're bounded File.read/1s with no user code.
  #
  # classify_slash_command/1 is a pure parser: it returns
  # `{:async, mod, args, msg}` (caller spawns the task) or
  # `{:sync, msg}` (caller proceeds directly with the rewritten
  # message).

  defp classify_slash_command(%Tau.Message.User{content: c} = msg, skills)
       when is_binary(c) do
    case Tau.Commands.Parser.parse(c) do
      {:command, "/model", args} ->
        {:model_command, String.trim(args), msg}

      {:command, "/" <> bare_name = name, args} ->
        # [C55-B4]: built-ins shadow same-named extensions.
        case Tau.Commands.Parser.lookup_builtin(name) do
          {:ok, mod} ->
            {:builtin, mod, args, msg}

          :error ->
            case Tau.Commands.Parser.lookup(name) do
              {:ok, mod} when is_atom(mod) ->
                if function_exported?(mod, :execute, 2) do
                  {:async, mod, args, msg}
                else
                  {:sync, msg}
                end

              {:ok, path} when is_binary(path) ->
                {:sync, invoke_file_command(path, args, msg)}

              :error ->
                # Not a built-in or extension command — check skills.
                case Tau.Commands.Parser.lookup_skill(bare_name, skills) do
                  {:ok, skill} ->
                    rewritten = %Tau.Message.User{msg | content: args}
                    {:skill_activation, skill, rewritten}

                  :error ->
                    # Unknown slash command; pass through verbatim — the
                    # model can handle it as a stylistic preface or report
                    # that it's unknown.
                    {:sync, msg}
                end
            end
        end

      _ ->
        {:sync, msg}
    end
  end

  defp classify_slash_command(msg, _skills), do: {:sync, msg}

  defp spawn_command_task(mod, args, msg, data) do
    parent = self()
    ctx = build_command_ctx(data)
    timeout_ms = Application.get_env(:tau, :slash_command_timeout_ms, 30_000)

    # Use start_child (not async_nolink) so we can deliver the result
    # from *inside* the worker via Process.send. async_nolink's Task
    # struct is owner-locked; querying it from a watcher pid raises
    # ArgumentError. The session FSM tracks the worker pid directly
    # for cancel/timeout purposes.
    {:ok, pid} =
      Task.Supervisor.start_child(Tau.Tools.TaskSupervisor, fn ->
        result =
          try do
            case prepare_command_args(mod, args) do
              {:ok, prepared} -> mod.execute(prepared, ctx)
              {:error, _} = err -> err
            end
          rescue
            e -> {:crashed, Exception.message(e)}
          catch
            kind, value -> {:crashed, "uncaught #{kind}: #{inspect(value)}"}
          end

        Process.send(parent, {:command_done, result, msg}, [])
      end)

    Process.send_after(self(), {:command_timeout, pid, msg, timeout_ms}, timeout_ms)

    {:keep_state, %{data | command_task: pid}}
  end

  defp apply_command_result(result, msg) do
    case result do
      {:inject, prefix} when is_binary(prefix) ->
        %Tau.Message.User{msg | content: prefix <> "\n\n" <> msg.content}

      {:replace, replacement} when is_binary(replacement) ->
        %Tau.Message.User{msg | content: replacement}

      {:run, replacement} when is_binary(replacement) ->
        %Tau.Message.User{msg | content: replacement}

      :ignore ->
        msg

      {:crashed, reason} ->
        %Tau.Message.User{
          msg
          | content: "(slash command crashed: #{reason})\n\n" <> msg.content
        }

      {:timeout, ms} ->
        %Tau.Message.User{
          msg
          | content: "(slash command timed out after #{ms}ms)\n\n" <> msg.content
        }

      # #15: spec-parse failure surfaced from prepare_command_args/2.
      {:error, reason} ->
        %Tau.Message.User{
          msg
          | content:
              "(slash command argument error: #{Tau.Command.Spec.format_error(reason)})\n\n" <>
                msg.content
        }

      _ ->
        msg
    end
  end

  # #15: if the command module declares a `parameters/0` spec, tokenise
  # the tail string and bind it before invoking `execute/2`. Otherwise
  # pass the raw tail (backwards-compatible).
  defp prepare_command_args(mod, args) when is_binary(args) do
    if function_exported?(mod, :parameters, 0) do
      Tau.Command.Spec.parse(mod.parameters(), args)
    else
      {:ok, args}
    end
  end

  defp prepare_command_args(_mod, args), do: {:ok, args}

  # D-042 / [C55-B4]: built-in slash-command inline handler.
  #
  # Dispatches `mod.run(args, data)` and maps the typed outcome to FSM
  # actions.  CRITICAL: {:notice}, {:mutate}, and {:error} branches MUST
  # NOT call process_user_message/2 — no provider turn is started.
  # Only :passthrough falls through to the normal provider path.
  defp handle_builtin_command(mod, args, original_msg, data) do
    outcome = mod.run(args, data)

    :telemetry.execute(
      [:tau, :session, :builtin_command],
      %{},
      %{session_id: data.id, command: mod.name(), outcome: outcome_tag(outcome)}
    )

    case outcome do
      {:notice, text} when is_binary(text) ->
        broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: text})
        {:keep_state, data}

      {:notice, lines} when is_list(lines) ->
        Enum.each(lines, fn line ->
          broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: line})
        end)

        {:keep_state, data}

      {:mutate, fun, notice} when is_function(fun, 1) ->
        data2 = fun.(data)

        if is_binary(notice) do
          broadcast(data2.id, %Events.SystemNotice{session_id: data2.id, text: notice})
        end

        {:keep_state, data2}

      {:error, text} ->
        broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: "Error: " <> text})
        {:keep_state, data}

      {:async_compact, notice} ->
        # C67-B4: the only outcome that changes FSM state (to :compacting).
        # Does NOT call process_user_message/2 (D-042).
        broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})

        ctx = %{provider: data.provider, model: data.model}
        timeout_ms = Application.get_env(:tau, :compaction_timeout_ms, 60_000)

        task =
          Task.Supervisor.async_nolink(Tau.Tools.TaskSupervisor, fn ->
            Tau.Compactor.impl().compact(data.messages, ctx)
          end)

        :telemetry.execute([:tau, :compaction, :start], %{system_time: System.system_time()}, %{
          session_id: data.id,
          message_count: length(data.messages),
          async: true
        })

        Process.send_after(self(), {:compaction_timeout, task.pid, timeout_ms}, timeout_ms)

        {:next_state, :compacting,
         %{data | compaction_task: task.pid, compaction_monitor: task.ref}}

      :passthrough ->
        # Fall through to the normal provider turn with the original message.
        process_user_message(original_msg, data)
    end
  end

  defp outcome_tag({:notice, _}), do: :notice
  defp outcome_tag({:mutate, _, _}), do: :mutate
  defp outcome_tag({:error, _}), do: :error
  defp outcome_tag({:async_compact, _}), do: :async_compact
  defp outcome_tag(:passthrough), do: :passthrough

  # D-041: /model <id> slash-command handler. Runs the same validate +
  # mutate + telemetry + persist logic as the {:swap_model} call handler
  # via the shared apply_model_swap/2 helper. Does NOT start a provider
  # turn — broadcasts a SystemNotice instead.
  defp handle_slash_model_swap(data, new_model) do
    case apply_model_swap(data, new_model) do
      {:ok, data2, %{from: from, to: to}} ->
        notice = "Model changed: #{from} → #{to}"
        broadcast(data2.id, %Events.SystemNotice{session_id: data2.id, text: notice})
        {:keep_state, data2}

      {:error, :invalid_model} ->
        notice = "Error: '#{new_model}' is not a valid model id (empty or whitespace)."
        broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})
        {:keep_state, data}
    end
  end

  defp invoke_file_command(path, args, msg) do
    case File.read(path) do
      {:ok, body} -> %Tau.Message.User{msg | content: body <> "\n\n" <> args}
      _ -> msg
    end
  end

  defp build_command_ctx(data) do
    sid = data.id

    Tau.Command.Context.new(
      session_id: sid,
      cwd: data.cwd,
      permissions_mode: Map.get(data.metadata, :permissions_mode, :default),
      emit: fn payload ->
        Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{sid}", payload)
      end,
      metadata: data.metadata
    )
  end
end
