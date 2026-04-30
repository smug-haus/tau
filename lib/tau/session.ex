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
          permissions_mode: atom()
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
         permissions_mode: Map.get(data.metadata, :permissions_mode, :default)
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
          model: model,
          metadata: metadata,
          provider_ctx: provider_ctx,
          messages: messages,
          skills: skills,
          persistence: persistence,
          persist_handle: persist_handle,
          provider_task: nil,
          assembler: nil,
          tools_in_flight: %{},
          # ADR-0008: slash-command tasks (user code) run isolated under
          # Tau.Tools.TaskSupervisor, never inline in the FSM.
          command_task: nil
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
  def handle_event(:cast, {:user_message, _}, _state, %{command_task: t} = _data)
      when t != nil do
    {:keep_state_and_data, [{:postpone, true}]}
  end

  def handle_event(:cast, {:user_message, msg}, _state, data) do
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

  def handle_event(:internal, :start_provider, :provider_streaming, data) do
    transition(data.id, data, :provider_streaming)

    parent = self()

    ctx = Map.merge(data.provider_ctx, %{session_id: data.id})

    case data.provider.stream(data.messages, %{model: data.model}, ctx) do
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

  def handle_event(:cast, :cancel, _state, data) do
    if data.provider_task && Process.alive?(data.provider_task.pid) do
      Task.shutdown(data.provider_task, :brutal_kill)
    end

    Enum.each(data.tools_in_flight, fn {_id, t} ->
      if Process.alive?(t.pid), do: Task.shutdown(t, :brutal_kill)
    end)

    if data.command_task && Process.alive?(data.command_task.pid) do
      Task.shutdown(data.command_task, :brutal_kill)
    end

    broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})
    persist_event(data, "cancellation", %{reason: "user"})

    {:next_state, :awaiting_user,
     %{data | provider_task: nil, tools_in_flight: %{}, assembler: nil, command_task: nil}}
  end

  def handle_event(:cast, :stop, _state, data) do
    {:stop, :normal, data}
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
      handle_event(:internal, :start_provider, :provider_streaming, %{data | tools_in_flight: tools})
    else
      {:keep_state, %{data | tools_in_flight: tools}}
    end
  end

  def handle_event(_type, _event, _state, data), do: {:keep_state, data}

  # --- Helpers --------------------------------------------------------------

  defp finalize_assistant(assembler, data) do
    msg = Assembler.assistant(assembler)
    data = data |> append_message(msg) |> persist_event("assistant_message", message_to_data(msg))
    broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: msg})

    data = maybe_compact(data, msg.usage || %{})

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
    rule_set = Tau.Permissions.RuleSet.get()
    mode = Map.get(data.metadata, :permissions_mode, :default)

    {gated, allowed} =
      Enum.split_with(tool_calls, fn %{name: name, arguments: args} ->
        Tau.Permissions.Evaluator.evaluate(rule_set, name, args, %{cwd: data.cwd}, mode) ==
          :deny
      end)

    # Synthesise tool_results for denied calls — model sees them as is_error.
    Enum.each(gated, fn %{id: id, name: name} ->
      result =
        ToolResult.new(
          tool_call_id: id,
          tool_name: name,
          content: "Permission denied: #{name} blocked by deny rule",
          is_error: true
        )

      Process.send(parent, {:tool_done, id, result}, [])

      :telemetry.execute([:tau, :permissions, :decision], %{system_time: System.system_time()}, %{
        tool: name,
        decision: :deny,
        session_id: data.id
      })
    end)

    tasks =
      Enum.into(allowed, %{}, fn %{id: id, name: name, arguments: args} ->
        # :pre_tool_use hook may rewrite args or veto.
        case Tau.Hooks.Dispatcher.run(
               :pre_tool_use,
               hook_payload(data, :pre_tool_use, %{
                 tool_name: name,
                 tool_call_id: id,
                 tool_input: args
               })
             ) do
          {:halt, reason} ->
            denied =
              ToolResult.new(
                tool_call_id: id,
                tool_name: name,
                content: "Hook blocked: #{inspect(reason)}",
                is_error: true
              )

            Process.send(parent, {:tool_done, id, denied}, [])
            {id, :hook_blocked}

          {:deny, reason} ->
            denied =
              ToolResult.new(
                tool_call_id: id,
                tool_name: name,
                content: "Hook denied: #{reason}",
                is_error: true
              )

            Process.send(parent, {:tool_done, id, denied}, [])
            {id, :hook_denied}

          {:cont, payload} ->
            args = Map.get(payload, :tool_input, args)
            spawn_tool_task(name, id, args, data, parent)
        end
      end)

    # Filter out the synthesised :hook_blocked / :hook_denied entries — they
    # already reported via :tool_done.
    real_tasks =
      tasks
      |> Enum.reject(fn {_id, v} -> v in [:hook_blocked, :hook_denied] end)
      |> Enum.into(%{})

    initial_in_flight =
      Map.merge(real_tasks, Enum.into(gated, %{}, fn %{id: id} -> {id, :denied} end))

    {:next_state, :tool_executing,
     %{data | tools_in_flight: initial_in_flight, provider_task: nil, assembler: nil}}
  end

  defp spawn_tool_task(name, id, args, data, parent) do
    task =
      Task.Supervisor.async_nolink(Tau.Tools.TaskSupervisor, fn ->
        run_tool(name, id, args, data)
      end)

    broadcast(data.id, %Events.ToolStart{
      session_id: data.id,
      tool_call_id: id,
      name: name,
      arguments: args
    })

    # Convert task completion into our :tool_done message.
    spawn_link(fn ->
      result =
        try do
          Task.await(task, :infinity)
        catch
          :exit, reason ->
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

    {id, task}
  end

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

    task =
      Task.Supervisor.async_nolink(Tau.Tools.TaskSupervisor, fn ->
        try do
          mod.execute(args, ctx)
        rescue
          e -> {:crashed, Exception.message(e)}
        catch
          kind, value -> {:crashed, "uncaught #{kind}: #{inspect(value)}"}
        end
      end)

    spawn_link(fn ->
      result =
        case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, r} -> r
          nil -> {:timeout, timeout_ms}
          {:exit, reason} -> {:crashed, inspect(reason)}
        end

      Process.send(parent, {:command_done, result, msg}, [])
    end)

    {:keep_state, %{data | command_task: task}}
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

      _ ->
        msg
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
