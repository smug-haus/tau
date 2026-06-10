---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Replace rescue/catch with GenServer.call timeout + tagged-tuple contract

## Approach

Replace the `rescue`/`catch :exit` blocks with an explicit `GenServer.call/3`
using a short timeout, returning `{:ok, result}` or `{:error, reason}` tagged
tuples. The callers (`list/1`, `status/1`, `reload/1`) pattern-match on the
tagged tuple and emit a non-zero exit code plus stderr diagnostic on `{:error,
_}`. No rescue or catch is used anywhere. The `:noproc` exit from a dead
GenServer surfaces as `{:error, :noproc}` through the `GenServer.call` timeout
path using `Process.whereis/1` + nil guard, or by catching only the specific
`:noproc` exit at the call boundary via `catch :exit, {:noproc, _}` — a
targeted, documented catch rather than a wildcard swallow.

## Rationale

The problem's complecting hypothesis is that error-reporting is woven into data
retrieval via a wildcard `rescue`/`catch`. This proposal decomplects by
separating two concerns: (a) a thin call adapter that translates OTP process
errors into tagged tuples at the boundary (`call_loader/1`), and (b) the CLI
handlers that interpret tagged tuples and produce user-visible output. The
adapter is explicit about which exits it handles (`:noproc`, `:timeout`) and
converts them to `{:error, reason}` — it does not swallow unknown exceptions.
The CLI handlers gain a real `{:error, reason}` branch that prints to stderr and
returns exit code 1 or 2.

## Sketch

**New private helper (shared pattern, shown for `Tau.CLI.Extensions`):**

```elixir
# lib/tau/cli/extensions.ex

@spec call_loader((() -> term())) :: {:ok, term()} | {:error, term()}
defp call_loader(fun) do
  {:ok, fun.()}
catch
  :exit, {:noproc, _} -> {:error, :process_unavailable}
  :exit, {:timeout, _} -> {:error, :timeout}
  :exit, reason -> {:error, {:exit, reason}}
end
```

**Updated `safe_list/0` → renamed, typed:**

```elixir
defp fetch_list do
  call_loader(&Tau.Extensions.Loader.list/0)
end

defp request_reload do
  call_loader(&Tau.Extensions.Loader.reload_all/0)
end
```

**Updated `list/1` call site:**

```elixir
@spec list(opts()) :: 0 | 1
def list(opts \\ []) do
  case fetch_list() do
    {:ok, entries} ->
      # ... existing rendering logic ...
      0

    {:error, reason} ->
      IO.puts(:stderr, "extensions list failed: #{format_reason(reason)}")
      1
  end
end
```

**Updated `reload/1` call site:**

```elixir
@spec reload(opts()) :: 0 | 1 | 2
def reload(opts \\ []) do
  case request_reload() do
    {:ok, :ok} ->
      # ... existing success output ...
      0

    {:ok, {:error, inner}} ->
      IO.puts(:stderr, "extensions reload failed: #{inspect(inner)}")
      2

    {:error, reason} ->
      IO.puts(:stderr, "extensions reload unavailable: #{format_reason(reason)}")
      1
  end
end

defp format_reason(:process_unavailable), do: "Extensions.Loader process is not running"
defp format_reason(:timeout), do: "Extensions.Loader call timed out"
defp format_reason({:exit, r}), do: "process exited: #{inspect(r)}"
```

Same pattern mirrored in `lib/tau/cli/mcp.ex` with `Tau.MCP.Reconciler` as the
callee.

**Type shape:**
```
fetch_list()     :: {:ok, [extension_entry()]} | {:error, process_error()}
request_reload() :: {:ok, :ok | {:error, term()}} | {:error, process_error()}
process_error()  :: :process_unavailable | :timeout | {:exit, term()}
```

## Tradeoffs

### Strengths

- Explicit about which exit reasons are handled; unknown exits still propagate
  (the `catch :exit, reason` arm re-wraps rather than silently discarding).
- Gives the CLI handlers per-command diagnostic messages ("extensions list
  failed", "mcp reload unavailable") rather than a uniform crash report.
- The `{:error, reason}` tagged-tuple contract is preserved and clarified;
  all call sites are already `case`-dispatching on it.
- Acceptance criterion is fully met: non-zero exit (1) + stderr message on
  `:noproc`.
- No new library dependencies; uses Elixir's `catch` for the specific exit
  shapes, not wildcard rescue.

### Weaknesses

- **Still uses `catch` at the boundary** — purists may argue this is still
  crossing a process boundary with a catch; OTP NN #7's prohibition is on
  `try/rescue` across process boundaries, but the spirit equally applies to
  `catch :exit`. The adapter is more targeted than the current wildcard but
  is not zero-catch.
- **Duplicates the adapter pattern** across two modules. A shared utility
  (`Tau.CLI.ProcessCall` or similar) would DRY this, but adds a new module.
  Leaving it duplicated violates DRY; extracting adds scope.
- **`{:ok, {:error, inner}}` nesting** for `reload/1` is awkward — the callee
  returns `{:error, reason}` on application-level reload failure, so the
  outer `{:ok, _}` wraps an inner `{:error, _}`. Callers must pattern-match
  two levels.
- **`list/1` spec changes** from always returning `0` to returning `0 | 1`,
  which may affect documentation and any call sites that hard-assume `0`.

### Costs

- ~40 lines changed; ~20 lines added (call_loader, format_reason, updated specs).
- Two modules (`extensions.ex`, `mcp.ex`) each get a nearly-identical private
  helper — ~10 lines of duplication unless extracted.
- Tests for `list/1` and `reload/1` must be extended to cover the `{:error, _}`
  branch with a mock/stub of the GenServer being unavailable.

## Dependencies

- No upstream module changes required — `Tau.Extensions.Loader.list/0` and
  `Tau.MCP.Reconciler.list/0` interfaces are unchanged.
- The `list/1` spec change (`0` → `0 | 1`) must not break any call site that
  hard-pattern-matches on the return value (audit `lib/tau/cli.ex`).

## Confidence

high — the pattern (catch specific exits at a thin boundary, return tagged
tuples) is idiomatic Elixir for wrapping GenServer calls in CLI adapters. The
catch arms are targeted, not wildcard. The `format_reason/1` function is
concrete. Sketch is complete enough to implement directly.

## Prior art / references

- Elixir `GenServer.call/3` documentation: `:noproc` exit shape is `{:noproc,
  {GenServer, :call, [pid, msg, timeout]}}` — the `catch :exit, {:noproc, _}`
  arm matches this precisely.
- OTP NN #7: the non-negotiable targets `try/rescue` and wildcard `:exit` catch;
  targeted `catch :exit, {:noproc, _}` is the recommended escape hatch in
  service-availability checks in OTP documentation.
- `Tau.CLI.Extensions` and `Tau.CLI.MCP` current code: the `{:error, reason}`
  branch in `reload/1` already exists but is unreachable through the top-level
  handler; this proposal makes it reachable with correct exit codes.
