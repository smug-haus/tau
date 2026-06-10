---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: API-breaking — move embedding status to an explicit FSM with re-enqueue as a first-class transition

## Approach

Change the embedding lifecycle from an implicit column pair (`embedding_status` string
+ `embedding_error_kind` in metadata JSON) to an explicit `Tau.Memory.EmbeddingState`
struct with a `:gen_statem`-compatible transition table. `Store.SQLite` gets a new
`handle_call({:transition_embedding, id, event}, ...)` clause that applies the FSM
transition and — when the new state is `:retriable` — immediately re-dispatches
`embedder.embed/3` as a side-effect of the transition itself. No separate sweep process
or timer is needed for newly-stuck entries. A `RetrySweeper` (one-shot, started at
boot) drains entries stuck before this session by querying for `embedding_status IN
('pending', 'failed')` with `embedding_error_kind = 'transient'` and applying
`transition_embedding(id, :force_retry)` for each.

The API change is: `store_embedding/3`'s callers continue to call the same function,
but internally the store now routes through `transition_embedding/3` rather than calling
`do_store_embedding` or `do_mark_embedding_failed` directly.

## Rationale

The complecting hypothesis names the root issue: "retryability classification is
recorded in metadata but nothing reads it to act." This proposal eliminates the
gap by making the re-enqueue a consequence of the state machine — when the FSM
enters a `:failed_transient` state, its transition table defines a `:retry` event
that triggers embedding dispatch. The FSM owns the policy; the store enforces it.
This removes the need for external polling or event-listener indirection. The boot-time
one-shot sweeper handles legacy stuck entries without ongoing overhead.

## Sketch

```elixir
# lib/tau/memory/embedding_state.ex
defmodule Tau.Memory.EmbeddingState do
  @moduledoc """
  Finite state machine for the embedding lifecycle of a memory entry.

  States: :pending | :in_flight | :ready | :failed_transient | :failed_terminal
  Events: :dispatch | :succeeded | {:failed, :transient} | {:failed, :terminal} | :retry

  Transitions:
    :pending       + :dispatch           -> :in_flight
    :in_flight     + :succeeded          -> :ready
    :in_flight     + {:failed, :transient} -> :failed_transient
    :in_flight     + {:failed, :terminal} -> :failed_terminal
    :failed_transient + :retry           -> :in_flight   (re-dispatches embed)
    :pending       + :retry              -> :in_flight   (handles stuck-pending)
  """

  @type state :: :pending | :in_flight | :ready | :failed_transient | :failed_terminal
  @type event :: :dispatch | :succeeded | {:failed, :transient | :terminal} | :retry

  @spec transition(state(), event()) :: {:ok, state()} | {:error, :invalid_transition}
  def transition(:pending, :dispatch),                 do: {:ok, :in_flight}
  def transition(:in_flight, :succeeded),              do: {:ok, :ready}
  def transition(:in_flight, {:failed, :transient}),   do: {:ok, :failed_transient}
  def transition(:in_flight, {:failed, :terminal}),    do: {:ok, :failed_terminal}
  def transition(:failed_transient, :retry),           do: {:ok, :in_flight}
  def transition(:pending, :retry),                    do: {:ok, :in_flight}
  def transition(_state, _event),                      do: {:error, :invalid_transition}

  @spec retriable?(state()) :: boolean()
  def retriable?(:failed_transient), do: true
  def retriable?(:pending),          do: true
  def retriable?(_),                 do: false
end

# In Store.SQLite — new internal API replacing direct do_mark_embedding_failed calls:
defp apply_embedding_event(db, entry_id, event, embedder, server) do
  with {:ok, current_state} <- do_get_embedding_state(db, entry_id),
       {:ok, next_state} <- EmbeddingState.transition(current_state, event) do
    :ok = do_set_embedding_state(db, entry_id, next_state)
    if next_state == :in_flight do
      # Re-dispatch is a side-effect of the transition, not a separate sweep
      :telemetry.execute([:tau, :memory, :retry_enqueue], %{}, %{entry_id: entry_id})
      embedder.embed(server, entry_id, do_get_content(db, entry_id))
    end
    {:ok, next_state}
  end
end

# The existing store_embedding/3 handle_call clauses become:
def handle_call({:store_embedding, entry_id, {:ok, _embedding}}, _from, state) do
  # ... (unchanged: calls do_store_embedding + update to 'ready')
end
def handle_call({:store_embedding, entry_id, {:error, kind, _reason}}, _from, %{db: db} = state) do
  embedder = Application.get_env(:tau, :embedder, Tau.Memory.EmbeddingWorker)
  result = apply_embedding_event(db, entry_id, {:failed, kind}, embedder, self())
  {:reply, result, state}
end

# Boot-time one-shot sweeper (simple Task, not supervised long-term):
# lib/tau/memory/supervisor.ex
children = [
  {Tau.Memory.Store.SQLite, opts},
  {Task, fn -> Tau.Memory.BootSweep.drain_stuck(opts) end}
]

# lib/tau/memory/boot_sweep.ex
defmodule Tau.Memory.BootSweep do
  def drain_stuck(opts) do
    store = Keyword.get(opts, :store, Tau.Memory.Store.SQLite)
    # Wait briefly for Store.SQLite to be ready
    Process.sleep(500)
    case Tau.Memory.Store.SQLite.list_retriable(store) do
      {:ok, entries} ->
        Enum.each(entries, fn %{id: id} ->
          Tau.Memory.Store.SQLite.apply_retry(store, id)
        end)
      _ -> :ok
    end
  end
end

# Store.SQLite gets a new public call for the boot sweeper:
@spec apply_retry(GenServer.server(), String.t()) :: {:ok, term()} | {:error, term()}
def apply_retry(server, entry_id) do
  GenServer.call(server, {:apply_retry, entry_id})
end
```

