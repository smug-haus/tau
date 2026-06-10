---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Periodic sweep GenServer emitting `[:tau, :memory, :pending_rot]` telemetry

## Approach

Add a new supervised GenServer, `Tau.Memory.PendingRotSweeper`, to
`Tau.Memory.Supervisor`. On a configurable interval (default: 60 s), the
sweeper queries SQLite for entries whose `embedding_status = "pending"` and
whose `inserted_at` timestamp is older than `@request_timeout_ms + grace_ms`
(default: `30_000 + 5_000 = 35_000` ms). For each stale entry found it emits a
telemetry event `[:tau, :memory, :pending_rot, :detected]` with measurements
`%{count: pos_integer()}` and metadata `%{entry_ids: [binary()], oldest_age_ms:
non_neg_integer()}`. The sweeper does not modify any entries; detection only.

## Rationale

The acceptance criterion requires that an operator can detect stale `"pending"`
entries without querying the database directly. A periodic sweep is the
canonical OTP pattern for surfacing accumulated state: it runs on its own
process (no coupling to the write path), it relies on the existing SQLite owner
process only via a read query, and it emits structured telemetry that external
dashboards and alerting systems can consume. It is strictly additive — no
existing codepath is modified — which minimises risk to D-045/D-046 invariants.
Telemetry-based detection satisfies OTP non-negotiable #5 (everything
user-visible or perf-sensitive must have a telemetry event), since semantic
search degradation is user-visible.

## Sketch

### New file: `lib/tau/memory/pending_rot_sweeper.ex`

```elixir
defmodule Tau.Memory.PendingRotSweeper do
  @moduledoc """
  Periodic GenServer that detects stale embedding_status="pending" entries.

  Emits [:tau, :memory, :pending_rot, :detected] with:
    measurements: %{count: non_neg_integer()}
    metadata:     %{entry_ids: [binary()], oldest_age_ms: non_neg_integer()}

  count: 0 emits are suppressed (no-op interval ticks produce no telemetry).
  """

  use GenServer

  require Logger

  @default_sweep_interval_ms 60_000
  # Must exceed @request_timeout_ms in EmbeddingWorker (30_000) plus grace.
  @default_stale_threshold_ms 35_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)
    threshold = Keyword.get(opts, :stale_threshold_ms, @default_stale_threshold_ms)
    store = Keyword.get(opts, :store, Tau.Memory.Store.SQLite)

    schedule_sweep(interval)

    {:ok, %{interval: interval, threshold: threshold, store: store}}
  end

  @impl GenServer
  def handle_info(:sweep, %{interval: interval, threshold: threshold, store: store} = state) do
    sweep(store, threshold)
    schedule_sweep(interval)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)

  defp sweep(store, threshold_ms) do
    case Tau.Memory.Store.SQLite.stale_pending_entries(store, threshold_ms) do
      {:ok, []} ->
        :ok

      {:ok, entries} ->
        count = length(entries)
        oldest_age_ms = Enum.max(Enum.map(entries, & &1.age_ms))

        :telemetry.execute(
          [:tau, :memory, :pending_rot, :detected],
          %{count: count},
          %{entry_ids: Enum.map(entries, & &1.id), oldest_age_ms: oldest_age_ms}
        )

        Logger.warning(
          "[PendingRotSweeper] #{count} stale pending embedding(s) detected; " <>
            "oldest #{oldest_age_ms} ms. entry_ids=#{inspect(Enum.map(entries, & &1.id))}"
        )

      {:error, reason} ->
        Logger.error("[PendingRotSweeper] sweep query failed: #{inspect(reason)}")
    end
  end
end
```

### New query in `lib/tau/memory/store/sqlite.ex`

```elixir
@doc """
Return entries with embedding_status="pending" older than `threshold_ms` milliseconds.
Returns {:ok, [%{id: binary(), age_ms: non_neg_integer()}]} or {:error, term()}.
"""
@spec stale_pending_entries(GenServer.server(), non_neg_integer()) ::
        {:ok, [%{id: binary(), age_ms: non_neg_integer()}]} | {:error, term()}
def stale_pending_entries(server \\ __MODULE__, threshold_ms) do
  GenServer.call(server, {:stale_pending_entries, threshold_ms})
end
```

Corresponding `handle_call` clause executes:

```sql
SELECT id,
       CAST((julianday('now') - julianday(inserted_at)) * 86400000 AS INTEGER) AS age_ms
FROM   memory
WHERE  embedding_status = 'pending'
  AND  age_ms > ?1
ORDER  BY age_ms DESC
```

### Supervisor change: `lib/tau/memory/supervisor.ex`

```elixir
children = [
  {Tau.Memory.Store.SQLite, opts},
  {Tau.Memory.PendingRotSweeper, opts}
]
```

## Tradeoffs

### Strengths

- Strictly additive; no existing call paths modified.
- Clean OTP pattern: stateful detector is its own supervised process.
- Emits structured telemetry satisfying OTP non-negotiable #5; integrates with
  any Telemetry-compatible dashboard (Prometheus, StatsD, LiveDashboard).
- Configurable interval and threshold; easy to tune for different environments.
- The sweep is also a pre-recovery probe for the `retry-recovery-path`
  sub-problem: the same `stale_pending_entries/2` query is exactly what a
  re-enqueue mechanism would call.

### Weaknesses

- Introduces a polling dependency on the SQLite owner process: every sweep
  interval adds a `GenServer.call` to the store's mailbox. Under high write
  volume this adds latency jitter (bounded: one extra query/minute at default).
- Detection latency is bounded by the sweep interval (up to 60 s at default);
  not real-time.
- `stale_pending_entries/2` requires a new public API on `Store.SQLite` and a
  corresponding SQL query that touches the `memory` table — minor surface area
  growth in the store's interface.
- The new query must be validated against the actual schema column type for
  `inserted_at` to confirm the `julianday` arithmetic is correct (SQLite date
  arithmetic is fragile without explicit ISO8601 storage).

### Costs

- 1 new module (~80 lines), 1 new `handle_call` clause in `sqlite.ex`, 1
  supervisor child entry.
- Test surface: 1 unit test for the sweeper (mock store), 1 integration test
  for `stale_pending_entries/2`.
- No new dependencies.

## Dependencies

- `Tau.Memory.Store.SQLite` must expose `stale_pending_entries/2` (new public API).
- The `inserted_at` column must be stored in ISO8601 UTC format for the
  `julianday` arithmetic to be accurate; verify in migrations.

## Confidence

**Medium.** The OTP pattern is standard; the telemetry emission is
straightforward. Confidence would be `high` after verifying the `inserted_at`
column format in the SQLite schema and running the query against a real DB.

## Prior art / references

- OTP `send_after`-based periodic sweeps: standard GenServer idiom; see
  Erlang/Elixir documentation for `:timer.send_interval` as an alternative.
- `julianday` SQLite date arithmetic: SQLite documentation §Date and Time
  Functions.
- `[:tau, :memory, :write]` telemetry in `store/sqlite.ex:190–220` — existing
  pattern this proposal extends.
