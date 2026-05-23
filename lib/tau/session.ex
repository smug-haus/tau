defmodule Tau.Session do
  @moduledoc """
  Per-session `:gen_statem` (callback mode `:handle_event_function`).

  States:

      :awaiting_user
      :provider_streaming
      :tool_executing
      :awaiting_permission
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

  alias Tau.Message.{ToolResult, User}
  alias Tau.Session.Events
  alias Tau.Provider.Event, as: PEvent
  # SPEC-CODING-AGENT: coding-agent session mode. The FSM hosts
  # a parallel `:coding_agent_streaming` state. When `data.coding_agent`
  # is non-nil, user messages route through `Tau.CodingAgent.Dispatcher`
  # instead of `data.provider.stream/3`; the dispatcher's normalized
  # events fold into `data.messages` as `%Assistant{}` / `%ToolResult{}`
  # so the existing TUI render path, persistence, and `/resume` apply
  # unchanged (D-037).
  alias Tau.CodingAgent.Workspace, as: CAWorkspace

  # Name of the synthetic FSM-internal tool the model emits to
  # activate a discovered skill. Not registered as a `Tau.Tool` module
  # — interception happens in `dispatch_tools/2` before any executor
  # would see it.
  @activate_skill_tool_name "__activate_skill__"

  @doc false
  def activate_skill_tool_name, do: @activate_skill_tool_name

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

  @doc "Start a session under `Tau.Sessions.Supervisor`. See `Tau.start_session/1` for the option set."
  @spec start(keyword()) :: {:ok, id()} | {:error, term()}
  def start(opts) do
    id = opts[:session_id] || generate_id()

    case Tau.Sessions.Supervisor.start_session(Keyword.put(opts, :session_id, id)) do
      {:ok, _pid} -> {:ok, id}
      {:error, _} = e -> e
    end
  end

  # D-077: hard cap on each queue tier. Messages past 32 entries are
  # dropped with a %SystemNotice{} (D-083).
  @queue_cap 32

  @doc "Send a user message; queued as `:followup`. See `Tau.send/2`."
  @spec send(id(), String.t() | Tau.Message.t()) :: :ok | {:error, term()}
  def send(id, message) do
    with {:ok, pid} <- whereis(id) do
      msg =
        case message do
          %User{} -> message
          s when is_binary(s) -> User.new(s)
          %{} -> message
        end

      # Default tier is :followup (backward compatible with callers that do not
      # specify a tier — they get follow-up semantics, same as the old postpone).
      :gen_statem.cast(pid, {:user_message, msg, :followup})
    end
  end

  @doc """
  Send a steering message to a running session.

  A steering message is delivered at the **tool-round boundary** — after the
  current round's tool results and before the next provider call (D-079 /
  SPEC-USER-TURN §6). Idle sessions run the message immediately as a normal
  turn (both tiers collapse in that case).

  When the session is cancelled, steering messages are returned to the caller
  via a `%QueueRestored{}` broadcast rather than being delivered (D-082).
  """
  @spec steer(id(), String.t() | Tau.Message.t()) :: :ok | {:error, term()}
  def steer(id, message) do
    with {:ok, pid} <- whereis(id) do
      msg =
        case message do
          %User{} -> message
          s when is_binary(s) -> User.new(s)
          %{} -> message
        end

      :gen_statem.cast(pid, {:user_message, msg, :steering})
    end
  end

  @doc "Subscribe to a session's event stream. See `Tau.stream/2`."
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

  @doc "Resume a persisted session by id. Replays the JSONL transcript."
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
            # post-header event log into `:preload_events` so the
            # `coding_agent_state_from_preload/1` and
            # `coding_agent_costs_from_preload/1` helpers can rehydrate
            # the adapter-side session_id and cost ledger.
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

  @doc "Fork a session at `parent_event_id`, creating a new branch."
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

  @doc "Cancel in-flight work; the FSM returns to `:awaiting_user`."
  @spec cancel(id()) :: :ok
  def cancel(id) do
    with {:ok, pid} <- whereis(id) do
      :gen_statem.cast(pid, :cancel)
    end

    :ok
  end

  @doc "Stop a session. Runs `:stop` hooks, flushes persistence, removes the process."
  @spec stop(id()) :: :ok
  def stop(id) do
    with {:ok, pid} <- whereis(id) do
      :gen_statem.cast(pid, :stop)
    end

    :ok
  end

  @doc "Reconfigure provider, model, or `provider_ctx` for the next turn."
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

  @doc """
  Resolve a pending permission request for a tool call in an interactive
  session (SPEC-PERMISSION-PROMPTS §4 B5, D-096).

  `verdict` MUST be `:allow_once` or `:deny_once`.

  - `:allow_once` — dispatch the tool call; no rule is written.
  - `:deny_once` — synthesise an `is_error` ToolResult; no rule is written.

  Returns `:ok` if the cast was dispatched (fire-and-forget; does not wait
  for the FSM to process it). Returns `{:error, :not_found}` if the session
  id is unknown.

  A cast for an unknown or stale `tool_call_id` is a logged no-op per D-090.
  """
  @spec decide_permission(id(), String.t(), :allow_once | :deny_once) ::
          :ok | {:error, :not_found}
  def decide_permission(id, tool_call_id, verdict) when verdict in [:allow_once, :deny_once] do
    with {:ok, pid} <- whereis(id) do
      :gen_statem.cast(pid, {:permission_decision, tool_call_id, verdict})
    end
  end

  @doc """
  Update the permissions mode for a session (SPEC-PERMISSION-PROMPTS §4 B5,
  D-096). Gated: only allowed while the FSM is in `:awaiting_user` with no
  command task in flight.

  Returns `:ok` on success. Returns `{:error, :busy}` if the session is
  streaming, executing tools, or otherwise not idle. Returns
  `{:error, :not_found}` if the session id is unknown.

  Valid modes: `:default | :accept_edits | :plan | :auto | :dont_ask | :bypass`.
  """
  @spec set_permissions_mode(id(), atom()) :: :ok | {:error, :busy | :not_found}
  def set_permissions_mode(id, mode) do
    with {:ok, pid} <- whereis(id) do
      :gen_statem.call(pid, {:set_permissions_mode, mode})
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
          max_tool_iterations: pos_integer(),
          tool_loop_state: map(),
          tool_loop_brake_threshold: pos_integer(),
          tool_loop_call_lookups: map(),
          provider_retry_state: %{count: non_neg_integer()},
          provider_retry_max: pos_integer(),
          interactive?: boolean()
        }

  @doc """
  Return a read-only snapshot of a live session's data.

  Callers (tests, inspection tools, TUI panels) should use this instead
  of reaching into the FSM via `:sys.get_state/1` — it insulates them
  from internal data-shape refactors. Returns `{:error, :not_found}`
  for a session id that isn't currently registered.
  """
  @spec snapshot(id()) :: {:ok, snapshot()} | {:error, :not_found}
  def snapshot(id) do
    with {:ok, pid} <- whereis(id),
         {:alive, true} <- {:alive, Process.alive?(pid)},
         # Wrap :sys.get_state to handle the TOCTOU window between the
         # Process.alive? guard and the synchronous sys call — the process
         # may exit between the two. Catch the resulting :exit and return
         # {:error, :not_found} so callers see a clean tagged error.
         {:ok, state_and_data} <-
           (try do
              {:ok, :sys.get_state(pid)}
            catch
              :exit, _ -> {:error, :not_found}
            end) do
      {state, data} = state_and_data

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
         max_tool_iterations: Map.get(data, :max_tool_iterations, 100),
         tool_loop_state: Map.get(data, :tool_loop_state, %{}),
         tool_loop_brake_threshold: Map.get(data, :tool_loop_brake_threshold, 3),
         tool_loop_call_lookups: Map.get(data, :tool_loop_call_lookups, %{}),
         provider_retry_state: Map.get(data, :provider_retry_state, %{count: 0}),
         provider_retry_max: Map.get(data, :provider_retry_max, 3),
         interactive?: Map.get(data, :interactive?, true),
         # D-077 / SPEC-USER-TURN §6: expose queue depths and contents.
         # ADR-0009 deferred this; it makes the queues introspectable for
         # tests and a future "pending input" panel.
         queues: %{
           steering: :queue.to_list(Map.get(data, :steering_queue, :queue.new())),
           followup: :queue.to_list(Map.get(data, :followup_queue, :queue.new()))
         }
       }}
    else
      # :not_found from Registry, or process no longer alive (shutting down).
      _ -> {:error, :not_found}
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
    case Tau.Session.Data.new(opts) do
      {:ok, data} -> {:ok, :awaiting_user, data}
      {:stop, _} = stop -> stop
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
  # NOTE: This is ADR-0008's slash-command-task postpone and is intentionally
  # preserved by ADR-0021 (which supersedes only ADR-0009's user-message-postpone).
  def handle_event(:cast, {:user_message, _, _tier}, state, %{command_task: t} = data)
      when t != nil do
    emit_user_message_telemetry(:enqueued, data, state)
    {:keep_state_and_data, [{:postpone, true}]}
  end

  # D-077 / D-078 / SPEC-USER-TURN §6: two-tier queue routing for
  # messages received in any state other than `:awaiting_user`. D-083
  # hard cap at 32 entries drops with a `%SystemNotice{}`.
  def handle_event(:cast, {:user_message, msg, tier}, state, data)
      when state != :awaiting_user do
    {queue_field, tier_atom} =
      case tier do
        :steering -> {:steering_queue, :steering}
        _ -> {:followup_queue, :followup}
      end

    queue = Map.get(data, queue_field)
    queue_size = :queue.len(queue)

    if queue_size >= @queue_cap do
      # D-083: hard cap — drop with a %SystemNotice{}, no unbounded growth.
      notice =
        "Message queue full (#{@queue_cap} #{tier_atom} messages queued); " <>
          "message dropped. Wait for the current turn to complete."

      broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})

      :telemetry.execute(
        [:tau, :session, tier_atom, :dropped],
        %{system_time: System.system_time()},
        %{session_id: data.id, from_state: state, queue_size: queue_size}
      )

      {:keep_state_and_data, []}
    else
      new_queue = :queue.in(msg, queue)
      new_data = Map.put(data, queue_field, new_queue)

      :telemetry.execute(
        [:tau, :session, tier_atom, :enqueued],
        %{system_time: System.system_time()},
        %{session_id: data.id, from_state: state, queue_size: queue_size + 1}
      )

      emit_user_message_telemetry(:enqueued, data, state)
      {:keep_state, new_data}
    end
  end

  def handle_event(:cast, {:user_message, msg, _tier}, :awaiting_user, %{command_task: nil} = data) do
    emit_user_message_telemetry(:delivered, data, :awaiting_user)

    case Tau.Session.SlashCommand.classify_slash_command(
           msg,
           data.skills,
           data.prompt_templates,
           data.cwd
         ) do
      {:builtin, mod, args, msg} ->
        Tau.Session.SlashCommand.handle_builtin_command(mod, args, msg, data)

      {:async, mod, args, msg} ->
        Tau.Session.SlashCommand.spawn_command_task(mod, args, msg, data)

      {:skill_activation, skill, rewritten_msg} ->
        data = Tau.Session.SkillActivation.activate_skill_via_slash(data, skill)
        process_user_message(rewritten_msg, data)

      {:model_command, "", _msg} ->
        # /model with no args: show current model
        notice = "Current model: #{data.model}"
        broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})
        {:keep_state, data}

      {:model_command, new_model, _msg} ->
        # /model <id>: attempt swap
        Tau.Session.ModelSwap.handle_slash_model_swap(data, new_model)

      {:unknown_command, name} ->
        # D-101 (SPEC-TUI-COMPLETION AC-2): unrecognized slash command.
        # Emit a SystemNotice and stay in :awaiting_user — do NOT start a
        # provider turn (never call process_user_message/2 from here).
        notice = "Unknown command #{name} — type /help to list available commands"
        broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})
        {:keep_state, data}

      {:sync, msg} ->
        process_user_message(msg, data)
    end
  end

  # D-080 / SPEC-USER-TURN §6: follow-up drain. Re-routes through
  # `handle_event(:cast, {:user_message, ...})` rather than calling
  # `process_user_message/2` directly so slash-command classification still
  # runs (a queued `/reload` must execute the builtin, not start a turn).
  def handle_event(:internal, :drain_followups, :awaiting_user, %{command_task: nil} = data) do
    case :queue.out(data.followup_queue) do
      {:empty, _} ->
        {:keep_state, data}

      {{:value, msg}, rest} ->
        :telemetry.execute(
          [:tau, :session, :followup, :delivered],
          %{system_time: System.system_time()},
          %{session_id: data.id, from_state: :awaiting_user}
        )

        # Re-route through the full user_message dispatch path so slash commands
        # are classified (classify_slash_command/4 runs). The :followup tier tag
        # is preserved but irrelevant in :awaiting_user — the handler delivers
        # immediately. Note: handle_event will also emit :delivered telemetry via
        # emit_user_message_telemetry, which is intentional — one pair per drain.
        handle_event(:cast, {:user_message, msg, :followup}, :awaiting_user, %{
          data
          | followup_queue: rest
        })
    end
  end

  # Busy or command_task in flight: re-deliver after next transition.
  # (ADR-0008's postpone handles the command_task case via re-delivery; for
  # the no-command-task busy case this should not happen since :drain_followups
  # is only posted on :awaiting_user transitions, but guard defensively.)
  def handle_event(:internal, :drain_followups, _state, data) do
    {:keep_state, data}
  end

  def handle_event(:info, {:command_done, result, original_msg}, _state, data) do
    msg = Tau.Session.SlashCommand.apply_command_result(result, original_msg)
    process_user_message(msg, %{data | command_task: nil})
  end

  def handle_event(
        :info,
        {:command_timeout, pid, original_msg, ms},
        _state,
        %{command_task: pid} = data
      ) do
    if Process.alive?(pid), do: Process.exit(pid, :brutal_kill)
    msg = Tau.Session.SlashCommand.apply_command_result({:timeout, ms}, original_msg)
    process_user_message(msg, %{data | command_task: nil})
  end

  def handle_event(:info, {:command_timeout, _pid, _msg, _ms}, _state, data) do
    # Late timeout — task already completed and {:command_done, ...}
    # has already been processed. Drop.
    {:keep_state, data}
  end

  def handle_event(:internal, :start_provider, :provider_streaming, data) do
    Tau.Session.ProviderTurn.start(data)
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
    Tau.Session.CodingAgentTurn.handle_start_coding_agent(data)
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
    Tau.Session.CodingAgentTurn.handle_coding_agent_event_message(pid, event, data)
  end

  # Stale or out-of-order event — dispatcher mismatch. Drop silently;
  # the dispatcher's `restart: :temporary` guarantees no zombie pid
  # is resurrected.
  def handle_event(:info, {:coding_agent_event, _other_pid, _event}, _state, data) do
    {:keep_state, data}
  end

  # D-061: retryable mid-stream error, no fallback chain remaining,
  # unspent retry budget. CLAUSE ORDERING IS LOAD-BEARING — must precede
  # the ADR-0012 fallback clause (both head-match `%PEvent.Error{retryable?: true}`).
  def handle_event(
        :info,
        {:provider_event, ref, %PEvent.Error{retryable?: true} = ev},
        :provider_streaming,
        %{
          fallback_chain_remaining: [],
          stream_ref: ref,
          provider_retry_state: %{count: c}
        } = data
      )
      when c < data.provider_retry_max do
    Tau.Session.ProviderTurn.handle_provider_retry_event(ref, ev, data)
  end

  # D-061: deferred retry trigger. Posted by the clause above
  # after the backoff delay elapses. Re-enters `:start_provider` on
  # the same provider. Stale messages (where `provider_retry_state`
  # has advanced past the count we were scheduled with — e.g. the
  # user cancelled, or a new turn started) are silently dropped.
  def handle_event(
        :info,
        {:provider_retry, count},
        :provider_streaming,
        %{provider_retry_state: %{count: c}} = data
      )
      when count == c do
    handle_event(:internal, :start_provider, :provider_streaming, data)
  end

  def handle_event(:info, {:provider_retry, _count}, _state, data) do
    {:keep_state, data}
  end

  # ADR-0012: retryable mid-stream errors fall back to the next provider.
  # CLAUSE ORDERING IS LOAD-BEARING — must precede the generic :provider_event clause.
  def handle_event(
        :info,
        {:provider_event, ref, %PEvent.Error{retryable?: true} = ev},
        :provider_streaming,
        %{fallback_chain_remaining: [_next | _rest], stream_ref: ref} = data
      ) do
    Tau.Session.ProviderTurn.handle_provider_fallback_event(ref, ev, data)
  end

  def handle_event(:info, {:provider_event, ref, ev}, :provider_streaming, data) do
    Tau.Session.ProviderTurn.handle_provider_event(ref, ev, data)
  end

  def handle_event(:info, {:provider_done, ref}, :provider_streaming, data) do
    Tau.Session.ProviderTurn.handle_provider_done(ref, data)
  end

  def handle_event(:info, {:provider_failed, ref, msg}, :provider_streaming, data) do
    Tau.Session.ProviderTurn.handle_provider_failed(ref, msg, data)
  end

  # ADR-0014: bookkeeping casts from the `Agent` tool task.
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

  # SPEC-PERMISSION-PROMPTS §3 / D-098: :cancel in :awaiting_permission →
  # deny all pending requests → :awaiting_user. MUST precede the cross-cutting
  # :cancel handler (which uses `_state`) so this more-specific clause fires
  # first. Source order is LOAD-BEARING in :handle_event_function mode.
  def handle_event(:cast, :cancel, :awaiting_permission, data) do
    # Emit all accumulated instant-resolve results (prior :deny_once decisions
    # stored in permission_pending_results) directly — no {:tool_done} routing.
    # Mirrors the emit sequence in finish_permission_round/1.
    data =
      Enum.reduce(
        Enum.reverse(data.permission_pending_results),
        data,
        fn {call_id, result_msg}, acc ->
          {_lookup, call_lookups_rest} = Map.pop(acc.tool_loop_call_lookups, call_id)

          acc =
            acc
            |> append_message(result_msg)
            |> Tau.Session.Journal.persist(
              "tool_result",
              Tau.Session.Journal.tool_result_to_data(result_msg)
            )
            |> Map.put(:tool_loop_call_lookups, call_lookups_rest)

          broadcast(acc.id, %Events.ToolEnd{
            session_id: acc.id,
            tool_call_id: call_id,
            result: result_msg
          })

          acc
        end
      )

    # Synthesise and emit is_error ToolResults for all still-pending :ask calls
    # directly into history and PubSub — no {:tool_done} self-send. The only
    # handler for {:tool_done} in :awaiting_user is the catch-all, which would
    # drop these messages. Emitting directly keeps history well-formed (every
    # tool_call block has a paired tool_result) so the next provider turn succeeds.
    data =
      Enum.reduce(
        data.pending_permission_requests,
        data,
        fn {tool_call_id, %{name: name}}, acc ->
          result =
            ToolResult.new(
              tool_call_id: tool_call_id,
              tool_name: name,
              content: "Session cancelled while awaiting permission for #{name}.",
              is_error: true
            )

          {_lookup, call_lookups_rest} = Map.pop(acc.tool_loop_call_lookups, tool_call_id)

          acc =
            acc
            |> append_message(result)
            |> Tau.Session.Journal.persist(
              "tool_result",
              Tau.Session.Journal.tool_result_to_data(result)
            )
            |> Map.put(:tool_loop_call_lookups, call_lookups_rest)

          broadcast(acc.id, %Events.ToolEnd{
            session_id: acc.id,
            tool_call_id: tool_call_id,
            result: result
          })

          acc
        end
      )

    broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})

    data =
      Tau.Session.Journal.persist(data, "cancellation", %{
        cause: "user",
        reason: "awaiting_permission"
      })

    # D-082 / SPEC-USER-TURN §6: drain steering queue back to user,
    # consistent with the general :cancel handler. The :awaiting_permission
    # state is a "busy" state from the steering/follow-up queue perspective
    # (B2 from the critic: it is in the busy-state queueing guard). On cancel,
    # restore queued steering messages to the editor via %QueueRestored{}.
    # Follow-up queue is kept (D-080) and drains on next :awaiting_user entry.
    steering_messages = :queue.to_list(data.steering_queue)

    if steering_messages != [] do
      broadcast(data.id, %Events.QueueRestored{
        session_id: data.id,
        messages: steering_messages
      })
    end

    next_data = %{
      data
      | pending_permission_requests: %{},
        permission_dispatch_batch: [],
        permission_pending_results: [],
        tools_in_flight: %{},
        tool_dispatcher: nil,
        provider_task: nil,
        assembler: nil,
        stream_ref: nil,
        provider_span_ref: nil,
        active_skill: nil,
        tool_iterations: 0,
        tool_loop_state: %{},
        tool_loop_call_lookups: %{},
        provider_retry_state: %{count: 0},
        # D-082: steering queue cleared; follow-up queue preserved.
        steering_queue: :queue.new()
    }

    # D-080: drain follow-up queue on transition into :awaiting_user.
    actions =
      if :queue.is_empty(next_data.followup_queue),
        do: [],
        else: [{:next_event, :internal, :drain_followups}]

    {:next_state, :awaiting_user, next_data, actions}
  end

  def handle_event(:cast, :cancel, _state, data) do
    # ADR-0014: cascade to children first so each child's FSM gets
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
    cancel_mechanism = Tau.Session.ProviderTurn.cancel_provider_task(data)

    # With async_stream_nolink the dispatcher owns the tool tasks.
    # Brutal-killing it stops the iterator; in-flight tool processes under
    # Tau.Tools.TaskSupervisor finish on their own (no link to dispatcher)
    # and any late `:tool_done` messages drop into the catch-all clause.
    if data.tool_dispatcher && Process.alive?(data.tool_dispatcher) do
      Process.exit(data.tool_dispatcher, :brutal_kill)
    end

    if data.command_task && Process.alive?(data.command_task) do
      Process.exit(data.command_task, :brutal_kill)
    end

    # Guard every demonitor/exit on the compaction worker fields — an
    # unguarded demonitor(nil) crashes the FSM. This handler runs in _state
    # so it fires even outside :compacting (e.g. user types /cancel while
    # the FSM is in :awaiting_user with no compaction running).
    # compaction_failures is NOT reset by :cancel — a cancelled compaction
    # is not a success; resetting would let users mask a broken compactor.
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

    data =
      Tau.Session.Journal.persist(data, "cancellation", %{
        cause: "user",
        # ADR-0017: distinguishes the cooperative path (clean socket
        # release, partial content captured) from the brutal-kill
        # fallback (provider task didn't yield within 250ms).
        reason: Atom.to_string(cancel_mechanism)
      })

    # D-082 / SPEC-USER-TURN §6: drain the steering queue back to the
    # caller as a %QueueRestored{} event. A steering message was meant to
    # redirect the now-cancelled turn; auto-delivering it on the post-cancel
    # turn would surprise the user. The follow-up queue is kept (D-080) —
    # follow-up messages survive cancel and run on the post-cancel turn.
    steering_messages = :queue.to_list(data.steering_queue)

    if steering_messages != [] do
      broadcast(data.id, %Events.QueueRestored{
        session_id: data.id,
        messages: steering_messages
      })
    end

    next_data = %{
      data
      | provider_task: nil,
        cancel_flag: nil,
        stream_ref: nil,
        # SPEC-OTEL-REPORTER: clear discriminator; the OTel reporter
        # consumed it at the *.cancelled / *.brutal_kill emit site above.
        provider_span_ref: nil,
        tools_in_flight: %{},
        tool_dispatcher: nil,
        assembler: nil,
        command_task: nil,
        # ADR-0013: cancel ends the current turn — drop any
        # active skill alongside it.
        active_skill: nil,
        # D-027: reset per-turn tool-iteration counter on every
        # return to :awaiting_user, including cancellation.
        tool_iterations: 0,
        # D-060: tool-loop brake state is per-turn; reset on cancel.
        tool_loop_state: %{},
        tool_loop_call_lookups: %{},
        # D-061: provider-retry counter is per-turn; reset on cancel.
        provider_retry_state: %{count: 0},
        # SPEC-CODING-AGENT: dispatcher state is per-turn; reset on
        # cancel. Workspace is per-session — preserved.
        coding_agent_dispatcher: nil,
        coding_agent_pending: nil,
        coding_agent_blocks: [],
        # Clear compaction worker fields. compaction_failures is
        # intentionally NOT reset (see guard comment above).
        compaction_task: nil,
        compaction_monitor: nil,
        # D-082: steering queue is drained back to the user; clear it.
        # Follow-up queue is kept (D-080) — it drains on the next
        # :awaiting_user entry via the :drain_followups internal event.
        steering_queue: :queue.new()
    }

    # D-080 / SPEC-USER-TURN §6: post a :drain_followups internal event
    # so it fires on the transition to :awaiting_user. `:internal` (not
    # state_enter) avoids a module-wide callback_mode change.
    actions =
      if :queue.is_empty(next_data.followup_queue),
        do: [],
        else: [{:next_event, :internal, :drain_followups}]

    {:next_state, :awaiting_user, next_data, actions}
  end

  def handle_event(:cast, :stop, _state, data) do
    # ADR-0014: cascade `Tau.stop/1` to children before terminating.
    # Each child runs its own `terminate/3` which broadcasts `%SessionEnd{}`
    # on the child's topic.
    cascade_to_children(data, :stop)
    {:stop, :normal, data}
  end

  # In-place provider/model/provider_ctx update. The change applies
  # to the next provider call — an in-flight :provider_streaming keeps
  # using the previous provider until it completes.
  # When opts[:model] is present and non-nil, route it through
  # do_swap_model/2 (the single data.model mutation site). A nil opts[:model]
  # (provider-only reconfigure) MUST NOT touch data.model. No model_swap
  # event is emitted here — only the single "reconfigure" event below.
  def handle_event(:cast, {:reconfigure, opts}, _state, data) do
    Tau.Session.ModelSwap.handle_reconfigure(opts, data)
  end

  def handle_event(:info, {:tool_done, call_id, result_msg}, :tool_executing, data) do
    Tau.Session.ToolDispatch.handle_tool_done(call_id, result_msg, data)
  end

  # D-041: synchronous, state-gated model swap. Allowed only in
  # :awaiting_user with no in-flight command task. Any other state is :busy.
  # do_swap_model/2 is the single data.model mutation site.
  def handle_event({:call, from}, {:swap_model, model}, :awaiting_user, %{command_task: nil} = data) do
    Tau.Session.ModelSwap.handle_swap_model_idle(from, model, data)
  end

  # Busy: state is not :awaiting_user, or command_task is in flight.
  def handle_event({:call, from}, {:swap_model, _model}, _state, _data) do
    Tau.Session.ModelSwap.handle_swap_model_busy(from)
  end

  # ---------------------------------------------------------------------------
  # :compacting state — five terminal clauses (D-048, D-049)
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
  #
  # All five clauses MUST precede the catch-all (next clause below).
  # ---------------------------------------------------------------------------

  # Clause 1 — worker success: Task.Supervisor.async_nolink/3 delivers
  # {ref, result} on completion. Guard on compaction_monitor (the ref)
  # ensures stale results from a prior worker (cleared fields) are ignored.
  # Clause 1 — worker success. Guards on compaction_monitor ref.
  def handle_event(:info, {ref, result}, :compacting, %{compaction_monitor: ref} = data)
      when is_reference(ref) do
    Tau.Session.Compaction.handle_worker_result(ref, result, data)
  end

  # Clause 2a — benign {:DOWN, :normal}: keep waiting for {ref, result}.
  # Guard on compaction_monitor; do NOT demonitor here.
  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, :normal},
        :compacting,
        %{compaction_monitor: ref} = data
      )
      when is_reference(ref) do
    Tau.Session.Compaction.handle_worker_down_normal(data)
  end

  # Clause 2b — worker crash: {:DOWN, reason} where reason != :normal.
  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        :compacting,
        %{compaction_monitor: ref} = data
      )
      when is_reference(ref) do
    Tau.Session.Compaction.handle_worker_crash(ref, reason, data)
  end

  # Clause 3 — live timeout. Guards on compaction_task pid. MUST precede Clause 4.
  def handle_event(
        :info,
        {:compaction_timeout, pid, _ms},
        :compacting,
        %{compaction_task: pid} = data
      )
      when is_pid(pid) do
    Tau.Session.Compaction.handle_timeout(pid, data)
  end

  # Clause 4 — stale timeout: arrives AFTER the worker already completed
  # (Clause 1 cleared compaction_task to nil, so pid != data.compaction_task).
  # Drop with NO demonitor — both worker fields are already nil.
  # MUST be ordered AFTER Clause 3.
  def handle_event(:info, {:compaction_timeout, _pid, _ms}, _state, data) do
    {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # End of :compacting terminal clauses
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # :awaiting_permission state — SPEC-PERMISSION-PROMPTS §4 B3
  #
  # The FSM enters this state when an interactive session has at least one
  # tool call with an `:ask` verdict from `Tau.Permissions.Evaluator`. It waits
  # for `{:permission_decision, tool_call_id, verdict}` casts from the TUI.
  #
  # Source order is LOAD-BEARING. Clause ordering:
  #   0. {:tool_done} for pre-resolved items (deny-rule, whitelist, activated)
  #   1. :allow_once decision (known tool_call_id, in :awaiting_permission)
  #   2. :deny_once decision (known tool_call_id, in :awaiting_permission)
  #   3. stale/unknown tool_call_id in :awaiting_permission → logged no-op (D-090)
  #   4. decision cast outside :awaiting_permission → logged no-op (D-090)
  #   5. :cancel in :awaiting_permission → deny all pending → :awaiting_user (D-098)
  # ---------------------------------------------------------------------------

  # Clause 0 — {:tool_done} from pre-resolved items (deny-rule gated calls,
  # whitelist-filtered calls, and skill-activation calls) that produced
  # {:tool_done} messages before the FSM entered :awaiting_permission.
  # We process them normally (append to history, broadcast ToolEnd, update
  # tools_in_flight) but do NOT trigger the post-round transition — that
  # only fires when pending_permission_requests is empty (via the
  # permission_decision handlers). Applies only to known non-ask entries.
  def handle_event(:info, {:tool_done, call_id, result_msg}, :awaiting_permission, data) do
    Tau.Session.ToolDispatch.handle_tool_done_awaiting_permission(call_id, result_msg, data)
  end

  # Clause 1 — :allow_once. Must precede clause 3 (same state, specific verdict).
  def handle_event(
        :cast,
        {:permission_decision, tool_call_id, :allow_once},
        :awaiting_permission,
        data
      ) do
    Tau.Session.ToolDispatch.handle_permission_allow_once(tool_call_id, data)
  end

  # Clause 2 — :deny_once. Must precede clause 3 (same state, specific verdict).
  def handle_event(
        :cast,
        {:permission_decision, tool_call_id, :deny_once},
        :awaiting_permission,
        data
      ) do
    Tau.Session.ToolDispatch.handle_permission_deny_once(tool_call_id, data)
  end

  # Clause 3 — stale/unknown verdict in :awaiting_permission (D-090). Must precede clause 4.
  def handle_event(
        :cast,
        {:permission_decision, tool_call_id, verdict},
        :awaiting_permission,
        data
      ) do
    Tau.Session.ToolDispatch.handle_permission_stale(tool_call_id, verdict, data)
  end

  # Clause 4 — decision outside :awaiting_permission (D-090).
  def handle_event(:cast, {:permission_decision, tool_call_id, verdict}, _state, data) do
    Tau.Session.ToolDispatch.handle_permission_outside_state(tool_call_id, verdict, data)
  end

  # Clause 5 — :cancel in :awaiting_permission is handled by the specific
  # handle_event(:cast, :cancel, :awaiting_permission, data) clause defined
  # earlier (before the cross-cutting _state wildcard cancel handler).
  # Source order is LOAD-BEARING: the specific :awaiting_permission clause
  # fires first per :gen_statem :handle_event_function matching semantics.

  # ---------------------------------------------------------------------------
  # End of :awaiting_permission clauses
  # ---------------------------------------------------------------------------

  # SPEC-PERMISSION-PROMPTS §4 B5 (D-096): set_permissions_mode call handler.
  # Gated to :awaiting_user only (no command task in flight). Mirrors swap_model.
  def handle_event(
        {:call, from},
        {:set_permissions_mode, mode},
        :awaiting_user,
        %{command_task: nil} = data
      ) do
    data = %{data | metadata: Map.put(data.metadata, :permissions_mode, mode)}
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  # Busy: any other state, or awaiting_user with command task in flight.
  def handle_event({:call, from}, {:set_permissions_mode, _mode}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}
  end

  def handle_event(_type, _event, _state, data), do: {:keep_state, data}

  # Is the inbound event tagged with the currently-live run token?
  # Provider events carry a `stream_ref`; coding-agent events carry a
  # dispatcher pid. Stale events from superseded runs return false and
  # are dropped by the caller (ADR-0012).
  @spec current_run?(map(), {:provider, reference()} | {:coding_agent, pid()}) :: boolean()
  @doc false
  def current_run?(%{stream_ref: ref}, {:provider, ref}) when is_reference(ref), do: true

  @doc false
  def current_run?(%{coding_agent_dispatcher: pid}, {:coding_agent, pid}) when is_pid(pid),
    do: true

  @doc false
  def current_run?(_data, _token), do: false

  # --- Helpers --------------------------------------------------------------

  # Common path that handles a user_message after any slash-command
  # expansion has resolved. Called both by the synchronous
  # handle_event(:cast, {:user_message, _}, _, _) clause (no slash
  # command, or file-command) and by the
  # handle_event(:info, {:command_done, _, _}, _, _) clause when the
  # slash-command Task delivers its result (ADR-0008).
  @doc false
  def process_user_message(msg, data) do
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
          |> Tau.Session.Journal.persist("user_message", Tau.Session.Journal.message_to_data(msg))

        # SPEC-CODING-AGENT / D-037: route to the coding-agent
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

  @doc false
  def append_message(data, msg), do: %{data | messages: data.messages ++ [msg]}

  @doc false
  def generate_event_id do
    case Code.ensure_loaded?(Uniq.UUID) do
      true -> apply(Uniq.UUID, :uuid7, [])
      _ -> "evt_" <> (:crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false))
    end
  end

  @doc false
  def transition(id, _data, to) do
    :telemetry.execute([:tau, :session, :transition], %{system_time: System.system_time()}, %{
      session_id: id,
      to: to
    })

    :ok
  end

  @doc false
  def broadcast(id, event) do
    Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{id}", event)
  end

  # ADR-0014: cascade lifecycle operation to children. Both
  # `Tau.cancel/1` and `Tau.stop/1` are fire-and-forget casts; a child
  # already gone is a silent no-op (the natural race with its own
  # `%SessionEnd{}` broadcast). Recursion is implicit.
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
  @doc false
  def emit_user_message_telemetry(event, data, state) do
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

  @doc false
  def hook_payload(data, event, extras) when is_map(extras) do
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
    # path_for/2 is a required Tau.Persistence callback. Backends
    # without an on-disk file return a pseudo-URI; the field on the
    # hook payload is always a non-nil binary.
    p.path_for(id, cwd)
  end

  @doc false
  def register_builtins do
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
end
