defmodule Tau.Tools.Builtin.Agent do
  @moduledoc """
  Spawn a sub-agent — an isolated child `Tau.Session` — and await its
  result.

  This is the v1.0 sub-agents centerpiece (ADR-0014, ADR-0015).
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
      tool dispatcher. No new supervisor.
    * No `Manager`/`Service` GenServer (CLAUDE.md non-negotiable #1) —
      the child session FSM IS the per-spawn process.
    * Cancellation cascade is parent-FSM-driven, plus a
      `Process.monitor/1` from inside this task on the parent's pid
      (ADR-0008: tool tasks own their own monitors, not the FSM).

  ## See also

    * `docs/adr/0014-subagents-are-sessions.md`
    * `docs/adr/0015-subagent-persona-is-a-skill.md`
    * `Tau.Permissions.Mode` — the clamp helper.
  """

  @behaviour Tau.Tool

  alias Tau.Message.Assistant
  alias Tau.Session.Events, as: SE
  alias Tau.Tool.Result

  # D-150 (SPEC-TUI-HEADLESS §5c): relay child events as Subagent* on the
  # PARENT topic so the TUI EventBridge (subscribed only to the parent topic)
  # receives them. The tool task is the natural relay point — it is the one
  # process bridging child topic and parent identity.

  @general_purpose "general-purpose"

  # Bounded await for the child's `:end_turn`. Sub-agents are model
  # turns; their unbounded counterpart is the parent's. We use a
  # generous default and let the parent FSM cascade `:cancel` if the
  # parent itself is cancelled or crashes.
  #
  # Test override: set `Application.put_env(:tau, :subagent_await_timeout_ms, N)`
  # to inject a short timeout in unit tests exercising the timeout branch.
  @await_timeout_ms 10 * 60 * 1000

  defp await_timeout_ms do
    Application.get_env(:tau, :subagent_await_timeout_ms, @await_timeout_ms)
  end

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

        # D-150 (SPEC-TUI-HEADLESS §5c): emit SubagentStart on the PARENT
        # topic before sending the brief. The label is the subagent_type
        # (or "general-purpose" when nil). The parent_tool_call_id is the
        # correlation key for the B1 de-dup rule in the render layer.
        label = subagent_type || @general_purpose

        Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{ctx.session_id}", %SE.SubagentStart{
          session_id: ctx.session_id,
          subagent_id: child_id,
          kind: :builtin_agent,
          label: label,
          parent_tool_call_id: ctx.tool_call_id,
          child_session_id: child_id
        })

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

  # --- Awaiting the child's :end_turn / :stop ------------------------------
  #
  # Provider adapters (Anthropic, OpenAI, Bedrock, Gemini, etc.) normalise
  # the model's `"end_turn"` to `:stop` via their `normalise_stop/1`. Children
  # driven by a real provider therefore end with `stop_reason: :stop`, not the
  # literal `:end_turn` atom. We accept both — plus `:length` (max_tokens) and
  # `:stop_sequence` which are also natural-end terminals where the model is
  # done producing output. Failure stop_reasons are enumerated explicitly so
  # the union shrinks predictably: any unknown stop_reason continues waiting
  # for the next MessageEnd (matches Tau.CLI.drain_run_loop's D-058: enumerate
  # failures, treat everything else as natural end).

  @subagent_natural_end [:stop, :end_turn, :length, :stop_sequence]
  @subagent_failure_end [:error, :aborted, :tool_loop_aborted, :compaction_failed]

  # B2 (SPEC-TUI-HEADLESS §5c): relay child events as Subagent* on the parent
  # topic. SubagentEnd MUST be emitted on ALL FIVE terminal branches:
  #   1. natural_end (MessageEnd with natural stop_reason)
  #   2. failure_end (MessageEnd with failure stop_reason)
  #   3. SessionEnd (child FSM terminated)
  #   4. {:DOWN, parent_ref} (parent died)
  #   5. after-timeout
  # A missed branch leaves the node stuck running (AC-7 failure).
  #
  # MessageUpdate MUST be explicitly matched-and-discarded. Otherwise the
  # tool-task mailbox grows unbounded on a chatty child (B2 / F-mode).
  defp await_child(child_id, ctx, parent_ref, started) do
    receive do
      %SE.MessageEnd{session_id: ^child_id, message: %Assistant{} = msg} ->
        cond do
          msg.stop_reason in @subagent_natural_end ->
            content = extract_text(msg)
            duration = System.monotonic_time(:millisecond) - started

            broadcast_subagent_end(
              ctx.session_id,
              child_id,
              :done,
              duration,
              "completed in #{div(duration, 1000)}s"
            )

            Result.text(content,
              details: %{
                kind: :subagent_result,
                child_session_id: child_id,
                stop_reason: msg.stop_reason,
                duration_ms: duration
              }
            )

          msg.stop_reason in @subagent_failure_end ->
            duration = System.monotonic_time(:millisecond) - started

            broadcast_subagent_end(
              ctx.session_id,
              child_id,
              :failed,
              duration,
              "failed: #{inspect(msg.stop_reason)}"
            )

            Result.error(
              "Sub-agent failed (stop_reason: #{inspect(msg.stop_reason)}). " <>
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

      # Relay child ToolStart as SubagentProgress on the parent topic.
      # The child_tool_call_id is the correlation key for B1 de-dup.
      %SE.ToolStart{session_id: ^child_id, tool_call_id: tcid, name: name} ->
        Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{ctx.session_id}", %SE.SubagentProgress{
          session_id: ctx.session_id,
          subagent_id: child_id,
          activity: {:tool_call, name},
          child_tool_call_id: tcid
        })

        await_child(child_id, ctx, parent_ref, started)

      # Relay child ToolEnd as SubagentProgress (activity carries result summary).
      %SE.ToolEnd{session_id: ^child_id, tool_call_id: tcid, result: result} ->
        summary =
          if is_binary(result.content), do: String.slice(result.content, 0..80), else: ""

        Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{ctx.session_id}", %SE.SubagentProgress{
          session_id: ctx.session_id,
          subagent_id: child_id,
          activity: {:tool_result, summary},
          child_tool_call_id: tcid
        })

        await_child(child_id, ctx, parent_ref, started)

      # D-031 parity: relay child MessageEnd (non-natural) as progress.
      # Natural MessageEnd is handled above in the top clause.
      %SE.MessageEnd{session_id: ^child_id} ->
        await_child(child_id, ctx, parent_ref, started)

      # B2: explicitly discard MessageUpdate — never forward, never accumulate.
      # The child may emit one per token; ignoring keeps the mailbox bounded.
      %SE.MessageUpdate{session_id: ^child_id} ->
        await_child(child_id, ctx, parent_ref, started)

      # Terminal branch 3: SessionEnd.
      %SE.SessionEnd{session_id: ^child_id, reason: reason} ->
        duration = System.monotonic_time(:millisecond) - started

        broadcast_subagent_end(
          ctx.session_id,
          child_id,
          :failed,
          duration,
          "session ended: #{inspect(reason)}"
        )

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

      # Terminal branch 4: parent died.
      {:DOWN, ^parent_ref, :process, _pid, _reason} ->
        # Parent died. Cascade-cancel the child to flush its persistence
        # then return an is_error. The FSM cancel cast is fire-and-
        # forget; a real shutdown is observed via `%SessionEnd{}` on
        # the child's topic — but our parent is already gone, so the
        # tool task is on borrowed time too. Return promptly.
        Tau.cancel(child_id)

        broadcast_subagent_end(ctx.session_id, child_id, :cancelled, 0, "parent terminated")

        Result.error(
          "Sub-agent aborted: parent session terminated",
          details: %{kind: :parent_down, child_session_id: child_id}
        )

      # B2: discard any other child-session event not explicitly
      # matched above — SystemNotice, ProviderFallback, QueueRestored,
      # CommandCatalog, etc. Without this catch-all they accumulate in the
      # tool-task mailbox and the "B2 any non-forwarded child event is
      # discarded" guarantee only partially holds.
      # MUST be the LAST receive clause so specific terminal/relay clauses
      # (MessageEnd/ToolStart/ToolEnd/MessageUpdate/SessionEnd/Cancelled/DOWN)
      # always match first.
      %{session_id: ^child_id} ->
        await_child(child_id, ctx, parent_ref, started)
    after
      # Terminal branch 5: timeout.
      await_timeout_ms() ->
        timeout = await_timeout_ms()
        Tau.cancel(child_id)

        broadcast_subagent_end(
          ctx.session_id,
          child_id,
          :cancelled,
          timeout,
          "timed out after #{div(timeout, 1000)}s"
        )

        Result.error(
          "Sub-agent timed out after #{timeout}ms",
          details: %{
            kind: :subagent_timeout,
            child_session_id: child_id,
            timeout_ms: timeout
          }
        )
    end
  end

  # Emit SubagentEnd on the parent topic. Best-effort: PubSub.broadcast
  # is fire-and-forget; a failure here does not affect the result.
  defp broadcast_subagent_end(parent_session_id, child_id, state, duration_ms, summary) do
    Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{parent_session_id}", %SE.SubagentEnd{
      session_id: parent_session_id,
      subagent_id: child_id,
      state: state,
      summary: summary
    })

    # Also emit cost with whatever duration we tracked.
    Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{parent_session_id}", %SE.SubagentCost{
      session_id: parent_session_id,
      subagent_id: child_id,
      tokens: nil,
      usd: nil,
      duration_ms: duration_ms
    })
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
