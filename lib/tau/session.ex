defmodule Tau.Session do
  @moduledoc """
  Per-session `:gen_statem` (callback mode `:handle_event_function`).

  States:

      :awaiting_user
      :provider_streaming
      :tool_executing
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

          [%{"kind" => "session_header", "data" => d} | _rest] ->
            opts = [
              session_id: id,
              cwd: d["cwd"],
              provider: resolve_provider(d["provider"]),
              model: d["model"],
              metadata: d["metadata"] || %{},
              resume?: true
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
          child_session_ids: MapSet.t(String.t())
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
         child_session_ids: data.child_session_ids
       }}
    end
  end

  defp whereis(id) do
    case Registry.lookup(Tau.Sessions.Registry, id) do
      [{pid, _}] -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end

  defp generate_id do
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
    model = opts[:model]
    metadata = opts[:metadata] || %{}
    provider_ctx = opts[:provider_ctx] || %{}
    persistence = opts[:persistence] || Tau.Persistence.impl()
    preload = opts[:preload_events] || []

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

        messages =
          preload
          |> events_to_messages()
          |> prepend_skill_messages(skills)
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
          # Per-turn lifetime: cleared in `finalize_assistant/2` when the
          # assistant returns `stop_reason == :end_turn` and on `:cancel`.
          active_skill: nil,
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
          child_session_ids: MapSet.new()
        }

        {:ok, :awaiting_user, data}

      err ->
        {:stop, err}
    end
  end

  @impl :gen_statem
  def terminate(reason, _state, %{persistence: p, persist_handle: h, id: id}) do
    p.close(h)

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

    case classify_slash_command(msg) do
      {:async, mod, args, msg} ->
        spawn_command_task(mod, args, msg, data)

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

    ctx = Map.merge(data.provider_ctx, %{session_id: data.id})

    stream_opts =
      %{model: data.model}
      |> maybe_put_tools(skill_activation_tool_spec(data.skills))

    case data.provider.stream(data.messages, stream_opts, ctx) do
      {:ok, stream} ->
        task =
          Task.async(fn ->
            try do
              Enum.each(stream, fn ev -> Process.send(parent, {:provider_event, ev}, []) end)
              Process.send(parent, :provider_done, [])
            rescue
              e -> Process.send(parent, {:provider_failed, Exception.message(e)}, [])
            end
          end)

        assembler = Assembler.new(provider: data.provider, model: data.model)
        broadcast(data.id, %Events.MessageStart{session_id: data.id, message: assembler.message})

        {:next_state, :provider_streaming, %{data | provider_task: task, assembler: assembler}}

      {:error, reason} ->
        # Synchronous provider error — emit and return to awaiting_user.
        msg = Assistant.new(stop_reason: :error, error_message: inspect(reason))
        broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: msg})
        {:next_state, :awaiting_user, data}
    end
  end

  # ADR-0012: retryable mid-stream errors fall back to the next provider
  # in `data.fallback_chain_remaining`. Inserted *before* the generic
  # :provider_event clause so a non-empty chain takes over before the
  # error reaches the assembler. Empty chain → fall through to the
  # generic clause, which records the error and finalises the message.
  def handle_event(
        :info,
        {:provider_event, %PEvent.Error{retryable?: true} = ev},
        :provider_streaming,
        %{fallback_chain_remaining: [next | rest]} = data
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
    # emitting events or about to send :provider_done). Subsequent
    # stragglers in the mailbox are absorbed by the catch-all
    # handle_event clause at the bottom of the module.
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
          provider_task: nil
      }
    )
  end

  def handle_event(:info, {:provider_event, ev}, :provider_streaming, data) do
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
  end

  def handle_event(:info, :provider_done, :provider_streaming, data) do
    if data.assembler && Assembler.done?(data.assembler) do
      {:keep_state, data}
    else
      # Stream ended without a Done event — synthesise one.
      assembler =
        Assembler.step(data.assembler || Assembler.new(), %PEvent.Done{stop_reason: :stop})

      finalize_assistant(assembler, data)
    end
  end

  def handle_event(:info, {:provider_failed, msg}, :provider_streaming, data) do
    assembler =
      Assembler.step(data.assembler || Assembler.new(), %PEvent.Error{
        reason: msg,
        retryable?: false
      })

    finalize_assistant(assembler, data)
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

    if data.provider_task && Process.alive?(data.provider_task.pid) do
      Task.shutdown(data.provider_task, :brutal_kill)
    end

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

    broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})
    persist_event(data, "cancellation", %{reason: "user"})

    {:next_state, :awaiting_user,
     %{
       data
       | provider_task: nil,
         tools_in_flight: %{},
         tool_dispatcher: nil,
         assembler: nil,
         command_task: nil,
         # ADR-0013 (#16): cancel ends the current turn — drop any
         # active skill alongside it.
         active_skill: nil
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
  def handle_event(:cast, {:reconfigure, opts}, _state, data) do
    data =
      data
      |> maybe_replace(:provider, opts[:provider])
      # ADR-0012: keep original_provider in lockstep with the user-
      # configured provider. Reconfigure replaces both — fallback chains
      # are looked up keyed by the *new* primary on the next turn.
      |> maybe_replace(:original_provider, opts[:provider])
      |> maybe_replace(:model, opts[:model])
      |> merge_provider_ctx(opts[:provider_ctx])

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

  def handle_event(_type, _event, _state, data), do: {:keep_state, data}

  # --- Helpers --------------------------------------------------------------

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

        handle_event(:internal, :start_provider, :provider_streaming, data)
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
        stop_reason: msg.stop_reason
      }
    )

    data = maybe_compact(data, msg.usage || %{})

    # ADR-0012: per-message fallback semantics. Restore the working
    # provider to the user-configured original_provider so the next
    # turn's :start_provider re-derives the chain freshly and starts
    # against the primary. A still-running tool call keeps using the
    # provider that produced *this* message until the next provider
    # turn — that's correct: the tool result feeds the same model
    # that asked for the call.
    data = %{data | provider: data.original_provider, fallback_chain_remaining: []}

    # ADR-0013 (#16): skill activation is per-turn. The skill's lifetime
    # ends when the model decides the task is complete (`:end_turn`).
    # Tool-call turns keep the active skill so subsequent dispatch is
    # still gated; only `:end_turn` clears it.
    data = if msg.stop_reason == :end_turn, do: %{data | active_skill: nil}, else: data

    tool_calls = Enum.filter(msg.content, &match?(%{type: :tool_call}, &1))

    cond do
      tool_calls == [] ->
        {:next_state, :awaiting_user, %{data | provider_task: nil, assembler: nil}}

      true ->
        dispatch_tools(tool_calls, data)
    end
  end

  defp maybe_compact(data, usage) do
    compactor = Tau.Compactor.impl()

    if compactor.should_compact?(data.messages, usage) do
      :telemetry.execute([:tau, :compaction, :start], %{system_time: System.system_time()}, %{
        session_id: data.id,
        message_count: length(data.messages)
      })

      case compactor.compact(data.messages, %{provider: data.provider, model: data.model}) do
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

          %{data | messages: new_messages}

        {:error, _} ->
          data
      end
    else
      data
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
      |> Map.merge(
        Enum.into(whitelisted_out, %{}, fn %{id: id} -> {id, :whitelist_filtered} end)
      )
      |> Map.merge(activated_in_flight)

    {:next_state, :tool_executing,
     %{
       data
       | tools_in_flight: initial_in_flight,
         tool_dispatcher: dispatcher_pid,
         provider_task: nil,
         assembler: nil
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

        parallel_calls
        |> Task.Supervisor.async_stream_nolink(
          Tau.Tools.TaskSupervisor,
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
            %{tool: name, error: Exception.message(e)}
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

  defp classify_slash_command(%Tau.Message.User{content: c} = msg) when is_binary(c) do
    case Tau.Commands.Parser.parse(c) do
      {:command, name, args} ->
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
            # Unknown slash command; pass through verbatim — the model
            # can handle it as a stylistic preface or report that it's
            # unknown.
            {:sync, msg}
        end

      _ ->
        {:sync, msg}
    end
  end

  defp classify_slash_command(msg), do: {:sync, msg}

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
