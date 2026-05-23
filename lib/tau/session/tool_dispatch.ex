defmodule Tau.Session.ToolDispatch do
  @moduledoc """
  Tool dispatch, permission round, and tool-loop brake helpers for `Tau.Session`.

  Encapsulates the parallel tool-dispatch contract (D-005 / AC-6 / D-060 /
  D-091 / SPEC-PERMISSION-PROMPTS §4).

  ## Invariants

  - D-005 / AC-6: per-turn tool-call iteration cap is enforced in
    `dispatch_tools/2` before dispatching the next round. `tool_iterations`
    counts dispatched rounds, not individual calls.
  - D-060: a `(tool_name, args_hash, error_message)` triple that repeats
    `tool_loop_brake_threshold` consecutive times triggers
    `emit_tool_loop_brake_abort/2`, which aborts the turn with
    `stop_reason: :tool_loop_aborted`. A successful dispatch resets the counter.
  - D-091: when an interactive session has `:ask`-verdict calls, the FSM
    enters `:awaiting_permission` and ALL calls (including pre-approved
    `:allow` calls) are held in `permission_dispatch_batch` until the last
    pending request is resolved in `finish_permission_round/1`.
  - D-035 (canonical `try/rescue` sites): `tool_args_hash/1` wraps
    `Jason.encode!/1` in `try/rescue`. `run_tool_validated/6` wraps the tool
    `execute/2` call. Both are preserved exactly — removal is out of scope.
  """

  alias Tau.Message.{Assistant, ToolResult}
  alias Tau.Session.Events

  @doc """
  Main dispatch entry-point called from `Tau.Session.ProviderTurn.finalize_assistant/2`
  and by `Tau.Session.ProviderTurn.handle_end_turn/2`.

  Runs skill-activation interception, whitelist filtering, permission evaluation,
  and either transitions to `:awaiting_permission` (interactive with `:ask` calls)
  or spawns the parallel dispatcher and transitions to `:tool_executing`.
  """
  @spec dispatch_tools(list(), Tau.Session.Data.t()) :: :gen_statem.event_handler_result()
  def dispatch_tools(tool_calls, data) do
    parent = self()

    call_lookups =
      Enum.into(tool_calls, %{}, fn %{id: id, name: name, arguments: args} ->
        {id, {name, tool_args_hash(args)}}
      end)

    {activation_calls, tool_calls} =
      Enum.split_with(tool_calls, fn %{name: name} ->
        name == Tau.Session.activate_skill_tool_name()
      end)

    {data, activated_in_flight} =
      Tau.Session.SkillActivation.handle_skill_activations(activation_calls, data, parent)

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

    {gated, ask_calls, allowed} =
      Enum.reduce(
        tool_calls,
        {[], [], []},
        fn %{name: name, arguments: args} = call, {denied, asking, allowed_acc} ->
          case Tau.Permissions.Evaluator.evaluate(rule_set, name, args, eval_ctx, mode) do
            :deny -> {[call | denied], asking, allowed_acc}
            :ask -> {denied, [call | asking], allowed_acc}
            :allow -> {denied, asking, [call | allowed_acc]}
          end
        end
      )

    gated = Enum.reverse(gated)
    ask_calls = Enum.reverse(ask_calls)
    allowed = Enum.reverse(allowed)

    Enum.each(gated, fn %{id: id, name: name} ->
      result =
        ToolResult.new(
          tool_call_id: id,
          tool_name: name,
          content: deny_reason(name, data.active_skill),
          is_error: true
        )

      Process.send(parent, {:tool_done, id, result}, [])

      :telemetry.execute(
        [:tau, :permissions, :decision],
        %{system_time: System.system_time()},
        %{
          tool: name,
          tool_call_id: id,
          decision: :deny,
          session_id: data.id
        }
      )
    end)

    {data, ask_in_flight} =
      if data.interactive? do
        pending =
          Enum.reduce(ask_calls, %{}, fn %{id: id, name: name, arguments: args}, acc ->
            :telemetry.execute(
              [:tau, :permissions, :request],
              %{system_time: System.system_time()},
              %{session_id: data.id, tool_call_id: id, tool_name: name}
            )

            Tau.Session.broadcast(data.id, %Events.PermissionRequest{
              session_id: data.id,
              tool_call_id: id,
              name: name,
              arguments: args,
              decision_reason: "Tool not matched by any allow rule in current mode."
            })

            Map.put(acc, id, %{name: name, arguments: args})
          end)

        ask_in_flight = Enum.into(ask_calls, %{}, fn %{id: id} -> {id, :awaiting_permission} end)
        {%{data | pending_permission_requests: pending}, ask_in_flight}
      else
        Enum.each(ask_calls, fn %{id: id, name: name} ->
          result =
            ToolResult.new(
              tool_call_id: id,
              tool_name: name,
              content:
                "Permission required for #{name} but session is non-interactive; denied by policy.",
              is_error: true
            )

          Process.send(parent, {:tool_done, id, result}, [])

          :telemetry.execute(
            [:tau, :permissions, :decision],
            %{system_time: System.system_time()},
            %{
              session_id: data.id,
              tool_call_id: id,
              tool_name: name,
              decision: :deny_non_interactive
            }
          )
        end)

        ask_in_flight = Enum.into(ask_calls, %{}, fn %{id: id} -> {id, :denied} end)
        {data, ask_in_flight}
      end

    if data.interactive? and ask_calls != [] do
      allow_batch =
        Enum.map(allowed, fn %{id: id, name: name, arguments: args} ->
          {id, name, args}
        end)

      initial_in_flight =
        ask_in_flight
        |> Map.merge(Enum.into(gated, %{}, fn %{id: id} -> {id, :denied} end))
        |> Map.merge(Enum.into(whitelisted_out, %{}, fn %{id: id} -> {id, :whitelist_filtered} end))
        |> Map.merge(activated_in_flight)

      Tau.Session.transition(data.id, data, :awaiting_permission)

      {:next_state, :awaiting_permission,
       %{
         data
         | tools_in_flight: initial_in_flight,
           tool_dispatcher: nil,
           permission_dispatch_batch: allow_batch,
           permission_pending_results: [],
           provider_task: nil,
           assembler: nil,
           stream_ref: nil,
           provider_span_ref: nil,
           tool_loop_call_lookups: Map.merge(data.tool_loop_call_lookups, call_lookups)
       }}
    else
      {_hook_denied, parallel_calls} =
        Enum.reduce(
          allowed,
          {[], []},
          fn %{id: id, name: name, arguments: args}, {denied, kept} ->
            case Tau.Hooks.Dispatcher.run(
                   :pre_tool_use,
                   Tau.Session.hook_payload(data, :pre_tool_use, %{
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
          end
        )

      parallel_calls = Enum.reverse(parallel_calls)

      call_lookups =
        Enum.reduce(parallel_calls, call_lookups, fn {id, name, args}, acc ->
          Map.put(acc, id, {name, tool_args_hash(args)})
        end)

      dispatcher_pid =
        case parallel_calls do
          [] -> nil
          _ -> spawn_parallel_dispatcher(parallel_calls, data, parent)
        end

      real_tasks = Enum.into(parallel_calls, %{}, fn {id, _n, _a} -> {id, :running} end)

      initial_in_flight =
        real_tasks
        |> Map.merge(ask_in_flight)
        |> Map.merge(Enum.into(gated, %{}, fn %{id: id} -> {id, :denied} end))
        |> Map.merge(Enum.into(whitelisted_out, %{}, fn %{id: id} -> {id, :whitelist_filtered} end))
        |> Map.merge(activated_in_flight)

      Tau.Session.transition(data.id, data, :tool_executing)

      {:next_state, :tool_executing,
       %{
         data
         | tools_in_flight: initial_in_flight,
           tool_dispatcher: dispatcher_pid,
           provider_task: nil,
           assembler: nil,
           stream_ref: nil,
           provider_span_ref: nil,
           tool_loop_call_lookups: Map.merge(data.tool_loop_call_lookups, call_lookups)
       }}
    end
  end

  @doc """
  Called when the last pending permission request resolves.

  Emits accumulated instant-resolve results (`permission_pending_results`),
  runs `:pre_tool_use` hooks on the approved batch, and either dispatches the
  parallel batch (transitioning to `:tool_executing`) or re-invokes
  `:start_provider` directly when no approved calls remain.
  """
  @spec finish_permission_round(Tau.Session.Data.t()) :: :gen_statem.event_handler_result()
  def finish_permission_round(data) do
    parent = self()

    tools_in_flight_after =
      Map.reject(data.tools_in_flight, fn {_id, status} -> status == :awaiting_permission end)

    data =
      Enum.reduce(
        Enum.reverse(data.permission_pending_results),
        %{data | tools_in_flight: tools_in_flight_after},
        fn {call_id, result_msg}, acc ->
          {_lookup, call_lookups_rest} = Map.pop(acc.tool_loop_call_lookups, call_id)

          acc =
            acc
            |> Tau.Session.append_message(result_msg)
            |> Tau.Session.Journal.persist(
              "tool_result",
              Tau.Session.Journal.tool_result_to_data(result_msg)
            )
            |> Map.put(:tool_loop_call_lookups, call_lookups_rest)

          Tau.Session.broadcast(acc.id, %Events.ToolEnd{
            session_id: acc.id,
            tool_call_id: call_id,
            result: result_msg
          })

          acc
        end
      )

    batch = Enum.reverse(data.permission_dispatch_batch)

    data = %{
      data
      | pending_permission_requests: %{},
        permission_dispatch_batch: [],
        permission_pending_results: []
    }

    {hook_denied_results, parallel_calls} =
      Enum.reduce(
        batch,
        {[], []},
        fn {id, name, args}, {denied_acc, kept} ->
          case Tau.Hooks.Dispatcher.run(
                 :pre_tool_use,
                 Tau.Session.hook_payload(data, :pre_tool_use, %{
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

              {[{id, result} | denied_acc], kept}

            {:deny, reason} ->
              result =
                ToolResult.new(
                  tool_call_id: id,
                  tool_name: name,
                  content: "Hook denied: #{reason}",
                  is_error: true
                )

              {[{id, result} | denied_acc], kept}

            {:cont, payload} ->
              rewritten_args = Map.get(payload, :tool_input, args)
              {denied_acc, [{id, name, rewritten_args} | kept]}
          end
        end
      )

    parallel_calls = Enum.reverse(parallel_calls)

    call_lookups =
      Enum.reduce(parallel_calls, data.tool_loop_call_lookups, fn {id, name, args}, acc ->
        Map.put(acc, id, {name, tool_args_hash(args)})
      end)

    data =
      Enum.reduce(
        hook_denied_results,
        %{data | tool_loop_call_lookups: call_lookups},
        fn {call_id, result_msg}, acc ->
          {_lookup, call_lookups_rest} = Map.pop(acc.tool_loop_call_lookups, call_id)

          acc =
            acc
            |> Tau.Session.append_message(result_msg)
            |> Tau.Session.Journal.persist(
              "tool_result",
              Tau.Session.Journal.tool_result_to_data(result_msg)
            )
            |> Map.put(:tool_loop_call_lookups, call_lookups_rest)

          Tau.Session.broadcast(acc.id, %Events.ToolEnd{
            session_id: acc.id,
            tool_call_id: call_id,
            result: result_msg
          })

          acc
        end
      )

    if parallel_calls == [] do
      Tau.Session.handle_event(
        :internal,
        :start_provider,
        :provider_streaming,
        %{data | tools_in_flight: %{}, tool_dispatcher: nil}
      )
    else
      dispatcher_pid = spawn_parallel_dispatcher(parallel_calls, data, parent)
      running = Enum.into(parallel_calls, %{}, fn {id, _n, _a} -> {id, :running} end)

      {:next_state, :tool_executing,
       %{data | tools_in_flight: running, tool_dispatcher: dispatcher_pid}}
    end
  end

  @doc """
  Split tool calls into `{filtered_out, kept}` based on `tools_whitelist`.

  `:all` is the no-op (everything kept). A list keeps only calls whose `name`
  is in the list. Ordering is preserved.
  """
  @spec split_tools_whitelist(list(), :all | list()) :: {list(), list()}
  def split_tools_whitelist(tool_calls, :all), do: {[], tool_calls}

  def split_tools_whitelist(tool_calls, list) when is_list(list) do
    Enum.split_with(tool_calls, fn %{name: name} -> name not in list end)
  end

  @doc """
  Return the effective whitelist size for telemetry.
  """
  @spec whitelist_size(:all | list()) :: :all | non_neg_integer()
  def whitelist_size(:all), do: :all
  def whitelist_size(list) when is_list(list), do: length(list)

  @doc """
  Compute a SHA-256 hash of tool arguments in canonical form.

  Canonical form: keys sorted recursively, encoded with `Jason.encode!/1`.
  Falls back to `inspect/1` if Jason cannot encode the arguments (D-035
  try/rescue site — preserved as-is).
  """
  @spec tool_args_hash(map() | nil) :: String.t()
  def tool_args_hash(args) do
    canonical =
      try do
        Jason.encode!(canonicalize_for_hash(args || %{}))
      rescue
        _ -> inspect(args, limit: :infinity, printable_limit: :infinity)
      end

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  @doc """
  Recursively sort map keys and normalise key type to string for hashing.
  """
  @spec canonicalize_for_hash(term()) :: term()
  def canonicalize_for_hash(%{} = m) do
    m
    |> Enum.map(fn {k, v} -> {to_string(k), canonicalize_for_hash(v)} end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.into(%{})
  end

  def canonicalize_for_hash(list) when is_list(list),
    do: Enum.map(list, &canonicalize_for_hash/1)

  def canonicalize_for_hash(other), do: other

  @doc """
  Evaluate whether the tool-loop brake threshold has been reached.

  Returns `{:continue, data}` for normal flow or `{:brake, data}` when the
  threshold is reached. A successful (non-error) result clears the whole brake
  table for the turn — evidence the model has un-wedged.
  """
  @spec maybe_apply_tool_loop_brake(Tau.Session.Data.t(), term(), struct()) ::
          {:continue, Tau.Session.Data.t()} | {:brake, Tau.Session.Data.t()}
  def maybe_apply_tool_loop_brake(data, nil, _result_msg), do: {:continue, data}

  def maybe_apply_tool_loop_brake(data, _lookup, %ToolResult{is_error: false}),
    do: {:continue, reset_tool_loop_state(data)}

  def maybe_apply_tool_loop_brake(data, {name, args_hash}, %ToolResult{
        is_error: true,
        content: error_text
      }) do
    key = {name, args_hash}
    error_str = to_string(error_text || "")
    prev = Map.get(data.tool_loop_state, key)

    cell =
      case prev do
        %{count: c, error: ^error_str} -> %{count: c + 1, error: error_str}
        _ -> %{count: 1, error: error_str}
      end

    state2 = Map.put(data.tool_loop_state, key, cell)
    data2 = %{data | tool_loop_state: state2}

    if cell.count >= data2.tool_loop_brake_threshold do
      {:brake, data2}
    else
      {:continue, data2}
    end
  end

  @doc """
  Clear the per-turn brake table.

  Called on a successful tool dispatch to signal the model has un-wedged.
  """
  @spec reset_tool_loop_state(Tau.Session.Data.t()) :: Tau.Session.Data.t()
  def reset_tool_loop_state(data), do: %{data | tool_loop_state: %{}}

  @doc """
  Synthesise the tool-loop-brake escalation notice and abort the turn.

  Broadcasts `%SystemNotice{}`, appends an `%Assistant{stop_reason:
  :tool_loop_aborted}` message, and transitions to `:awaiting_user`.
  """
  @spec emit_tool_loop_brake_abort(Tau.Session.Data.t(), map()) ::
          :gen_statem.event_handler_result()
  def emit_tool_loop_brake_abort(data, tools) do
    {{name, args_hash}, %{count: count, error: error_str}} =
      Enum.max_by(data.tool_loop_state, fn {_k, %{count: c}} -> c end)

    notice_text =
      "Tool '#{name}' has been called with identical arguments #{count}x in a row, " <>
        "each time rejected with: '#{error_str}'. Halting this turn."

    :telemetry.execute(
      [:tau, :session, :tool_loop_brake],
      %{count: count},
      %{
        session_id: data.id,
        tool_name: name,
        args_hash: args_hash,
        error: error_str
      }
    )

    Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice_text})

    abort_msg =
      Assistant.new(
        stop_reason: :tool_loop_aborted,
        content: [%{type: :text, text: notice_text}]
      )

    data =
      data
      |> Tau.Session.append_message(abort_msg)
      |> Tau.Session.Journal.persist(
        "assistant_message",
        Tau.Session.Journal.message_to_data(abort_msg)
      )

    Tau.Session.broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: abort_msg})

    next_data = %{
      data
      | provider_task: nil,
        assembler: nil,
        cancel_flag: nil,
        stream_ref: nil,
        provider_span_ref: nil,
        tools_in_flight: tools,
        tool_dispatcher: nil,
        tool_iterations: 0,
        tool_loop_state: %{},
        tool_loop_call_lookups: %{},
        provider_retry_state: %{count: 0}
    }

    actions =
      if :queue.is_empty(next_data.followup_queue),
        do: [],
        else: [{:next_event, :internal, :drain_followups}]

    {:next_state, :awaiting_user, next_data, actions}
  end

  @doc """
  Format the deny reason for a permission-denied tool call.

  When an active skill is in effect and the tool is not on its `allowed_tools`
  list, the denial is attributed to the skill; otherwise it came from a
  rule-set deny rule.
  """
  @spec deny_reason(String.t(), struct() | nil) :: String.t()
  def deny_reason(name, %Tau.Skill{name: skill_name, allowed_tools: list})
      when is_list(list) and list != [] do
    if name in list do
      "Permission denied: #{name} blocked by deny rule"
    else
      "Tool '#{name}' not on active skill '#{skill_name}' allowed_tools whitelist"
    end
  end

  def deny_reason(name, _active_skill),
    do: "Permission denied: #{name} blocked by deny rule"

  @doc """
  Lookup and execute a tool by name, handling validation errors and unknown tools.

  Returns a `%ToolResult{}` — never raises.
  """
  @spec run_tool(String.t(), String.t(), map() | nil, Tau.Session.Data.t()) :: struct()
  def run_tool(name, call_id, args, data) do
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

  @doc """
  Execute a validated tool, wrapping in `try/rescue` (D-035 site — preserved).

  Emits `[:tau, :tool, :execute, :start]` / `[:tau, :tool, :execute, :stop]` pair
  and `[:tau, :tool, :execute, :exception]` on raise. Returns a `%ToolResult{}`.
  """
  @spec run_tool_validated(
          String.t(),
          String.t(),
          map() | nil,
          Tau.Session.Data.t(),
          module(),
          integer()
        ) :: struct()
  def run_tool_validated(name, call_id, args, data, mod, started) do
    ctx =
      Tau.Tool.Context.new(
        tool_call_id: call_id,
        session_id: data.id,
        cwd: data.cwd,
        emit: fn payload ->
          Tau.Session.broadcast(data.id, %Events.ToolUpdate{
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

  @doc """
  Spawn the parallel tool dispatcher under `Tau.Tools.TaskSupervisor`.

  A single iterator process drives the `async_stream_nolink` pipeline; crashes
  surface as `{:exit, reason}` and are synthesised into `is_error: true`
  ToolResults so the FSM never loses a tool_call → tool_result correspondence.
  Returns the dispatcher `pid`.
  """
  @spec spawn_parallel_dispatcher(list(), Tau.Session.Data.t(), pid()) :: pid()
  def spawn_parallel_dispatcher(parallel_calls, data, parent) do
    {:ok, pid} =
      Task.Supervisor.start_child(Tau.Tools.TaskSupervisor, fn ->
        Enum.each(parallel_calls, fn {id, name, args} ->
          Tau.Session.broadcast(data.id, %Events.ToolStart{
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

          post_event = if result.is_error, do: :post_tool_use_failure, else: :post_tool_use

          result =
            case Tau.Hooks.Dispatcher.run(
                   post_event,
                   Tau.Session.hook_payload(data, post_event, %{
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

  # --- FSM clause handlers ---------------------------------------------------

  @doc """
  Handle `{:tool_done, call_id, result_msg}` info in `:tool_executing`.

  Appends the result, checks the tool-loop brake, and either aborts the turn
  (brake fired) or starts the next provider call (all tools done) or keeps
  waiting (more in-flight).
  """
  @spec handle_tool_done(String.t(), struct(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_tool_done(call_id, result_msg, data) do
    tools = Map.delete(data.tools_in_flight, call_id)

    {lookup, call_lookups_rest} = Map.pop(data.tool_loop_call_lookups, call_id)

    data =
      data
      |> Tau.Session.append_message(result_msg)
      |> Tau.Session.Journal.persist(
        "tool_result",
        Tau.Session.Journal.tool_result_to_data(result_msg)
      )
      |> Map.put(:tool_loop_call_lookups, call_lookups_rest)

    Tau.Session.broadcast(data.id, %Events.ToolEnd{
      session_id: data.id,
      tool_call_id: call_id,
      result: result_msg
    })

    case maybe_apply_tool_loop_brake(data, lookup, result_msg) do
      {:brake, data} ->
        emit_tool_loop_brake_abort(data, tools)

      {:continue, data} ->
        if map_size(tools) == 0 do
          data = Tau.Session.Queue.drain_steering_queue_one(data)

          Tau.Session.handle_event(
            :internal,
            :start_provider,
            :provider_streaming,
            %{data | tools_in_flight: tools, tool_dispatcher: nil}
          )
        else
          {:keep_state, %{data | tools_in_flight: tools}}
        end
    end
  end

  @doc """
  Handle `{:tool_done, call_id, result_msg}` info in `:awaiting_permission`.

  Pre-resolved items (deny-rule, whitelist-filtered, skill-activated) arrive
  via `{:tool_done}`. They are processed (append, persist, broadcast) but do
  NOT trigger the post-round transition — that fires only when
  `pending_permission_requests` is empty.
  """
  @spec handle_tool_done_awaiting_permission(String.t(), struct(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_tool_done_awaiting_permission(call_id, result_msg, data) do
    case Map.get(data.tools_in_flight, call_id) do
      :awaiting_permission ->
        require Logger

        Logger.warning(
          "Unexpected {:tool_done} for :awaiting_permission sentinel #{inspect(call_id)}; ignoring"
        )

        {:keep_state, data}

      nil ->
        {:keep_state, data}

      _status ->
        tools = Map.delete(data.tools_in_flight, call_id)
        {_lookup, call_lookups_rest} = Map.pop(data.tool_loop_call_lookups, call_id)

        data =
          data
          |> Tau.Session.append_message(result_msg)
          |> Tau.Session.Journal.persist(
            "tool_result",
            Tau.Session.Journal.tool_result_to_data(result_msg)
          )
          |> Map.put(:tool_loop_call_lookups, call_lookups_rest)
          |> Map.put(:tools_in_flight, tools)

        Tau.Session.broadcast(data.id, %Events.ToolEnd{
          session_id: data.id,
          tool_call_id: call_id,
          result: result_msg
        })

        {:keep_state, data}
    end
  end

  @doc """
  Handle `{:permission_decision, tool_call_id, :allow_once}` cast in
  `:awaiting_permission`.

  Adds the call to the dispatch batch; if the last pending, runs
  `finish_permission_round/1`.
  """
  @spec handle_permission_allow_once(String.t(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_permission_allow_once(tool_call_id, data) do
    case Map.pop(data.pending_permission_requests, tool_call_id) do
      {nil, _} ->
        require Logger

        Logger.debug(
          "permission_decision :allow_once for unknown tool_call_id #{inspect(tool_call_id)}"
        )

        :telemetry.execute(
          [:tau, :permissions, :stale_decision],
          %{system_time: System.system_time()},
          %{session_id: data.id, tool_call_id: tool_call_id, verdict: :allow_once}
        )

        {:keep_state, data}

      {%{name: name, arguments: args}, remaining} ->
        :telemetry.execute(
          [:tau, :permissions, :decision],
          %{system_time: System.system_time()},
          %{
            session_id: data.id,
            tool_call_id: tool_call_id,
            tool_name: name,
            decision: :allow_once
          }
        )

        batch = [{tool_call_id, name, args} | data.permission_dispatch_batch]
        data = %{data | pending_permission_requests: remaining, permission_dispatch_batch: batch}

        if map_size(remaining) == 0 do
          finish_permission_round(data)
        else
          {:keep_state, data}
        end
    end
  end

  @doc """
  Handle `{:permission_decision, tool_call_id, :deny_once}` cast in
  `:awaiting_permission`.

  Synthesises an `is_error` ToolResult accumulated in `permission_pending_results`;
  if the last pending, calls `finish_permission_round/1`.
  """
  @spec handle_permission_deny_once(String.t(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_permission_deny_once(tool_call_id, data) do
    case Map.pop(data.pending_permission_requests, tool_call_id) do
      {nil, _} ->
        require Logger

        Logger.debug(
          "permission_decision :deny_once for unknown tool_call_id #{inspect(tool_call_id)}"
        )

        :telemetry.execute(
          [:tau, :permissions, :stale_decision],
          %{system_time: System.system_time()},
          %{session_id: data.id, tool_call_id: tool_call_id, verdict: :deny_once}
        )

        {:keep_state, data}

      {%{name: name}, remaining} ->
        result =
          ToolResult.new(
            tool_call_id: tool_call_id,
            tool_name: name,
            content: "Permission denied: #{name} denied by user.",
            is_error: true
          )

        :telemetry.execute(
          [:tau, :permissions, :decision],
          %{system_time: System.system_time()},
          %{
            session_id: data.id,
            tool_call_id: tool_call_id,
            tool_name: name,
            decision: :deny_once
          }
        )

        pending_results = [{tool_call_id, result} | data.permission_pending_results]

        data = %{
          data
          | pending_permission_requests: remaining,
            permission_pending_results: pending_results
        }

        if map_size(remaining) == 0 do
          finish_permission_round(data)
        else
          {:keep_state, data}
        end
    end
  end

  @doc """
  Handle a stale/unknown `{:permission_decision, tool_call_id, verdict}` in
  `:awaiting_permission` (D-090 logged no-op).
  """
  @spec handle_permission_stale(String.t(), term(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_permission_stale(tool_call_id, verdict, data) do
    require Logger

    Logger.debug(
      "permission_decision #{inspect(verdict)} for unknown/stale tool_call_id #{inspect(tool_call_id)}"
    )

    :telemetry.execute(
      [:tau, :permissions, :stale_decision],
      %{system_time: System.system_time()},
      %{session_id: data.id, tool_call_id: tool_call_id, verdict: verdict}
    )

    {:keep_state, data}
  end

  @doc """
  Handle a `{:permission_decision, ...}` cast outside `:awaiting_permission`
  (D-090 logged no-op — stale decision after state transition).
  """
  @spec handle_permission_outside_state(String.t(), term(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_permission_outside_state(tool_call_id, verdict, data) do
    require Logger

    Logger.debug(
      "permission_decision #{inspect(verdict)} for #{inspect(tool_call_id)} outside :awaiting_permission (state ignored)"
    )

    :telemetry.execute(
      [:tau, :permissions, :stale_decision],
      %{system_time: System.system_time()},
      %{session_id: data.id, tool_call_id: tool_call_id, verdict: verdict}
    )

    {:keep_state, data}
  end
end
