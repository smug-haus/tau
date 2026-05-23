defmodule Tau.CodingAgent.Dispatcher do
  @moduledoc """
  GenServer that owns one run of one coding-agent adapter.

  ## What it does

  1. Calls the adapter's `start/2` callback to obtain a stream of
     `Tau.CodingAgent.Event` structs.
  2. Forwards each event to a subscriber (the caller pid, by
     default) as a `{:coding_agent_event, dispatcher_pid, event}`
     message.
  3. Emits `[:tau, :coding_agent, :start | :event | :stop |
     :exception]` telemetry along the way (D-034 — parity with
     `Tau.Provider`).
  4. Honors `cancel/1`: stops draining, calls the adapter's
     `cancel/1`, and emits a synthetic `%Event.Done{exit_status:
     -2}` so consumers see a clean terminal event (D-032).
  5. Enforces an inactivity timeout (configurable; default 120s).
     On timeout the dispatcher emits `%Event.Error{reason:
     :inactivity_timeout, recoverable: false}` then `%Done{}`
     and exits normally.
  6. Trap-exits. If the adapter's stream raises despite D-035 —
     or the underlying Port dies — the dispatcher emits
     `%Event.Error{recoverable: false}` then `%Done{exit_status:
     -1}` rather than crashing silently.

  ## Why a GenServer over a bare Task

  The dispatcher is the *boundary* between adapter and the rest of
  tau. It needs:

  * a stable pid the caller can `cancel/1` even after the stream
    has drifted into an inner Stream.resource lambda;
  * `:trap_exit` so unexpected death of the adapter's underlying
    Port / Task produces a normalized error event rather than a
    silent supervisor restart;
  * `handle_continue` so `start_link/1` returns quickly and the
    adapter's `start/2` runs inside the supervised process.

  Real subprocess-backed adapters lean on these guarantees. Keep the
  surface area small.

  ## Public API

      {:ok, pid} =
        Tau.CodingAgent.Supervisor.start_dispatcher(
          adapter: Tau.CodingAgents.Replay,
          task: %{prompt: "…", workspace: cwd},
          ctx: %{},
          subscriber: self()
        )

      receive do
        {:coding_agent_event, ^pid, %Tau.CodingAgent.Event.Done{}} -> :ok
      end

      Tau.CodingAgent.Dispatcher.cancel(pid)
  """

  # Dispatchers are one-shot: each `start_link` represents a single
  # coding-agent run. `restart: :temporary` keeps `Tau.CodingAgent.Supervisor`
  # from interpreting a clean `:normal` exit as a restart event — without
  # this, rapid runs trip the DynamicSupervisor's max_restarts intensity
  # and bring the whole subtree down.
  use GenServer, restart: :temporary

  alias Tau.CodingAgent.Event
  alias Tau.CodingAgent.TauContext
  alias Tau.Settings.Cache, as: SettingsCache

  @default_inactivity_timeout_ms 120_000
  @cancel_exit_status -2
  @unexpected_exit_status -1

  @type init_arg :: [
          {:adapter, module()}
          | {:task, Tau.CodingAgent.task()}
          | {:ctx, Tau.CodingAgent.ctx()}
          | {:subscriber, pid()}
          | {:name, GenServer.name()}
        ]

  defmodule State do
    @moduledoc false

    @enforce_keys [:adapter, :task, :ctx, :subscriber, :inactivity_timeout_ms, :start_mono]
    defstruct [
      :adapter,
      :task,
      :ctx,
      :subscriber,
      :inactivity_timeout_ms,
      :start_mono,
      :drain_pid,
      :drain_ref,
      :inactivity_timer,
      :tau_context_pid,
      cancelled?: false,
      done_emitted?: false,
      events_count: 0
    ]
  end

  # ── public api ────────────────────────────────────────────────

  @spec start_link(init_arg()) :: GenServer.on_start()
  def start_link(args) do
    name = Keyword.get(args, :name)

    if name,
      do: GenServer.start_link(__MODULE__, args, name: name),
      else: GenServer.start_link(__MODULE__, args)
  end

  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid), do: GenServer.cast(pid, :cancel)

  @doc """
  Block until the dispatcher emits a terminal event (`%Done{}` or
  unrecoverable `%Error{}`). Returns the accumulated event list.
  Mainly a testing convenience; production code reads the stream
  by mailbox.
  """
  @spec await(pid(), timeout()) ::
          {:ok, [Tau.CodingAgent.Event.t()]} | {:error, :timeout}
  def await(pid, timeout \\ 5_000) do
    collect(pid, [], timeout)
  end

  defp collect(pid, acc, timeout) do
    receive do
      {:coding_agent_event, ^pid, %Event.Done{} = done} ->
        {:ok, Enum.reverse([done | acc])}

      {:coding_agent_event, ^pid, ev} ->
        collect(pid, [ev | acc], timeout)
    after
      timeout -> {:error, :timeout}
    end
  end

  # ── genserver ─────────────────────────────────────────────────

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)

    adapter = Keyword.fetch!(args, :adapter)
    task = Keyword.fetch!(args, :task)
    ctx = Keyword.get(args, :ctx, %{})
    subscriber = Keyword.get(args, :subscriber, self())

    inactivity_timeout_ms =
      Map.get(ctx, :inactivity_timeout_ms, @default_inactivity_timeout_ms)

    state = %State{
      adapter: adapter,
      task: task,
      ctx: ctx,
      subscriber: subscriber,
      inactivity_timeout_ms: inactivity_timeout_ms,
      start_mono: System.monotonic_time()
    }

    :telemetry.execute(
      [:tau, :coding_agent, :start],
      %{system_time: System.system_time()},
      %{
        adapter: adapter,
        workspace: Map.get(task, :workspace),
        session_id: Map.get(ctx, :session_id),
        request_id: Map.get(ctx, :request_id)
      }
    )

    {:ok, state, {:continue, :start_adapter}}
  end

  @impl true
  def handle_continue(:start_adapter, state) do
    # SPEC-CODING-AGENT [C5-B4]: the per-run tau-context MCP server
    # MUST be reachable BEFORE the adapter invokes its first MCP
    # tool. Start it (when enabled) and merge the resulting entry
    # into `task.mcp_servers` BEFORE calling adapter.start/2.
    state = maybe_start_tau_context(state)

    case safe_start(state.adapter, state.task, state.ctx) do
      {:ok, stream} ->
        {drain_pid, drain_ref} = spawn_drainer(stream, self())
        state = %{state | drain_pid: drain_pid, drain_ref: drain_ref}
        {:noreply, schedule_inactivity_timeout(state)}

      {:error, reason} ->
        # D-035: synchronous config error → emit a synthetic Error
        # event so subscribers see a normalized terminal pair, then
        # stop normally.
        emit(state, %Event.Error{reason: reason, recoverable: false})
        state = emit_done(state, @unexpected_exit_status, nil)
        emit_stop_telemetry(state, exit_status: @unexpected_exit_status, reason: reason)
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_cast(:cancel, %State{cancelled?: true} = state) do
    {:noreply, state}
  end

  def handle_cast(:cancel, %State{} = state) do
    state = %{state | cancelled?: true}

    # Best-effort: shut the drainer down, then notify the adapter.
    stop_drainer(state)
    safe_cancel(state.adapter, state.drain_pid)

    state = emit_done(state, @cancel_exit_status, nil)
    emit_stop_telemetry(state, exit_status: @cancel_exit_status, reason: :cancelled)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:coding_agent_event_internal, ref, event}, %State{drain_ref: ref} = state) do
    state =
      state
      |> emit(event)
      |> reschedule_inactivity_timeout()

    case event do
      %Event.Done{exit_status: status} = done ->
        state = %{state | done_emitted?: true}
        emit_stop_telemetry(state, exit_status: status, reason: done.final_message)
        {:stop, :normal, state}

      %Event.Error{recoverable: false, reason: reason} ->
        # The adapter says this is terminal but didn't emit Done;
        # synthesize one so subscribers see a clean pair.
        state = emit_done(state, @unexpected_exit_status, nil)
        emit_stop_telemetry(state, exit_status: @unexpected_exit_status, reason: reason)
        {:stop, :normal, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:coding_agent_event_internal, _ref, _event}, state) do
    # Stale message from a previous drainer (after cancel).
    {:noreply, state}
  end

  def handle_info({:coding_agent_drain_done, ref}, %State{drain_ref: ref} = state) do
    if state.done_emitted? do
      {:stop, :normal, state}
    else
      # Adapter stream exhausted without a Done event. D-031: emit
      # a synthetic terminal pair so consumers always see Done.
      emit(state, %Event.Error{
        reason: :stream_exhausted_without_done,
        recoverable: false
      })

      state = emit_done(state, @unexpected_exit_status, nil)

      emit_stop_telemetry(state,
        exit_status: @unexpected_exit_status,
        reason: :stream_exhausted_without_done
      )

      {:stop, :normal, state}
    end
  end

  def handle_info({:coding_agent_drain_done, _ref}, state) do
    {:noreply, state}
  end

  def handle_info({:coding_agent_drain_crash, ref, reason}, %State{drain_ref: ref} = state) do
    # D-035: adapter raised across the boundary. Surface as a
    # non-recoverable error event, then Done; don't propagate.
    emit(state, %Event.Error{reason: {:adapter_crashed, reason}, recoverable: false})
    state = emit_done(state, @unexpected_exit_status, nil)

    :telemetry.execute(
      [:tau, :coding_agent, :exception],
      %{
        system_time: System.system_time(),
        duration: duration(state)
      },
      %{
        adapter: state.adapter,
        kind: :adapter_crash,
        reason: reason,
        events_count: state.events_count
      }
    )

    {:stop, :normal, state}
  end

  def handle_info({:coding_agent_drain_crash, _ref, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:inactivity_timeout, %State{cancelled?: false, done_emitted?: false} = state) do
    stop_drainer(state)
    safe_cancel(state.adapter, state.drain_pid)

    emit(state, %Event.Error{reason: :inactivity_timeout, recoverable: false})
    state = emit_done(state, @unexpected_exit_status, nil)

    emit_stop_telemetry(state,
      exit_status: @unexpected_exit_status,
      reason: :inactivity_timeout
    )

    {:stop, :normal, state}
  end

  def handle_info(:inactivity_timeout, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Linked drainer exited. We already get a drain_done / drain_crash
    # via the explicit message, so the EXIT is informational.
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_tau_context(state)
    :ok
  end

  # ── internals ─────────────────────────────────────────────────

  # SPEC-CODING-AGENT §4 B4: read the
  # `coding_agent.expose_tau_context` setting (default true).
  # Start a per-run MCP server and thread its mcp_servers entry
  # into `task.mcp_servers` for the adapter to forward to the
  # child subprocess. Failure to start the server is NOT fatal:
  # we log via telemetry and continue with the original task —
  # the agent simply won't see tau context tools.
  defp maybe_start_tau_context(state) do
    if expose_tau_context?() do
      args = [
        owner: self(),
        session_id: Map.get(state.ctx, :session_id),
        cwd: Map.get(state.task, :workspace),
        max_depth: Map.get(state.ctx, :tau_context_max_depth, 2)
      ]

      case TauContext.start_link(args) do
        {:ok, pid} ->
          entry = TauContext.mcp_servers_entry(pid)
          existing = state.task |> Map.get(:mcp_servers, []) |> List.wrap()
          task = Map.put(state.task, :mcp_servers, [entry | existing])
          %{state | task: task, tau_context_pid: pid}

        {:error, reason} ->
          :telemetry.execute(
            [:tau, :coding_agent, :tau_context, :start_failed],
            %{system_time: System.system_time()},
            %{reason: reason, adapter: state.adapter}
          )

          state
      end
    else
      state
    end
  end

  defp stop_tau_context(%State{tau_context_pid: nil}), do: :ok

  defp stop_tau_context(%State{tau_context_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      TauContext.stop(pid)
    end

    :ok
  end

  defp expose_tau_context? do
    settings =
      try do
        SettingsCache.get()
      rescue
        _ -> %{}
      catch
        _, _ -> %{}
      end

    settings
    |> Map.get(:coding_agent, %{})
    |> case do
      %{} = ca -> Map.get(ca, :expose_tau_context, Map.get(ca, "expose_tau_context", true))
      _ -> true
    end
  end

  defp safe_start(adapter, task, ctx) do
    adapter.start(task, ctx)
  rescue
    e ->
      {:error, {:adapter_raised, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:adapter_threw, kind, reason}}
  end

  defp safe_cancel(adapter, handle) do
    if function_exported?(adapter, :cancel, 1) do
      try do
        adapter.cancel(handle)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp spawn_drainer(stream, parent) do
    ref = make_ref()

    pid =
      spawn_link(fn ->
        try do
          Enum.each(stream, fn ev ->
            Kernel.send(parent, {:coding_agent_event_internal, ref, ev})
          end)

          Kernel.send(parent, {:coding_agent_drain_done, ref})
        rescue
          e ->
            Kernel.send(parent, {:coding_agent_drain_crash, ref, Exception.message(e)})
        catch
          kind, reason ->
            Kernel.send(parent, {:coding_agent_drain_crash, ref, {kind, reason}})
        end
      end)

    {pid, ref}
  end

  defp stop_drainer(%State{drain_pid: nil}), do: :ok

  defp stop_drainer(%State{drain_pid: pid}) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  defp emit(%State{subscriber: sub} = state, %struct{} = event)
       when struct in [
              Event.Start,
              Event.AssistantText,
              Event.ToolUse,
              Event.ToolResult,
              Event.FileEdit,
              Event.Cost,
              Event.Error,
              Event.Done
            ] do
    if is_pid(sub) and Process.alive?(sub) do
      Kernel.send(sub, {:coding_agent_event, self(), event})
    end

    :telemetry.execute(
      [:tau, :coding_agent, :event],
      %{system_time: System.system_time()},
      %{adapter: state.adapter, event: struct}
    )

    %{state | events_count: state.events_count + 1}
  end

  defp emit_done(%State{done_emitted?: true} = state, _status, _final), do: state

  defp emit_done(state, exit_status, final_message) do
    state
    |> emit(%Event.Done{exit_status: exit_status, final_message: final_message})
    |> Map.put(:done_emitted?, true)
  end

  defp emit_stop_telemetry(state, opts) do
    :telemetry.execute(
      [:tau, :coding_agent, :stop],
      %{
        system_time: System.system_time(),
        duration: duration(state),
        events_count: state.events_count
      },
      %{
        adapter: state.adapter,
        exit_status: Keyword.get(opts, :exit_status),
        reason: Keyword.get(opts, :reason)
      }
    )

    state
  end

  defp duration(%State{start_mono: t0}) do
    System.monotonic_time() - t0
  end

  defp schedule_inactivity_timeout(%State{inactivity_timeout_ms: :infinity} = state), do: state

  defp schedule_inactivity_timeout(%State{inactivity_timeout_ms: ms} = state) when is_integer(ms) do
    timer = Process.send_after(self(), :inactivity_timeout, ms)
    %{state | inactivity_timer: timer}
  end

  defp reschedule_inactivity_timeout(state) do
    if state.inactivity_timer, do: Process.cancel_timer(state.inactivity_timer)
    schedule_inactivity_timeout(state)
  end
end
