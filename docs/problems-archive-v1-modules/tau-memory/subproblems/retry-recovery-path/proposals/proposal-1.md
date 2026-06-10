---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Tau.Memory.RetrySweeper — dedicated supervised GenServer with a periodic timer

## Approach

Add `Tau.Memory.RetrySweeper`, a new `GenServer` child under `Tau.Memory.Supervisor`,
whose sole responsibility is periodically querying the DB for `"pending"` and
`"failed"` / `embedding_error_kind: "transient"` rows, then re-dispatching
`embedder.embed/3` for each. The sweep interval is configurable via
`:tau, :retry_sweep_interval_ms` (default 60_000 ms). The sweeper holds a reference
to the store's GenServer name and the configured embedder module; it does not own
a DB connection — it delegates all DB reads through the existing store API.

The sweeper adds one public function: `Tau.Memory.RetrySweeper.trigger_sweep/0`
(for tests and operator tooling). The store must expose one new API call,
`list_retriable/1`, that returns `[%{id: String.t(), content: String.t()}]` filtered
to retriable statuses. No changes to `Store.SQLite`'s existing callbacks.

## Rationale

This directly satisfies the OTP non-negotiable (#1): the retry concern lives as a
supervised process, not as ad-hoc timers inside the store GenServer. It decomplects
the re-enqueue trigger from the store's write/embedding path — the store records
status; the sweeper reads it and acts. A dedicated process makes the retry loop
independently restartable, observable (its own telemetry), and testable in isolation.
The sweeper reads the `:transient` classification already stored in metadata by
`do_mark_embedding_failed/3`, so no classification logic moves.

## Sketch

```elixir
# lib/tau/memory/retry_sweeper.ex
defmodule Tau.Memory.RetrySweeper do
  use GenServer

  @default_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec trigger_sweep(GenServer.server()) :: :ok
  def trigger_sweep(server \\ __MODULE__) do
    GenServer.call(server, :sweep)
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms,
      Application.get_env(:tau, :retry_sweep_interval_ms, @default_interval_ms))
    store = Keyword.get(opts, :store, Tau.Memory.Store.SQLite)
    embedder = Application.get_env(:tau, :embedder, Tau.Memory.EmbeddingWorker)
    state = %{interval: interval, store: store, embedder: embedder}
    {:ok, state, {:continue, :schedule}}
  end

  @impl GenServer
  def handle_continue(:schedule, state) do
    Process.send_after(self(), :sweep, state.interval)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    do_sweep(state)
    Process.send_after(self(), :sweep, state.interval)
    {:noreply, state}
  end

  def handle_call(:sweep, _from, state) do
    do_sweep(state)
    {:reply, :ok, state}
  end

  defp do_sweep(%{store: store, embedder: embedder} = _state) do
    :telemetry.span([:tau, :memory, :retry_sweep], %{}, fn ->
      case Tau.Memory.Store.SQLite.list_retriable(store) do
        {:ok, entries} ->
          Enum.each(entries, fn %{id: id, content: content} ->
            :telemetry.execute([:tau, :memory, :retry_enqueue], %{}, %{entry_id: id})
            embedder.embed(store, id, content)
          end)
          {{:ok, length(entries)}, %{count: length(entries)}}
        {:error, reason} ->
          :telemetry.execute([:tau, :memory, :retry_sweep_error], %{}, %{reason: reason})
          {{:error, reason}, %{}}
      end
    end)
  end
end

# New public API on Store.SQLite
@spec list_retriable(GenServer.server()) :: {:ok, [%{id: String.t(), content: String.t()}]} | {:error, term()}
def list_retriable(server \\ __MODULE__) do
  GenServer.call(server, :list_retriable)
end

# New handle_call in Store.SQLite
def handle_call(:list_retriable, _from, %{db: db} = state) do
  sql = """
  SELECT id, content FROM memory_entries
  WHERE embedding_status = 'pending'
     OR (embedding_status = 'failed'
         AND json_extract(metadata, '$.embedding_error_kind') = 'transient')
  """
  # ... prepare, fetch_all, release pattern; map to %{id: ..., content: ...}
  {:reply, result, state}
end

# lib/tau/memory/supervisor.ex — add RetrySweeper child
children = [
  {Tau.Memory.Store.SQLite, opts},
  {Tau.Memory.RetrySweeper, opts}
]
```

The supervision strategy stays `:one_for_one`; a sweeper crash does not restart
the store.

## Tradeoffs

### Strengths

- Satisfies OTP non-negotiable #1: retry concern is a supervised process.
- Minimal coupling: sweeper only calls `list_retriable/1` and `embedder.embed/3`;
  no internal state shared with the store.
- `trigger_sweep/0` makes the retry path synchronously testable without timers.
- Adding `:tau, :retry_sweep_interval_ms = 0` in tests allows full integration testing.
- Sweeper crash does not affect the store; `:one_for_one` restarts it independently.
- Telemetry on sweep and per-enqueue event satisfies the "should emit telemetry" note in the problem.

### Weaknesses

- Polling: the sweep fires on a fixed interval regardless of whether any retriable
  entries exist. Idle overhead is minimal but non-zero.
- The first retry after startup is delayed by up to one full interval (default 60 s).
- `list_retriable/1` adds a round-trip through the store mailbox; under high write
  load, this call competes with writes and embedder callbacks.
- If the sweeper dispatches entries that are already mid-embedding (from a concurrent
  fix being merged), duplicate embedding tasks will race. The store's
  `do_store_embedding` is idempotent (DELETE + INSERT inside a transaction), so
  correctness is preserved, but wasted work occurs.

### Costs

- New module (~80 LOC), new store API function (~30 LOC), supervisor change (~3 LOC).
- New test module for the sweeper; integration test using `trigger_sweep/0`.
- `list_retriable` adds one SQL read per sweep cycle against `memory_entries`.

## Dependencies

- `Tau.Memory.Store.SQLite` must expose `list_retriable/1` (new call — no existing
  callers to migrate).
- `Tau.Tools.TaskSupervisor` must be started before `Tau.Memory.Supervisor`
  (already the case per `Tau.Application` child order).
- The Finch name mismatch (`finch-name-mismatch` sub-problem) must be fixed first;
  otherwise the sweeper re-enqueues entries that immediately fail again.

## Confidence

medium — the GenServer + `Process.send_after` pattern is idiomatic Elixir; no novel
mechanism. Confidence would be high after verifying that `list_retriable` performs
adequately under the expected row counts (thousands) and that the duplicate-embedding
race does not cause observable correctness issues.

## Prior art / references

- `Oban` (Elixir job queue): periodic sweep GenServer pattern for stuck jobs is a
  first-class concept.
- `Tau.Memory.Supervisor` existing pattern: adding a sibling child for a distinct concern.
- OTP non-negotiable #1 in `TAU.md` / `.claude/rules/otp-non-negotiables.md`.
