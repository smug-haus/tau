defmodule Tau.Session.ProviderTurn do
  @moduledoc """
  Provider streaming, fallback chain, retry budget, and turn finalisation
  for `Tau.Session`.

  Encapsulates all provider-side FSM logic: starting a stream, handling
  per-event callbacks, managing ADR-0012 fallback chains, the D-061 same-
  provider retry budget, cooperative/brutal task cancellation (ADR-0017),
  and the `finalize_assistant/2` post-stream processing path.

  ## Invariants

  - ADR-0012: `data.provider` shape-shifts during fallback; `original_provider`
    is restored at `finalize_assistant/2` so each turn starts against the primary.
  - `stream_ref` staleness: stale events from a killed predecessor carry a
    mismatched ref and are dropped.
  - D-061: the retry counter (`provider_retry_state.count`) is per-turn and
    resets on clean return to `:awaiting_user`.
  - Retry-budget monotonicity per turn: once exhausted, retryable errors are
    treated as terminal.
  """

  alias Tau.Message.{Assembler, Assistant}
  alias Tau.Provider.Event, as: PEvent
  alias Tau.Session.Events

  # --- Helpers called from session.ex ----------------------------------------

  @doc """
  Resolve a provider atom from a nil, binary, or atom value.

  Returns the module atom if valid, or `Tau.Provider.default()` if nil or if
  `String.to_existing_atom/1` fails (try/rescue is intentional — inventory §3).
  """
  @spec resolve_provider(module() | String.t() | nil) :: module()
  def resolve_provider(nil), do: Tau.Provider.default()

  def resolve_provider(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      _ -> Tau.Provider.default()
    end
  end

  def resolve_provider(m) when is_atom(m), do: m

  @doc """
  Look up the fallback chain for `original_provider` from settings.

  ADR-0012: returns `[]` when no chain is configured or the settings carry
  a typo (fail-closed via `Tau.Settings.Schema.resolve_fallback_chains/1`).
  """
  @spec lookup_fallback_chain(module()) :: [module()]
  def lookup_fallback_chain(original_provider) when is_atom(original_provider) do
    settings = Tau.Settings.Cache.get()

    case Tau.Settings.Schema.resolve_fallback_chains(settings) do
      {:ok, chains} -> Map.get(chains, original_provider, [])
      {:error, _} -> []
    end
  end

  @doc """
  Emit the telemetry event closing an in-flight provider request span.

  D-057 / SPEC-OTEL-REPORTER: every path abandoning an in-flight request
  MUST call this before re-entering `:start_provider` or returning to
  `:awaiting_user`. No-op when `provider_span_ref` is nil.
  """
  @spec emit_provider_request_terminal(:cancelled | :brutal_kill, Tau.Session.Data.t()) :: :ok
  def emit_provider_request_terminal(_suffix, %{provider_span_ref: nil}), do: :ok

  def emit_provider_request_terminal(suffix, data)
      when suffix in [:cancelled, :brutal_kill] do
    :telemetry.execute(
      [:tau, :provider, :request, suffix],
      %{system_time: System.system_time()},
      %{
        provider: data.provider,
        model: data.model,
        session_id: data.id,
        span_ref: data.provider_span_ref
      }
    )
  end

  @doc """
  Cancel the in-flight provider stream task, cooperatively then brutally.

  ADR-0017: sets the cancel flag and yields up to 250ms. Returns `:cooperative`,
  `:brutal_kill`, or `:noop` (no task active).
  """
  @spec cancel_provider_task(Tau.Session.Data.t()) :: :cooperative | :brutal_kill | :noop
  def cancel_provider_task(%{provider_task: nil}), do: :noop

  def cancel_provider_task(%{provider_task: task} = data) do
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

      # ADR-0017: telemetry event names decouple from the mechanism atom.
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
          span_ref: data.provider_span_ref
        }
      )

      mechanism
    end
  end

  @doc """
  Describe a known provider error atom as a user-actionable string.

  D-018: translates known auth atoms into human-readable messages.
  Unknown atoms fall through to `inspect/1`.
  """
  @spec describe_provider_error(atom() | term()) :: String.t()
  def describe_provider_error(:missing_api_key) do
    Tau.Providers.Anthropic.Auth.describe_error({:error, :no_auth})
  end

  def describe_provider_error(:oauth_expired) do
    Tau.Providers.Anthropic.Auth.describe_error({:error, :oauth_expired})
  end

  def describe_provider_error(:oauth_missing_scope) do
    Tau.Providers.Anthropic.Auth.describe_error({:error, :oauth_missing_scope})
  end

  def describe_provider_error(:oauth_malformed) do
    Tau.Providers.Anthropic.Auth.describe_error({:error, :oauth_malformed})
  end

  def describe_provider_error(:circuit_open) do
    "Provider is temporarily unavailable (circuit breaker open). " <>
      "The provider has returned too many consecutive errors. " <>
      "Please wait a moment and try again, or switch providers."
  end

  def describe_provider_error(other), do: inspect(other)

  @doc """
  Merge `nil` or extra provider context opts into data. No-op for nil.
  """
  @spec merge_provider_ctx(Tau.Session.Data.t(), map() | nil) :: Tau.Session.Data.t()
  def merge_provider_ctx(data, nil), do: data

  def merge_provider_ctx(data, ctx) when is_map(ctx) do
    %{data | provider_ctx: Map.merge(data.provider_ctx || %{}, ctx)}
  end

  @doc """
  Return `nil` when `data.provider_task` is nil; the provider task pid
  otherwise.
  """
  @spec maybe_replace(Tau.Session.Data.t(), atom(), term()) :: Tau.Session.Data.t()
  def maybe_replace(data, _key, nil), do: data
  def maybe_replace(data, key, value), do: Map.put(data, key, value)

  @doc """
  Guard: is the inbound event tagged with the currently-live run token?

  Provider events carry a `stream_ref`; coding-agent events carry a dispatcher
  pid. Stale events from superseded runs return false (ADR-0012).
  """
  @spec current_run?(Tau.Session.Data.t(), {:provider, reference()} | {:coding_agent, pid()}) ::
          boolean()
  def current_run?(%{stream_ref: ref}, {:provider, ref}) when is_reference(ref), do: true

  def current_run?(%{coding_agent_dispatcher: pid}, {:coding_agent, pid}) when is_pid(pid),
    do: true

  def current_run?(_data, _token), do: false

  @doc """
  Handle a user message after slash-command expansion has resolved.

  Runs the `:user_prompt_submit` hook chain. On `:cont`, appends the message
  to history, persists it, then routes to the coding-agent or provider
  streaming path.
  """
  @spec process_user_message(Tau.Message.t(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def process_user_message(msg, data) do
    case Tau.Hooks.Dispatcher.run(
           :user_prompt_submit,
           Tau.Session.hook_payload(data, :user_prompt_submit, %{message: msg})
         ) do
      {:halt, reason} ->
        Tau.Session.broadcast(data.id, %Events.Cancelled{
          session_id: data.id,
          reason: {:hook_halt, reason}
        })

        {:keep_state, data}

      {:deny, reason} ->
        Tau.Session.broadcast(data.id, %Events.Cancelled{
          session_id: data.id,
          reason: {:hook_deny, reason}
        })

        {:keep_state, data}

      {:cont, payload} ->
        msg = Map.get(payload, :message, msg)

        data =
          data
          |> Tau.Session.append_message(msg)
          |> Tau.Session.Journal.persist("user_message", Tau.Session.Journal.message_to_data(msg))

        # SPEC-CODING-AGENT / D-037: route to the coding-agent dispatcher when
        # one is configured; preserve the legacy provider path otherwise.
        if data.coding_agent do
          Tau.Session.handle_event(:internal, :start_coding_agent, :coding_agent_streaming, data)
        else
          Tau.Session.handle_event(:internal, :start_provider, :provider_streaming, data)
        end
    end
  end

  @doc """
  Finalise the assistant message at the end of a provider stream.

  Assembles the message, appends to history, persists, broadcasts, emits
  telemetry, optionally compacts, and then dispatches tool calls or returns
  to `:awaiting_user`.
  """
  @spec finalize_assistant(Assembler.t(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def finalize_assistant(assembler, data) do
    msg = Assembler.assistant(assembler)

    data =
      data
      |> Tau.Session.append_message(msg)
      |> Tau.Session.Journal.persist(
        "assistant_message",
        Tau.Session.Journal.message_to_data(msg)
      )

    Tau.Session.broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: msg})

    :telemetry.execute(
      [:tau, :provider, :request, :stop],
      %{system_time: System.system_time(), usage: msg.usage || %{}},
      %{
        provider: data.provider,
        model: data.model,
        session_id: data.id,
        stop_reason: msg.stop_reason,
        span_ref: data.provider_span_ref
      }
    )

    # SPEC-PROMPT-CACHING AC-4
    Tau.Session.Compaction.emit_cache_usage(data, msg.usage || %{})

    case Tau.Session.Compaction.maybe_compact(data, msg.usage || %{}) do
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

      compact_result ->
        data =
          if match?({:soft_error, _}, compact_result),
            do: elem(compact_result, 1),
            else: compact_result

        # ADR-0012: restore working provider to original_provider.
        data = %{data | provider: data.original_provider, fallback_chain_remaining: []}

        # ADR-0013 / ADR-0015: per-turn skill lifetime.
        data =
          if msg.stop_reason == :end_turn and Map.get(data, :persona_lifetime, :turn) == :turn do
            %{data | active_skill: nil}
          else
            data
          end

        tool_calls = Enum.filter(msg.content, &match?(%{type: :tool_call}, &1))

        cond do
          tool_calls == [] ->
            # D-079: merge surviving steering messages to front of followup_queue.
            {merged_followup, cleared_steering} =
              if :queue.is_empty(data.steering_queue) do
                {data.followup_queue, data.steering_queue}
              else
                steering_list = :queue.to_list(data.steering_queue)

                merged =
                  Enum.reduce(
                    Enum.reverse(steering_list),
                    data.followup_queue,
                    fn m, q -> :queue.in_r(m, q) end
                  )

                {merged, :queue.new()}
              end

            next_data = %{
              data
              | provider_task: nil,
                assembler: nil,
                cancel_flag: nil,
                stream_ref: nil,
                provider_span_ref: nil,
                tool_iterations: 0,
                tool_loop_state: %{},
                tool_loop_call_lookups: %{},
                provider_retry_state: %{count: 0},
                followup_queue: merged_followup,
                steering_queue: cleared_steering
            }

            actions =
              if :queue.is_empty(next_data.followup_queue),
                do: [],
                else: [{:next_event, :internal, :drain_followups}]

            {:next_state, :awaiting_user, next_data, actions}

          true ->
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
                |> Tau.Session.append_message(abort_msg)
                |> Tau.Session.Journal.persist(
                  "assistant_message",
                  Tau.Session.Journal.message_to_data(abort_msg)
                )

              Tau.Session.broadcast(data.id, %Events.MessageEnd{
                session_id: data.id,
                message: abort_msg
              })

              next_data = %{
                data
                | provider_task: nil,
                  assembler: nil,
                  cancel_flag: nil,
                  stream_ref: nil,
                  provider_span_ref: nil,
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
            else
              Tau.Session.ToolDispatch.dispatch_tools(
                tool_calls,
                %{data | tool_iterations: data.tool_iterations + 1}
              )
            end
        end
    end
  end

  # --- FSM clause handlers ---------------------------------------------------

  @doc """
  Start a provider stream in `:provider_streaming`.

  ADR-0012: re-derives the fallback chain from settings on each fresh turn.
  ADR-0017: allocates a fresh cancel flag per stream.
  D-057 / SPEC-OTEL-REPORTER: allocates a fresh `provider_span_ref` per request.
  """
  @spec start(Tau.Session.Data.t()) :: :gen_statem.event_handler_result()
  def start(data) do
    Tau.Session.transition(data.id, data, :provider_streaming)

    data =
      if data.fallback_chain_remaining == [] and data.provider == data.original_provider do
        %{data | fallback_chain_remaining: lookup_fallback_chain(data.original_provider)}
      else
        data
      end

    parent = self()
    cancel_flag = :counters.new(1, [])

    ctx =
      data.provider_ctx
      |> Map.merge(%{session_id: data.id, cancel_flag: cancel_flag})

    provider_span_ref = make_ref()
    data = %{data | provider_span_ref: provider_span_ref}

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
      |> Tau.Session.SkillActivation.maybe_put_tools(
        Tau.Session.SkillActivation.model_visible_tool_specs(data)
      )

    case Tau.CircuitBreaker.call(data.provider, [], fn ->
           data.provider.stream(data.messages, stream_opts, ctx)
         end) do
      {:ok, stream} ->
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

        Tau.Session.broadcast(data.id, %Events.MessageStart{
          session_id: data.id,
          message: assembler.message
        })

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
        handle_circuit_open(data)

      {:error, reason} ->
        handle_sync_error(reason, data)
    end
  end

  @doc """
  Handle a provider event arriving in `:provider_streaming`.
  """
  @spec handle_provider_event(reference(), term(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_provider_event(ref, ev, data) do
    if current_run?(data, {:provider, ref}) do
      new_assembler = Assembler.step(data.assembler, ev)

      Tau.Session.broadcast(data.id, %Events.MessageUpdate{
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

  @doc """
  Handle a retryable provider error with an empty fallback chain and retry budget remaining.

  D-061: schedules a same-provider retry after a backoff delay.
  """
  @spec handle_provider_retry_event(reference(), PEvent.Error.t(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_provider_retry_event(ref, ev, data) do
    if current_run?(data, {:provider, ref}) do
      next_count = data.provider_retry_state.count + 1
      delay = data.provider_retry_base_delay_ms * Integer.pow(2, data.provider_retry_state.count)

      :telemetry.execute(
        [:tau, :session, :provider_retry],
        %{count: next_count, delay_ms: delay},
        %{
          session_id: data.id,
          provider: data.provider,
          reason: ev.reason,
          max: data.provider_retry_max
        }
      )

      notice =
        "provider #{inspect(data.provider)} errored (#{inspect(ev.reason)}); " <>
          "retrying #{next_count}/#{data.provider_retry_max} after #{delay}ms"

      Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})

      data =
        Tau.Session.Journal.persist(data, "provider_retry", %{
          provider: inspect(data.provider),
          reason: inspect(ev.reason),
          count: next_count,
          max: data.provider_retry_max,
          delay_ms: delay
        })

      emit_provider_request_terminal(:brutal_kill, data)

      if data.provider_task && Process.alive?(data.provider_task.pid) do
        Task.shutdown(data.provider_task, :brutal_kill)
      end

      data = %{
        data
        | provider_retry_state: %{count: next_count},
          provider_task: nil,
          assembler: nil,
          stream_ref: nil,
          provider_span_ref: nil
      }

      Process.send_after(self(), {:provider_retry, next_count}, delay)
      {:keep_state, data}
    else
      {:keep_state, data}
    end
  end

  @doc """
  Handle a retryable provider error with a non-empty fallback chain.

  ADR-0012: advances to the next provider in the chain.
  """
  @spec handle_provider_fallback_event(reference(), PEvent.Error.t(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_provider_fallback_event(ref, ev, %{fallback_chain_remaining: [next | rest]} = data) do
    if current_run?(data, {:provider, ref}) do
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

      Tau.Session.broadcast(data.id, %Events.ProviderFallback{
        session_id: data.id,
        from_provider: from_provider,
        to_provider: next,
        reason: ev.reason
      })

      data =
        Tau.Session.Journal.persist(data, "provider_fallback", %{
          from_provider: inspect(from_provider),
          to_provider: inspect(next),
          reason: inspect(ev.reason)
        })

      emit_provider_request_terminal(:brutal_kill, data)

      if data.provider_task && Process.alive?(data.provider_task.pid) do
        Task.shutdown(data.provider_task, :brutal_kill)
      end

      transformed =
        Tau.Providers.Shared.ContentTransform.transform(data.messages, from_provider, next)

      Tau.Session.handle_event(
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
            stream_ref: nil,
            provider_span_ref: nil
        }
      )
    else
      {:keep_state, data}
    end
  end

  @doc """
  Handle `:provider_done` in `:provider_streaming`.
  """
  @spec handle_provider_done(reference(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_provider_done(ref, data) do
    if current_run?(data, {:provider, ref}) do
      if data.assembler && Assembler.done?(data.assembler) do
        {:keep_state, data}
      else
        assembler =
          Assembler.step(data.assembler || Assembler.new(), %PEvent.Done{stop_reason: :stop})

        finalize_assistant(assembler, data)
      end
    else
      {:keep_state, data}
    end
  end

  @doc """
  Handle `:provider_failed` (task raised) in `:provider_streaming`.
  """
  @spec handle_provider_failed(reference(), String.t(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_provider_failed(ref, msg, data) do
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

  @doc """
  Handle `:finish_provider` internal event in `:provider_streaming`.
  """
  @spec handle_finish_provider(Tau.Session.Data.t()) :: :gen_statem.event_handler_result()
  def handle_finish_provider(data) do
    handle_provider_done(data.stream_ref, data)
  end

  @doc """
  Handle `:end_turn` internal event — provider signals graceful completion.
  """
  @spec handle_end_turn(atom(), Tau.Session.Data.t()) :: :gen_statem.event_handler_result()
  def handle_end_turn(_state, data) do
    if data.assembler do
      finalize_assistant(data.assembler, data)
    else
      {:keep_state, data}
    end
  end

  @doc """
  Handle a deferred retry trigger `{:provider_retry, count}` in `:provider_streaming`.
  """
  @spec handle_provider_retry_trigger(non_neg_integer(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_provider_retry_trigger(count, data) do
    if count == data.provider_retry_state.count do
      start(data)
    else
      {:keep_state, data}
    end
  end

  # --- Private helpers -------------------------------------------------------

  defp brutal_kill_provider_task(task) do
    Task.shutdown(task, :brutal_kill)
    :brutal_kill
  end

  defp handle_circuit_open(%{fallback_chain_remaining: [next | rest]} = data) do
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

    Tau.Session.broadcast(data.id, %Events.ProviderFallback{
      session_id: data.id,
      from_provider: from_provider,
      to_provider: next,
      reason: :circuit_open
    })

    data =
      Tau.Session.Journal.persist(data, "provider_fallback", %{
        from_provider: inspect(from_provider),
        to_provider: inspect(next),
        reason: "circuit_open"
      })

    emit_provider_request_terminal(:cancelled, data)

    transformed =
      Tau.Providers.Shared.ContentTransform.transform(data.messages, from_provider, next)

    Tau.Session.handle_event(
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
          stream_ref: nil,
          provider_span_ref: nil
      }
    )
  end

  defp handle_circuit_open(data) do
    emit_provider_request_terminal(:cancelled, data)
    reason_str = describe_provider_error(:circuit_open)

    msg =
      Assistant.new(
        stop_reason: :error,
        error_message: reason_str,
        content: [%{type: :text, text: "Error: " <> reason_str}]
      )

    Tau.Session.broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: msg})

    next_data = %{data | cancel_flag: nil, stream_ref: nil, provider_span_ref: nil}

    actions =
      if :queue.is_empty(next_data.followup_queue),
        do: [],
        else: [{:next_event, :internal, :drain_followups}]

    {:next_state, :awaiting_user, next_data, actions}
  end

  defp handle_sync_error(reason, data) do
    emit_provider_request_terminal(:cancelled, data)
    reason_str = describe_provider_error(reason)

    msg =
      Assistant.new(
        stop_reason: :error,
        error_message: reason_str,
        content: [%{type: :text, text: "Error: " <> reason_str}]
      )

    Tau.Session.broadcast(data.id, %Events.MessageEnd{session_id: data.id, message: msg})

    next_data = %{data | cancel_flag: nil, stream_ref: nil, provider_span_ref: nil}

    actions =
      if :queue.is_empty(next_data.followup_queue),
        do: [],
        else: [{:next_event, :internal, :drain_followups}]

    {:next_state, :awaiting_user, next_data, actions}
  end
end
