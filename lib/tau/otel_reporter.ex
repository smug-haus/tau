defmodule Tau.OtelReporter do
  @moduledoc """
  OpenTelemetry reporter.

  Supervised GenServer. Attaches telemetry handlers on `init/1`, holds the
  open-span map, implements the stale-span sweep timer, and detaches handlers
  on `terminate/2`.

  ## Design constraints (SPEC-OTEL-REPORTER)

  - D-050: Runs only as a supervised process; no module-level state.
  - D-051: Open-span map mutated ONLY in this GenServer.
  - D-053: Stale-span sweep on a configurable interval (sweep_interval_ms).
  - D-054: Bounded open-span map (max_open_spans); oldest-first eviction.
  - D-055: OTel SDK calls are guarded by `Code.ensure_loaded?/1` so the
    build is clean without the optional OTel deps.

  ## Placement in supervision tree (B4)

  Added to `Tau.Application` when `otel.enabled: true`. If the `:opentelemetry`
  application is not running at start, returns `{:stop, :otel_not_started}` so
  the supervisor does not loop-restart.
  """

  use GenServer
  require Logger

  alias Tau.OtelReporter.Config
  alias Tau.OtelReporter.Handler

  # State shape (§5):
  # %{open_spans: %{key => {span_ctx, opened_at_mono :: integer()}},
  #   config: Config.t(),
  #   sweep_timer: reference() | nil}

  # ---------------------------------------------------------------------------
  # API
  # ---------------------------------------------------------------------------

  @doc "Starts the reporter under the supervision tree."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    config = Config.load()

    if config.enabled do
      case check_otel_running() do
        :ok ->
          state = %{
            open_spans: %{},
            config: config,
            sweep_timer: nil
          }

          state = schedule_sweep(state)
          attach_handlers(config)
          {:ok, state}

        {:error, reason} ->
          Logger.warning("[OtelReporter] OTel SDK not available: #{inspect(reason)}. Aborting.")
          {:stop, :otel_not_started}
      end
    else
      # No-op when disabled. Return :ignore so the supervisor doesn't loop-restart.
      :ignore
    end
  end

  @impl true
  def terminate(_reason, state) do
    detach_handlers()
    end_all_open_spans(state.open_spans)
    :ok
  end

  # ---------------------------------------------------------------------------
  # handle_cast — span lifecycle (B2 contract)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast({:span_open, key, span_name, attrs}, state) do
    state = maybe_evict(state)

    span_ctx = start_otel_span(span_name, attrs)
    opened_at = System.monotonic_time(:millisecond)

    open_spans = Map.put(state.open_spans, key, {span_ctx, opened_at})
    {:noreply, %{state | open_spans: open_spans}}
  end

  def handle_cast({:span_close, key, duration_native, outcome}, state) do
    case Map.pop(state.open_spans, key) do
      {nil, _} ->
        # No open span for this key — discard silently.
        {:noreply, state}

      {{span_ctx, _opened_at}, remaining} ->
        end_otel_span(span_ctx, duration_native, outcome)
        {:noreply, %{state | open_spans: remaining}}
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info — sweep timer (D-053)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:sweep, state) do
    now_ms = System.monotonic_time(:millisecond)
    sweep_age_ms = state.config.sweep_age_ms

    {stale, fresh} =
      Map.split_with(state.open_spans, fn {_key, {_ctx, opened_at}} ->
        now_ms - opened_at >= sweep_age_ms
      end)

    Enum.each(stale, fn {_key, {span_ctx, _opened_at}} ->
      end_otel_span_stale(span_ctx)
    end)

    state = %{state | open_spans: fresh}
    state = schedule_sweep(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private — OTel span lifecycle
  # ---------------------------------------------------------------------------

  # D-055: guard all OTel SDK calls with Code.ensure_loaded? so the module
  # compiles cleanly when opentelemetry_api is absent.

  if Code.ensure_loaded?(:otel_tracer) do
    defp start_otel_span(span_name, attrs) do
      tracer = :opentelemetry.get_application_tracer(:tau)
      ctx = :otel_ctx.get_current()
      name_charlist = to_charlist(span_name)
      :otel_tracer.start_span(ctx, tracer, name_charlist, %{attributes: attrs})
    end

    defp end_otel_span(span_ctx, _duration_native, outcome) do
      set_span_status(span_ctx, outcome)
      :otel_span.end_span(span_ctx)
    end

    defp end_otel_span_stale(span_ctx) do
      :otel_span.set_attribute(span_ctx, "tau.span.stale", true)
      :otel_span.set_status(span_ctx, :opentelemetry.status(:error, "stale span force-finished"))
      :otel_span.end_span(span_ctx)
    end

    defp end_span_evicted(span_ctx) do
      :otel_span.set_attribute(span_ctx, "tau.span.evicted", true)

      :otel_span.set_status(
        span_ctx,
        :opentelemetry.status(:error, "evicted: max_open_spans reached")
      )

      :otel_span.end_span(span_ctx)
    end

    defp set_span_status(span_ctx, :ok) do
      :otel_span.set_status(span_ctx, :opentelemetry.status(:ok, ""))
    end

    defp set_span_status(span_ctx, :error) do
      :otel_span.set_status(span_ctx, :opentelemetry.status(:error, "error"))
    end

    defp set_span_status(span_ctx, :exception) do
      :otel_span.set_status(span_ctx, :opentelemetry.status(:error, "exception"))
    end

    defp end_all_open_spans(open_spans) do
      Enum.each(open_spans, fn {_key, {span_ctx, _opened_at}} ->
        :otel_span.set_attribute(span_ctx, "tau.span.terminated", true)
        :otel_span.set_status(span_ctx, :opentelemetry.status(:error, "reporter terminated"))
        :otel_span.end_span(span_ctx)
      end)
    end
  else
    # Stub implementations when OTel deps are absent (D-055).
    defp start_otel_span(_span_name, _attrs), do: :no_otel
    defp end_otel_span(_span_ctx, _duration, _outcome), do: :ok
    defp end_otel_span_stale(_span_ctx), do: :ok
    defp end_span_evicted(_span_ctx), do: :ok
    defp set_span_status(_span_ctx, _outcome), do: :ok
    defp end_all_open_spans(_open_spans), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Private — handler attach/detach (D-050)
  # ---------------------------------------------------------------------------

  # Fixed handler id (not pid-scoped) so a restarted reporter can detach the
  # crashed instance's handler. A pid-scoped id would be undetachable after
  # crash because the new pid cannot construct the old pid's id.
  defp handler_id, do: __MODULE__

  defp attach_handlers(config) do
    # Detach any stale handler from a prior instance before attaching.
    :telemetry.detach(handler_id())

    events = build_event_list(config)

    :telemetry.attach_many(
      handler_id(),
      events,
      &Handler.handle_event/4,
      %{reporter: self()}
    )
  end

  defp detach_handlers do
    :telemetry.detach(handler_id())
  end

  defp build_event_list(config) do
    # Mandatory set: event families whose *.start/*.stop emit sites carry
    # a correlating key.
    # - provider.request: composite key {:provider_request, session_id,
    #   provider, span_ref}; *.stop without span_ref is discarded.
    # - tool.execute: correlates on tool_call_id (D-052).
    # - hook.run: correlates on span_ref discriminator.
    # - session.stop, circuit_breaker.transition: point events.
    mandatory = [
      [:tau, :provider, :request, :start],
      [:tau, :provider, :request, :stop],
      [:tau, :provider, :request, :cancelled],
      [:tau, :provider, :request, :brutal_kill],
      [:tau, :tool, :execute, :start],
      [:tau, :tool, :execute, :stop],
      [:tau, :tool, :execute, :exception],
      [:tau, :hook, :run, :start],
      [:tau, :hook, :run, :stop],
      [:tau, :hook, :run, :exception],
      [:tau, :session, :stop],
      [:tau, :circuit_breaker, :transition]
    ]

    # Optional events (SPEC §4 B1: configurable, default off).
    # MCP and compaction emit sites do not yet carry span_ref — when enabled,
    # spans will leak until their emit sites are amended. The config flag is
    # the operator's explicit opt-in acknowledging this limitation.
    optional =
      []
      |> maybe_add(config.mcp_spans_enabled, [
        [:tau, :mcp, :rpc, :start],
        [:tau, :mcp, :rpc, :stop]
      ])
      |> maybe_add(config.compaction_spans_enabled, [
        [:tau, :compaction, :start],
        [:tau, :compaction, :stop]
      ])
      |> maybe_add(config.permissions_spans_enabled, [
        [:tau, :permissions, :decision]
      ])

    mandatory ++ optional
  end

  defp maybe_add(acc, true, events), do: acc ++ events
  defp maybe_add(acc, _, _events), do: acc

  # ---------------------------------------------------------------------------
  # Private — sweep timer (D-053)
  # ---------------------------------------------------------------------------

  defp schedule_sweep(state) do
    if state.sweep_timer do
      Process.cancel_timer(state.sweep_timer)
    end

    timer = Process.send_after(self(), :sweep, state.config.sweep_interval_ms)
    %{state | sweep_timer: timer}
  end

  # ---------------------------------------------------------------------------
  # Private — bounded memory, oldest-first eviction (D-054)
  # ---------------------------------------------------------------------------

  defp maybe_evict(state) do
    max = state.config.max_open_spans

    if map_size(state.open_spans) >= max do
      evict_oldest(state)
    else
      state
    end
  end

  defp evict_oldest(state) do
    {oldest_key, {span_ctx, _opened_at}} =
      Enum.min_by(state.open_spans, fn {_k, {_ctx, opened_at}} -> opened_at end)

    end_span_evicted(span_ctx)
    %{state | open_spans: Map.delete(state.open_spans, oldest_key)}
  end

  # ---------------------------------------------------------------------------
  # Private — OTel SDK availability check
  # ---------------------------------------------------------------------------

  defp check_otel_running do
    if Code.ensure_loaded?(:otel_tracer) do
      started = Application.started_applications() |> Enum.map(&elem(&1, 0))

      if :opentelemetry in started do
        :ok
      else
        {:error, :opentelemetry_not_started}
      end
    else
      {:error, :opentelemetry_api_not_loaded}
    end
  end
end
