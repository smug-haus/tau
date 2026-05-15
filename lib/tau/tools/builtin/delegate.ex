defmodule Tau.Tools.Builtin.Delegate do
  @moduledoc """
  Hand a subtask off to an external coding-agent backend (Claude Code,
  Aider, …) via the `Tau.CodingAgent` substrate.

  Phase 2 of SPEC-CODING-AGENT §7 Q2: the provider conversation's
  planner emits a `Delegate` tool call; this tool stands up a
  `Tau.CodingAgent.Dispatcher` against the requested adapter, drains
  its event stream synchronously, and folds the assembled final text
  + intermediate tool activity back into the parent's transcript as
  a `ToolResult`.

  Mirrors `Tau.Tools.Builtin.Agent` in spirit (sub-agent dispatch) but
  the worker is a child **OS subprocess** rather than a child
  `Tau.Session`. The contract differences are deliberate:

  * Stateless. Each call starts a fresh coding-agent session. Resume
    (`--resume <id>`) is reserved for the session-mode surface
    (SPEC §7 Q5); the Delegate surface does not persist resume ids
    between calls.
  * Recursion-limited. A Delegate-from-within-Delegate is allowed up
    to `@max_depth` levels; deeper calls fail with `is_error: true`.
  * Workspace-explicit. The tool defaults to a per-task git worktree
    (D-033, SPEC §4 B3); an opt-in `workspace` parameter pins a
    caller-provided absolute path instead.

  ## Algorithm

    1. Resolve `agent` → adapter module via the whitelist below.
       Unknown agent → `is_error` ToolResult.
    2. Check depth against `@max_depth`. Over the cap → `is_error`.
    3. Prepare the workspace. If the caller supplied an absolute
       path, use it; otherwise pick the default backend for the
       session's cwd (Git when a repo is present, Cwd otherwise) and
       call `Workspace.prepare/1`.
    4. Build the `Tau.CodingAgent.task()` and start a dispatcher
       under `Tau.CodingAgent.Supervisor`. Subscribe to its event
       stream (`{:coding_agent_event, pid, _}` mailbox).
    5. Drain the stream up to the per-call `timeout_ms` (default 10
       minutes — generous, since coding-agent runs are long). On
       timeout, cooperatively cancel the dispatcher and return the
       partial trace as `is_error: true`.
    6. Monitor the parent session pid. If the parent dies mid-run
       (e.g. user pressed ESC), cancel the dispatcher and return a
       partial+is_error result; the dispatcher's own cancel path
       (D-032) takes the subprocess down within 250ms grace + SIGKILL.
    7. Clean up the workspace (no-op for `Workspace.Cwd`; `git
       worktree remove` for `Workspace.Git`).

  ## Why this tool exists separately from `Agent`

  `Agent` spawns a child `Tau.Session` driven by tau's own
  `Tau.Provider` stack — it consumes the user's API credits. Delegate
  spawns a child OS process that talks to its own subscription
  surface (Claude Code's bundled Pro/Max plan, Aider's local LLM,
  etc.). The two surfaces co-exist; choosing between them is a model-
  / planner-level decision driven by cost vs. capability.

  See SPEC-CODING-AGENT §0 and §7 Q2 for the user-facing rationale,
  Appendix B for why this is not "just another `Tau.Provider`".

  ## Permission integration

  Permissions are evaluated by `Tau.Permissions.Evaluator` **before**
  `execute/2` runs (D-035-adjacent — the Evaluator synthesises an
  `is_error` ToolResult when a call is denied; this tool never sees
  the call in that case). Scope strings are tool-name-and-agent
  shaped:

      permissions:
        allow: ["Delegate(claude_code)"]   # one specific adapter
        allow: ["Delegate(*)"]              # any adapter (glob)
        deny:  ["Delegate(replay)"]         # blocklist a test surface

  The `Tau.Permissions.Matchers.Glob` matcher reads the `agent` field
  from this tool's args as its `arg_for/2` value (registered there
  alongside `Bash(command)` and `Read(path)`).

  ## Cost folding

  Coding-agent runs that report cost emit `%Tau.CodingAgent.Event.Cost{}`
  events. The dispatcher's per-event telemetry (`[:tau, :coding_agent,
  :event]`) carries the adapter module in its metadata, and Phase 1B
  Team D's session-cost aggregator subscribes to those events to fold
  the line items into `Tau.Cost.Tracker` tagged by adapter (separate
  bucket from `Tau.Provider`-direct usage, per SPEC §7 Q4). The
  Delegate tool does NOT touch the cost path directly — it only
  surfaces the cost summary in the ToolResult's `:details` so the
  audit log and TUI can show it inline.

  ## Telemetry

    * `[:tau, :tool, :delegate, :start]`     — system_time + agent
    * `[:tau, :tool, :delegate, :stop]`      — duration + outcome
    * `[:tau, :tool, :delegate, :exception]` — depth-exceeded / unknown agent

  Plus the underlying `[:tau, :coding_agent, :start | :event | :stop]`
  emitted by the dispatcher.

  ## See also

    * `docs/spec/SPEC-CODING-AGENT.md` — locked contracts; D-031..D-036
    * `Tau.CodingAgent` — behaviour the adapter implements
    * `Tau.CodingAgent.Dispatcher` — owns the run lifecycle
    * `Tau.CodingAgent.Workspace` — worktree vs cwd selection
    * `Tau.Tools.Builtin.Agent` — sibling sub-agent tool (in-BEAM)
  """

  @behaviour Tau.Tool

  alias Tau.CodingAgent.Dispatcher
  alias Tau.CodingAgent.Event
  alias Tau.CodingAgent.Supervisor, as: CASup
  alias Tau.CodingAgent.Workspace
  alias Tau.Tool.Result

  @adapters %{
    "claude_code" => Tau.CodingAgents.ClaudeCode,
    "replay" => Tau.CodingAgents.Replay
  }

  # SPEC-CODING-AGENT §6 D-037 (this PR): a Delegate chain bottoms
  # out at depth 2 — i.e. the initial Delegate is depth 0, a
  # Delegate-within-Delegate is depth 1, the third call (depth 2)
  # is refused. This mirrors the `tau-context` MCP server's
  # `tau_delegate` cap (dispatcher.ex `tau_context_max_depth`).
  @max_depth 2

  # Generous default. Coding-agent runs are minutes-scale, not
  # seconds-scale; the dispatcher's per-event inactivity timeout
  # (default 120s) catches stalled subprocesses long before this.
  @default_timeout_ms 10 * 60 * 1000

  @impl Tau.Tool
  def name, do: "Delegate"

  @impl Tau.Tool
  def description do
    "Delegate a self-contained subtask to an external coding agent " <>
      "(Claude Code, Replay test fixture). The agent runs end-to-end " <>
      "in its own workspace, performs its own tool calls/edits, and " <>
      "returns a final assistant message + audit summary. Use for " <>
      "implementation work the planner wants to hand off; the agent " <>
      "operates under its own subscription, not tau's provider " <>
      "credits. Each call is stateless — no session resume."
  end

  @impl Tau.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "prompt" => %{
          "type" => "string",
          "description" => "The subtask description sent to the coding agent."
        },
        "agent" => %{
          "type" => "string",
          "enum" => Map.keys(@adapters),
          "description" =>
            "Adapter identifier. `claude_code` is the real Claude Code CLI; " <>
              "`replay` is the in-tree test fixture."
        },
        "workspace" => %{
          "type" => "string",
          "description" =>
            "Optional absolute path the agent should operate in. " <>
              "If omitted, a per-task git worktree is created under the " <>
              "session's cwd (default) or the cwd is used directly when " <>
              "not in a git repo."
        },
        "allowed_tools" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Optional whitelist passed to the coding agent to restrict " <>
              "its tool palette (adapter-dependent; ignored when the " <>
              "adapter declares `tool_restriction: false`)."
        },
        "timeout_ms" => %{
          "type" => "integer",
          "minimum" => 1_000,
          "description" => "Optional per-call wall-clock cap; default 600_000 (10 min)."
        },
        "depth" => %{
          "type" => "integer",
          "minimum" => 0,
          "description" =>
            "Recursion depth set by the caller. The initial Delegate " <>
              "call is depth 0; a Delegate-within-Delegate is depth 1. " <>
              "Calls at or above max_depth (#{@max_depth}) are rejected."
        }
      },
      "required" => ["prompt", "agent"],
      "additionalProperties" => false
    }
  end

  # Delegate runs are long; per-call serialisation lets the FSM and
  # the user keep a coherent view of what the agent is doing. Two
  # concurrent Delegate calls in the same turn would also race on
  # workspace creation (SPEC §3 [C2-B3]).
  @impl Tau.Tool
  def execution_mode, do: :sequential

  @impl Tau.Tool
  def streams_updates?, do: false

  @impl Tau.Tool
  def execute(%{"prompt" => prompt, "agent" => agent_name} = params, ctx) do
    started_mono = System.monotonic_time(:millisecond)
    depth = params |> Map.get("depth", 0) |> normalise_depth()
    timeout_ms = Map.get(params, "timeout_ms", @default_timeout_ms)

    emit_start_telemetry(agent_name, depth, ctx)

    with {:ok, adapter} <- resolve_adapter(agent_name),
         :ok <- check_depth(depth),
         {:ok, workspace_struct, workspace_path} <- resolve_workspace(params, ctx) do
      do_dispatch(%{
        adapter: adapter,
        agent_name: agent_name,
        prompt: prompt,
        params: params,
        ctx: ctx,
        depth: depth,
        timeout_ms: timeout_ms,
        workspace_struct: workspace_struct,
        workspace_path: workspace_path,
        started_mono: started_mono
      })
    else
      {:error, {:unknown_agent, name}} ->
        emit_exception_telemetry(agent_name, :unknown_agent, started_mono)

        {:ok,
         Result.error(
           "Unknown coding-agent identifier: #{inspect(name)}. " <>
             "Known: #{Enum.join(Map.keys(@adapters), ", ")}.",
           details: %{kind: :unknown_agent, agent: name}
         )}

      {:error, {:depth_exceeded, d}} ->
        emit_exception_telemetry(agent_name, :depth_exceeded, started_mono)

        {:ok,
         Result.error(
           "Delegate recursion limit reached (depth=#{d}, max=#{@max_depth}). " <>
             "Each Delegate-within-Delegate adds a level; restructure the " <>
             "subtask to flatten the chain.",
           details: %{kind: :depth_exceeded, depth: d, max_depth: @max_depth}
         )}

      {:error, {:workspace, reason}} ->
        emit_exception_telemetry(agent_name, :workspace_error, started_mono)

        {:ok,
         Result.error(
           "Workspace preparation failed: #{inspect(reason)}",
           details: %{kind: :workspace_error, reason: reason}
         )}
    end
  end

  # --- Internals: dispatch ---------------------------------------------------

  defp do_dispatch(%{
         adapter: adapter,
         agent_name: agent_name,
         prompt: prompt,
         params: params,
         ctx: ctx,
         depth: depth,
         timeout_ms: timeout_ms,
         workspace_struct: workspace_struct,
         workspace_path: workspace_path,
         started_mono: started_mono
       }) do
    task = build_task(prompt, params, workspace_path, timeout_ms, ctx)
    dispatcher_ctx = build_dispatcher_ctx(ctx, depth)

    args = [
      adapter: adapter,
      task: task,
      ctx: dispatcher_ctx,
      subscriber: self()
    ]

    case CASup.start_dispatcher(args) do
      {:ok, dispatcher_pid} ->
        parent_ref = monitor_parent(ctx)

        outcome =
          drain(dispatcher_pid, parent_ref, timeout_ms, %{
            agent: agent_name,
            adapter: adapter,
            events: [],
            assistant_text: [],
            tool_uses: [],
            tool_results: [],
            file_edits: [],
            cost: nil,
            error: nil,
            done: nil,
            timed_out?: false,
            cancelled_by_parent?: false
          })

        if parent_ref, do: Process.demonitor(parent_ref, [:flush])

        # Workspace cleanup: only when we created it. A user-supplied
        # path is the user's to manage.
        if workspace_struct, do: Workspace.cleanup(workspace_struct)

        emit_stop_telemetry(agent_name, outcome, started_mono)
        {:ok, finalize_result(outcome, workspace_path)}

      {:error, reason} ->
        # The supervisor refused to start a child — typically a
        # restart-intensity trip or a broken `init/1`. Surface as
        # `is_error` so the model sees the failure.
        emit_exception_telemetry(agent_name, {:supervisor_start_failed, reason}, started_mono)

        if workspace_struct, do: Workspace.cleanup(workspace_struct)

        {:ok,
         Result.error("Failed to start coding-agent dispatcher: #{inspect(reason)}",
           details: %{kind: :dispatcher_start_failed, reason: reason}
         )}
    end
  end

  defp build_task(prompt, params, workspace_path, timeout_ms, ctx) do
    base = %{
      prompt: prompt,
      workspace: workspace_path,
      session_id: ctx.session_id,
      resume_id: nil,
      allowed_tools: normalise_allowed_tools(Map.get(params, "allowed_tools")),
      mcp_servers: [],
      timeout: timeout_ms
    }

    # Pass through the Replay adapter's fixture knob when the caller
    # supplied one (test ergonomics; ignored by real adapters).
    case Map.fetch(params, "replay_fixture") do
      {:ok, fixture} -> Map.put(base, :replay_fixture, fixture)
      :error -> base
    end
  end

  defp build_dispatcher_ctx(ctx, depth) do
    base = %{
      session_id: ctx.session_id,
      request_id: ctx.tool_call_id,
      # Forward depth+1 to the spawned tau-context MCP server so a
      # recursive `tau_delegate` from the coding agent respects the
      # same ceiling. Phase 1B Team C's TauContext reads this key
      # via the dispatcher.
      tau_context_max_depth: max(@max_depth - depth, 0)
    }

    # Tests can widen / narrow the dispatcher's inactivity window
    # and inject Replay-only knobs (delay_ms, ignore_cancel) via
    # the parent FSM's metadata. The Delegate tool forwards a fixed
    # allow-list of keys; production callers leave metadata empty.
    metadata = ctx.metadata || %{}

    Enum.reduce(
      [:inactivity_timeout_ms, :replay_delay_ms, :replay_ignore_cancel],
      base,
      fn key, acc ->
        case Map.fetch(metadata, key) do
          {:ok, v} -> Map.put(acc, key, v)
          :error -> acc
        end
      end
    )
  end

  # --- Internals: workspace --------------------------------------------------

  # Three cases:
  #   * caller-supplied absolute path  → validate, no workspace struct
  #     (we don't own its lifecycle).
  #   * caller-supplied relative path  → reject (D-033: explicit only).
  #   * absent                         → prepare a default workspace
  #     and own its cleanup.
  defp resolve_workspace(params, ctx) do
    case Map.get(params, "workspace") do
      nil ->
        cwd = ctx.cwd || File.cwd!()
        backend = Workspace.resolve_default_backend(cwd)

        opts = [
          backend: backend,
          session_id: workspace_session_id(ctx),
          cwd: cwd
        ]

        case Workspace.prepare(opts) do
          {:ok, ws} -> {:ok, ws, ws.path}
          {:error, reason} -> {:error, {:workspace, reason}}
        end

      path when is_binary(path) ->
        cond do
          Path.absname(path) != path ->
            {:error, {:workspace, {:not_absolute, path}}}

          not File.dir?(path) ->
            {:error, {:workspace, {:not_a_directory, path}}}

          true ->
            {:ok, nil, path}
        end

      other ->
        {:error, {:workspace, {:invalid_path, other}}}
    end
  end

  # Each Delegate call wants a fresh worktree (no resume). Use the
  # tool_call_id under the session_id so two Delegate calls in the
  # same session don't collide.
  defp workspace_session_id(ctx) do
    "#{ctx.session_id}-#{ctx.tool_call_id}"
  end

  # --- Internals: drain ------------------------------------------------------

  defp drain(dispatcher_pid, parent_ref, remaining_ms, acc) do
    deadline = System.monotonic_time(:millisecond) + remaining_ms
    do_drain(dispatcher_pid, parent_ref, deadline, acc)
  end

  defp do_drain(dispatcher_pid, parent_ref, deadline, acc) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:coding_agent_event, ^dispatcher_pid, event} ->
        acc = fold_event(event, acc)

        case event do
          %Event.Done{} = done ->
            %{acc | done: done}

          %Event.Error{recoverable: false} = err ->
            # The dispatcher always emits a Done after an unrecoverable
            # Error (see dispatcher.ex). Keep draining until we see it.
            do_drain(dispatcher_pid, parent_ref, deadline, %{acc | error: err})

          _ ->
            do_drain(dispatcher_pid, parent_ref, deadline, acc)
        end

      {:DOWN, ^parent_ref, :process, _pid, _reason} when not is_nil(parent_ref) ->
        # Parent session died. Cancel cooperatively; the dispatcher
        # will emit Done with exit_status: -2 which we still want to
        # observe so the workspace gets cleaned up.
        Dispatcher.cancel(dispatcher_pid)

        do_drain(
          dispatcher_pid,
          # Demonitor would arrive after this DOWN; nil it out to
          # avoid matching again.
          nil,
          deadline,
          %{acc | cancelled_by_parent?: true}
        )
    after
      timeout ->
        # Timeout — ask the dispatcher to shut down cleanly. We do
        # NOT await Done here: the workspace cleanup runs in the
        # caller path and the dispatcher's own terminate/2 reaps
        # the subprocess.
        Dispatcher.cancel(dispatcher_pid)
        %{acc | timed_out?: true}
    end
  end

  defp fold_event(%Event.Start{}, acc), do: %{acc | events: [:start | acc.events]}

  defp fold_event(%Event.AssistantText{text: t}, acc) when is_binary(t) do
    %{acc | events: [:assistant_text | acc.events], assistant_text: [t | acc.assistant_text]}
  end

  defp fold_event(%Event.ToolUse{} = ev, acc) do
    %{
      acc
      | events: [:tool_use | acc.events],
        tool_uses: [%{id: ev.id, name: ev.name, input: ev.input} | acc.tool_uses]
    }
  end

  defp fold_event(%Event.ToolResult{} = ev, acc) do
    %{
      acc
      | events: [:tool_result | acc.events],
        tool_results: [
          %{tool_use_id: ev.tool_use_id, content: ev.content, is_error: ev.is_error}
          | acc.tool_results
        ]
    }
  end

  defp fold_event(%Event.FileEdit{} = ev, acc) do
    %{
      acc
      | events: [:file_edit | acc.events],
        file_edits: [%{path: ev.path, kind: ev.kind} | acc.file_edits]
    }
  end

  defp fold_event(%Event.Cost{} = ev, acc) do
    %{
      acc
      | events: [:cost | acc.events],
        cost: %{tokens: ev.tokens, usd: ev.usd, duration_ms: ev.duration_ms}
    }
  end

  defp fold_event(%Event.Error{} = err, acc) do
    %{acc | events: [:error | acc.events], error: err}
  end

  defp fold_event(%Event.Done{} = done, acc) do
    %{acc | events: [:done | acc.events], done: done}
  end

  defp fold_event(_, acc), do: acc

  # --- Internals: result assembly --------------------------------------------

  defp finalize_result(outcome, workspace_path) do
    text = assemble_text(outcome)

    base_details = %{
      kind: :delegate_result,
      agent: outcome.agent,
      adapter: outcome.adapter,
      workspace: workspace_path,
      events_count: length(outcome.events),
      tool_uses: Enum.reverse(outcome.tool_uses),
      tool_results: Enum.reverse(outcome.tool_results),
      file_edits: Enum.reverse(outcome.file_edits),
      cost: outcome.cost,
      exit_status: outcome.done && outcome.done.exit_status,
      final_message: outcome.done && outcome.done.final_message
    }

    cond do
      outcome.timed_out? ->
        Result.error(
          timeout_message(outcome, text),
          details: Map.merge(base_details, %{kind: :delegate_timeout})
        )

      outcome.cancelled_by_parent? ->
        Result.error(
          cancel_message(text),
          details: Map.merge(base_details, %{kind: :delegate_cancelled})
        )

      outcome.error != nil ->
        Result.error(
          error_message(outcome.error, text),
          details:
            Map.merge(base_details, %{
              kind: :delegate_error,
              error_reason: inspect(outcome.error.reason)
            })
        )

      outcome.done && outcome.done.exit_status not in [0] ->
        # Non-zero exit (real or sentinel) without an explicit Error
        # event — surface as is_error with the assembled text so the
        # model has something to react to.
        Result.error(
          nonzero_message(outcome.done, text),
          details:
            Map.merge(base_details, %{
              kind: :delegate_nonzero_exit
            })
        )

      true ->
        Result.text(text, details: base_details)
    end
  end

  defp assemble_text(%{assistant_text: []} = outcome) do
    case outcome.done do
      %Event.Done{final_message: msg} when is_binary(msg) and msg != "" -> msg
      _ -> ""
    end
  end

  defp assemble_text(%{assistant_text: chunks}) do
    chunks |> Enum.reverse() |> Enum.join("")
  end

  defp timeout_message(_outcome, ""), do: "Coding-agent delegation timed out"

  defp timeout_message(_outcome, text),
    do: "Coding-agent delegation timed out. Partial output:\n\n" <> text

  defp cancel_message(""), do: "Coding-agent delegation cancelled by parent session"

  defp cancel_message(text),
    do: "Coding-agent delegation cancelled by parent session. Partial output:\n\n" <> text

  defp error_message(%Event.Error{reason: reason}, ""),
    do: "Coding-agent delegation failed: #{inspect(reason)}"

  defp error_message(%Event.Error{reason: reason}, text),
    do: "Coding-agent delegation failed: #{inspect(reason)}\n\nPartial output:\n\n" <> text

  defp nonzero_message(%Event.Done{exit_status: status, final_message: msg}, text) do
    body =
      cond do
        is_binary(msg) and msg != "" -> msg
        text != "" -> text
        true -> ""
      end

    prefix = "Coding-agent exited with status #{status}"

    case body do
      "" -> prefix
      _ -> prefix <> ":\n\n" <> body
    end
  end

  # --- Internals: misc -------------------------------------------------------

  defp resolve_adapter(name) when is_binary(name) do
    case Map.fetch(@adapters, name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_agent, name}}
    end
  end

  defp resolve_adapter(other), do: {:error, {:unknown_agent, other}}

  defp check_depth(depth) when is_integer(depth) and depth >= @max_depth,
    do: {:error, {:depth_exceeded, depth}}

  defp check_depth(_), do: :ok

  defp normalise_depth(d) when is_integer(d) and d >= 0, do: d
  defp normalise_depth(_), do: 0

  defp normalise_allowed_tools(nil), do: :all
  defp normalise_allowed_tools(:all), do: :all

  defp normalise_allowed_tools(list) when is_list(list),
    do: Enum.filter(list, &is_binary/1)

  defp normalise_allowed_tools(_), do: :all

  defp monitor_parent(ctx) do
    case Registry.lookup(Tau.Sessions.Registry, ctx.session_id) do
      [{pid, _}] -> Process.monitor(pid)
      _ -> nil
    end
  end

  # --- Internals: telemetry --------------------------------------------------

  defp emit_start_telemetry(agent_name, depth, ctx) do
    :telemetry.execute(
      [:tau, :tool, :delegate, :start],
      %{system_time: System.system_time()},
      %{
        agent: agent_name,
        depth: depth,
        session_id: ctx.session_id,
        tool_call_id: ctx.tool_call_id
      }
    )
  end

  defp emit_stop_telemetry(agent_name, outcome, started_mono) do
    is_error? =
      outcome.timed_out? or
        outcome.cancelled_by_parent? or
        outcome.error != nil or
        (outcome.done && outcome.done.exit_status != 0)

    :telemetry.execute(
      [:tau, :tool, :delegate, :stop],
      %{duration: System.monotonic_time(:millisecond) - started_mono},
      %{
        agent: agent_name,
        events_count: length(outcome.events),
        is_error: !!is_error?,
        exit_status: outcome.done && outcome.done.exit_status
      }
    )
  end

  defp emit_exception_telemetry(agent_name, reason, started_mono) do
    :telemetry.execute(
      [:tau, :tool, :delegate, :exception],
      %{duration: System.monotonic_time(:millisecond) - started_mono},
      %{agent: agent_name, reason: reason}
    )
  end
end
