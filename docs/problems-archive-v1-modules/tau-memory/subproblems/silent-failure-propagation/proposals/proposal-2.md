---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Wrap Embedder Dispatch in a Linked Task with After-Rescue Callback

## Approach

Change the `embedder.embed/3` contract so that the embedder is responsible for
guaranteeing a callback under all exit conditions. Concretely: replace
`Task.Supervisor.async_nolink` in `handle_continue/2` with a `Task.Supervisor.start_child`
(fire-and-forget, linked to the supervisor, not the GenServer) whose body wraps
`embedder.embed/3` in a `try/rescue/catch` that calls `MemoryStore.store_embedding/3` with
`{:error, :transient, exception_reason}` on any exception or exit. The `handle_info`
clauses for `{ref, ...}` and `{:DOWN, ...}` remain simple discards. No ref map in GenServer
state. The callback guarantee is pushed into the caller site of `embed/3`, not the
GenServer's message handler.

## Rationale

This proposal decomplects the problem differently from Proposal 1: instead of adding
observability to the crash path in the GenServer, it eliminates the crash-without-callback
case by making the wrapper unconditionally deliver a result. The two complects are
resolved by (a) making the wrapper the identity link between task and entry ID (the
wrapper's closure holds `entry_id`), and (b) ensuring the "task crashed" and "task
succeeded" paths both terminate by calling `store_embedding/3`. The GenServer's
`handle_info` for `:DOWN` truly becomes a no-op because no crash escapes the wrapper
without first calling back. The `Store.SQLite` GenServer retains no task-identity state,
keeping its state shape simple.

## Sketch

```elixir
# In Store.SQLite.handle_continue/2 — replace async_nolink with a wrapped child:
def handle_continue({:dispatch_embedding, id, content}, state) do
  embedder = Application.get_env(:tau, :embedder, Tau.Memory.EmbeddingWorker)
  server = self()

  Task.Supervisor.start_child(Tau.Tools.TaskSupervisor, fn ->
    try do
      embedder.embed(server, id, content)
    rescue
      e ->
        MemoryStore.store_embedding(server, id, {:error, :transient, Exception.message(e)})
    catch
      :exit, reason ->
        MemoryStore.store_embedding(server, id, {:error, :transient, {:exit, reason}})
    end
  end)

  {:noreply, state}
end

# handle_info clauses remain exactly as they are (silent discards).
# No state field added.
```

`EmbeddingWorker.embed/3` is unchanged. The wrapper is the "outer" task that the GenServer
dispatches; it already holds `entry_id` in its closure, giving the mapping without a
map in state.

The `MemoryStore.store_embedding/3` call in the rescue/catch block is the same call that
the normal success path makes, routed through `handle_call({:store_embedding, ...})` which
calls `do_mark_embedding_failed/3` for error tuples.

## Tradeoffs

### Strengths

- The GenServer state remains `%{db: reference()}` with no added fields — simpler state.
- Unconditional callback guarantee: even a BEAM-level exit (`exit(:kill)`) from outside
  the task will not be caught by `rescue/catch`, but a `:noproc` error (the actual failure
  mode) raises a regular exception and IS caught.
- No ref-map bookkeeping; the closure already binds `entry_id`.
- The `handle_info` clauses require no change — they correctly remain discards because
  no abnormal `:DOWN` will carry an unhandled entry ID.

### Weaknesses

- Using `try/rescue` across a process boundary is prohibited by OTP non-negotiable rule 7
  ("MUST NOT `try/rescue` across process boundaries. MUST NOT catch `:exit`"). This
  proposal violates that rule — the `rescue/catch` block is inside the child Task and
  calls back into the GenServer (`MemoryStore.store_embedding/3`) across the process
  boundary. The rule exists precisely to prevent this pattern. Adopting this proposal
  requires a written justification in the PR or an amendment to the non-negotiable rule.
- An unconditional `:exit, reason` catch in the child task means that even intentional
  supervisor shutdown signals are caught and result in a spurious `"failed"` callback to
  the GenServer. A `when reason != :normal` guard on the catch helps but is not complete
  (shutdown exits use `:shutdown`, not `:normal`).
- The double-spawn layering from `EmbeddingWorker.embed/3` (which also uses
  `Task.Supervisor.async_nolink` internally) means the inner crash may not propagate to
  the outer wrapper's `try` block — the inner Task's crash is caught by its own supervisor,
  not propagated as an exception to the outer body. The wrapper only catches crashes in
  the outer task body itself (i.e., failures before the inner spawn or failures in code
  path between the outer Task body entry and the inner spawn call).
- This approach conflates "transient embedding failure" with "any exception inside the
  wrapper" — including bugs in the embedder code — and marks all of them as
  `:transient`. A bug-triggered status of `"failed: transient"` implies retryability
  when the real cause may require a code fix.

### Costs

- 1 `handle_continue` clause changed; 0 new state fields; 0 new clauses.
- `try/rescue/catch` requires explicit OTP non-negotiable rule exception justification
  in the PR — a non-trivial gate review item.
- Test surface: needs a test where `embedder.embed/3` raises and verifies the entry
  transitions to `"failed"`. Estimated 1 new test case.

## Dependencies

- The OTP non-negotiable rule 7 as written in `otp-non-negotiables.md` must either
  grant an exception or be amended for this proposal to pass the critic gate.
- The `EmbeddingWorker.embed/3` double-spawn layering needs to be audited to confirm
  whether the inner crash reaches the outer `rescue` block.

## Confidence

Low. The OTP non-negotiable rule violation is a hard gate blocker. The double-spawn
layering issue may mean the safety net does not fire for the primary failure mode. Would
require rule amendment + layering audit to reach medium.

## Prior art / references

- The rule conflict is documented in `otp-non-negotiables.md` rule 7.
- The "wrap with rescue for guaranteed delivery" pattern is used in Elixir's `GenStage`
  dispatcher examples, but specifically avoids cross-process calls inside the rescue block.
- Elixir `Task.Supervisor.start_child/2` docs: fire-and-forget variant, linked to the
  supervisor not the caller.
