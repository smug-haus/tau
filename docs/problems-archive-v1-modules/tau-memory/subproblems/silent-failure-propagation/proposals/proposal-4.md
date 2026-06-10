---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Redefine the `Tau.Memory.Embedder` Callback to Return a Result Directly

## Approach

Change the `Tau.Memory.Embedder` behaviour so that `embed/3` returns `{:ok, result} |
{:error, kind, reason}` synchronously (renaming to `embed_result/3` or changing the
return contract), and move the `store_embedding/3` callback responsibility into
`Store.SQLite.handle_continue/2` rather than the embedder. The embedder no longer
calls back into the store; instead `handle_continue/2` awaits the result via
`Task.Supervisor.async_nolink` + explicit `await_with_timeout`, or better: spawns the
Task, stores the ref, and handles both `{ref, result}` (success with result value) and
`{:DOWN, ref, ...}` (crash) in `handle_info` — both paths calling the store-update logic
directly. The `{ref, result}` clause receives the actual embedding result (not discarded
as today) and calls `do_store_embedding` or `do_mark_embedding_failed`. The
`{:DOWN, ...}` clause calls `do_mark_embedding_failed`. This is a data-shape change: the
embedder's output is a plain value, not a side-effecting callback, eliminating the
inversion-of-control that currently makes the crash unobservable.

## Rationale

The current design is an inversion-of-control: the Store dispatches a Task, and the Task
calls back into the Store to write its result. This inversion is the architectural source
of the complect: the Store has no way to observe "Task crashed before calling back"
because the callback is the only signal. This proposal eliminates the inversion entirely
by making the embedder a pure function (async, but with a structured result return) and
the Store the sole writer. The `(ref → entry_id)` map is still needed (as in Proposal 1),
but the `{ref, result}` clause now receives the actual result rather than discarding it.
The crash path (`{:DOWN, ...}`) gains the same ref-map lookup as Proposal 1 but the
success path no longer relies on a separate GenServer call from the worker — the result
arrives in the message itself. This removes the inversion-of-control entirely, trading
the callback API for a structured-return API.

## Sketch

```elixir
# New Tau.Memory.Embedder behaviour (API-breaking change):
defmodule Tau.Memory.Embedder do
  @moduledoc "Behaviour for computing embedding vectors."

  @callback embed_async(String.t()) ::
    {:ok, Task.t()} |
    {:error, term()}
  # embed_async/1 starts a Task whose return value is:
  #   {:ok, [float()]} | {:error, :transient | :terminal, term()}
  # The Task result is sent to the calling process as {ref, result}.
  # The embedder does NOT call store_embedding/3.
end

# EmbeddingWorker updated:
@impl Tau.Memory.Embedder
def embed_async(content) do
  task =
    Task.Supervisor.async_nolink(Tau.Tools.TaskSupervisor, fn ->
      do_embed(content)
      # Returns {:ok, [float()]} or {:error, kind, reason}
      # No call to MemoryStore.store_embedding/3
    end)
  {:ok, task}
end
```

```elixir
# Store.SQLite state:
@type state :: %{db: reference(), pending_tasks: %{reference() => String.t()}}

# handle_continue — store ref:
def handle_continue({:dispatch_embedding, id, content}, state) do
  embedder = Application.get_env(:tau, :embedder, Tau.Memory.EmbeddingWorker)
  {:ok, task} = embedder.embed_async(content)
  {:noreply, put_in(state, [:pending_tasks, task.ref], id)}
end

# handle_info — success path (result IS the embedding or error):
def handle_info({ref, embed_result}, %{db: db, pending_tasks: pt} = state)
    when is_reference(ref) do
  Process.demonitor(ref, [:flush])
  state = update_in(state, [:pending_tasks], &Map.delete(&1, ref))

  case Map.fetch(pt, ref) do
    {:ok, entry_id} ->
      case embed_result do
        {:ok, embedding} -> do_store_embedding(db, entry_id, embedding)
        {:error, kind, reason} -> do_mark_embedding_failed(db, entry_id, kind)
      end
    :error -> :ok
  end

  {:noreply, state}
end

# handle_info — crash path:
def handle_info({:DOWN, ref, :process, _pid, reason}, %{db: db, pending_tasks: pt} = state)
    when reason != :normal do
  case Map.fetch(pt, ref) do
    {:ok, entry_id} ->
      do_mark_embedding_failed(db, entry_id, :transient)
      {:noreply, update_in(state, [:pending_tasks], &Map.delete(&1, ref))}
    :error ->
      {:noreply, state}
  end
end

def handle_info({:DOWN, _ref, :process, _pid, :normal}, state), do: {:noreply, state}
```

