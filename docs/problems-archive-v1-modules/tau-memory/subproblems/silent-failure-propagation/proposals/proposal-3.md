---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Introduce a `Tau.Memory.EmbeddingTask` Supervised Process per Entry

## Approach

Replace the fire-and-forget `Task.Supervisor.async_nolink` dispatch with a dedicated
`Tau.Memory.EmbeddingTask` GenServer (or `:gen_statem`) that is started under a
`DynamicSupervisor` per entry. The `EmbeddingTask` process owns one embedding attempt:
it holds `{store_pid, entry_id, content}` as its state, performs the embedding call,
delivers the callback on success, and — on crash or restart — its `terminate/2` callback
calls `MemoryStore.store_embedding(store, entry_id, {:error, :transient, :task_crashed})`
before exiting. The `DynamicSupervisor` uses `:temporary` restart strategy so the process
is not restarted on crash (retry is handled by the separate `retry-recovery-path`
sub-problem). The `Store.SQLite` GenServer no longer dispatches Tasks directly and holds
no ref map; it starts a supervised `EmbeddingTask` child instead.

## Rationale

This proposal elevates the task identity concern to the supervision level: each in-flight
embedding is a named entity in the OTP supervision tree. The `(ref → entry_id)` mapping
is no longer a map in a GenServer's state — it is the process identity itself. The crash
path is handled by OTP's built-in `terminate/2` callback, which is called on any exit
(normal or abnormal), eliminating the "crash without callback" case at the process
lifecycle level rather than by intercepting messages. This directly satisfies OTP
non-negotiable rule 1 ("every stateful subsystem is a process under a supervisor") in a
way the current fire-and-forget pattern does not.

## Sketch

```elixir
# New file: lib/tau/memory/embedding_task.ex

defmodule Tau.Memory.EmbeddingTask do
  @moduledoc """
  A `:temporary` supervised process that owns one embedding attempt.

  On normal completion it calls `MemoryStore.store_embedding/3` with the result.
  On abnormal exit `terminate/2` is called by the runtime; we use it to mark the
  entry `"failed"` so the entry never remains stuck `"pending"`.
  """
  use GenServer, restart: :temporary

  alias Tau.Memory.MemoryStore

  def start_link({store, entry_id, content, embedder}) do
    GenServer.start_link(__MODULE__, {store, entry_id, content, embedder})
  end

  @impl GenServer
  def init({store, entry_id, content, embedder}) do
    # Use handle_continue so init/1 returns fast, keeping the supervisor unblocked.
    {:ok, %{store: store, entry_id: entry_id, content: content, embedder: embedder},
     {:continue, :embed}}
  end

  @impl GenServer
  def handle_continue(:embed, %{store: store, entry_id: id, content: c, embedder: e} = state) do
    result = e.embed_sync(c)        # synchronous variant — see note below
    MemoryStore.store_embedding(store, id, result)
    {:stop, :normal, state}
  end

  @impl GenServer
  def terminate(reason, %{store: store, entry_id: id})
      when reason not in [:normal, :shutdown] do
    MemoryStore.store_embedding(store, id, {:error, :transient, {:task_crashed, reason}})
  end

  def terminate(_reason, _state), do: :ok
end
```

```elixir
# New file: lib/tau/memory/embedding_supervisor.ex

defmodule Tau.Memory.EmbeddingSupervisor do
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def dispatch(store, entry_id, content, embedder) do
    DynamicSupervisor.start_child(__MODULE__,
      {EmbeddingTask, {store, entry_id, content, embedder}})
  end
end
```

```elixir
# Store.SQLite.handle_continue/2 updated:
def handle_continue({:dispatch_embedding, id, content}, state) do
  embedder = Application.get_env(:tau, :embedder, Tau.Memory.EmbeddingWorker)
  Tau.Memory.EmbeddingSupervisor.dispatch(self(), id, content, embedder)
  {:noreply, state}
end
```

`EmbeddingSupervisor` is added to `Tau.Memory.Supervisor`'s child list before `Store.SQLite`.

