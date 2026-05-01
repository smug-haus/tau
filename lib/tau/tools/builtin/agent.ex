defmodule Tau.Tools.Builtin.Agent do
  @moduledoc """
  Spawn a sub-agent — an isolated child `Tau.Session` — and await its
  result.

  This is the v1.0 sub-agents centerpiece (ADR-0014, ADR-0015, issue #32).
  The model emits an `Agent` tool call with a brief; this tool stands up
  a child session under `Tau.Sessions.Supervisor`, sends the brief, and
  returns the child's first `:end_turn` assistant text as the parent's
  `ToolResult.content`. The parent's transcript records the
  ToolResult; the child's full transcript stays addressable by its
  session id.

  ## Algorithm

    1. Resolve `subagent_type` → `%Tau.Skill{}` via `data.skills`
       (snapshot of the parent). Unknown name → `is_error` ToolResult.
       Omitted → `general-purpose` (no persona, full tools).
    2. Dispatch the `:subagent_start` hook (declared on `Tau.Hook`
       since day one). `:halt`/`:deny` → `is_error` ToolResult.
    3. Compute the child's permissions mode: `Tau.Permissions.Mode.clamp/2`
       against the parent. The child can request stricter, never
       broader. A clamp emits `[:tau, :permissions, :ceiling_clamped]`
       telemetry.
    4. `Tau.start_session/1` with inherited `cwd`, `provider`, `model`,
       `provider_ctx`; `:tools_whitelist` from the skill's `allowed_tools`
       (or `:all`); `:active_skill` + `:persona_lifetime: :session` per
       ADR-0015 so the persona stays pinned for the child's life.
    5. Subscribe to `"session:\#{child_id}"` PubSub, register the child
       with the parent FSM (cascade-cancel via `Tau.register_child/2`),
       monitor the parent's pid (cascade in the OTHER direction —
       parent dies → cancel child), send the brief.
    6. Await the child's `%MessageEnd{stop_reason: :end_turn}`. Return
       its assistant text as the parent's ToolResult content. On
       `%SessionEnd{}` before `:end_turn` (the child crashed or was
       cancelled), return `is_error: true`.

  ## Telemetry

  Span semantics (CLAUDE.md non-negotiable #5):

    * `[:tau, :session, :subagent, :start]`
    * `[:tau, :session, :subagent, :stop]`
    * `[:tau, :session, :subagent, :exception]`

  Plus `[:tau, :permissions, :ceiling_clamped]` when the requested mode
  was clamped against the parent.

  ## OTP placement

    * The Agent tool's `execute/2` runs inside a per-call task spawned
      under `Tau.Tools.TaskSupervisor` by the session FSM's parallel
      tool dispatcher (#33). No new supervisor.
    * No `Manager`/`Service` GenServer (CLAUDE.md non-negotiable #1) —
      the child session FSM IS the per-spawn process.
    * Cancellation cascade is parent-FSM-driven (#92) plus a
      `Process.monitor/1` from inside this task on the parent's pid
      (ADR-0008: tool tasks own their own monitors, not the FSM).

  ## See also

    * `docs/adr/0014-subagents-are-sessions.md`
    * `docs/adr/0015-subagent-persona-is-a-skill.md`
    * `Tau.Permissions.Mode` — the clamp helper.
    * Issue #32 — the spec body.
  """

  @behaviour Tau.Tool

  alias Tau.Message.Assistant
  alias Tau.Session.Events, as: SE
  alias Tau.Tool.Result

  @general_purpose "general-purpose"

  # Bounded await for the child's `:end_turn`. Sub-agents are model
  # turns; their unbounded counterpart is the parent's. We use a
  # generous default and let the parent FSM cascade `:cancel` if the
  # parent itself is cancelled or crashes.
  @await_timeout_ms 10 * 60 * 1000

  @impl Tau.Tool
  def name, do: "Agent"

  @impl Tau.Tool
  def description do
    "Spawn a sub-agent with an isolated session, optional persona (`subagent_type` resolves to a skill), " <>
      "and an inherited-or-tighter permissions mode. The sub-agent runs to its first `:end_turn` and " <>
      "returns its assistant text as this tool's result. Sub-agent crashes never crash the parent — they " <>
      "surface as `is_error: true`. Use for delegated read-only investigation (`Explore`), planning, or " <>
      "any task the parent wants to do in a fresh context with restricted tools."
  end

  @impl Tau.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "description" => %{
          "type" => "string",
          "description" => "The brief sent as the sub-agent's first user message. Required."
        },
        "system_prompt" => %{
          "type" => "string",
          "description" =>
            "Optional addendum prepended to the sub-agent's brief. Layered on top of the resolved skill body."
        },
        "subagent_type" => %{
          "type" => "string",
          "description" =>
            "Optional skill name to install as the sub-agent's persona. Resolves against the parent's skills registry. Omit for a general-purpose sub-agent (full tools, no persona)."
        },
        "permissions_mode" => %{
          "type" => "string",
          "enum" => ["default", "accept_edits", "plan", "auto", "dont_ask", "bypass"],
          "description" =>
            "Optional. Requested permissions mode for the sub-agent. Clamped against the parent — the child can never escalate."
        }
      },
      "required" => ["description"],
      "additionalProperties" => false
    }
  end

  @impl Tau.Tool
  def execution_mode, do: :parallel

  @impl Tau.Tool
  def streams_updates?, do: false

  @impl Tau.Tool
  def execute(%{"description" => description} = params, ctx) do
    started = System.monotonic_time(:millisecond)
    subagent_type = Map.get(params, "subagent_type")
    requested_mode = parse_mode(Map.get(params, "permissions_mode"))
    system_prompt = Map.get(params, "system_prompt")

    with {:ok, parent_snap} <- snapshot_parent(ctx.session_id),
         {:ok, skill} <- resolve_skill(subagent_type, parent_snap.skills),
         :cont <- run_subagent_start_hook(ctx, parent_snap, params, skill) do
      parent_mode = Map.get(parent_snap.metadata || %{}, :permissions_mode, :default)
      child_mode = clamp_with_telemetry(requested_mode, parent_mode, ctx, subagent_type)

      brief = build_brief(description, system_prompt)
      whitelist = whitelist_from(skill)

      :telemetry.execute(
        [:tau, :session, :subagent, :start],
        %{system_time: System.system_time()},
        %{
          parent_session_id: ctx.session_id,
          parent_tool_call_id: ctx.tool_call_id,
          subagent_type: subagent_type,
          permissions_mode: child_mode
        }
      )

      child_metadata = %{
        parent_session_id: ctx.session_id,
        parent_tool_call_id: ctx.tool_call_id,
        subagent_type: subagent_type || @general_purpose,
        permissions_mode: child_mode
      }

      start_opts =
        [
          cwd: parent_snap.cwd,
          provider: parent_snap.provider,
          model: parent_snap.model,
          metadata: child_metadata,
          tools_whitelist: whitelist,
          # Only pin a persona when one was actually resolved. A
          # `general-purpose` sub-agent runs without an active_skill so
          # the global rule set is the only gate (modulo the clamped
          # mode + whitelist).
          active_skill: skill,
          persona_lifetime: if(skill, do: :session, else: :turn)
        ]
        |> maybe_inherit_provider_ctx(ctx, parent_snap)

      with {:ok, child_id} <- Tau.start_session(start_opts) do
        # Subscribe BEFORE sending the brief so we don't race the
        # child's MessageEnd — `Tau.start_session/1` is synchronous;
        # the FSM is registered and broadcasting before we proceed.
        Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{child_id}")
        :ok = Tau.register_child(ctx.session_id, child_id)

        parent_pid =
          case Registry.lookup(Tau.Sessions.Registry, ctx.session_id) do
            [{pid, _}] -> pid
            _ -> nil
          end

        # ADR-0008: monitor lives in this tool task, NOT the FSM.
        parent_ref = parent_pid && Process.monitor(parent_pid)

        :ok = Tau.send(child_id, brief)

        result = await_child(child_id, ctx, parent_ref, started)

        # Best-effort: drop the child from the parent's cascade set.
        # Cast semantics — silently no-ops if the parent is already
        # gone, which matches the contract of `Tau.unregister_child/2`.
        Tau.unregister_child(ctx.session_id, child_id)
        if parent_ref, do: Process.demonitor(parent_ref, [:flush])

        :telemetry.execute(
          [:tau, :session, :subagent, :stop],
          %{duration: System.monotonic_time(:millisecond) - started},
          %{
            parent_session_id: ctx.session_id,
            child_session_id: child_id,
            subagent_type: subagent_type,
            is_error: result.is_error
          }
        )

        {:ok, result}
      else
        {:error, reason} ->
          :telemetry.execute(
            [:tau, :session, :subagent, :exception],
            %{duration: System.monotonic_time(:millisecond) - started},
            %{
              parent_session_id: ctx.session_id,
              subagent_type: subagent_type,
              error: inspect(reason)
            }
          )

          {:ok,
           Result.error("Failed to spawn sub-agent: #{inspect(reason)}",
             details: %{
               kind: :spawn_error,
               subagent_type: subagent_type
             }
           )}
      end
    else
      {:error, {:unknown_subagent_type, name}} ->
        {:ok,
         Result.error("Unknown subagent_type: #{name}",
           details: %{kind: :unknown_subagent_type, subagent_type: name}
         )}

      {:error, :parent_not_found} ->
        {:ok,
         Result.error("Parent session not found",
           details: %{kind: :parent_not_found}
         )}

      {:halt, reason} ->
        :telemetry.execute(
          [:tau, :session, :subagent, :exception],
          %{duration: System.monotonic_time(:millisecond) - started},
          %{
            parent_session_id: ctx.session_id,
            subagent_type: subagent_type,
            error: "hook_halt: #{inspect(reason)}"
          }
        )

        {:ok,
         Result.error("Sub-agent spawn blocked by hook: #{inspect(reason)}",
           details: %{kind: :hook_halt}
         )}

      {:deny, reason} ->
        :telemetry.execute(
          [:tau, :session, :subagent, :exception],
          %{duration: System.monotonic_time(:millisecond) - started},
          %{
            parent_session_id: ctx.session_id,
            subagent_type: subagent_type,
            error: "hook_deny: #{reason}"
          }
        )

        {:ok,
         Result.error("Sub-agent spawn denied by hook: #{reason}",
           details: %{kind: :hook_deny}
         )}
    end
  end

  # --- Internals ------------------------------------------------------------

  defp snapshot_parent(parent_id) do
    case Tau.snapshot(parent_id) do
      {:ok, snap} -> {:ok, snap}
      {:error, :not_found} -> {:error, :parent_not_found}
    end
  end

  # `subagent_type == nil` → no persona. `general-purpose` is special-cased
  # so the model can name it explicitly without us looking it up as a
  # skill (it doesn't need to exist on disk).
  defp resolve_skill(nil, _skills), do: {:ok, nil}
  defp resolve_skill(@general_purpose, _skills), do: {:ok, nil}

  defp resolve_skill(name, skills) when is_binary(name) and is_list(skills) do
    case List.keyfind(skills, name, 0) do
      {^name, %Tau.Skill{} = skill} -> {:ok, skill}
      _ -> {:error, {:unknown_subagent_type, name}}
    end
  end

  defp run_subagent_start_hook(ctx, parent_snap, params, skill) do
    payload = %{
      session_id: ctx.session_id,
      parent_session_id: ctx.session_id,
      parent_tool_call_id: ctx.tool_call_id,
      cwd: parent_snap.cwd,
      permission_mode: Map.get(parent_snap.metadata || %{}, :permissions_mode, :default),
      hook_event_name: "subagent_start",
      transcript_path: nil,
      metadata: parent_snap.metadata || %{},
      subagent_type: Map.get(params, "subagent_type"),
      brief: Map.get(params, "description"),
      system_prompt: Map.get(params, "system_prompt"),
      permissions_mode: parse_mode(Map.get(params, "permissions_mode")),
      skill_name: skill && skill.name
    }

    case Tau.Hooks.Dispatcher.run(:subagent_start, payload) do
      {:cont, _payload} -> :cont
      {:halt, _} = h -> h
      {:deny, _} = d -> d
    end
  end

  defp clamp_with_telemetry(nil, parent_mode, _ctx, _subagent_type), do: parent_mode

  defp clamp_with_telemetry(requested, parent_mode, ctx, subagent_type) do
    effective = Tau.Permissions.Mode.clamp(requested, parent_mode)

    if effective != requested do
      :telemetry.execute(
        [:tau, :permissions, :ceiling_clamped],
        %{system_time: System.system_time()},
        %{
          parent_session_id: ctx.session_id,
          parent_tool_call_id: ctx.tool_call_id,
          subagent_type: subagent_type,
          requested: requested,
          parent: parent_mode,
          effective: effective
        }
      )
    end

    effective
  end

  defp parse_mode(nil), do: nil

  defp parse_mode(s) when is_binary(s) do
    try do
      atom = String.to_existing_atom(s)
      if Tau.Permissions.Mode.mode?(atom), do: atom, else: nil
    rescue
      _ -> nil
    end
  end

  defp parse_mode(a) when is_atom(a), do: a

  # Skill `allowed_tools` of `[]` means "no whitelist declared" (matches
  # the loader contract); `:all` is the right value to pass on then so
  # the child has full tool access.
  defp whitelist_from(nil), do: :all
  defp whitelist_from(%Tau.Skill{allowed_tools: []}), do: :all
  defp whitelist_from(%Tau.Skill{allowed_tools: list}) when is_list(list), do: list

  defp build_brief(description, nil), do: description
  defp build_brief(description, ""), do: description

  defp build_brief(description, system_prompt) when is_binary(system_prompt) do
    system_prompt <> "\n\n" <> description
  end

  # Inherit the parent's `provider_ctx` so child runs see the same
  # replay fixtures / per-session routing tags. The parent snapshot
  # doesn't expose `provider_ctx` directly (deliberate — see
  # `Tau.Session.snapshot/1`'s typespec for what's promised), so we
  # read it through the registered pid the same way `snapshot/1` does.
  defp maybe_inherit_provider_ctx(opts, ctx, _parent_snap) do
    case Registry.lookup(Tau.Sessions.Registry, ctx.session_id) do
      [{pid, _}] ->
        {_state, data} = :sys.get_state(pid)
        Keyword.put(opts, :provider_ctx, data.provider_ctx || %{})

      _ ->
        opts
    end
  end

  # --- Awaiting the child's :end_turn --------------------------------------

  defp await_child(child_id, ctx, parent_ref, started) do
    receive do
      %SE.MessageEnd{session_id: ^child_id, message: %Assistant{} = msg} ->
        cond do
          msg.stop_reason == :end_turn ->
            content = extract_text(msg)

            Result.text(content,
              details: %{
                kind: :subagent_result,
                child_session_id: child_id,
                stop_reason: :end_turn,
                duration_ms: System.monotonic_time(:millisecond) - started
              }
            )

          msg.stop_reason in [:error, :aborted] ->
            Result.error(
              "Sub-agent ended without :end_turn (stop_reason: #{inspect(msg.stop_reason)}). " <>
                (msg.error_message || ""),
              details: %{
                kind: :subagent_failed,
                child_session_id: child_id,
                stop_reason: msg.stop_reason
              }
            )

          true ->
            # `:tool_use` etc. — keep waiting for the next MessageEnd.
            await_child(child_id, ctx, parent_ref, started)
        end

      %SE.SessionEnd{session_id: ^child_id, reason: reason} ->
        Result.error(
          "Sub-agent session ended before :end_turn (#{inspect(reason)})",
          details: %{
            kind: :subagent_session_end,
            child_session_id: child_id,
            reason: inspect(reason)
          }
        )

      %SE.Cancelled{session_id: ^child_id} ->
        # Cancelled returns to :awaiting_user; the FSM does NOT
        # terminate. Wait for the eventual SessionEnd cascaded by the
        # parent, or another MessageEnd if the parent un-cancels.
        await_child(child_id, ctx, parent_ref, started)

      {:DOWN, ^parent_ref, :process, _pid, _reason} ->
        # Parent died. Cascade-cancel the child to flush its persistence
        # then return an is_error. The FSM cancel cast is fire-and-
        # forget; a real shutdown is observed via `%SessionEnd{}` on
        # the child's topic — but our parent is already gone, so the
        # tool task is on borrowed time too. Return promptly.
        Tau.cancel(child_id)

        Result.error(
          "Sub-agent aborted: parent session terminated",
          details: %{kind: :parent_down, child_session_id: child_id}
        )
    after
      @await_timeout_ms ->
        Tau.cancel(child_id)

        Result.error(
          "Sub-agent timed out after #{@await_timeout_ms}ms",
          details: %{
            kind: :subagent_timeout,
            child_session_id: child_id,
            timeout_ms: @await_timeout_ms
          }
        )
    end
  end

  defp extract_text(%Assistant{content: blocks}) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{type: :text, text: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp extract_text(_), do: ""
end