`MemoryStore.store_embedding/3` public function and `handle_call({:store_embedding, ...})`
clause become internal or are removed (no external caller after this change).

## Tradeoffs

### Strengths

- Eliminates the inversion-of-control entirely; the Store is the sole writer of
  embedding results, which is the most principled fix for the complect.
- The `{ref, result}` message carries the actual result as a value — no silent discard,
  no fire-and-forget, no cross-process callback.
- The success and crash paths are now symmetric in the `handle_info` handler, making the
  code easier to reason about.
- Satisfies the acceptance criterion for all abnormal exits, not just `:noproc` crashes.
- `MemoryStore.store_embedding/3` public API, which exposes the DB reference indirectly,
  can be removed — reducing the API surface.

### Weaknesses

- **API-breaking change** to `Tau.Memory.Embedder`: the current `embed/3` callback
  (which takes `store` as an argument and calls back into it) is replaced. All embedder
  implementations and all consumers that call `embed/3` must be updated. This is a wider
  change than Proposals 1 or 3.
- The double-ref problem: `EmbeddingWorker` currently dispatches its OWN inner Task
  (line 51 of `embedding_worker.ex`). Under this proposal, the new `embed_async/1` would
  still need to use `async_nolink` so its Task ref can be forwarded to the Store's
  `handle_info`. But `Task.Supervisor.async_nolink` sends the result to the process that
  called it — if `embed_async/1` is called inside `handle_continue`, the result goes to
  the GenServer's mailbox, which is correct. If `embed_async/1` returns the Task, the
  ref is from the inner Task; the outer `handle_continue` gets the inner Task's ref.
  This requires careful review of the call chain to ensure the ref is the one that
  delivers `{ref, result}` to the GenServer's mailbox.
- The `store_embedding/3` public API, currently used in `embedding_worker.ex` at line 57,
  becomes dead code. Removing it is correct hygiene but widens the change scope.
- `do_store_embedding/3` is currently called from `handle_call`, not `handle_info`;
  this change moves the write to `handle_info`, which changes the call ordering
  semantics (writes are now processed asynchronously from the perspective of the
  `handle_continue` caller).

### Costs

- `Tau.Memory.Embedder` behaviour: 1 callback renamed/changed.
- `EmbeddingWorker`: `embed/3` body rewritten; `store_embedding` call removed.
- `Store.SQLite`: `handle_continue`, 2 `handle_info` clauses, state type updated;
  `handle_call({:store_embedding, ...})` clause removed.
- `MemoryStore.store_embedding/3` public function: removed or deprecated.
- All test doubles that implement `Tau.Memory.Embedder` must be updated.
- Test surface: larger than Proposal 1; the success path `handle_info` change requires
  regression testing. Estimated 3–4 new test cases; 1–2 existing tests modified.

## Dependencies

- `Tau.Memory.Embedder` behaviour amendment must land before any embedder update.
- All test doubles and mock embedders in `test/` must be updated.
- The `embedding_worker.ex` inner-Task layering must be resolved: either flatten to
  a single Task or clearly route the inner ref back to the GenServer's mailbox.

## Confidence

Medium. The design is more principled than Proposal 1 but the API surface impact is
wider and the Task-ref routing requires careful implementation. Confidence would rise
to high after a prototype that verifies `{ref, result}` delivery to the GenServer's
mailbox when `embed_async/1` is called from `handle_continue`.

## Prior art / references

- The "return a value, don't call back" pattern is the idiomatic Elixir preference for
  simple result communication: Elixir `Task.async/1` + `Task.await/2` is the canonical
  form; `async_nolink` + `handle_info` is the fire-and-forget equivalent where the
  GenServer must not block.
- OTP design principle: side-effectful callbacks between peer processes increase coupling;
  result-bearing messages decrease it. Source: Erlang/OTP Design Principles §"gen_server".
- Hickey's "Simple Made Easy": inversion-of-control is a form of complecting (the
  callback caller must know the callee's state); returning a value removes that knowledge
  requirement.
