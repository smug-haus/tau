---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Inject the Finch name via the EmbeddingWorker start argument

## Approach

Remove `Application.get_env/3` from `call_embedding_api/3` entirely. Instead,
make `EmbeddingWorker` (or its caller) receive the Finch pool name as an
explicit parameter at the point of invocation. `Tau.Memory.Supervisor` (or
`Tau.Memory.Store.SQLite`) passes `Tau.Providers.Finch` directly from the
supervision configuration; no config key exists or is needed.

## Rationale

`Application.get_env/3` introduces a hidden, runtime-only coupling: the caller
cannot see what pool name the function will use without reading the application
environment. Removing the env lookup and making the dependency explicit
(a passed argument) means the coupling is visible in the type signature and
testable without environment manipulation. This is behaviour-correcting AND
interface-changing: it replaces implicit global state with explicit data
flow — the Hickey principle of "separating values from place."

## Sketch

`EmbeddingWorker` exposes the pool name as a parameter:

```elixir
# lib/tau/memory/embedding_worker.ex

# Public entry point — callers supply finch_name explicitly
@spec embed(String.t(), String.t(), String.t(), atom()) ::
        {:ok, list(float())} | {:error, :transient | :terminal, term()}
def embed(url, api_key, content, finch_name) do
  # ... existing guard checks ...
  call_embedding_api(url, api_key, content, finch_name)
end

defp call_embedding_api(url, api_key, content, finch_name) do
  # finch_name is now a local parameter — no Application.get_env
  request = Finch.build(:post, url, headers, body)
  Finch.request(request, finch_name, receive_timeout: @request_timeout_ms)
  # ...
end
```

The caller (in `Tau.Memory.Store.SQLite` or wherever the Task is spawned)
passes the name from a module attribute or process state:

```elixir
# lib/tau/memory/store/sqlite.ex (call-site, schematic)
@finch_name Tau.Providers.Finch

# Inside handle_continue that dispatches the embedding task:
Task.Supervisor.async_nolink(Tau.Memory.TaskSupervisor, fn ->
  EmbeddingWorker.embed(url, api_key, content, @finch_name)
end)
```

The `@finch_name` attribute in `sqlite.ex` is the only place the concrete atom
appears; it is adjacent to the `Finch` pool start in `application.ex`, easy to
grep, and not hidden behind an env key.

## Tradeoffs

### Strengths

- Eliminates hidden global state: the dependency is visible in the function
  signature.
- Testable without manipulating application environment: pass any atom in tests.
- The concrete atom (`Tau.Providers.Finch`) appears in one file; no shared
  constant module required.
- Aligns with OTP non-negotiable §8: "pure functions are the default; processes
  are the exception" — a pure embedding function with explicit deps is simpler.

### Weaknesses

- API-breaking: every caller of `EmbeddingWorker.embed/3` (or `call_embedding_api/3`)
  must be updated to pass the name. If there are multiple call-sites this is
  more disruptive than Proposals 1 or 2.
- Does not prevent a caller from passing a stale atom; the drift problem moves
  from `embedding_worker.ex` to the caller(s).
- Slightly more verbose at call-sites compared to a zero-argument lookup.
- If a future requirement introduces multiple Finch pools (per-provider), this
  proposal handles that naturally — but that flexibility is speculative and not
  in scope.

### Costs

- Changes the public signature of `EmbeddingWorker.embed/N`; callers must be
  updated (currently appears to be one call-site in `sqlite.ex`).
- ~15–20 lines changed across 2 files.
- Tests that call `EmbeddingWorker` directly must pass the extra argument.
- No new files.

## Dependencies

- Requires identifying all call-sites of the embedding invocation path to update
  them (grep `EmbeddingWorker` and the Task dispatch in `sqlite.ex`).
- No library changes.

## Confidence

**Medium.** The pattern is sound and common in Elixir; uncertainty is about
the exact call-site count and whether the Task dispatch in `sqlite.ex` already
holds state that can supply the pool name, or requires a new init-time argument
to the GenServer.

What would raise it: reading `sqlite.ex`'s `init/1` and `handle_continue/2`
to confirm the call-site structure (read-only access is available; a quick
scan would settle this).

## Prior art / references

- Elixir idiom: dependency injection via function arguments is preferred over
  `Application.get_env/3` in unit-testable code; see
  `https://hexdocs.pm/elixir/testing.html#mocks-and-explicit-contracts`.
- Phoenix `Ecto.Repo` operations pass the repo module explicitly as an
  argument in multi-repo setups — the same decomplecting move.
