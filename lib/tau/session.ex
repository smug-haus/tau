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
    @moduledoc "Session metadata returned by `Tau.list_sessions/1`."
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
          messages: messages,
          skills: skills,
          persistence: persistence,
          persist_handle: persist_handle,
          provider_task: nil,
          assembler: nil,
          tools_in_flight: %{}
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
  def handle_event(:cast, {:user_message, msg}, _state, data) do
    msg = expand_slash_command(msg)

    case Tau.Hooks.Dispatcher.run(:user_prompt_submit, %{
           session_id: data.id,
           message: msg,
           cwd: data.cwd
         }) do
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

    case data.provider.stream(data.messages, %{model: data.model}, %{session_id: data.id}) do
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

    broadcast(data.id, %Events.Cancelled{session_id: data.id, reason: :user})
    persist_event(data, "cancellation", %{reason: "user"})

    {:next_state, :awaiting_user,
     %{data | provider_task: nil, tools_in_flight: %{}, assembler: nil}}
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
        {:ok, new_messages} ->
          data =
            persist_event(data, "compaction", %{
              before_count: length(data.messages),
              after_count: length(new_messages)
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
        case Tau.Hooks.Dispatcher.run(:pre_tool_use, %{
               session_id: data.id,
               tool_name: name,
               tool_call_id: id,
               tool_input: args,
               cwd: data.cwd
             }) do
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
      result =
        case Tau.Hooks.Dispatcher.run(
               if(result.is_error, do: :post_tool_use_failure, else: :post_tool_use),
               %{
                 session_id: data.id,
                 tool_name: name,
                 tool_call_id: id,
                 result: result
               }
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

      :error ->
        ToolResult.new(
          tool_call_id: call_id,
          tool_name: name,
          content: "Unknown tool: #{name}",
          is_error: true
        )
    end
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

  defp load_skills(cwd) do
    Tau.Skills.Loader.load_all(cwd)
    skills = Tau.Skills.Loader.list()

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

  defp event_to_message(_), do: nil

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

  # --- Slash commands -------------------------------------------------------

  defp expand_slash_command(%Tau.Message.User{content: c} = msg) when is_binary(c) do
    case Tau.Commands.Parser.parse(c) do
      {:command, name, args} ->
        case Tau.Commands.Parser.lookup(name) do
          {:ok, mod} when is_atom(mod) ->
            invoke_command(mod, name, args, msg)

          {:ok, path} when is_binary(path) ->
            invoke_file_command(path, args, msg)

          :error ->
            # Unknown slash command; pass through verbatim — the model can
            # handle it as a stylistic preface or report that it's unknown.
            msg
        end

      _ ->
        msg
    end
  end

  defp expand_slash_command(msg), do: msg

  defp invoke_command(mod, _name, args, msg) do
    if function_exported?(mod, :execute, 2) do
      case mod.execute(args, %{}) do
        {:inject, prefix} -> %Tau.Message.User{msg | content: prefix <> "\n\n" <> msg.content}
        {:replace, replacement} -> %Tau.Message.User{msg | content: replacement}
        {:run, replacement} -> %Tau.Message.User{msg | content: replacement}
        :ignore -> msg
        _ -> msg
      end
    else
      msg
    end
  end

  defp invoke_file_command(path, args, msg) do
    case File.read(path) do
      {:ok, body} -> %Tau.Message.User{msg | content: body <> "\n\n" <> args}
      _ -> msg
    end
  end
end