**Note on `embed_sync/1`**: The current `EmbeddingWorker.embed/3` is designed as a
fire-and-forget Task launcher; this proposal needs a synchronous variant. The embedder
behaviour gains an `embed_sync/1` callback returning `{:ok, embedding}` or
`{:error, kind, reason}`. `EmbeddingWorker` implements it. The existing `embed/3` can be
deprecated or wrapped to call `embed_sync`.

## Tradeoffs

### Strengths

- Fully OTP-idiomatic: each in-flight embedding is a supervised process. Crash recovery
  semantics are defined at the supervision level, not via message interception.
- `terminate/2` is called by the runtime on abnormal exits; this is the OTP-sanctioned
  place for "cleanup on crash" logic, avoiding `try/rescue`.
- No ref-map in GenServer state; no complex `handle_info` matching.
- Introspectable: `DynamicSupervisor.which_children/1` lists all in-flight embeddings.
- Satisfies OTP non-negotiables 1 and 7 simultaneously.
- The `EmbeddingTask` process can be extended later to support retry (sub-problem 4)
  without changing `Store.SQLite`.

### Weaknesses

- `terminate/2` is called by the runtime only if the process was started with
  `trap_exit: true` OR if the process is terminating normally. For an abnormal exit
  (e.g., killed by a linked process), `terminate/2` is NOT guaranteed to be called
  unless `Process.flag(:trap_exit, true)` is set in `init/1`. Without that flag,
  a hard kill skips `terminate/2` — the same stuck-`"pending"` scenario survives.
  Adding `trap_exit` changes the process's exit semantics and must be explicit.
- Requires a new `embed_sync/1` behaviour callback — an API-breaking change to
  `Tau.Memory.Embedder`. All embedder implementations (including test doubles) must
  be updated.
- A new supervised process per entry adds BEAM process overhead. Under high write
  throughput this is `O(concurrent embeddings)` extra processes. Normally bounded and
  cheap, but a potential concern at extreme load.
- Adds two new files and a supervision tree entry: higher structural complexity than
  Proposals 1 or 2 for the same acceptance criterion.
- The `DynamicSupervisor` entry in `Tau.Memory.Supervisor` must come before
  `Store.SQLite` to avoid a startup race; ordering matters and is easy to get wrong.

### Costs

- 2 new modules (`EmbeddingTask`, `EmbeddingSupervisor`).
- `Tau.Memory.Embedder` behaviour gains 1 new callback.
- `EmbeddingWorker` gains 1 new function.
- `Tau.Memory.Supervisor` child list updated.
- `Store.SQLite.handle_continue/2` simplified.
- Test surface: `EmbeddingTask` needs unit tests for normal exit, crash exit, and
  the `terminate/2` → store callback path. Estimated 3–5 new test cases.

## Dependencies

- `Tau.Memory.Embedder` behaviour must be amended before any embedder can implement
  `embed_sync/1`.
- `Tau.Memory.Supervisor` must be updated to start `EmbeddingSupervisor` before
  `Store.SQLite`.
- All test doubles (`MockEmbedder`, etc.) must implement `embed_sync/1`.

## Confidence

Medium. The pattern is OTP-idiomatic but requires the `trap_exit` caveat to be
resolved and a behaviour API change. Confidence would rise to high after: (1) confirming
`trap_exit: true` in `init/1` is acceptable and (2) prototyping the `terminate/2`
path in a test.

## Prior art / references

- `terminate/2` for crash-state cleanup is used in `Tau.Memory.Store.SQLite` itself
  (lines 317–322) to close the DB connection on exit.
- `DynamicSupervisor` per-entity child pattern: Elixir docs §"DynamicSupervisor" and
  José Valim's "Elixir in Action" chapter on dynamic process management.
- `Process.flag(:trap_exit, true)` requirement for `terminate/2` on abnormal exits:
  Erlang/OTP documentation §"gen_server:terminate".
- `Tau.CircuitBreaker.Store` in this project uses a GenServer with `trap_exit` to
  manage monitored pids and call cleanup on exit.
