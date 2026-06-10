---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Telemetry-driven re-enqueue — retry sweep triggered by `[:tau, :memory, :write, :stop]` events

## Approach

Replace the polling model entirely. Instead of a periodic timer, the retry path is
event-driven: when the Finch name mismatch is fixed (or a transient fault clears),
the next successful `write/1` emits `[:tau, :memory, :write, :stop]`. A new
lightweight GenServer, `Tau.Memory.RetryHandler`, subscribes to this telemetry
event via `:telemetry.attach/4` and, on receipt, performs one retriable-row sweep
and re-dispatches embeddings. Additionally, `RetryHandler` performs an initial
sweep on startup (via `handle_continue`) to drain any entries that were stuck
before the current session started.

The sweep query and dispatch logic is identical to Proposal 1 but the trigger is
event-driven rather than interval-based. `Tau.Memory.Supervisor` gains
`RetryHandler` as a sibling child.

## Rationale

The acceptance criterion says re-submission must happen "within a bounded time
window." The bounded window after the Finch fix is not clock-based — it is the
first new write that succeeds. Using a write-triggered sweep rather than a polling
interval means: (a) there is no wasted overhead when the pipeline is idle, and
(b) the retry happens at the earliest possible moment after the pipeline becomes
healthy again (the first successful write). The startup sweep handles entries that
were stuck before this session, satisfying the case where the operator fixes the
configuration and restarts without writing a new entry.

This decomplects the retry trigger from time and instead ties it to the observable
health signal already emitted by the store.

## Sketch

```elixir
# lib/tau/memory/retry_handler.ex
defmodule Tau.Memory.RetryHandler do
  use GenServer

  @telemetry_event [:tau, :memory, :write, :stop]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    store = Keyword.get(opts, :store, Tau.Memory.Store.SQLite)
    embedder = Application.get_env(:tau, :embedder, Tau.Memory.EmbeddingWorker)
    state = %{store: store, embedder: embedder}

    :telemetry.attach(
      "tau-memory-retry-on-write",
      @telemetry_event,
      &__MODULE__.handle_telemetry/4,
      %{pid: self()}
    )

    {:ok, state, {:continue, :startup_sweep}}
  end

  @impl GenServer
  def handle_continue(:startup_sweep, state) do
    do_sweep(state)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    do_sweep(state)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach("tau-memory-retry-on-write")
    :ok
  end

  # Called from telemetry handler in the emitting process context;
  # forwards to the RetryHandler mailbox to avoid blocking the emitter.
  def handle_telemetry(_event, _measurements, _metadata, %{pid: pid}) do
    send(pid, :sweep)
  end

  defp do_sweep(%{store: store, embedder: embedder}) do
    :telemetry.span([:tau, :memory, :retry_sweep], %{}, fn ->
      case Tau.Memory.Store.SQLite.list_retriable(store) do
        {:ok, []} ->
          {{:ok, 0}, %{count: 0}}
        {:ok, entries} ->
          Enum.each(entries, fn %{id: id, content: content} ->
            :telemetry.execute([:tau, :memory, :retry_enqueue], %{}, %{entry_id: id})
            embedder.embed(store, id, content)
          end)
          {{:ok, length(entries)}, %{count: length(entries)}}
        {:error, reason} ->
          {{:error, reason}, %{}}
      end
    end)
  end
end

# Store.SQLite gains list_retriable/1 (same as Proposal 1):
@spec list_retriable(GenServer.server()) :: {:ok, [%{id: String.t(), content: String.t()}]} | {:error, term()}
def list_retriable(server \\ __MODULE__) do
  GenServer.call(server, :list_retriable)
end

# lib/tau/memory/supervisor.ex — add RetryHandler:
children = [
  {Tau.Memory.Store.SQLite, opts},
  {Tau.Memory.RetryHandler, opts}
]
```

The `handle_telemetry/4` callback is invoked in the telemetry emitter's process
context; forwarding to the GenServer mailbox via `send/2` ensures the sweep runs
off the store's write path.

## Tradeoffs

### Strengths

- No polling overhead: the sweep runs only when there is evidence of pipeline
  activity (a write event) or at startup.
- Retry latency after a configuration fix is bounded by the next successful write
  (not a clock interval), which is typically the tightest possible bound.
- Startup sweep handles stuck entries from prior sessions without requiring a write.
- Decomplects retry trigger from clock; ties it to a meaningful domain event.
- Telemetry attachment/detachment is supervised through the GenServer lifecycle:
  on crash + restart, the attachment is re-established.

### Weaknesses

- If no new writes occur after the configuration fix (e.g. the operator restarts
  but nothing new is written), the retry sweep fires only once (at startup). Entries
  that fail again during the startup sweep will remain stuck until the next write or
  next restart. A subsequent write-triggered sweep will re-try them, but the bound
  becomes "next new write," not a fixed interval.
- The telemetry callback is called in the emitting process's context. The `send/2`
  approach avoids blocking, but adds a message to RetryHandler's mailbox on every
  write. If write volume is very high, the sweeps may queue up faster than they
  drain. A debounce (ignore sweep messages while a sweep is in flight) would
  mitigate this but adds complexity.
- Requires `list_retriable/1` new store API (same as Proposal 1).
- The event-driven model is less familiar to contributors than a timer sweep; the
  flow (write → telemetry → handler → re-enqueue) requires reading two files to
  understand.

### Costs

- New module (~80 LOC), new store API (~30 LOC), supervisor change (~3 LOC).
- Telemetry attachment lifecycle must be tested: crash + restart re-attaches correctly.
- Debounce logic (optional): ~20 LOC if added.

## Dependencies

- `Tau.Memory.Store.SQLite` must expose `list_retriable/1`.
- The Finch name mismatch must be fixed; otherwise the startup sweep and every
  write-triggered sweep dispatch embeddings that immediately fail again, creating a
  retry storm.
- Telemetry must be available before `Tau.Memory.Supervisor` starts (it is, as
  `:telemetry` is a library dependency loaded at application start).

## Confidence

medium — the telemetry-attach-from-GenServer-init pattern is used elsewhere in the
Tau codebase (OtelReporter). The write-triggered sweep is novel for this problem but
mechanically sound. Confidence would rise after verifying the debounce is not
needed at realistic write rates and after testing the restart-re-attaches scenario.

## Prior art / references

- `Tau.OtelReporter` (`lib/tau/otel_reporter.ex`): `:telemetry.attach/4` inside
  `GenServer.init/1` with detach in `terminate/2` — exact same pattern.
- SPEC-OTEL-REPORTER.md §3: documents the attach/detach lifecycle invariant.
- Event-driven recovery in distributed systems: reaction to a health-signal event
  rather than polling is a standard pattern (cf. circuit-breaker half-open probe).
