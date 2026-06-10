---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Ref-to-ID Map in GenServer State

## Approach

Extend the `Store.SQLite` GenServer state with a `%{reference() => String.t()}` map that
records the task `ref → entry_id` association at dispatch time. The `handle_continue/2`
clause stores the ref returned by `Task.Supervisor.async_nolink/2`. The `{:DOWN, ref, ...}`
clause looks up the entry ID and calls `do_mark_embedding_failed/3` with `:transient`
if the reason is not `:normal`. The `{ref, result}` (success) clause demonitors and
removes the entry from the map; it does not change status because the callback already
handled that via `store_embedding/3`.

## Rationale

The complecting hypothesis names exactly this missing mapping as the root structural gap:
"the store holds no `(ref → entry_id)` mapping, so it cannot act on a `{:DOWN, ...}` message."
This proposal decomplects task identity from entry identity by making the association
explicit in state. The "task crashed" path gains its own `handle_info/2` clause body
instead of sharing the silent discard with the "task result delivered" path, resolving the
second complect. The change is minimal and entirely within `Store.SQLite`; no interface
changes and no new processes.

## Sketch

```elixir
# State type extended:
@type state :: %{db: reference(), pending_tasks: %{reference() => String.t()}}

# init/1 initialisation (add field):
{:ok, %{db: db, pending_tasks: %{}}}

# handle_continue — store ref:
def handle_continue({:dispatch_embedding, id, content}, state) do
  embedder = Application.get_env(:tau, :embedder, Tau.Memory.EmbeddingWorker)
  server = self()

  task =
    Task.Supervisor.async_nolink(Tau.Tools.TaskSupervisor, fn ->
      embedder.embed(server, id, content)
    end)

  {:noreply, put_in(state, [:pending_tasks, task.ref], id)}
end

# handle_info — success path (remove from map, demonitor):
def handle_info({ref, _result}, state) when is_reference(ref) do
  Process.demonitor(ref, [:flush])
  {:noreply, update_in(state, [:pending_tasks], &Map.delete(&1, ref))}
end

# handle_info — crash path (look up id, mark failed):
def handle_info({:DOWN, ref, :process, _pid, reason}, %{db: db, pending_tasks: pt} = state) do
  state =
    case Map.fetch(pt, ref) do
      {:ok, entry_id} when reason != :normal ->
        do_mark_embedding_failed(db, entry_id, :transient)
        update_in(state, [:pending_tasks], &Map.delete(&1, ref))

      {:ok, entry_id} ->
        # :normal exit — callback already fired via store_embedding/3; just clean up
        update_in(state, [:pending_tasks], &Map.delete(&1, ref))

      :error ->
        # ref not ours (shouldn't happen with async_nolink, but safe)
        state
    end

  {:noreply, state}
end
```

No change to `EmbeddingWorker`. No change to public API. The `do_mark_embedding_failed/3`
function already exists at line 286 and handles the DB write; this proposal simply calls
it from the crash path.

## Tradeoffs

### Strengths

- Minimal: the map adds ~20 bytes per in-flight task; the change is entirely internal to
  the GenServer with no API surface impact.
- Directly addresses both complects named in the problem statement.
- `do_mark_embedding_failed/3` is already implemented and tested; no new DB logic.
- Behaviour-preserving on the success path; only the crash path changes observable state.
- The state is bounded: a Task crash removes its entry; no leak.

### Weaknesses

- The map is in-process heap; if the GenServer itself crashes while tasks are in-flight,
  the map is lost and entries revert to stuck-`"pending"`. (This is a separate survivability
  concern beyond the problem's acceptance criterion, but it is a real gap.)
- If the embedder's `embed/3` spawns its OWN inner Task (as `EmbeddingWorker.embed/3`
  currently does at line 51 of `embedding_worker.ex`), the outer Task ref tracked here
  will see a `:normal` exit when the inner Task finishes, even if the inner Task crashed.
  The outermost Task body then succeeds without calling `store_embedding/3` — the ref map
  sees `:normal` and removes cleanly but the entry is still `"pending"`. This means the
  proposal is only correct when the embedder's Task body crashes before the inner spawn,
  not if it crashes inside the inner body. The `EmbeddingWorker` double-spawn layering
  must be audited before this proposal is safe.
- The `handle_info` for `{ref, result}` currently discards `_result` even on the success
  path. If a future embedder returns an error in `result` rather than calling back, this
  clause silently drops it — a latent gap this proposal does not address.

### Costs

- 1 state field added; `init/1` and 3 `handle_info`/`handle_continue` clauses touched.
- No migration. No API change. No dependency change.
- Test surface: the crash path via `{:DOWN, ...}` requires a test that kills a task ref
  and asserts the DB row transitions to `"failed"`. Estimated 1 new test case.

## Dependencies

- Verify `EmbeddingWorker.embed/3`'s inner-Task layering: if the outer Task body catches
  the inner crash and calls `store_embedding/3` with `{:error, :transient, ...}`, the
  callback fires normally and no `{:DOWN, abnormal}` message reaches the GenServer. In
  that case this proposal is a safety net that is never triggered — which is fine. If the
  outer body can crash before calling back, this proposal is the only guard.
- No other modules need to change.

## Confidence

Medium. The mapping logic is straightforward and the existing `do_mark_embedding_failed/3`
is reused. Confidence would rise to high after: (1) tracing the `EmbeddingWorker` inner-Task
layering to confirm crash propagation, and (2) a unit test that explicitly kills the Task
and asserts DB status.

## Prior art / references

- The `Task.Supervisor.async_nolink` + ref-tracking pattern is the idiomatic Elixir
  solution for tracking fire-and-forget tasks: Elixir docs §"Task.Supervisor.async_nolink".
- `GenServer` state map for ref tracking: used in `Tau.CircuitBreaker.Store` (`lib/tau/circuit_breaker/store.ex`) to manage monitored owner refs.
- The `do_mark_embedding_failed/3` call already present at `sqlite.ex:286` (called from
  `handle_call` success path) is direct prior art for the write operation.