The `embedding_status` DB column's valid values remain strings (`"pending"`,
`"in_flight"`, `"ready"`, `"failed_transient"`, `"failed_terminal"`) — a migration
adds `"in_flight"` and `"failed_transient"` / `"failed_terminal"` to the valid set.
Existing `"failed"` rows with `embedding_error_kind: "transient"` are treated as
`"failed_transient"` by the boot sweep's SQL query.

## Tradeoffs

### Strengths

- Eliminates the polling/event-listener entirely for the ongoing case: the FSM
  makes re-enqueue an invariant of the `:failed_transient → :retry` transition,
  not a background job.
- The `EmbeddingState` module is pure and property-testable; the transition table
  is a complete specification of valid lifecycle paths.
- `"in_flight"` status becomes observable (currently `"pending"` is ambiguous
  between "waiting for dispatch" and "dispatch in progress"), resolving part of
  the `pending-rot-observability` concern as a side effect.
- Removes the metadata JSON field `embedding_error_kind` as the sole carrier of
  retryability; the DB column carries the classification directly.

### Weaknesses

- API-breaking: adds a DB migration for new status values and changes the semantics
  of existing `"failed"` rows. Any external tooling reading `embedding_status` must
  be updated.
- The boot-time sweeper uses `Process.sleep/1` to wait for `Store.SQLite` to be
  ready — fragile; the correct approach is a `GenServer.call` once the store is
  known to be registered, but timing this in a Task child is awkward.
- Increases Store.SQLite complexity: `apply_embedding_event/5` reads the current
  state, transitions, writes the new state, and possibly dispatches an embed — all
  inside a single GenServer message. If `embedder.embed/3` blocks (it should not,
  but stubs may), this stalls the store mailbox.
- The `EmbeddingState` FSM must be kept in sync with the DB migration; a mismatch
  (e.g. a new state added in code but not in the migration constraint) is a runtime
  failure.
- More code than the other proposals; higher review surface.

### Costs

- New module `EmbeddingState` (~50 LOC), new module `BootSweep` (~30 LOC),
  DB migration for new status values (~10 LOC SQL), changes to `Store.SQLite`
  (~50 LOC delta).
- Property tests for `EmbeddingState.transition/2` (strongly recommended: all
  valid transitions + all invalid transitions).
- Migration must handle the `"failed"` → `"failed_transient"` / `"failed_terminal"`
  split for existing rows (requires reading `embedding_error_kind` from metadata JSON).

## Dependencies

- Requires a DB migration (migration N+1 after the current highest): new
  `embedding_status` values and a backfill for existing `"failed"` rows.
- `list_retriable/1` still needed for the boot sweep.
- Finch name mismatch must be fixed before the boot sweep is useful.
- If `pending-rot-observability` introduces a `"stale_pending"` concept, it may
  need to align with the FSM state names introduced here.

## Confidence

low-medium — the FSM design is sound and the `EmbeddingState` module is straightforward.
Confidence is lowered by the migration complexity (backfilling `"failed"` rows from
JSON metadata) and the `BootSweep` timing fragility. A prototype of the migration
backfill query and a review of whether `embedder.embed/3` can ever block inside
`apply_embedding_event/5` would raise confidence to medium.

## Prior art / references

- `:gen_statem` (OTP): the canonical FSM abstraction; `EmbeddingState` is a pure
  functional version of its transition table.
- Oban job states (`available`, `executing`, `retryable`, `completed`, `discarded`):
  explicit DB-column FSM for job lifecycle — exact conceptual parallel.
- SPEC-MEMORY-STORE.md D-046: `embedding_status` invariant; the proposal extends
  its valid values.
- Erlang "let it crash" + FSM pattern: encoding recovery policy in the state machine
  rather than in ad-hoc error handlers is idiomatic BEAM design.
