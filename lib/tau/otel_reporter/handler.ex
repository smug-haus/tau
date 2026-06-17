defmodule Tau.OtelReporter.Handler do
  @moduledoc """
  Pure-function telemetry handler module.

  Each `handle_event/4` runs in the emitter's process. It MUST be fast
  and non-blocking. It casts a structured message to `Tau.OtelReporter`,
  which serialises all span-map mutations through its mailbox.

  SPEC-OTEL-REPORTER §2, §3, §4 B1/B2, D-051.

  No state. No OTel SDK calls. Only `GenServer.cast/2` to the reporter.
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Handler entry point (B1 contract)
  # ---------------------------------------------------------------------------

  @doc false
  @spec handle_event(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          map()
        ) :: :ok
  def handle_event(event, measurements, metadata, config) do
    try do
      do_handle(event, measurements, metadata, config)
    rescue
      e ->
        Logger.warning(
          "[OtelReporter.Handler] handle_event/4 raised for #{inspect(event)}: #{Exception.message(e)}"
        )

        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Provider request
  # ---------------------------------------------------------------------------

  defp do_handle([:tau, :provider, :request, :start], _measurements, metadata, %{
         reporter: reporter
       }) do
    session_id = Map.get(metadata, :session_id)
    provider = Map.get(metadata, :provider)
    # Use span_ref if echoed by emit site; fall back to make_ref().
    ref = Map.get(metadata, :span_ref, make_ref())
    key = {:provider_request, session_id, provider, ref}

    attrs =
      primitive_map(%{
        "tau.session_id" => session_id,
        "tau.provider" => provider,
        "tau.model" => Map.get(metadata, :model)
      })

    GenServer.cast(reporter, {:span_open, key, "tau.provider.request", attrs})
  end

  defp do_handle([:tau, :provider, :request, stop_kind], measurements, metadata, %{
         reporter: reporter
       })
       when stop_kind in [:stop, :cancelled, :brutal_kill] do
    session_id = Map.get(metadata, :session_id)
    provider = Map.get(metadata, :provider)

    case Map.get(metadata, :span_ref) do
      nil ->
        # No span_ref in metadata — cannot correlate. Discard.
        :ok

      ref ->
        key = {:provider_request, session_id, provider, ref}

        duration =
          case measurements do
            %{duration: d} -> d
            _ -> 0
          end

        outcome = if stop_kind == :stop, do: :ok, else: :error
        GenServer.cast(reporter, {:span_close, key, duration, outcome})
    end
  end

  # ---------------------------------------------------------------------------
  # Tool execute
  # ---------------------------------------------------------------------------

  defp do_handle([:tau, :tool, :execute, :start], _measurements, metadata, %{reporter: reporter}) do
    tool_call_id = Map.get(metadata, :tool_call_id)
    tool = Map.get(metadata, :tool)
    key = {:tool_execute, tool_call_id}

    attrs =
      primitive_map(%{
        "tau.tool" => tool,
        "tau.tool_call_id" => tool_call_id
      })

    GenServer.cast(reporter, {:span_open, key, "tau.tool.execute", attrs})
  end

  defp do_handle([:tau, :tool, :execute, :stop], measurements, metadata, %{reporter: reporter}) do
    tool_call_id = Map.get(metadata, :tool_call_id)
    key = {:tool_execute, tool_call_id}
    duration = Map.get(measurements, :duration, 0)
    outcome = if Map.get(metadata, :is_error, false), do: :error, else: :ok
    GenServer.cast(reporter, {:span_close, key, duration, outcome})
  end

  defp do_handle([:tau, :tool, :execute, :exception], measurements, metadata, %{
         reporter: reporter
       }) do
    # D-052: tool_call_id MUST be present.
    tool_call_id = Map.get(metadata, :tool_call_id)
    key = {:tool_execute, tool_call_id}
    duration = Map.get(measurements, :duration, 0)
    GenServer.cast(reporter, {:span_close, key, duration, :exception})
  end

  # ---------------------------------------------------------------------------
  # Hook run
  # ---------------------------------------------------------------------------

  defp do_handle([:tau, :hook, :run, :start], _measurements, metadata, %{reporter: reporter}) do
    hook = Map.get(metadata, :hook)
    event = Map.get(metadata, :event)
    # Discriminator ref MUST be echoed by dispatcher in stop/exception.
    ref = Map.get(metadata, :span_ref, make_ref())
    key = {:hook_run, hook, event, ref}

    attrs =
      primitive_map(%{
        "tau.hook" => hook,
        "tau.hook.event" => event
      })

    GenServer.cast(reporter, {:span_open, key, "tau.hook.run", attrs})
  end

  defp do_handle([:tau, :hook, :run, stop_kind], measurements, metadata, %{reporter: reporter})
       when stop_kind in [:stop, :exception] do
    hook = Map.get(metadata, :hook)
    event = Map.get(metadata, :event)

    case Map.get(metadata, :span_ref) do
      nil ->
        # No discriminator — cannot correlate. Discard.
        :ok

      ref ->
        key = {:hook_run, hook, event, ref}
        duration = Map.get(measurements, :duration, 0)
        outcome = if stop_kind == :stop, do: :ok, else: :exception
        GenServer.cast(reporter, {:span_close, key, duration, outcome})
    end
  end

  # ---------------------------------------------------------------------------
  # Session stop
  # ---------------------------------------------------------------------------

  defp do_handle([:tau, :session, :stop], _measurements, metadata, %{reporter: reporter}) do
    session_id = Map.get(metadata, :session_id)
    key = {:session, session_id}

    attrs =
      primitive_map(%{
        "tau.session_id" => session_id
      })

    # Session stop is a point event — open and immediately close.
    GenServer.cast(reporter, {:span_open, key, "tau.session.stop", attrs})
    GenServer.cast(reporter, {:span_close, key, 0, :ok})
  end

  # ---------------------------------------------------------------------------
  # Circuit breaker transition
  # ---------------------------------------------------------------------------

  defp do_handle([:tau, :circuit_breaker, :transition], _measurements, metadata, %{
         reporter: reporter
       }) do
    provider = Map.get(metadata, :provider)
    ref = make_ref()
    key = {:circuit_breaker_transition, provider, ref}

    attrs =
      primitive_map(%{
        "tau.provider" => provider,
        "tau.circuit_breaker.from" => Map.get(metadata, :from),
        "tau.circuit_breaker.to" => Map.get(metadata, :to)
      })

    GenServer.cast(reporter, {:span_open, key, "tau.circuit_breaker.transition", attrs})
    GenServer.cast(reporter, {:span_close, key, 0, :ok})
  end

  # ---------------------------------------------------------------------------
  # Factory gate run (FR-9.1 / issue #664)
  # ---------------------------------------------------------------------------

  defp do_handle([:tau, :factory, :gate, :run, :start], _measurements, metadata, %{
         reporter: reporter
       }) do
    unit = Map.get(metadata, :unit)
    hash = Map.get(metadata, :hash)
    run = Map.get(metadata, :run)
    key = {:factory_gate_run, unit, hash, run}

    attrs =
      primitive_map(%{
        "tau.factory.unit" => unit,
        "tau.factory.gate.hash" => hash,
        "tau.factory.gate.run" => run
      })

    GenServer.cast(reporter, {:span_open, key, "tau.factory.gate.run", attrs})
  end

  defp do_handle([:tau, :factory, :gate, :run, :stop], measurements, metadata, %{
         reporter: reporter
       }) do
    unit = Map.get(metadata, :unit)
    hash = Map.get(metadata, :hash)
    run = Map.get(metadata, :run)
    key = {:factory_gate_run, unit, hash, run}

    duration = Map.get(measurements, :duration, 0)
    status = Map.get(metadata, :status)
    outcome = if status == :pass, do: :ok, else: :error
    GenServer.cast(reporter, {:span_close, key, duration, outcome})
  end

  # ---------------------------------------------------------------------------
  # Factory worker events (D-352)
  # ---------------------------------------------------------------------------

  defp do_handle([:tau, :factory, :worker, :start], _measurements, metadata, %{
         reporter: reporter
       }) do
    worker_id = Map.get(metadata, :worker_id)
    key = {:factory_worker, worker_id}

    attrs =
      primitive_map(%{
        "tau.factory.worker_id" => worker_id,
        "tau.factory.unit_id" => Map.get(metadata, :unit_id),
        "tau.factory.agent_mode" => Map.get(metadata, :agent_mode)
      })

    GenServer.cast(reporter, {:span_open, key, "tau.factory.worker", attrs})
  end

  defp do_handle([:tau, :factory, :worker, :exit], measurements, metadata, %{
         reporter: reporter
       }) do
    worker_id = Map.get(metadata, :worker_id)
    key = {:factory_worker, worker_id}
    duration = Map.get(measurements, :duration, 0)
    reason = Map.get(metadata, :reason, :normal)
    outcome = if reason == :normal, do: :ok, else: :error
    GenServer.cast(reporter, {:span_close, key, duration, outcome})
  end

  # ---------------------------------------------------------------------------
  # Factory unit outcome events (D-352)
  # ---------------------------------------------------------------------------

  defp do_handle([:tau, :factory, :unit, outcome], _measurements, metadata, %{
         reporter: reporter
       })
       when outcome in [:merged, :escalated, :cancelled, :gating, :implementing] do
    unit_id = Map.get(metadata, :unit_id)
    ref = make_ref()
    key = {:factory_unit_outcome, unit_id, outcome, ref}

    attrs =
      primitive_map(%{
        "tau.factory.unit_id" => unit_id,
        "tau.factory.unit.outcome" => outcome,
        "tau.factory.unit.reason" => Map.get(metadata, :reason)
      })

    span_name = "tau.factory.unit.#{outcome}"
    GenServer.cast(reporter, {:span_open, key, span_name, attrs})
    GenServer.cast(reporter, {:span_close, key, 0, :ok})
  end

  # ---------------------------------------------------------------------------
  # Factory coordinator events (D-352)
  # ---------------------------------------------------------------------------

  defp do_handle([:tau, :factory, :coordinator, event], _measurements, metadata, %{
         reporter: reporter
       }) do
    ref = make_ref()
    key = {:factory_coordinator, event, ref}

    attrs =
      primitive_map(%{
        "tau.factory.coordinator.event" => event,
        "tau.factory.coordinator.issue" => Map.get(metadata, :issue),
        "tau.factory.coordinator.milestone" => Map.get(metadata, :milestone)
      })

    span_name = "tau.factory.coordinator.#{event}"
    GenServer.cast(reporter, {:span_open, key, span_name, attrs})
    GenServer.cast(reporter, {:span_close, key, 0, :ok})
  end

  # ---------------------------------------------------------------------------
  # Factory merge events (D-352)
  # ---------------------------------------------------------------------------

  defp do_handle([:tau, :factory, :merge, event], measurements, metadata, %{
         reporter: reporter
       }) do
    unit_id = Map.get(metadata, :unit_id)
    ref = make_ref()
    key = {:factory_merge, unit_id, event, ref}
    duration = Map.get(measurements, :duration, 0)

    attrs =
      primitive_map(%{
        "tau.factory.unit_id" => unit_id,
        "tau.factory.merge.event" => event,
        "tau.factory.merge.pr" => Map.get(metadata, :pr),
        "tau.factory.merge.sha" => Map.get(metadata, :sha)
      })

    span_name = "tau.factory.merge.#{event}"
    GenServer.cast(reporter, {:span_open, key, span_name, attrs})
    GenServer.cast(reporter, {:span_close, key, duration, :ok})
  end

  # ---------------------------------------------------------------------------
  # Factory janitor events (D-352)
  # ---------------------------------------------------------------------------

  defp do_handle([:tau, :factory, :janitor, :reclaim], _measurements, metadata, %{
         reporter: reporter
       }) do
    worker_id = Map.get(metadata, :worker_id)
    ref = make_ref()
    key = {:factory_janitor_reclaim, worker_id, ref}

    attrs =
      primitive_map(%{
        "tau.factory.worker_id" => worker_id,
        "tau.factory.janitor.reason" => Map.get(metadata, :reason)
      })

    GenServer.cast(reporter, {:span_open, key, "tau.factory.janitor.reclaim", attrs})
    GenServer.cast(reporter, {:span_close, key, 0, :ok})
  end

  # ---------------------------------------------------------------------------
  # Optional events (configurable; default off — no-op here)
  # ---------------------------------------------------------------------------

  defp do_handle([:tau, :mcp, :rpc, :start], _measurements, metadata, %{reporter: reporter}) do
    ref = Map.get(metadata, :span_ref, make_ref())
    key = {:mcp_rpc, Map.get(metadata, :method), ref}

    attrs =
      primitive_map(%{
        "tau.mcp.method" => Map.get(metadata, :method),
        "tau.mcp.server" => Map.get(metadata, :server)
      })

    GenServer.cast(reporter, {:span_open, key, "tau.mcp.rpc", attrs})
  end

  defp do_handle([:tau, :mcp, :rpc, :stop], measurements, metadata, %{reporter: reporter}) do
    case Map.get(metadata, :span_ref) do
      nil ->
        :ok

      ref ->
        key = {:mcp_rpc, Map.get(metadata, :method), ref}
        duration = Map.get(measurements, :duration, 0)
        GenServer.cast(reporter, {:span_close, key, duration, :ok})
    end
  end

  defp do_handle([:tau, :compaction, :start], _measurements, metadata, %{reporter: reporter}) do
    session_id = Map.get(metadata, :session_id)
    ref = Map.get(metadata, :span_ref, make_ref())
    key = {:compaction, session_id, ref}

    attrs = primitive_map(%{"tau.session_id" => session_id})
    GenServer.cast(reporter, {:span_open, key, "tau.compaction", attrs})
  end

  defp do_handle([:tau, :compaction, :stop], measurements, metadata, %{reporter: reporter}) do
    session_id = Map.get(metadata, :session_id)

    case Map.get(metadata, :span_ref) do
      nil ->
        :ok

      ref ->
        key = {:compaction, session_id, ref}
        duration = Map.get(measurements, :duration, 0)
        GenServer.cast(reporter, {:span_close, key, duration, :ok})
    end
  end

  defp do_handle([:tau, :permissions, :decision], _measurements, metadata, %{reporter: reporter}) do
    ref = make_ref()
    key = {:permissions_decision, ref}

    attrs =
      primitive_map(%{
        "tau.permissions.decision" => Map.get(metadata, :decision),
        "tau.tool" => Map.get(metadata, :tool)
      })

    GenServer.cast(reporter, {:span_open, key, "tau.permissions.decision", attrs})
    GenServer.cast(reporter, {:span_close, key, 0, :ok})
  end

  # Catch-all: unknown events are silently dropped.
  defp do_handle(_event, _measurements, _metadata, _config), do: :ok

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Converts a map to a primitive-only map. Non-primitive values are
  # serialised to strings via inspect/1.
  @spec primitive_map(map()) :: map()
  def primitive_map(m) do
    Map.new(m, fn {k, v} -> {k, to_primitive(v)} end)
  end

  defp to_primitive(v) when is_binary(v), do: v
  defp to_primitive(v) when is_integer(v), do: v
  defp to_primitive(v) when is_float(v), do: v
  defp to_primitive(v) when is_boolean(v), do: v
  defp to_primitive(nil), do: "nil"
  defp to_primitive(v), do: inspect(v)
end
