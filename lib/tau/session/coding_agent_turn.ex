defmodule Tau.Session.CodingAgentTurn do
  @moduledoc """
  Coding-agent streaming helpers for `Tau.Session`.

  Encapsulates the `:coding_agent_streaming` FSM path introduced by
  SPEC-CODING-AGENT §4 B1 / D-037. A dispatcher is started under
  `Tau.CodingAgent.Supervisor`; its normalized event stream lands in the
  FSM mailbox tagged `{:coding_agent_event, pid, struct}` and is handled by
  the two public FSM-clause functions at the bottom of this module.

  ## Invariants

  - D-032: the coding-agent dispatcher is subprocess-bound to the session.
    Cancel broadcasts a synthetic `%Done{exit_status: -2}` sentinel; the
    session FSM ignores it (cancel has already broadcast `%Cancelled{}`).
  - D-035: cost-folding errors MUST NOT crash the session. `maybe_apply_cost_hook/2`
    wraps the side-effect block in `try/rescue` and continues with original data.
  - D-037: `%Assistant{}` / `%ToolResult{}` messages are appended using the same
    shapes as the provider path so TUI render, persistence, and `/resume` apply
    unchanged.
  - SPEC-CODING-AGENT §7 Q5: the adapter-side `session_id` is captured via
    `maybe_capture_coding_agent_session/2` when it first appears so a later
    `Tau.resume/1` can thread it as `task.resume_id`.
  """

  alias Tau.CodingAgent.Event, as: CAEvent
  alias Tau.CodingAgent.Workspace, as: CAWorkspace
  alias Tau.Message.{Assembler, Assistant, ToolResult}
  alias Tau.Session.Events
  alias Tau.Settings.Cache, as: SettingsCache

  # --- Public helpers -------------------------------------------------------

  @doc """
  Ensure the coding-agent workspace is ready, creating it if it does not yet
  exist.

  Returns `{:ok, data, workspace_path}` or `{:error, reason}`.
  """
  @spec ensure_coding_agent_workspace(Tau.Session.Data.t()) ::
          {:ok, Tau.Session.Data.t(), String.t()} | {:error, term()}
  def ensure_coding_agent_workspace(%{coding_agent_workspace: %CAWorkspace{} = ws} = data) do
    {:ok, data, ws.path}
  end

  def ensure_coding_agent_workspace(%{coding_agent_workspace: nil} = data) do
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

  @doc """
  Emit a synchronous pre-dispatch error as an `%Assistant{}` message with
  `stop_reason: :error` and transition to `:awaiting_user`.

  Mirrors D-009 for the provider path so the existing TUI render path works.
  """
  @spec emit_coding_agent_sync_error(Tau.Session.Data.t(), term()) ::
          Tau.Session.Data.fsm_result()
  def emit_coding_agent_sync_error(data, reason) do
    reason_str = describe_coding_agent_error(reason)

    msg =
      Assistant.new(
        stop_reason: :error,
        error_message: reason_str,
        content: [%{type: :text, text: "Error: " <> reason_str}]
      )

    data =
      data
      |> Tau.Session.append_message(msg)
      |> Tau.Session.Journal.persist("assistant_message", Tau.Session.Journal.message_to_data(msg))

    Tau.Session.broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: msg})

    :telemetry.execute(
      [:tau, :session, :coding_agent_streaming, :exception],
      %{system_time: System.system_time()},
      %{session_id: data.id, agent: data.coding_agent, reason: reason}
    )

    {:next_state, :awaiting_user,
     %{data | coding_agent_dispatcher: nil, coding_agent_pending: nil, coding_agent_blocks: []}}
  end

  @doc """
  Start a fresh dispatcher under `Tau.CodingAgent.Supervisor` and broadcast
  `MessageStart` so the TUI's `:streaming` indicator lights up immediately.

  Returns an FSM action tuple (`{:next_state, :coding_agent_streaming, ...}` or
  `{:next_state, :awaiting_user, ...}` on failure).
  """
  @spec start_coding_agent_dispatcher(Tau.Session.Data.t(), String.t()) ::
          Tau.Session.Data.fsm_result()
  def start_coding_agent_dispatcher(data, workspace_path) do
    user_text = latest_user_text(data.messages)

    resume_id = Map.get(data.coding_agent_state, :session_id)

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
          request_id: Tau.Session.generate_event_id()
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

        Tau.Session.broadcast(data.id, %Events.MessageStart{session_id: data.id, message: pending})

        ca_subagent_id = "#{data.id}:ca"
        label = agent_to_string(data.coding_agent) || "coding-agent"

        Tau.Session.broadcast(data.id, %Events.SubagentStart{
          session_id: data.id,
          subagent_id: ca_subagent_id,
          kind: :coding_agent,
          label: label,
          parent_tool_call_id: nil,
          child_session_id: nil
        })

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

  @doc """
  Dispatch a single coding-agent event, updating FSM data or finalising the turn.

  Pattern-matched on the CAEvent struct module (D-031). Returns an FSM action tuple.
  """
  @spec handle_coding_agent_event(struct(), Tau.Session.Data.t()) ::
          Tau.Session.Data.fsm_result()
  def handle_coding_agent_event(%CAEvent.Start{} = ev, data) do
    :telemetry.execute(
      [:tau, :session, :coding_agent_streaming, :adapter_start],
      %{system_time: System.system_time()},
      %{session_id: data.id, agent: data.coding_agent, version: ev.version}
    )

    data = maybe_capture_coding_agent_session(data, ev)

    {:keep_state, data}
  end

  def handle_coding_agent_event(%CAEvent.AssistantText{text: t}, data) do
    blocks = append_assistant_text(data.coding_agent_blocks, t)
    pending = %{data.coding_agent_pending | content: blocks}

    Tau.Session.broadcast(data.id, %Events.MessageUpdate{
      session_id: data.id,
      event: %CAEvent.AssistantText{text: t},
      message: pending
    })

    {:keep_state, %{data | coding_agent_blocks: blocks, coding_agent_pending: pending}}
  end

  def handle_coding_agent_event(%CAEvent.ToolUse{id: id, name: name, input: input}, data) do
    block = %{type: :tool_call, id: id, name: name, arguments: input || %{}}
    blocks = data.coding_agent_blocks ++ [block]
    pending = %{data.coding_agent_pending | content: blocks}

    Tau.Session.broadcast(data.id, %Events.MessageUpdate{
      session_id: data.id,
      event: %CAEvent.ToolUse{id: id, name: name, input: input},
      message: pending
    })

    Tau.Session.broadcast(data.id, %Events.ToolStart{
      session_id: data.id,
      tool_call_id: id,
      name: name,
      arguments: input || %{}
    })

    ca_subagent_id = "#{data.id}:ca"

    Tau.Session.broadcast(data.id, %Events.SubagentProgress{
      session_id: data.id,
      subagent_id: ca_subagent_id,
      activity: {:tool_call, name},
      child_tool_call_id: id
    })

    {:keep_state, %{data | coding_agent_blocks: blocks, coding_agent_pending: pending}}
  end

  def handle_coding_agent_event(
        %CAEvent.ToolResult{tool_use_id: tool_id, content: content, is_error: is_err},
        data
      ) do
    {data, _} = flush_pending_assistant(data, :tool_use)

    tool_result =
      ToolResult.new(
        tool_call_id: tool_id,
        tool_name: tool_name_for(data, tool_id),
        content: content,
        is_error: is_err
      )

    data =
      data
      |> Tau.Session.append_message(tool_result)
      |> Tau.Session.Journal.persist(
        "tool_result",
        Tau.Session.Journal.tool_result_to_data(tool_result)
      )

    Tau.Session.broadcast(data.id, %Events.ToolEnd{
      session_id: data.id,
      tool_call_id: tool_id,
      result: tool_result
    })

    pending =
      Assistant.new(
        provider: data.coding_agent,
        model: nil,
        api: :coding_agent,
        content: []
      )

    Tau.Session.broadcast(data.id, %Events.MessageStart{session_id: data.id, message: pending})

    {:keep_state, %{data | coding_agent_pending: pending, coding_agent_blocks: []}}
  end

  def handle_coding_agent_event(%CAEvent.FileEdit{path: path, kind: kind}, data) do
    :telemetry.execute(
      [:tau, :session, :coding_agent_streaming, :file_edit],
      %{system_time: System.system_time()},
      %{session_id: data.id, agent: data.coding_agent, path: path, kind: kind}
    )

    {:keep_state, data}
  end

  def handle_coding_agent_event(%CAEvent.Cost{} = cost, data) do
    :telemetry.execute(
      [:tau, :session, :coding_agent_streaming, :cost],
      %{
        system_time: System.system_time(),
        duration_ms: cost.duration_ms,
        usd: cost.usd || 0.0
      },
      %{session_id: data.id, agent: data.coding_agent, tokens: cost.tokens}
    )

    ca_subagent_id = "#{data.id}:ca"

    Tau.Session.broadcast(data.id, %Events.SubagentCost{
      session_id: data.id,
      subagent_id: ca_subagent_id,
      tokens: cost.tokens,
      usd: cost.usd,
      duration_ms: cost.duration_ms
    })

    {:keep_state, maybe_apply_cost_hook(data, cost)}
  end

  def handle_coding_agent_event(%CAEvent.Error{reason: reason, recoverable: rec?}, data) do
    reason_str = describe_coding_agent_error(reason)

    if rec? do
      blocks =
        data.coding_agent_blocks ++ [%{type: :text, text: "[adapter error] " <> reason_str}]

      pending = %{data.coding_agent_pending | content: blocks, error_message: reason_str}

      Tau.Session.broadcast(data.id, %Events.MessageUpdate{
        session_id: data.id,
        event: %CAEvent.Error{reason: reason, recoverable: rec?},
        message: pending
      })

      {:keep_state, %{data | coding_agent_blocks: blocks, coding_agent_pending: pending}}
    else
      pending = %{
        data.coding_agent_pending
        | error_message: reason_str,
          stop_reason: :error
      }

      {:keep_state, %{data | coding_agent_pending: pending}}
    end
  end

  def handle_coding_agent_event(%CAEvent.Done{} = done, data) do
    finalize_coding_agent_turn(done, data)
  end

  def handle_coding_agent_event(_other, data), do: {:keep_state, data}

  @doc """
  Build or extend the in-progress text block.

  AssistantText events within one turn concatenate into a single text content
  block — mirrors how Anthropic's stream-json folds text deltas.
  """
  @spec append_assistant_text(list(), String.t()) :: list()
  def append_assistant_text(blocks, t) when is_binary(t) do
    case List.last(blocks) do
      %{type: :text, text: existing} ->
        Enum.drop(blocks, -1) ++ [%{type: :text, text: existing <> t}]

      _ ->
        blocks ++ [%{type: :text, text: t}]
    end
  end

  @doc """
  Push the current pending assistant message into `data.messages`, persist, and
  broadcast `MessageEnd`. Returns `{data, msg}`. If no pending message exists,
  returns `{data, nil}`.
  """
  @spec flush_pending_assistant(Tau.Session.Data.t(), atom()) ::
          {Tau.Session.Data.t(), struct() | nil}
  def flush_pending_assistant(%{coding_agent_pending: nil} = data, _stop_reason),
    do: {data, nil}

  def flush_pending_assistant(data, stop_reason) do
    effective_stop = data.coding_agent_pending.stop_reason || stop_reason

    msg =
      Assembler.finalize(data.coding_agent_pending, data.coding_agent_blocks,
        stop_reason: effective_stop
      )

    data =
      data
      |> Tau.Session.append_message(msg)
      |> Tau.Session.Journal.persist("assistant_message", Tau.Session.Journal.message_to_data(msg))

    Tau.Session.broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: msg})

    {data, msg}
  end

  @doc """
  Finalise the coding-agent turn on `%CAEvent.Done{}`. Flushes the pending
  assistant message, emits telemetry and `SubagentEnd`, clears per-turn fields,
  and transitions to `:awaiting_user`.
  """
  @spec finalize_coding_agent_turn(struct(), Tau.Session.Data.t()) ::
          Tau.Session.Data.fsm_result()
  def finalize_coding_agent_turn(%CAEvent.Done{exit_status: status} = done, data) do
    stop_reason =
      cond do
        data.coding_agent_pending && data.coding_agent_pending.stop_reason == :error -> :error
        status == -2 -> :aborted
        status == -1 -> :error
        status == 0 -> :end_turn
        true -> :error
      end

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

    ca_subagent_id = "#{data.id}:ca"

    end_state =
      cond do
        status == -2 -> :cancelled
        stop_reason == :end_turn -> :done
        true -> :failed
      end

    end_summary =
      case end_state do
        :done -> "completed"
        :cancelled -> "cancelled"
        :failed -> "failed (exit #{status})"
      end

    Tau.Session.broadcast(data.id, %Events.SubagentEnd{
      session_id: data.id,
      subagent_id: ca_subagent_id,
      state: end_state,
      summary: end_summary
    })

    {:next_state, :awaiting_user,
     %{
       data
       | coding_agent_dispatcher: nil,
         coding_agent_pending: nil,
         coding_agent_blocks: []
     }}
  end

  @doc """
  Recover a tool name from the in-progress message's ToolUse blocks for a given
  `tool_use_id`. Falls back to `"tool"` if the ToolUse event was not observed.
  """
  @spec tool_name_for(Tau.Session.Data.t(), String.t()) :: String.t()
  def tool_name_for(data, tool_use_id) do
    blocks = (data.coding_agent_pending && data.coding_agent_pending.content) || []

    Enum.find_value(blocks, "tool", fn
      %{type: :tool_call, id: ^tool_use_id, name: n} -> n
      _ -> nil
    end)
  end

  @doc """
  Fold `%CAEvent.Cost{}` into session totals as an adapter-tagged line item
  (SPEC-CODING-AGENT §7 Q4 / D-038).

  Three side effects (append to `data.coding_agent_costs`, persist
  `coding_agent_cost` JSONL, emit `[:tau, :coding_agent, :cost]` telemetry),
  each wrapped per D-035 so a failure MUST NOT crash the session.
  """
  @spec maybe_apply_cost_hook(Tau.Session.Data.t(), struct()) :: Tau.Session.Data.t()
  def maybe_apply_cost_hook(data, %CAEvent.Cost{} = cost) do
    try do
      tagged =
        Tau.CodingAgent.Cost.from_event(cost,
          agent: data.coding_agent,
          session_id: data.id,
          adapter_session_id: Map.get(data.coding_agent_state, :session_id)
        )

      data =
        Tau.Session.Journal.persist(
          data,
          "coding_agent_cost",
          Tau.CodingAgent.Cost.to_jsonl(tagged)
        )

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

  @doc """
  Capture the adapter-side `session_id` from `%CAEvent.Start{}` when it is new
  (SPEC-CODING-AGENT §7 Q5).

  Persists a `coding_agent_session` JSONL event so a later `Tau.resume/1` can
  recover it and pass it as `task.resume_id`. No-op when `session_id` is nil or
  already known.
  """
  @spec maybe_capture_coding_agent_session(Tau.Session.Data.t(), struct()) ::
          Tau.Session.Data.t()
  def maybe_capture_coding_agent_session(data, %CAEvent.Start{session_id: nil}), do: data

  def maybe_capture_coding_agent_session(data, %CAEvent.Start{session_id: sid} = ev)
      when is_binary(sid) do
    state = data.coding_agent_state || %{session_id: nil, agent: nil}

    if state.session_id == sid do
      data
    else
      new_state = %{state | session_id: sid, agent: data.coding_agent}

      data
      |> Map.put(:coding_agent_state, new_state)
      |> Tau.Session.Journal.persist("coding_agent_session", %{
        "session_id" => sid,
        "agent" => agent_to_string(data.coding_agent),
        "version" => ev.version
      })
    end
  end

  def maybe_capture_coding_agent_session(data, _ev), do: data

  @doc """
  Translate a coding-agent atom/binary/module to a display string.
  """
  @spec agent_to_string(atom() | binary() | nil) :: String.t() | nil
  def agent_to_string(nil), do: nil
  def agent_to_string(agent) when is_atom(agent), do: Atom.to_string(agent)
  def agent_to_string(bin) when is_binary(bin), do: bin

  @doc """
  Translate a coding-agent error reason into a user-visible string.
  Mirrors `ProviderTurn.describe_provider_error/1` for the provider path.
  """
  @spec describe_coding_agent_error(term()) :: String.t()
  def describe_coding_agent_error({:workspace_prepare_failed, reason}),
    do: "Workspace preparation failed: " <> inspect(reason)

  def describe_coding_agent_error({:dispatcher_start_failed, reason}),
    do: "Coding-agent dispatcher failed to start: " <> inspect(reason)

  def describe_coding_agent_error(:cancelled), do: "cancelled"
  def describe_coding_agent_error(:inactivity_timeout), do: "Coding-agent inactivity timeout"

  def describe_coding_agent_error(other) when is_binary(other), do: other
  def describe_coding_agent_error(other), do: inspect(other)

  @doc """
  Recover the most recent adapter-side session_id from a preload event log
  (SPEC-CODING-AGENT §7 Q5).

  Walks events in order so the LAST `coding_agent_session` wins.
  """
  @spec coding_agent_state_from_preload(list()) :: map() | nil
  def coding_agent_state_from_preload(preload) when is_list(preload) do
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

  def coding_agent_state_from_preload(_), do: nil

  @doc """
  Fold persisted `coding_agent_cost` events back into in-memory records
  (SPEC-CODING-AGENT §7 Q4 / D-038).

  Skips malformed lines silently for forward-compatibility.
  """
  @spec coding_agent_costs_from_preload(list()) :: list()
  def coding_agent_costs_from_preload(preload) when is_list(preload) do
    preload
    |> Enum.filter(&match?(%{"kind" => "coding_agent_cost"}, &1))
    |> Enum.map(fn %{"data" => d} -> Tau.CodingAgent.Cost.from_jsonl(d) end)
    |> Enum.reject(&is_nil/1)
  end

  def coding_agent_costs_from_preload(_), do: []

  @doc """
  Convert a binary agent name back to an atom.

  Uses `String.to_existing_atom/1`; returns `nil` if the atom was not yet
  loaded (D-035 try/rescue site — preserved as-is).
  """
  @spec agent_to_atom(String.t() | nil) :: atom() | nil
  def agent_to_atom(nil), do: nil

  def agent_to_atom(bin) when is_binary(bin) do
    String.to_existing_atom(bin)
  rescue
    ArgumentError -> nil
  end

  @doc """
  Walk `messages` from the end to find the most recent user-supplied text.

  Skips synthetic User messages whose `metadata.role` is `:system` or
  `:compaction_summary` — these are injected by skill/memory helpers and
  should not be mistaken for the user's actual input.
  """
  @spec latest_user_text(list()) :: String.t()
  def latest_user_text(messages) do
    alias Tau.Message.User

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

  # --- FSM clause handlers ---------------------------------------------------

  @doc """
  Handle `:start_coding_agent` internal event in `:coding_agent_streaming`.

  Ensures the workspace, then starts the dispatcher. Telemetry is emitted
  at entry; failure surfaces as an `%Assistant{stop_reason: :error}` message.
  """
  @spec handle_start_coding_agent(Tau.Session.Data.t()) :: Tau.Session.Data.fsm_result()
  def handle_start_coding_agent(data) do
    Tau.Session.transition(data.id, data, :coding_agent_streaming)

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

  @doc """
  Handle `{:coding_agent_event, pid, event}` info in `:coding_agent_streaming`.

  Guards on `Tau.Session.current_run?/2` to drop stale events from superseded
  dispatchers, analogous to `stream_ref` for the provider path (ADR-0012).
  """
  @spec handle_coding_agent_event_message(pid(), struct(), Tau.Session.Data.t()) ::
          Tau.Session.Data.fsm_result()
  def handle_coding_agent_event_message(pid, event, data) do
    if Tau.Session.current_run?(data, {:coding_agent, pid}),
      do: handle_coding_agent_event(event, data),
      else: {:keep_state, data}
  end

  @doc """
  Read the default coding agent from settings (called from `Tau.Session.init/1`).
  """
  @spec coding_agent_from_settings() :: atom() | binary() | nil
  def coding_agent_from_settings do
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
end
